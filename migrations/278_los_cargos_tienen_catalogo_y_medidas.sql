-- =========================================================================
-- mig 278 · LOS CARGOS TIENEN CATALOGO, Y LOS PALLETS SE MIDEN EN LA FICHA
--
-- Hasta aca cada cargo de una compra (flete, pallets, separadores,
-- bonificaciones) era texto libre, y el reparto por pallets se tipeaba a mano
-- linea por linea: en la compra 304 el que cargo escribio "2" para 240 u. de
-- agua 600cc porque sabe que entran 120 por pallet. Ese dato —cuantas
-- unidades entran en un pallet— es fisico, es del producto y no cambia de
-- factura a factura. Se modela:
--
--   cargo_medidas     · GLOBAL. Pallet, Separador, Lugar en el flete. Una
--                       medida puede tener `medida_base_id` (un nivel): si el
--                       producto no tiene valor propio para "Lugar en el
--                       flete", usa el de Pallet. Asi el Placer 500cc puede
--                       decir que 2 pallets ocupan 1 lugar sin que nadie
--                       cargue el lugar de cada producto.
--   producto_medidas  · POR SUCURSAL (productos es por sucursal): unidades por
--                       medida. FK compuesta a productos(id, sucursal_id).
--   cargo_conceptos   · GLOBAL. Nombre unico (normalizado: minusculas, sin
--                       tildes, espacios colapsados — la misma regla que usa
--                       el modal) y DEFAULTS para precargar el renglon. Sin
--                       `afecta_base_ii`: eso lo deduce el solver del impuesto
--                       interno declarado en cada factura.
--
-- LOS DEFAULTS SOLO PRECARGAN. `compra_cargos` sigue guardando la foto de lo
-- que quedo en esa compra (concepto, banderas, base, pesos). `concepto_id` y
-- `medida_id` son nullable y no deciden nada: son para estadistica y para que
-- la plantilla del proveedor sepa con que medida repartir la proxima vez.
--
-- EL SIGNO NO SE APLICA DOS VECES. `compra_cargos.monto` ya viaja con signo
-- (una bonificacion se guarda negativa desde la mig 192) y la RPC lo guarda
-- tal cual. `cargo_conceptos.signo` es solo el default del toggle +/- del
-- renglon: elegir "Bonificacion" pone el toggle en "−". Ninguna funcion
-- multiplica el monto por el signo del catalogo.
--
-- NUEVA BASE 'medida'. El motor no cambia: la base solo precarga el vector de
-- pesos (peso = cantidad / unidades_por), y lo que se persiste y se calcula
-- sigue siendo el vector. Por eso alcanza con sumarla al CHECK y a las dos
-- listas NOT IN que las RPCs escriben a mano.
--
-- PARCHE POR ANCLA sobre el cuerpo vivo (como la 236 y la 277), no CREATE OR
-- REPLACE desde el repo: registrar_compra_completa, actualizar_compra_items y
-- cambiar_proveedor_compra estan parcheadas en una docena de migraciones.
-- Ninguna cambia de firma: concepto_id y medida_id viajan dentro de cada
-- elemento de p_cargos.
--
-- Las medidas de la ficha NO viajan en la compra: van despues, con
-- guardar_producto_medidas, igual que los vencimientos con
-- sincronizar_lotes_compra. Si fallan, la compra ya esta registrada y el
-- costo ya salio de los pesos.
--
-- auditoria_integridad(): revisada. COMPRA-A3 recalcula el reparto desde
-- compra_cargo_repartos y no mira la base, asi que no hay nada que tocar.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 0 · Helper de cirugia sobre el cuerpo vivo (mismo contrato que _mig277_ancla)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig278_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- -------------------------------------------------------------------------
-- 1 · Normalizacion del nombre de un concepto
--
-- La misma que `normalizarBusqueda` (src/utils/filtrarOpciones.ts), que es la
-- que usa el modal para no traer dos veces "Flete" de la plantilla: sin
-- tildes, minusculas, espacios colapsados. STABLE y no IMMUTABLE porque
-- unaccent no lo es; por eso se guarda en una columna escrita por trigger y
-- no en un indice de expresion.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.normalizar_nombre_concepto(p_nombre text)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT lower(public.unaccent(btrim(regexp_replace(COALESCE(p_nombre, ''), '\s+', ' ', 'g'))))
$fn$;

REVOKE EXECUTE ON FUNCTION public.normalizar_nombre_concepto(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.normalizar_nombre_concepto(text) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 2 · Medidas (globales)
-- -------------------------------------------------------------------------
CREATE TABLE public.cargo_medidas (
  id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre           text NOT NULL,
  -- Para la UI: "N pallets (120 u/pallet)".
  unidad_singular  text NOT NULL,
  -- Fallback de UN nivel: si el producto no tiene valor para esta medida, se
  -- usa el de la base. Ver validar_cargo_medida().
  medida_base_id   bigint REFERENCES public.cargo_medidas(id) ON DELETE RESTRICT,
  activo           boolean NOT NULL DEFAULT true,
  created_at       timestamptz NOT NULL DEFAULT now(),
  updated_at       timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT cargo_medidas_nombre_no_vacio CHECK (btrim(nombre) <> ''),
  CONSTRAINT cargo_medidas_unidad_no_vacia CHECK (btrim(unidad_singular) <> ''),
  CONSTRAINT cargo_medidas_base_no_propia CHECK (medida_base_id IS DISTINCT FROM id)
);

CREATE UNIQUE INDEX cargo_medidas_nombre_uk ON public.cargo_medidas (lower(btrim(nombre)));

COMMENT ON TABLE public.cargo_medidas IS
  'Medidas para repartir cargos (mig 278): Pallet, Separador, Lugar en el flete. Global. medida_base_id = fallback de un nivel.';

-- Un solo nivel de fallback: la base no puede tener base, y una medida que ya
-- es base de otra no puede tomar una. Asi la resolucion nunca entra en ciclo
-- y el cliente la puede hacer con un solo salto.
CREATE OR REPLACE FUNCTION public.validar_cargo_medida()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
BEGIN
  NEW.updated_at := now();
  IF NEW.medida_base_id IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM public.cargo_medidas b
                WHERE b.id = NEW.medida_base_id AND b.medida_base_id IS NOT NULL) THEN
      RAISE EXCEPTION 'La medida base tiene a su vez una base: el fallback es de un solo nivel.'
        USING ERRCODE = '23514';
    END IF;
    IF EXISTS (SELECT 1 FROM public.cargo_medidas h
                WHERE h.medida_base_id = NEW.id AND h.id <> NEW.id) THEN
      RAISE EXCEPTION 'Esta medida es la base de otra: no puede tener base propia (el fallback es de un solo nivel).'
        USING ERRCODE = '23514';
    END IF;
  END IF;
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_validar_cargo_medida
  BEFORE INSERT OR UPDATE ON public.cargo_medidas
  FOR EACH ROW EXECUTE FUNCTION public.validar_cargo_medida();

REVOKE EXECUTE ON FUNCTION public.validar_cargo_medida() FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 3 · Conceptos (globales)
-- -------------------------------------------------------------------------
CREATE TABLE public.cargo_conceptos (
  id                  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre              text NOT NULL,
  -- Lo escribe el trigger: normalizar_nombre_concepto(nombre).
  nombre_normalizado  text NOT NULL,
  -- Default del toggle +/- del renglon. NO multiplica el monto (ver encabezado).
  signo               smallint NOT NULL DEFAULT 1,
  condicion_iva       text NOT NULL DEFAULT 'no_gravado',
  en_factura          boolean NOT NULL DEFAULT true,
  prorratea_al_costo  boolean NOT NULL DEFAULT true,
  base_prorrateo      text NOT NULL DEFAULT 'monto',
  medida_id           bigint REFERENCES public.cargo_medidas(id) ON DELETE RESTRICT,
  activo              boolean NOT NULL DEFAULT true,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  creado_por          uuid DEFAULT auth.uid(),
  CONSTRAINT cargo_conceptos_nombre_no_vacio CHECK (btrim(nombre) <> ''),
  CONSTRAINT cargo_conceptos_nombre_normalizado_uk UNIQUE (nombre_normalizado),
  CONSTRAINT cargo_conceptos_signo_check CHECK (signo IN (-1, 1)),
  CONSTRAINT cargo_conceptos_condicion_iva_check CHECK (condicion_iva IN ('gravado', 'exento', 'no_gravado')),
  CONSTRAINT cargo_conceptos_base_prorrateo_check CHECK (base_prorrateo IN ('monto', 'cantidad', 'unidades', 'medida')),
  CONSTRAINT cargo_conceptos_medida_con_base CHECK (base_prorrateo <> 'medida' OR medida_id IS NOT NULL)
);

CREATE INDEX cargo_conceptos_medida_idx ON public.cargo_conceptos (medida_id);

COMMENT ON TABLE public.cargo_conceptos IS
  'Catalogo de conceptos de cargo de compra (mig 278). Global. Los defaults solo precargan el renglon; compra_cargos guarda la foto.';
COMMENT ON COLUMN public.cargo_conceptos.signo IS
  'Default del toggle +/- (−1 = bonificacion). compra_cargos.monto ya viaja con signo: nadie multiplica por esto.';

CREATE OR REPLACE FUNCTION public.normalizar_cargo_concepto()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public
AS $fn$
BEGIN
  NEW.nombre := btrim(regexp_replace(NEW.nombre, '\s+', ' ', 'g'));
  NEW.nombre_normalizado := public.normalizar_nombre_concepto(NEW.nombre);
  NEW.updated_at := now();
  RETURN NEW;
END;
$fn$;

CREATE TRIGGER trg_normalizar_cargo_concepto
  BEFORE INSERT OR UPDATE ON public.cargo_conceptos
  FOR EACH ROW EXECUTE FUNCTION public.normalizar_cargo_concepto();

REVOKE EXECUTE ON FUNCTION public.normalizar_cargo_concepto() FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 4 · Medidas por producto (por sucursal)
-- -------------------------------------------------------------------------
CREATE TABLE public.producto_medidas (
  producto_id   bigint NOT NULL,
  sucursal_id   bigint NOT NULL REFERENCES public.sucursales(id),
  medida_id     bigint NOT NULL REFERENCES public.cargo_medidas(id) ON DELETE RESTRICT,
  -- Sin redondear: 1000 u. en 3 pallets son 333,333... y el peso tiene que
  -- volver a dar 3, no 3,0003. El tope descarta NaN e infinito (en numeric,
  -- NaN es MAYOR que todo y pasaria un `> 0` pelado).
  unidades_por  numeric NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT producto_medidas_pkey PRIMARY KEY (producto_id, sucursal_id, medida_id),
  -- Compuesta: el aislamiento por sucursal (migs 186/187). Una simple dejaria
  -- colgar la medida de Tucuman de un producto de Taco Pozo.
  CONSTRAINT producto_medidas_producto_fk FOREIGN KEY (producto_id, sucursal_id)
    REFERENCES public.productos(id, sucursal_id) ON DELETE CASCADE,
  CONSTRAINT producto_medidas_unidades_rango CHECK (unidades_por > 0 AND unidades_por < 1000000000)
);

CREATE INDEX producto_medidas_sucursal_idx ON public.producto_medidas (sucursal_id, medida_id);
CREATE INDEX producto_medidas_medida_idx ON public.producto_medidas (medida_id);

COMMENT ON TABLE public.producto_medidas IS
  'Unidades del producto por medida (mig 278): cuantas entran en un pallet, un separador, un lugar del flete. Dato fisico, no el peso de una compra.';

-- -------------------------------------------------------------------------
-- 5 · compra_cargos: la foto gana de que concepto y con que medida
-- -------------------------------------------------------------------------
ALTER TABLE public.compra_cargos
  ADD COLUMN concepto_id bigint REFERENCES public.cargo_conceptos(id) ON DELETE SET NULL,
  ADD COLUMN medida_id   bigint REFERENCES public.cargo_medidas(id) ON DELETE SET NULL;

CREATE INDEX compra_cargos_concepto_idx ON public.compra_cargos (concepto_id);
CREATE INDEX compra_cargos_medida_idx ON public.compra_cargos (medida_id);

ALTER TABLE public.compra_cargos DROP CONSTRAINT compra_cargos_base_prorrateo_check;
ALTER TABLE public.compra_cargos ADD CONSTRAINT compra_cargos_base_prorrateo_check
  CHECK (base_prorrateo IN ('monto', 'cantidad', 'unidades', 'medida'));

COMMENT ON COLUMN public.compra_cargos.concepto_id IS
  'Concepto del catalogo del que salio el renglon (mig 278). Nullable: el concepto/banderas de esta fila son la foto que manda.';
COMMENT ON COLUMN public.compra_cargos.medida_id IS
  'Medida con la que se precargaron los pesos si la base es medida (mig 278). Los pesos guardados mandan.';

-- -------------------------------------------------------------------------
-- 6 · RLS y permisos. Leer: autenticados. Escribir: quien carga compras
--     (admin, encargado o deposito: registrar_compra_completa deja a admin y
--     encargado, y la RLS de compras suma a deposito). anon: nada.
-- -------------------------------------------------------------------------
ALTER TABLE public.cargo_medidas ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cargo_conceptos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.producto_medidas ENABLE ROW LEVEL SECURITY;

-- Medidas: el catalogo lo arma admin (son tres filas y cambian casi nunca).
CREATE POLICY cargo_medidas_select ON public.cargo_medidas
  FOR SELECT TO authenticated USING (true);
CREATE POLICY cargo_medidas_insert ON public.cargo_medidas
  FOR INSERT TO authenticated WITH CHECK (public.es_admin());
CREATE POLICY cargo_medidas_update ON public.cargo_medidas
  FOR UPDATE TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());
CREATE POLICY cargo_medidas_delete ON public.cargo_medidas
  FOR DELETE TO authenticated USING (public.es_admin());

-- Conceptos: los crea quien carga la compra ("+ Crear 'X'"); renombrar o dar
-- de baja es de admin.
CREATE POLICY cargo_conceptos_select ON public.cargo_conceptos
  FOR SELECT TO authenticated USING (true);
CREATE POLICY cargo_conceptos_insert ON public.cargo_conceptos
  FOR INSERT TO authenticated WITH CHECK (
    public.es_admin() OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol IN ('encargado', 'deposito')));
CREATE POLICY cargo_conceptos_update ON public.cargo_conceptos
  FOR UPDATE TO authenticated USING (public.es_admin()) WITH CHECK (public.es_admin());
CREATE POLICY cargo_conceptos_delete ON public.cargo_conceptos
  FOR DELETE TO authenticated USING (public.es_admin());

-- Medidas por producto: de la sucursal activa, como productos.
CREATE POLICY producto_medidas_select ON public.producto_medidas
  FOR SELECT TO authenticated USING (sucursal_id = public.current_sucursal_id());
CREATE POLICY producto_medidas_insert ON public.producto_medidas
  FOR INSERT TO authenticated WITH CHECK (
    (public.es_admin() OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol IN ('encargado', 'deposito')))
    AND sucursal_id = public.current_sucursal_id());
CREATE POLICY producto_medidas_update ON public.producto_medidas
  FOR UPDATE TO authenticated
  USING (
    (public.es_admin() OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol IN ('encargado', 'deposito')))
    AND sucursal_id = public.current_sucursal_id())
  WITH CHECK (
    (public.es_admin() OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol IN ('encargado', 'deposito')))
    AND sucursal_id = public.current_sucursal_id());
CREATE POLICY producto_medidas_delete ON public.producto_medidas
  FOR DELETE TO authenticated USING (
    (public.es_admin() OR EXISTS (SELECT 1 FROM public.perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol IN ('encargado', 'deposito')))
    AND sucursal_id = public.current_sucursal_id());

REVOKE ALL ON public.cargo_medidas FROM anon;
REVOKE ALL ON public.cargo_conceptos FROM anon;
REVOKE ALL ON public.producto_medidas FROM anon;

-- -------------------------------------------------------------------------
-- 7 · Seed
--
-- Lo que usaron las compras 303/304 (Manaos): Flete no gravado y FUERA de la
-- factura (lo cobra el transportista), Pallets y Separadores no gravados y en
-- la factura, la bonificacion gravada, en la factura y por monto. Las tres
-- primeras pasan a la base 'medida'; en la 304 se repartieron por cantidad
-- con los pallets tipeados a mano, que es justo lo que esto reemplaza.
-- -------------------------------------------------------------------------
INSERT INTO public.cargo_medidas (nombre, unidad_singular) VALUES
  ('Pallet',    'pallet'),
  ('Separador', 'separador');

INSERT INTO public.cargo_medidas (nombre, unidad_singular, medida_base_id)
SELECT 'Lugar en el flete', 'lugar', id FROM public.cargo_medidas WHERE nombre = 'Pallet';

INSERT INTO public.cargo_conceptos
  (nombre, signo, condicion_iva, en_factura, prorratea_al_costo, base_prorrateo, medida_id)
SELECT v.nombre, v.signo, v.condicion_iva, v.en_factura, true, v.base, m.id
  FROM (VALUES
    ('Flete',        1, 'no_gravado', false, 'medida', 'Lugar en el flete'),
    ('Pallets',      1, 'no_gravado', true,  'medida', 'Pallet'),
    ('Separadores',  1, 'no_gravado', true,  'medida', 'Separador'),
    ('Bonificación', -1, 'gravado',   true,  'monto',  NULL)
  ) AS v(nombre, signo, condicion_iva, en_factura, base, medida)
  LEFT JOIN public.cargo_medidas m ON m.nombre = v.medida;

-- -------------------------------------------------------------------------
-- 8 · RPC: alta de un concepto desde la compra ("+ Crear 'X'")
--
-- Upsert por el nombre normalizado: si ya existe (otro lo creo en el medio,
-- o se tipeo "flete " con espacio) devuelve ese id y no toca sus defaults.
-- INVOKER: la RLS de cargo_conceptos es la que decide quien inserta. El
-- cliente la llama al guardar la compra, por separado, y si falla la compra
-- se guarda igual con concepto_id NULL.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.asegurar_cargo_concepto(
  p_nombre             text,
  p_signo              integer,
  p_condicion_iva      text,
  p_en_factura         boolean,
  p_prorratea_al_costo boolean,
  p_base_prorrateo     text,
  p_medida_id          bigint DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_id    bigint;
  v_base  text := COALESCE(p_base_prorrateo, 'monto');
BEGIN
  IF NOT (public.es_admin() OR EXISTS (
            SELECT 1 FROM public.perfiles WHERE id = auth.uid() AND rol IN ('encargado', 'deposito'))) THEN
    RAISE EXCEPTION 'Solo quien carga compras (admin, encargado o deposito) puede crear conceptos de cargo.'
      USING ERRCODE = '42501';
  END IF;
  IF public.normalizar_nombre_concepto(p_nombre) = '' THEN
    RAISE EXCEPTION 'El concepto necesita un nombre.' USING ERRCODE = '22023';
  END IF;
  IF COALESCE(p_signo, 1) NOT IN (-1, 1) THEN
    RAISE EXCEPTION 'El signo de un concepto es 1 (cargo) o -1 (bonificacion), no %.', p_signo
      USING ERRCODE = '22023';
  END IF;
  -- Una base 'medida' sin medida no se puede precargar: el concepto nace
  -- repartiendo por monto, que es el default de la tabla.
  IF v_base = 'medida' AND p_medida_id IS NULL THEN
    v_base := 'monto';
  END IF;

  INSERT INTO public.cargo_conceptos
    (nombre, signo, condicion_iva, en_factura, prorratea_al_costo, base_prorrateo, medida_id)
  VALUES
    (p_nombre, COALESCE(p_signo, 1)::smallint, COALESCE(p_condicion_iva, 'no_gravado'),
     COALESCE(p_en_factura, true), COALESCE(p_prorratea_al_costo, true), v_base,
     CASE WHEN v_base = 'medida' THEN p_medida_id END)
  ON CONFLICT (nombre_normalizado) DO NOTHING
  RETURNING id INTO v_id;

  IF v_id IS NULL THEN
    SELECT id INTO v_id FROM public.cargo_conceptos
     WHERE nombre_normalizado = public.normalizar_nombre_concepto(p_nombre);
  END IF;
  RETURN v_id;
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.asegurar_cargo_concepto(text, integer, text, boolean, boolean, text, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.asegurar_cargo_concepto(text, integer, text, boolean, boolean, text, bigint) TO authenticated;

-- -------------------------------------------------------------------------
-- 9 · RPC: medidas de la ficha, de la sucursal activa
--
-- p_items: [{producto_id, medida_id, unidades_por}]. unidades_por null =
-- borrar el valor de la ficha (el input vaciado). Valida todo antes de
-- escribir nada: o se guarda el lote entero o nada.
-- La llaman la ficha del producto y la compra DESPUES de registrarse (no
-- bloqueante, como sincronizar_lotes_compra). INVOKER: la RLS hace cumplir
-- la sucursal y el rol.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_producto_medidas(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_sucursal  bigint := public.current_sucursal_id();
  v_motivo    text;
  v_guardadas integer := 0;
  v_borradas  integer := 0;
BEGIN
  IF NOT (public.es_admin() OR EXISTS (
            SELECT 1 FROM public.perfiles WHERE id = auth.uid() AND rol IN ('encargado', 'deposito'))) THEN
    RAISE EXCEPTION 'Solo quien carga compras (admin, encargado o deposito) puede guardar medidas de producto.'
      USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa.' USING ERRCODE = '22023';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items tiene que ser un array de medidas.' USING ERRCODE = '22023';
  END IF;

  -- Forma de cada elemento. El CASE fuerza el orden: nada se castea antes de
  -- saber que es un entero o un numero.
  SELECT format('La medida en la posicion %s %s.', e.ord - 1,
           CASE WHEN jsonb_typeof(e.val) <> 'object' THEN 'no es un objeto'
                WHEN COALESCE(e.val->>'producto_id', '') !~ '^[0-9]{1,18}$' THEN 'no tiene un producto_id valido'
                WHEN COALESCE(e.val->>'medida_id', '') !~ '^[0-9]{1,18}$' THEN 'no tiene un medida_id valido'
                ELSE 'tiene unidades_por que no es un numero mayor que 0 (null borra el valor)' END)
    INTO v_motivo
    FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(val, ord)
   WHERE CASE WHEN jsonb_typeof(e.val) <> 'object' THEN true
              WHEN COALESCE(e.val->>'producto_id', '') !~ '^[0-9]{1,18}$' THEN true
              WHEN COALESCE(e.val->>'medida_id', '') !~ '^[0-9]{1,18}$' THEN true
              WHEN jsonb_typeof(COALESCE(e.val->'unidades_por', 'null'::jsonb)) = 'null' THEN false
              WHEN jsonb_typeof(e.val->'unidades_por') <> 'number' THEN true
              ELSE NOT ((e.val->>'unidades_por')::numeric > 0
                        AND (e.val->>'unidades_por')::numeric < 1000000000) END
   ORDER BY e.ord
   LIMIT 1;
  IF v_motivo IS NOT NULL THEN
    RAISE EXCEPTION '%', v_motivo USING ERRCODE = '22023';
  END IF;

  -- Mismo producto y medida dos veces: el upsert no puede tocar una fila dos
  -- veces en la misma sentencia, y ademas no se sabria cual vale.
  SELECT format('El producto %s tiene la medida %s dos veces.', e.val->>'producto_id', e.val->>'medida_id')
    INTO v_motivo
    FROM jsonb_array_elements(p_items) AS e(val)
   GROUP BY e.val->>'producto_id', e.val->>'medida_id'
  HAVING count(*) > 1
   LIMIT 1;
  IF v_motivo IS NOT NULL THEN
    RAISE EXCEPTION '%', v_motivo USING ERRCODE = '22023';
  END IF;

  -- Producto de ESTA sucursal y medida existente.
  SELECT format('El producto %s no es de la sucursal activa.', e.val->>'producto_id')
    INTO v_motivo
    FROM jsonb_array_elements(p_items) AS e(val)
   WHERE NOT EXISTS (SELECT 1 FROM public.productos p
                      WHERE p.id = (e.val->>'producto_id')::bigint AND p.sucursal_id = v_sucursal)
   LIMIT 1;
  IF v_motivo IS NOT NULL THEN
    RAISE EXCEPTION '%', v_motivo USING ERRCODE = '23503';
  END IF;

  SELECT format('La medida %s no existe.', e.val->>'medida_id')
    INTO v_motivo
    FROM jsonb_array_elements(p_items) AS e(val)
   WHERE NOT EXISTS (SELECT 1 FROM public.cargo_medidas m WHERE m.id = (e.val->>'medida_id')::bigint)
   LIMIT 1;
  IF v_motivo IS NOT NULL THEN
    RAISE EXCEPTION '%', v_motivo USING ERRCODE = '23503';
  END IF;

  DELETE FROM public.producto_medidas pm
   USING jsonb_array_elements(p_items) AS e(val)
   WHERE jsonb_typeof(COALESCE(e.val->'unidades_por', 'null'::jsonb)) = 'null'
     AND pm.producto_id = (e.val->>'producto_id')::bigint
     AND pm.medida_id = (e.val->>'medida_id')::bigint
     AND pm.sucursal_id = v_sucursal;
  GET DIAGNOSTICS v_borradas = ROW_COUNT;

  INSERT INTO public.producto_medidas (producto_id, sucursal_id, medida_id, unidades_por)
  SELECT (e.val->>'producto_id')::bigint, v_sucursal, (e.val->>'medida_id')::bigint,
         (e.val->>'unidades_por')::numeric
    FROM jsonb_array_elements(p_items) AS e(val)
   WHERE jsonb_typeof(COALESCE(e.val->'unidades_por', 'null'::jsonb)) = 'number'
  ON CONFLICT (producto_id, sucursal_id, medida_id)
  DO UPDATE SET unidades_por = EXCLUDED.unidades_por, updated_at = now();
  GET DIAGNOSTICS v_guardadas = ROW_COUNT;

  RETURN jsonb_build_object('success', true, 'guardadas', v_guardadas, 'borradas', v_borradas);
END;
$fn$;

REVOKE EXECUTE ON FUNCTION public.guardar_producto_medidas(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_producto_medidas(jsonb) TO authenticated;

-- -------------------------------------------------------------------------
-- 10 · Las RPCs de compra aceptan la base 'medida' y guardan concepto/medida
--
-- concepto_id / medida_id se leen de cada elemento de p_cargos en la
-- normalizacion (v_cargos), que es la version que se guarda. Un id que no es
-- un entero o que no existe en el catalogo queda NULL en vez de tirar la
-- compra: es un dato de estadistica, nunca una razon para no registrar una
-- factura. El CASE adentro del WHERE fuerza el orden (sin el, el planner
-- podria castear antes de mirar la regex).
-- -------------------------------------------------------------------------

-- 10.a · registrar_compra_completa
SELECT public._mig278_ancla(
  'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  $a$WHEN COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades')$a$,
  $n$WHEN COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades','medida')$n$);
SELECT public._mig278_ancla(
  'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  $a$OR COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades')$a$,
  $n$OR COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades','medida')$n$);
SELECT public._mig278_ancla(
  'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  $a$(se espera monto, cantidad o unidades)$a$,
  $n$(se espera monto, cantidad, unidades o medida)$n$);
SELECT public._mig278_ancla(
  'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  $a$'base_prorrateo',     COALESCE(c.val->>'base_prorrateo', 'unidades'),$a$,
  $n$'base_prorrateo',     COALESCE(c.val->>'base_prorrateo', 'unidades'),
             'concepto_id',        (SELECT cco.id FROM cargo_conceptos cco
                                     WHERE cco.id = CASE WHEN c.val->>'concepto_id' ~ '^[0-9]{1,18}$'
                                                         THEN (c.val->>'concepto_id')::BIGINT END),
             'medida_id',          (SELECT cme.id FROM cargo_medidas cme
                                     WHERE cme.id = CASE WHEN c.val->>'medida_id' ~ '^[0-9]{1,18}$'
                                                         THEN (c.val->>'medida_id')::BIGINT END),$n$);
SELECT public._mig278_ancla(
  'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  E'prorratea_al_costo, afecta_base_ii, base_prorrateo\n',
  E'prorratea_al_costo, afecta_base_ii, base_prorrateo, concepto_id, medida_id\n');
SELECT public._mig278_ancla(
  'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  E'c.val->>''base_prorrateo''\n      FROM jsonb_array_elements(v_cargos) AS c(val);',
  E'c.val->>''base_prorrateo'',\n           (c.val->>''concepto_id'')::BIGINT,\n           (c.val->>''medida_id'')::BIGINT\n      FROM jsonb_array_elements(v_cargos) AS c(val);');

-- 10.b · actualizar_compra_items
SELECT public._mig278_ancla(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  $a$WHEN COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades')$a$,
  $n$WHEN COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades','medida')$n$);
SELECT public._mig278_ancla(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  $a$OR COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades')$a$,
  $n$OR COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades','medida')$n$);
SELECT public._mig278_ancla(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  $a$(se espera monto, cantidad o unidades)$a$,
  $n$(se espera monto, cantidad, unidades o medida)$n$);
SELECT public._mig278_ancla(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  $a$'base_prorrateo',     COALESCE(c.val->>'base_prorrateo', 'unidades'),$a$,
  $n$'base_prorrateo',     COALESCE(c.val->>'base_prorrateo', 'unidades'),
             'concepto_id',        (SELECT cco.id FROM cargo_conceptos cco
                                     WHERE cco.id = CASE WHEN c.val->>'concepto_id' ~ '^[0-9]{1,18}$'
                                                         THEN (c.val->>'concepto_id')::BIGINT END),
             'medida_id',          (SELECT cme.id FROM cargo_medidas cme
                                     WHERE cme.id = CASE WHEN c.val->>'medida_id' ~ '^[0-9]{1,18}$'
                                                         THEN (c.val->>'medida_id')::BIGINT END),$n$);
SELECT public._mig278_ancla(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  E'prorratea_al_costo, afecta_base_ii, base_prorrateo\n',
  E'prorratea_al_costo, afecta_base_ii, base_prorrateo, concepto_id, medida_id\n');
SELECT public._mig278_ancla(
  'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'::regprocedure,
  E'c.val->>''base_prorrateo''\n        FROM jsonb_array_elements(v_cargos) AS c(val);',
  E'c.val->>''base_prorrateo'',\n             (c.val->>''concepto_id'')::BIGINT,\n             (c.val->>''medida_id'')::BIGINT\n        FROM jsonb_array_elements(v_cargos) AS c(val);');

-- 10.c · cambiar_proveedor_compra: el clon lleva concepto y medida
SELECT public._mig278_ancla(
  'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure,
  E'prorratea_al_costo, afecta_base_ii, base_prorrateo\n',
  E'prorratea_al_costo, afecta_base_ii, base_prorrateo, concepto_id, medida_id\n');
SELECT public._mig278_ancla(
  'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure,
  E'v_cargo.afecta_base_ii, v_cargo.base_prorrateo\n',
  E'v_cargo.afecta_base_ii, v_cargo.base_prorrateo, v_cargo.concepto_id, v_cargo.medida_id\n');

DROP FUNCTION public._mig278_ancla(regprocedure, text, text);

-- -------------------------------------------------------------------------
-- 11 · Verificacion. Si algo de esto falla, no se aplica nada.
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  v_n    integer;
  v_def  text;
  v_fn   text;
BEGIN
  -- Seed.
  SELECT count(*) INTO v_n FROM public.cargo_medidas;
  IF v_n <> 3 THEN RAISE EXCEPTION 'Se esperaban 3 medidas sembradas y hay %', v_n; END IF;
  SELECT count(*) INTO v_n FROM public.cargo_medidas l JOIN public.cargo_medidas b ON b.id = l.medida_base_id
   WHERE l.nombre = 'Lugar en el flete' AND b.nombre = 'Pallet';
  IF v_n <> 1 THEN RAISE EXCEPTION '"Lugar en el flete" no quedo con Pallet de base'; END IF;
  SELECT count(*) INTO v_n FROM public.cargo_conceptos;
  IF v_n <> 4 THEN RAISE EXCEPTION 'Se esperaban 4 conceptos sembrados y hay %', v_n; END IF;
  IF (SELECT signo FROM public.cargo_conceptos WHERE nombre_normalizado = 'bonificacion') <> -1 THEN
    RAISE EXCEPTION 'La bonificacion sembrada no quedo con signo -1';
  END IF;

  -- La normalizacion es la del modal.
  IF public.normalizar_nombre_concepto(E'  Bonificación \t  Manaos ') <> 'bonificacion manaos' THEN
    RAISE EXCEPTION 'normalizar_nombre_concepto no normaliza como el modal: %',
      public.normalizar_nombre_concepto(E'  Bonificación \t  Manaos ');
  END IF;

  -- El CHECK de compra_cargos acepta 'medida'.
  SELECT pg_get_constraintdef(oid) INTO v_def FROM pg_constraint
   WHERE conrelid = 'public.compra_cargos'::regclass AND conname = 'compra_cargos_base_prorrateo_check';
  IF v_def NOT LIKE '%medida%' THEN RAISE EXCEPTION 'El CHECK de base_prorrateo no tiene medida: %', v_def; END IF;

  -- Las dos RPCs de compra: 'medida' en las dos listas, y concepto/medida en
  -- la normalizacion y en el INSERT. La lista vieja no puede quedar en pie.
  FOREACH v_fn IN ARRAY ARRAY[
    'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)',
    'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric)'
  ] LOOP
    v_def := pg_get_functiondef(v_fn::regprocedure);
    IF v_def LIKE $q$%NOT IN ('monto','cantidad','unidades')%$q$ THEN
      RAISE EXCEPTION '% conserva una lista de bases sin medida', v_fn;
    END IF;
    IF (length(v_def) - length(replace(v_def, $q$'unidades','medida')$q$, ''))) / length($q$'unidades','medida')$q$) <> 2 THEN
      RAISE EXCEPTION '% no tiene medida en las dos listas de bases', v_fn;
    END IF;
    IF v_def NOT LIKE $q$%'concepto_id',%$q$ OR v_def NOT LIKE '%base_prorrateo, concepto_id, medida_id%'
       OR v_def NOT LIKE $q$%(c.val->>'medida_id')::BIGINT%$q$ THEN
      RAISE EXCEPTION '% no guarda concepto_id / medida_id', v_fn;
    END IF;
  END LOOP;

  v_def := pg_get_functiondef('public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure);
  IF v_def NOT LIKE '%v_cargo.concepto_id, v_cargo.medida_id%' THEN
    RAISE EXCEPTION 'cambiar_proveedor_compra no copia concepto_id / medida_id';
  END IF;

  -- RLS prendida en las tres tablas nuevas.
  SELECT count(*) INTO v_n FROM pg_class
   WHERE oid IN ('public.cargo_medidas'::regclass, 'public.cargo_conceptos'::regclass, 'public.producto_medidas'::regclass)
     AND relrowsecurity;
  IF v_n <> 3 THEN RAISE EXCEPTION 'RLS apagada en alguna tabla nueva'; END IF;

  -- anon no lee ni escribe las tablas nuevas.
  IF has_table_privilege('anon', 'public.cargo_medidas', 'SELECT')
     OR has_table_privilege('anon', 'public.cargo_conceptos', 'SELECT')
     OR has_table_privilege('anon', 'public.producto_medidas', 'SELECT')
     OR has_table_privilege('anon', 'public.producto_medidas', 'INSERT') THEN
    RAISE EXCEPTION 'anon conserva privilegios sobre las tablas nuevas';
  END IF;

  -- Ni anon ni PUBLIC alcanzan las funciones nuevas; las de trigger, nadie.
  IF has_function_privilege('anon', 'public.normalizar_nombre_concepto(text)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.asegurar_cargo_concepto(text, integer, text, boolean, boolean, text, bigint)', 'EXECUTE')
     OR has_function_privilege('anon', 'public.guardar_producto_medidas(jsonb)', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.normalizar_cargo_concepto()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.validar_cargo_medida()', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.asegurar_cargo_concepto(text, integer, text, boolean, boolean, text, bigint)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.guardar_producto_medidas(jsonb)', 'EXECUTE') THEN
    RAISE EXCEPTION 'Permisos de las funciones nuevas mal puestos';
  END IF;

  -- Una sola firma de cada RPC nueva (PGRST203).
  SELECT count(*) INTO v_n FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace
   WHERE s.nspname = 'public' AND p.proname IN ('asegurar_cargo_concepto', 'guardar_producto_medidas');
  IF v_n <> 2 THEN RAISE EXCEPTION 'Hay % firmas para las dos RPCs nuevas (se esperaban 2)', v_n; END IF;

  -- La FK de producto_medidas es compuesta.
  SELECT count(*) INTO v_n FROM pg_constraint
   WHERE conrelid = 'public.producto_medidas'::regclass AND contype = 'f'
     AND confrelid = 'public.productos'::regclass AND array_length(conkey, 1) = 2;
  IF v_n <> 1 THEN RAISE EXCEPTION 'producto_medidas no quedo con FK compuesta a productos'; END IF;
END
$verif$;

COMMIT;
