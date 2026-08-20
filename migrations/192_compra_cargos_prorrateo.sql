-- ============================================================================
-- 192 · Compras: cargos prorrateados y cuadre fiscal
-- ============================================================================
-- Ver docs/plans/2026-08-18-cargos-y-cuadre-de-compras.md
--
-- Tres cosas que la carga de compras no sabía representar:
--   · flete, pallets y separadores (el 16,2% del costo de la factura testigo)
--   · que el reparto es por volumen, no por monto, y a veces sólo a un subconjunto
--   · que NO toda bonificación baja la base del impuesto interno
--
-- El "alcance" no es un concepto: un peso 0 excluye la línea. Y una bonificación
-- es un cargo de monto negativo. Por eso alcanza con una sola tabla.
--
-- Forward-only: las compras existentes no tienen cargos ⇒ Σ cargos = 0 ⇒ el
-- costo es idéntico al de hoy. Cero backfill.
--
-- Terminó siendo la 192 después de perder el número TRES veces, y conviene que
-- quede contado porque a la tercera ya no es mala suerte. Nació como 182: la 182
-- se la llevó `182_pagos_fecha_en_hora_argentina`, mergeada a main mientras esta
-- rama estaba abierta, así que pasó a 183. Y mientras se escribía el motor,
-- otras ramas aplicaron `183_cerrar_recorridos_terminados` y las 186-189 — el
-- ledger llegó a 189 y las tres de esta tanda pasaron a 190, 191 y 192. Y
-- todavía no era el final: mientras se cerraba el check de integridad entraron
-- `190_guards_de_estado_y_cobranza`, `190b_pagos_forzar_usuario_no_definer` y
-- `191_pagos_forzar_usuario_sin_public`, el ledger llegó a 191, y las tres de
-- esta tanda terminaron en 192, 193 y 194.
--
-- La lección de la segunda vez es más dura que la de la primera. La primera
-- decía "preguntale al LEDGER, no a `ls migrations/`", y no alcanzó: son TRES
-- las fuentes que pueden ocupar un número —`origin/main`, el ledger de prod y
-- las ramas abiertas de los demás— y la tercera no hay forma confiable de
-- consultarla. Así que lo que cambia no es a quién preguntarle sino CUÁNDO
-- preguntar: el número se elige AL FINAL, justo antes de aplicar, no al empezar
-- a escribir. Numerar primero es reservar algo que no se puede reservar.
-- A la tercera la regla se siguió: se reconfirmó contra el ledger y contra todas
-- las refs de git en el minuto anterior a aplicar, y recién ahí se aplicó.
--
-- El espejo en TypeScript de todo esto es `src/utils/prorrateoCompra.ts`, que ya
-- reproduce la factura testigo: cada línea al medio centavo, y los dos totales
-- del golden dentro de los 5 centavos. Las funciones SQL NO van en este archivo:
-- van en la 193 (motor de cálculo) y la 194 (RPCs y check de integridad).
-- Appendearlas acá las dejaría fuera del BEGIN/COMMIT de abajo, que es justo lo
-- que evita quedarse con las tablas creadas y las RPCs a medias.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 1 · Los destinos de las FK compuestas
--
-- Las dos son redundantes por construcción —`id` ya es PK en las dos tablas—, así
-- que no rechazan ninguna fila existente: verificado con conteos contra prod, 128
-- compras y 524 líneas, 0 duplicados y 0 nulos en las dos parejas. Existen sólo
-- para poder exigir por FK, más abajo, que un cargo no cruce de sucursal y que un
-- reparto no cruce de compra.
--
-- `ADD CONSTRAINT` no acepta IF NOT EXISTS: el guard va afuera.
-- ----------------------------------------------------------------------------
DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'compras_id_sucursal_uk'
       AND conrelid = 'public.compras'::regclass
  ) THEN
    ALTER TABLE public.compras
      ADD CONSTRAINT compras_id_sucursal_uk UNIQUE (id, sucursal_id);
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'compra_items_id_compra_uk'
       AND conrelid = 'public.compra_items'::regclass
  ) THEN
    ALTER TABLE public.compra_items
      ADD CONSTRAINT compra_items_id_compra_uk UNIQUE (id, compra_id);
  END IF;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 2 · Los cargos de la factura
--
-- La FK a `compras` es COMPUESTA por (compra_id, sucursal_id), y eso cierra un
-- agujero real: `es_admin()` es global y `current_sucursal_id()` sale del header,
-- así que un admin parado en la sucursal A podía colgar un cargo con
-- `sucursal_id = A` sobre una compra de B — la policy de INSERT chequea la fila y
-- pasa, y una FK simple a `compras(id)` no mira la sucursal. Lo grave no es que
-- se pueda: es que el cargo quedaba INVISIBLE para los usuarios de B, porque la
-- policy de SELECT filtra por `sucursal_id` del cargo. Corrupción silenciosa con
-- la víctima ciega. Ahora la base lo rechaza.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.compra_cargos (
  id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  compra_id          bigint NOT NULL,
  sucursal_id        bigint NOT NULL REFERENCES public.sucursales(id),
  usuario_id         uuid REFERENCES public.perfiles(id) ON DELETE SET NULL,
  orden              integer NOT NULL DEFAULT 0,
  concepto           text    NOT NULL CHECK (btrim(concepto) <> ''),
  monto              numeric(12,2) NOT NULL,
  condicion_iva      text    NOT NULL DEFAULT 'no_gravado'
                       CHECK (condicion_iva IN ('gravado','exento','no_gravado')),
  en_factura         boolean NOT NULL DEFAULT true,
  prorratea_al_costo boolean NOT NULL DEFAULT true,
  afecta_base_ii     boolean NOT NULL DEFAULT false,
  base_prorrateo     text    NOT NULL DEFAULT 'unidades'
                       CHECK (base_prorrateo IN ('monto','cantidad','unidades')),
  created_at         timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT compra_cargos_compra_fk
    FOREIGN KEY (compra_id, sucursal_id)
    REFERENCES public.compras(id, sucursal_id) ON DELETE CASCADE,

  -- Destino de la FK compuesta de compra_cargo_repartos.
  CONSTRAINT compra_cargos_id_compra_uk UNIQUE (id, compra_id)
);

COMMENT ON TABLE public.compra_cargos IS
  'Conceptos de una compra que no son renglones de producto: flete, pallets, separadores, bonificaciones promocionales, redondeo. Monto negativo = bonificación.';
COMMENT ON COLUMN public.compra_cargos.monto IS
  'SIN IVA. Negativo = bonificación.';
COMMENT ON COLUMN public.compra_cargos.usuario_id IS
  'Quién cargó el concepto. El contenido de esta tabla mueve el costo de los productos y la RLS deja escribirla directo a los admin, así que la autoría importa. Misma convención que compras.usuario_id.';
COMMENT ON COLUMN public.compra_cargos.en_factura IS
  'true = el concepto viene impreso en la factura y suma al cuadre. El flete de un tercero va en false: no toca compras.total ni compras.iva, pero sí el costo.';
COMMENT ON COLUMN public.compra_cargos.prorratea_al_costo IS
  'true = entra al costo unitario de los productos. Independiente de en_factura.';
COMMENT ON COLUMN public.compra_cargos.afecta_base_ii IS
  'true = el cargo modifica la base de cálculo de impuestos internos. Una bonificación comercial NO la modifica; un descuento de precio SI. Es la causa del descuadre histórico del II.';
COMMENT ON COLUMN public.compra_cargos.base_prorrateo IS
  'Sólo pre-llena el vector de pesos en la UI. La verdad siempre es compra_cargo_repartos.';
COMMENT ON COLUMN public.compra_cargos.condicion_iva IS
  'Un cargo gravado tributa a la alícuota de las líneas sobre las que se prorratea: no lleva alícuota propia. Hoy los 247 productos son 21%, así que la distinción no se plantea. Si alguna vez conviven alícuotas distintas en una misma compra hay que decidir qué significa la base gravada de una línea que recibe un cargo de otra alícuota.';

CREATE INDEX IF NOT EXISTS idx_compra_cargos_compra ON public.compra_cargos(compra_id);

-- ----------------------------------------------------------------------------
-- 3 · El vector de pesos
--
-- `compra_id` está denormalizado a propósito: es lo que permite que las DOS FK
-- sean compuestas y que la base —no la buena conducta de la RPC— garantice que un
-- reparto nunca cruce COMPRAS. Sin esto, `compra_item_id` podía apuntar a la
-- línea de otra compra y nada lo impedía; importa porque la RLS habilita
-- escritura directa a los admin, no sólo por RPC. Las dos FK compuestas mantienen
-- las tres compra_id consistentes entre sí.
--
-- El alcance exacto, para no prometer de más: la coherencia de SUCURSAL de esta
-- tabla se apoya en la del cargo (sección 2). Nada ata todavía
-- `compra_items.sucursal_id` a `compras.sucursal_id` — es un hueco preexistente,
-- de otro trabajo.
--
-- ON UPDATE queda en NO ACTION a propósito: si alguien moviera una línea de
-- compra, que falle ruidosamente en vez de arrastrar el reparto en silencio.
-- ----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.compra_cargo_repartos (
  cargo_id       bigint NOT NULL,
  compra_item_id bigint NOT NULL,
  compra_id      bigint NOT NULL,
  -- Misma invariante que `prorratearCargo` en prorrateoCompra.ts, que lanza tanto
  -- ante un peso negativo como ante uno no finito: los pesos son proporciones y
  -- el 0 es la exclusión.
  --
  -- El `<> 'NaN'` NO es redundante con el `>= 0`: en numeric, `'NaN' >= 0` es
  -- TRUE, así que el chequeo de signo por sí solo deja entrar un NaN. Y un solo
  -- NaN contamina el cargo entero —sum(peso) da NaN y por lo tanto TODOS sus
  -- repartos salen NaN—, o sea costos corruptos en silencio. Funciona porque
  -- `'NaN' <> 'NaN'` es false en numeric.
  --
  -- (16,4) y no (12,4) pese a que la columna sea una proporción: con
  -- `base_prorrateo = 'monto'` el pre-llenado deja literalmente un MONTO acá, y
  -- (12,4) topea en ~100 M contra una línea máxima de 3,0 M hoy. 33x no es
  -- horizonte en pesos argentinos; ensanchar ahora es gratis y con datos adentro
  -- es un rewrite de tabla.
  peso           numeric(16,4) NOT NULL DEFAULT 0
                   CHECK (peso >= 0 AND peso <> 'NaN'::numeric),

  PRIMARY KEY (cargo_id, compra_item_id),

  CONSTRAINT compra_cargo_repartos_cargo_fk
    FOREIGN KEY (cargo_id, compra_id)
    REFERENCES public.compra_cargos(id, compra_id) ON DELETE CASCADE,

  -- El CASCADE es deliberado, y hay que decir lo que se lleva puesto:
  -- `actualizar_compra_items` hace DELETE + INSERT de las líneas en CADA edición
  -- de una compra, así que cada edición borra TODOS los repartos de esa compra.
  -- Los cargos sobreviven —cuelgan de compra_id, no de la línea— y queda el peor
  -- estado posible: cargo vivo con el vector vacío ⇒ sum(peso) = 0 ⇒ el flete
  -- deja de repartirse. Y no grita, porque el espejo TS trata el vector vacío
  -- como legal (`prorratearCargo` devuelve {}): los cargos se caen del costo en
  -- silencio, que es exactamente el bug que esta feature viene a arreglar.
  -- El CASCADE evita huérfanos; NO evita esa pérdida. Quien tiene que evitarla es
  -- la RPC de edición, reescribiendo los cargos junto con las líneas (Task 10).
  CONSTRAINT compra_cargo_repartos_item_fk
    FOREIGN KEY (compra_item_id, compra_id)
    REFERENCES public.compra_items(id, compra_id) ON DELETE CASCADE
);

COMMENT ON TABLE public.compra_cargo_repartos IS
  'Vector de pesos de un cargo. Peso 0 excluye la línea: por eso el "alcance" no existe como concepto aparte. OJO: editar la compra borra estas filas por CASCADE (actualizar_compra_items recrea las líneas) y deja los cargos con el vector vacío; la RPC de edición tiene que reescribirlos.';
COMMENT ON COLUMN public.compra_cargo_repartos.compra_id IS
  'Denormalizado desde el cargo y la línea. Las dos FK compuestas lo usan para garantizar que un reparto no cruce compras.';
COMMENT ON COLUMN public.compra_cargo_repartos.peso IS
  'Proporción, no monto — salvo que base_prorrateo sea monto, donde el pre-llenado deja un monto acá; de ahí el ancho. 0 excluye la línea del reparto. Un peso negativo y un NaN son dato corrupto, no una exclusión: el CHECK rechaza los dos. El NaN necesita su propia mitad porque NaN >= 0 es TRUE en numeric.';

-- El compuesto (compra_id, compra_item_id) y no (compra_item_id) solo, porque
-- sirve a los tres accesos con un solo índice:
--   · reabrir una compra = todos sus repartos (compra_id es prefijo);
--   · reconstruir una línea = (compra_id, compra_item_id) exacto;
--   · la integridad referencial de compra_cargo_repartos_item_fk, que filtra las
--     dos columnas por igualdad y por lo tanto no depende del orden.
-- Ese último es el que importa en caliente: `actualizar_compra_items` hace
-- DELETE + INSERT de las líneas, así que sin índice cada edición de compra
-- dispararía un seq scan por fila borrada.
-- La PK (cargo_id, compra_item_id) ya cubre el acceso por cargo y la FK al cargo.
CREATE INDEX IF NOT EXISTS idx_compra_cargo_repartos_compra_item
  ON public.compra_cargo_repartos(compra_id, compra_item_id);

-- ----------------------------------------------------------------------------
-- 4 · Los dos snapshots
--
-- Sin el de la LÍNEA no se puede reconstruir cuánto fue flete y cuánto impuesto
-- interno al reabrir la compra.
-- ----------------------------------------------------------------------------
ALTER TABLE public.compra_items
  ADD COLUMN IF NOT EXISTS cargos_unitarios numeric(12,4) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.compra_items.cargos_unitarios IS
  'Cargos no gravados prorrateados a esta línea, por unidad (mig 192). Ya está incluido en costo_real_unitario.';

-- Y el de la COMPRA es la apertura del impuesto interno por alícuota, que es lo
-- único que el factor de ajuste de `calcular_costos_compra` sabe leer.
--
-- No está acá para que alguien la consulte: está para que el ajuste no se
-- EVAPORE. Es una entrada que mueve el costo guardado y no dejaba rastro, así
-- que una edición que no la reenviara recalculaba con factor 1 y revertía el
-- ajuste en silencio — la misma pérdida que el CASCADE le hace a los repartos,
-- pero peor, porque sin esta columna la base no tiene con qué darse cuenta. El
-- guard de `actualizar_compra_items` que la usa vive en la 194.
--
-- La factura testigo necesita un factor de 1,0496 para que el II declarado cuadre
-- con el calculado: un ajuste de ese tamaño desapareciendo solo al editar es peor
-- que no tenerlo, porque nadie lo va a sospechar.
--
-- Nullable y sin DEFAULT a propósito: las 128 compras existentes quedan en NULL,
-- que es exactamente lo que son —compras cargadas sin apertura—, y ese ALTER no
-- reescribe la tabla.
ALTER TABLE public.compras
  ADD COLUMN IF NOT EXISTS ii_declarado jsonb;

COMMENT ON COLUMN public.compras.ii_declarado IS
  'Apertura del impuesto interno POR ALICUOTA tal como vino en la factura: {tasa: monto}. Alimenta el factor de ajuste de calcular_costos_compra, que corrige el II calculado hasta el declarado. NULL = esta compra no se cargo con apertura, y NO es lo mismo que {}: el parametro p_ii_declarado de las RPCs distingue "no me mandaron nada" (NULL, y si la compra tiene apertura la edicion se rechaza) de "me mandaron vacio" ({}, el usuario la borro). Una apertura vacia se persiste como NULL, porque no ajusta nada y no hay nada que proteger. Se guarda porque sin ella el ajuste se revertiria solo en la primera edicion que no la reenviara, y la base no tendria con que detectarlo (mig 192/194).';

-- ----------------------------------------------------------------------------
-- 5 · RLS
--
-- Espejo exacto de `mt_compra_items_*`: depósito lee y carga, admin corrige y
-- borra, todo acotado a la sucursal de la sesión. Un reparto es tan sensible como
-- la línea de compra —es la plata—, así que NO va una sola policy FOR ALL que
-- mire sólo la sucursal: eso le daría lectura y escritura a un preventista o a un
-- transportista de esa sucursal, o sea la capacidad de alterar el costo de los
-- productos.
--
-- No existe un helper `es_deposito()`: las policies de compra_items inlinean el
-- EXISTS sobre `perfiles`, y acá se replica literal para no introducir una
-- variante que después divergiera.
--
-- En compra_cargo_repartos el rol y la sucursal se resuelven por el join con
-- compra_cargos. Ese EXISTS pasa además por la RLS de compra_cargos, lo cual es
-- redundante pero deliberado: si mañana se endurece compra_cargos, los repartos
-- se endurecen solos. La contracara, que hay que tener presente: como el EXISTS
-- pasa por la policy de SELECT, endurecer esa LECTURA cambia en silencio quién
-- puede ESCRIBIR repartos, y el síntoma sería un error de RLS apuntando a la
-- tabla equivocada.
-- ----------------------------------------------------------------------------
ALTER TABLE public.compra_cargos          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.compra_cargo_repartos  ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mt_compra_cargos_select ON public.compra_cargos;
CREATE POLICY mt_compra_cargos_select ON public.compra_cargos
  FOR SELECT TO authenticated
  USING (
    (es_admin() OR EXISTS (
      SELECT 1 FROM public.perfiles
       WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  );

DROP POLICY IF EXISTS mt_compra_cargos_insert ON public.compra_cargos;
CREATE POLICY mt_compra_cargos_insert ON public.compra_cargos
  FOR INSERT TO authenticated
  WITH CHECK (
    (es_admin() OR EXISTS (
      SELECT 1 FROM public.perfiles
       WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
    AND sucursal_id = current_sucursal_id()
  );

DROP POLICY IF EXISTS mt_compra_cargos_update ON public.compra_cargos;
CREATE POLICY mt_compra_cargos_update ON public.compra_cargos
  FOR UPDATE TO authenticated
  USING      (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

DROP POLICY IF EXISTS mt_compra_cargos_delete ON public.compra_cargos;
CREATE POLICY mt_compra_cargos_delete ON public.compra_cargos
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());

DROP POLICY IF EXISTS mt_compra_cargo_repartos_select ON public.compra_cargo_repartos;
CREATE POLICY mt_compra_cargo_repartos_select ON public.compra_cargo_repartos
  FOR SELECT TO authenticated
  USING (
    (es_admin() OR EXISTS (
      SELECT 1 FROM public.perfiles
       WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
    AND EXISTS (
      SELECT 1 FROM public.compra_cargos c
       WHERE c.id = compra_cargo_repartos.cargo_id
         AND c.sucursal_id = current_sucursal_id())
  );

DROP POLICY IF EXISTS mt_compra_cargo_repartos_insert ON public.compra_cargo_repartos;
CREATE POLICY mt_compra_cargo_repartos_insert ON public.compra_cargo_repartos
  FOR INSERT TO authenticated
  WITH CHECK (
    (es_admin() OR EXISTS (
      SELECT 1 FROM public.perfiles
       WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
    AND EXISTS (
      SELECT 1 FROM public.compra_cargos c
       WHERE c.id = compra_cargo_repartos.cargo_id
         AND c.sucursal_id = current_sucursal_id())
  );

DROP POLICY IF EXISTS mt_compra_cargo_repartos_update ON public.compra_cargo_repartos;
CREATE POLICY mt_compra_cargo_repartos_update ON public.compra_cargo_repartos
  FOR UPDATE TO authenticated
  USING (
    es_admin() AND EXISTS (
      SELECT 1 FROM public.compra_cargos c
       WHERE c.id = compra_cargo_repartos.cargo_id
         AND c.sucursal_id = current_sucursal_id())
  )
  WITH CHECK (
    es_admin() AND EXISTS (
      SELECT 1 FROM public.compra_cargos c
       WHERE c.id = compra_cargo_repartos.cargo_id
         AND c.sucursal_id = current_sucursal_id())
  );

DROP POLICY IF EXISTS mt_compra_cargo_repartos_delete ON public.compra_cargo_repartos;
CREATE POLICY mt_compra_cargo_repartos_delete ON public.compra_cargo_repartos
  FOR DELETE TO authenticated
  USING (
    es_admin() AND EXISTS (
      SELECT 1 FROM public.compra_cargos c
       WHERE c.id = compra_cargo_repartos.cargo_id
         AND c.sucursal_id = current_sucursal_id())
  );

COMMIT;

-- ----------------------------------------------------------------------------
-- Rollback
--
--   DROP TABLE  IF EXISTS public.compra_cargo_repartos;
--   DROP TABLE  IF EXISTS public.compra_cargos;
--   ALTER TABLE public.compras      DROP COLUMN     IF EXISTS ii_declarado;
--   ALTER TABLE public.compra_items DROP COLUMN     IF EXISTS cargos_unitarios;
--   ALTER TABLE public.compra_items DROP CONSTRAINT IF EXISTS compra_items_id_compra_uk;
--   ALTER TABLE public.compras      DROP CONSTRAINT IF EXISTS compras_id_sucursal_uk;
--
-- Mientras no existan cargos eso es exacto y el costo vuelve solo: Σ cargos = 0.
--
-- DEJA de ser exacto en cuanto los cargos empiecen a entrar al
-- `costo_real_unitario` y, por ahí, al costo promedio ponderado. A partir de ese
-- momento dropear estas tablas borra CUÁLES fueron los cargos pero NO los saca de
-- los costos ya calculados: quedan costos que incluyen cargos sin ningún registro
-- de su origen, y nada que permita reconstruirlos. Deja de ser reversible y pasa
-- a ser reversible-con-recálculo — hay que recomputar el costo de las compras
-- afectadas y su CPP, con las tablas todavía en pie.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Verificación
--
--   -- Las dos tablas, con RLS prendida y 4 policies cada una:
--   SELECT c.relname, c.relrowsecurity,
--          (SELECT count(*) FROM pg_policies p
--            WHERE p.schemaname = 'public' AND p.tablename = c.relname) AS policies
--     FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
--    WHERE n.nspname = 'public'
--      AND c.relname IN ('compra_cargos','compra_cargo_repartos');
--   -- compra_cargos         | t | 4
--   -- compra_cargo_repartos | t | 4
--
--   -- Las tres FK compuestas: la del cargo a su compra+sucursal, y las dos del
--   -- reparto a su cargo y a su línea.
--   SELECT conrelid::regclass AS tabla, conname, pg_get_constraintdef(oid)
--     FROM pg_constraint
--    WHERE contype = 'f'
--      AND conrelid IN ('public.compra_cargos'::regclass,
--                       'public.compra_cargo_repartos'::regclass)
--      AND cardinality(conkey) = 2;
--   -- compra_cargos_compra_fk      | (compra_id, sucursal_id)   -> compras(id, sucursal_id)
--   -- compra_cargo_repartos_cargo_fk | (cargo_id, compra_id)    -> compra_cargos(id, compra_id)
--   -- compra_cargo_repartos_item_fk  | (compra_item_id, compra_id) -> compra_items(id, compra_id)
--
--   -- El snapshot por línea, en 0 para las 524 líneas existentes (forward-only):
--   SELECT count(*) AS lineas,
--          count(*) FILTER (WHERE cargos_unitarios = 0) AS en_cero
--     FROM compra_items;                                  -- 524 | 524
--
--   -- Y el de la compra, en NULL para todas las existentes:
--   SELECT count(*) AS compras,
--          count(*) FILTER (WHERE ii_declarado IS NULL) AS sin_apertura
--     FROM compras;                                       -- 128 | 128
--
--   -- Y ninguna compra cambió de costo, porque todavía no hay cargos:
--   SELECT count(*) FROM compra_cargos;                   -- 0
-- ----------------------------------------------------------------------------
