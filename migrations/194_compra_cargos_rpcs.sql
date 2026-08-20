-- ============================================================================
-- 194 · Compras: las RPCs aprenden a recibir cargos y el II declarado
-- ============================================================================
-- Ver docs/archive/2026-08-18-cargos-y-cuadre-de-compras.md
--
-- La 192 creó las tablas, la 193 el motor de cálculo. Acá se enchufa ese motor
-- a las dos RPCs que la app usa de verdad:
--
--   · registrar_compra_completa  — gana `p_cargos jsonb DEFAULT '[]'` (task 9)
--   · actualizar_compra_items    — gana `p_cargos jsonb DEFAULT NULL` (task 10)
--   · las dos                    — ganan `p_ii_declarado jsonb DEFAULT '{}'`
--
-- EL II DECLARADO POR ALÍCUOTA ES LA MITAD QUE FALTABA. El motor de la 193 sabe
-- ajustar el impuesto interno calculado al declarado —`factor_ajuste`— pero las
-- RPCs sólo recibían el II TOTAL del header (`p_impuestos_internos`), no su
-- apertura `{tasa: monto}`, que es lo único que ese ajuste sabe leer. Sin este
-- parámetro el factor se calculaba en la vista previa del navegador y se tiraba
-- a la basura al guardar. La factura testigo hoy se corrige a mano con 1,0496.
--
-- Y por eso el motor ya NO corre sólo cuando hay cargos: corre cuando hay cargos
-- **o** cuando hay II declarado (`v_usar_motor`). El ajuste del II es
-- independiente de los cargos — una factura sin un solo cargo puede igual
-- declarar un II que no cuadra con el calculado.
--
-- CUANDO EL TOTAL Y LA APERTURA SE CONTRADICEN no se pisa ninguno de los dos: se
-- avisa en `warning_ii_declarado` y listo. `p_impuestos_internos` es lo que va a
-- `compras.impuestos_internos`, al cuadre contra `p_total` y a la posición
-- fiscal; `p_ii_declarado` sólo alimenta el factor. Sobrescribir el header con la
-- suma de la apertura movería la posición fiscal sin que nadie lo pidiera, y
-- fallar bloquearía una carga por una diferencia que puede ser legítima. La RPC
-- no tiene cómo saber cuál de los dos está bien. Mismo umbral de 1 peso que el
-- cuadre del total. Se avisa también si una tasa declarada no la usa ninguna
-- línea: su factor es un no-op y ese importe no se refleja en ningún costo.
--
-- LOS PESOS VIENEN POR ÍNDICE DE `p_items`, BASE 0. Y no es un capricho: cuando
-- el cliente arma el payload los `compra_items` todavía no existen, así que no
-- hay ids que mandar. El índice es lo único que el cliente puede nombrar.
--
-- POR QUÉ EL MOTOR CORRE ANTES DEL LOOP Y NO DESPUÉS DE INSERTAR LAS LÍNEAS.
-- La lectura obvia es "primero insertá las líneas, así tenés los ids, y recién
-- ahí calculá". Pero el cálculo no necesita ids REALES: necesita identificadores,
-- y los índices sirven igual —`calcular_costos_compra` es aritmética pura sobre
-- las claves que le des—. Hacerlo después obligaría a RE-DERIVAR el costo
-- promedio ponderado, porque el loop ya lo calculó con el costo sin cargos: una
-- segunda copia de la recurrencia del CPP, con su encadenamiento por producto
-- repetido, sus `stock_anterior` y su rama de "compra vieja". Duplicar esa lógica
-- es exactamente la clase de cosa que después diverge en silencio. Corriendo el
-- motor ANTES, el loop calcula el CPP con el costo real definitivo y no hay
-- ninguna lógica duplicada. Lo único que sí necesita los ids reales es
-- PERSISTIR `compra_cargo_repartos`, y eso va después del loop, que es cuando
-- existen.
--
-- FORWARD-ONLY, y es el criterio de éxito: sin `p_cargos` y sin
-- `p_ii_declarado`, `v_usar_motor` queda en false y **no se ejecuta una sola
-- línea nueva** en el camino del costo — se sigue llamando a
-- `costo_real_unitario(...)` igual que antes. Verificado registrando y editando
-- la misma compra contra la base con y sin la migración: mismo
-- `costo_real_unitario`, mismo `costo_neto_unitario` y mismo costo promedio
-- ponderado al último decimal.
--
-- LA REGLA DE ZZ, que ya está decidida y no se re-litiga: `tipo_factura` decide
-- si se agregan IMPUESTOS encima, no si se ignoran COSTOS. ZZ es el 47,9% de las
-- compras, así que conviene decir POR DÓNDE pasa y no dejarlo inferir del
-- resultado: **`calcular_costos_compra` no conoce `tipo_factura`**, y su
-- `costo_real` es `(base_costo + ii + cargos_al_costo) / cantidad`, sin una sola
-- rama por tipo. Lo que hace que ZZ se comporte distinto es que la RPC le pasa
-- **la tasa de II de cada línea en 0** —el mismo CASE que ya usaba el loop para
-- guardar la fila— y entonces `ii = base_ii × tasa × factor` da 0 cualquiera sea
-- la base y cualquiera sea el factor. El cargo, en cambio, viaja en `base_costo`
-- (si es gravado) o en `cargos_al_costo` (si no lo es), y ninguno de los dos mira
-- la tasa: por eso suma igual. O sea que la regla NO está implementada con un IF
-- adentro del motor sino **poniendo la tasa en 0 en el borde**. Medido: una ZZ de
-- 4 × 1000 con flete de 400 y la línea declarando 8,6956 de II da `costo_real`
-- 1100, no 1186,96. Y `p_ii_declarado` se descarta en ZZ por el mismo motivo,
-- aunque no haría falta: contra una tasa 0 el factor es irrelevante.
--
-- SOBRECARGAS: las dos funciones cambian de firma, y `CREATE OR REPLACE` con un
-- parámetro nuevo NO reemplaza —crea una segunda—. Las viejas se DROPEAN en esta
-- misma transacción. Dos sobrecargas con rangos de aridad superpuestos dan
-- PGRST203 en runtime, invisible para tsc y para los tests; ya nos mordió en la
-- mig 176 y la post-condición de abajo lo verifica.
--
-- Los cuerpos se leen del CATÁLOGO VIVO con `pg_get_functiondef` y se parchean
-- por ancla única, igual que la 193: `migrations/` no es 1:1 con prod y copiar un
-- cuerpo del repo puede revertir lógica viva sin decir nada.
--
-- ⚠ DEPENDE DE LA 191. Los parches anclan en la marca que dejó la 193
-- (`, 0 /* mig 193: los cargos entran en la task 9 */)`). Si la 193 no está
-- aplicada, esta migración falla al aplicar en vez de dejar algo a medias.
--
-- ----------------------------------------------------------------------------
-- CINCO COSAS QUE ALGUIEN VA A QUERER "ARREGLAR", Y NO HAY QUE
-- ----------------------------------------------------------------------------
--
-- 1 · EL 4º ARGUMENTO DE `costo_real_unitario` SE QUEDA EN 0. La 193 lo introdujo
--     diciendo "los cargos entran en la task 9" y la task 9 NO lo usa, a
--     propósito. **Un cargo GRAVADO que prorratea al costo viaja adentro de
--     `base_costo`, no adentro de `cargos`**, así que pasarle el `cargos` del
--     motor como 4º argumento perdería la mitad gravada en silencio. Y el término
--     de II es estructuralmente distinto: el motor hace `base_ii × tasa × factor`
--     y esa función sólo sabe hacer `neto × tasa` — no puede expresar ni la base
--     separada ni el factor de ajuste. Por eso la rama CON cargos usa el
--     `costo_real` del motor y `costo_real_unitario` sobrevive sólo en la rama
--     SIN cargos, que es justamente lo que sostiene el forward-only. La promesa
--     de la 193 queda acotada acá: los tres call sites siguen pasando 0.
--
-- 2 · `cargos_al_costo` NO PUEDE RECONCILIAR EXACTO contra Σ (`cargos_unitarios`
--     × cantidad), ni con los tres guards de abajo puestos. `cargos_unitarios` es
--     `numeric(12,4)` y el cargo se divide por la cantidad: 500 sobre 3 unidades
--     da 166,6667 × 3 = 500,0001 al reconstruir. La 193 enumera dos excepciones
--     (cantidad 0 y peso fuera de rango) y las dos están cerradas acá, pero el
--     redondeo es estructural y no se cierra. Por eso **el check COMPRA-A3 lleva
--     tolerancia —un centavo por línea más el redondeo del unitario—, no
--     igualdad.** Lo mismo ya pasa hoy con `costo_real_unitario`.
--     (Y se llama A3 y no A2 porque **A2 ya existía**: `compras.subtotal =
--     SUM(compra_items.subtotal)`, en rojo con 5 legacy. Medido, no supuesto.)
--
-- 3 · UN CARGO `en_factura` NO LLEGA SOLO A `compras.no_gravado`. Los pallets
--     están en el papel y suman al cuadre, pero esta RPC no toca el header: el
--     cliente tiene que incluirlos en `p_no_gravado`. Si no lo hace salta el
--     warning blando de descuadre, que es lo correcto. Va en el trabajo de front.
--
-- 4 · LOS `RAISE` DE ACÁ NO ABORTAN LA TRANSACCIÓN DEL LLAMADOR. Las dos RPCs
--     terminan en `EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object(...)`,
--     así que una validación que falla vuelve como `{"success": false, "error":
--     "..."}` con HTTP 200 y el bloque plpgsql revierte todo lo que la RPC había
--     escrito — nada queda a medias. Pero la transacción EXTERNA no se aborta.
--     Hoy da igual porque el front no las llama adentro de una transacción más
--     grande; si algún día lo hiciera, hay que mirar el `success` y no confiar en
--     que la excepción se propague sola.
--
-- 5 · SON DOS LOS GUARDS DE LA EDICIÓN, NO UNO, y el segundo no es opcional.
--     `p_ii_declarado` mueve el costo guardado igual que los cargos, así que se
--     PERSISTE en `compras.ii_declarado` (mig 192) y `actualizar_compra_items`
--     rechaza la edición que no lo reenvía sobre una compra que lo tiene. Sin eso
--     el ajuste se revertía SOLO en la primera edición de un cliente viejo, y es
--     peor que la pérdida de los cargos en un aspecto: los cargos se reconstruyen
--     desde `compra_cargos`, un factor revertido no deja ningún rastro.
--     Los dos guards son independientes porque las dos entradas lo son: una
--     compra puede tener apertura sin un solo cargo, y de hecho ése es el caso
--     normal. Una apertura vacía se persiste como NULL y no como `{}`, para que
--     el guard no rechace a un cliente viejo por una compra sin ajuste ninguno.
--
-- ----------------------------------------------------------------------------
-- ⚠ LO QUE ESTA MIGRACIÓN NO CIERRA: `cambiar_proveedor_compra`
-- ----------------------------------------------------------------------------
-- Medido sobre el catálogo vivo, no inferido: esa RPC anula y CLONA la compra, y
-- las dos copias van con lista de columnas EXPLÍCITA. Con esta tanda aplicada, el
-- clon queda así:
--   · `compras.ii_declarado`        NO se copia  → la apertura desaparece;
--   · `compra_items.cargos_unitarios` NO se copia → cae al DEFAULT 0;
--   · `compra_cargos` y `compra_cargo_repartos` NO se clonan (cuelgan de compra_id);
--   · `costo_real_unitario` SÍ se copia, con los cargos y el factor ya adentro.
-- O sea que después de un cambio de proveedor queda exactamente el estado que el
-- rollback de la 192 describe como el peor: costos que incluyen cargos sin
-- ningún registro de su origen. Y el comentario de esa RPC —"clonar items
-- verbatim (incluye snapshots fiscales)"— pasa a ser falso.
-- NO se parchea acá a propósito: es una tercera RPC, clonar los cargos exige
-- remapear ids (cargo nuevo → línea nueva) y eso pide su propio ensayo. Hoy no
-- hay una sola compra con cargos, así que la ventana está abierta; hay que
-- cerrarla antes de que el front empiece a cargarlos.
-- ============================================================================

BEGIN;

-- ----------------------------------------------------------------------------
-- 0 · Helper de parcheo: reemplaza exigiendo que el ancla sea única
--
-- Mismo patrón que las migs 176/177/178/191. Si el ancla no aparece exactamente
-- una vez, la migración FALLA en vez de aplicar un parche parcial.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig192_reemplazo_unico(
  p_texto text, p_ancla text, p_nuevo text, p_donde text
) RETURNS text LANGUAGE plpgsql IMMUTABLE AS $helper$
DECLARE
  v_veces integer;
BEGIN
  v_veces := (length(p_texto) - length(replace(p_texto, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'mig 194 · % : el ancla "%" aparece % veces (se esperaba 1). El cuerpo derivó del texto conocido; revisá el parche antes de aplicar.',
      p_donde, left(p_ancla, 90), v_veces;
  END IF;
  RETURN replace(p_texto, p_ancla, p_nuevo);
END;
$helper$;

-- ----------------------------------------------------------------------------
-- 1 · TASK 9 · registrar_compra_completa acepta cargos y el II declarado
--
-- Cinco parches sobre el cuerpo vivo:
--   a) la firma gana `p_cargos jsonb DEFAULT '[]'::jsonb` AL FINAL. Con DEFAULT
--      y siendo el único agregado, un cliente viejo sigue andando tal cual.
--   b) las variables nuevas.
--   c) el bloque de validación + motor, justo antes del loop.
--   d) el costo real de la línea sale del motor cuando hay cargos.
--   e) la línea guarda `cargos_unitarios` y devuelve su id, para poder mapear
--      índice → compra_item_id al persistir los repartos después del loop.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE
  v_vieja constant text := 'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric)';
  v_nueva constant text := 'public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb)';
  v_def   text;
BEGIN
  -- Idempotencia por FIRMA y no por marca en el cuerpo: es lo único que no puede
  -- dar un falso positivo si mañana alguien menciona "mig 194" en un comentario.
  IF to_regprocedure(v_nueva) IS NOT NULL AND to_regprocedure(v_vieja) IS NULL THEN
    RETURN;
  END IF;
  IF to_regprocedure(v_vieja) IS NULL THEN
    RAISE EXCEPTION 'mig 194 · no existe % en el catálogo. Esta migración parchea el cuerpo vivo: revisá qué le pasó antes de seguir.', v_vieja;
  END IF;

  v_def := pg_get_functiondef(to_regprocedure(v_vieja));

  IF position(', 0 /* mig 193: los cargos entran en la task 9 */)' in v_def) = 0 THEN
    RAISE EXCEPTION 'mig 194 · registrar_compra_completa no tiene la marca de la mig 193. Aplicá la 193 antes que ésta.'
      USING ERRCODE = '22023';
  END IF;

  -- a) firma -----------------------------------------------------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$p_no_gravado numeric DEFAULT 0)$a$,
    $a$p_no_gravado numeric DEFAULT 0, p_cargos jsonb DEFAULT '[]'::jsonb, p_ii_declarado jsonb DEFAULT '{}'::jsonb)$a$,
    'registrar_compra_completa · firma');

  -- b) variables -------------------------------------------------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$  v_user_role           TEXT;
BEGIN$a$,
    $a$  v_user_role           TEXT;
  -- mig 194 · cargos prorrateados
  v_cargos              JSONB;       -- p_cargos normalizado: ES la version que se valida, se calcula y se guarda
  v_hay_cargos          BOOLEAN := false;
  v_items_motor         JSONB;
  v_costos              JSONB;
  v_costos_por_linea    JSONB;       -- {indice: {costo_real, cargos, ...}}
  v_linea_costos        JSONB;
  v_idx                 INTEGER := 0;
  v_n_items             INTEGER;
  v_item_id             BIGINT;
  v_item_ids            BIGINT[] := '{}';
  v_cargo_unit          NUMERIC := 0;
  v_concepto            TEXT;
  v_clave               TEXT;
  v_motivo              TEXT;
  v_ii_declarado        JSONB;       -- p_ii_declarado normalizado ({} en ZZ)
  v_ii_suma             NUMERIC;
  v_usar_motor          BOOLEAN := false;
  v_warning_ii          TEXT;
BEGIN$a$,
    'registrar_compra_completa · declaraciones');

  -- c) validación + motor, antes del loop ------------------------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT id, stock, costo_promedio INTO v_producto$a$,
    $a$  /* ── mig 194 · cargos prorrateados ──────────────────────────────────────
       Los pesos vienen por INDICE de p_items (base 0): cuando el cliente arma el
       payload los compra_items todavia no existen. El motor corre ACA, sobre esos
       indices, para que el loop calcule el costo promedio ponderado con el costo
       real definitivo y no haya que re-derivar el CPP. Los repartos se persisten
       despues del loop, ya con los ids reales.                                  */
  IF p_cargos IS NULL OR jsonb_typeof(p_cargos) = 'null' THEN
    p_cargos := '[]'::JSONB;
  END IF;
  IF jsonb_typeof(p_cargos) <> 'array' THEN
    RAISE EXCEPTION 'p_cargos tiene que ser un array de cargos y llego %.', jsonb_typeof(p_cargos);
  END IF;
  v_hay_cargos := jsonb_array_length(p_cargos) > 0;

  /* El impuesto interno DECLARADO por alicuota: {tasa: monto}. Es lo unico que
     el ajuste del motor sabe leer, y sin este parametro el factor se calculaba en
     la vista previa del navegador y se tiraba a la basura al guardar.
     En ZZ se descarta, con el mismo criterio que el IVA, las dos percepciones y
     el II total del header: en ZZ no se agregan impuestos encima. Aunque no se
     descartara daria igual —la tasa de cada linea tambien va en 0 y el II del
     motor es base_ii x tasa x factor—, pero descartarlo lo deja dicho. */
  v_ii_declarado := CASE
    WHEN v_es_zz THEN '{}'::JSONB
    WHEN p_ii_declarado IS NULL OR jsonb_typeof(p_ii_declarado) = 'null' THEN '{}'::JSONB
    ELSE p_ii_declarado END;
  IF jsonb_typeof(v_ii_declarado) <> 'object' THEN
    RAISE EXCEPTION 'p_ii_declarado tiene que ser un objeto {tasa: monto} y llego %.', jsonb_typeof(v_ii_declarado);
  END IF;

  -- Un declarado NEGATIVO daria un factor negativo y le daria vuelta el signo al
  -- II de TODAS las lineas de ese bucket. El 0 si es legal y significa algo: "esa
  -- alicuota no tributa en esta factura". El resto de la forma —que las claves
  -- sean tasas, que los montos sean numeros, que dos claves no colapsen al mismo
  -- bucket de 4 decimales— lo valida el motor con sus propios mensajes.
  SELECT d.key INTO v_clave
    FROM jsonb_each(v_ii_declarado) d
   WHERE jsonb_typeof(d.value) = 'number' AND (d.value #>> '{}')::NUMERIC < 0
   ORDER BY d.key
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'El impuesto interno declarado para la tasa % es negativo. El 0 es valido (esa alicuota no tributa en esta factura); un negativo le daria vuelta el signo al II de todas las lineas de esa tasa.', v_clave;
  END IF;

  v_n_items := CASE WHEN jsonb_typeof(p_items) = 'array' THEN jsonb_array_length(p_items) ELSE 0 END;

  -- El motor corre si hay cargos O si hay II declarado. El ajuste del II es
  -- INDEPENDIENTE de los cargos: una factura sin un solo cargo puede igual
  -- declarar un II que no cuadra con el calculado — es el caso de la factura
  -- testigo, que hoy se ajusta a mano con 1,0496. Sin ninguno de los dos no se
  -- ejecuta una sola linea nueva del camino del costo: ahi esta el forward-only.
  v_usar_motor := (v_hay_cargos OR v_ii_declarado <> '{}'::JSONB) AND v_n_items > 0;

  IF v_hay_cargos THEN
    IF v_n_items = 0 THEN
      RAISE EXCEPTION 'Hay cargos para prorratear pero la compra no tiene lineas.';
    END IF;

    -- Forma del cargo. El CASE fuerza el orden de evaluacion en los dos lados.
    SELECT (c.ord - 1)::TEXT,
           CASE WHEN jsonb_typeof(c.val) <> 'object'                    THEN 'no es un objeto'
                WHEN COALESCE(btrim(c.val->>'concepto'), '') = ''        THEN 'no tiene concepto'
                ELSE 'no tiene un monto numerico' END
      INTO v_clave, v_motivo
      FROM jsonb_array_elements(p_cargos) WITH ORDINALITY AS c(val, ord)
     WHERE CASE WHEN jsonb_typeof(c.val) <> 'object'               THEN true
                WHEN COALESCE(btrim(c.val->>'concepto'), '') = ''  THEN true
                ELSE jsonb_typeof(c.val->'monto') <> 'number' END
     ORDER BY c.ord
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo en la posicion % %.', v_clave, v_motivo;
    END IF;

    -- Dominios y banderas. Sin esto un typo en condicion_iva cae en la rama NO
    -- gravada y el cargo deja de sumar a la base de IVA sin avisar, y una bandera
    -- que no es booleana revienta en el cast sin nombrar el cargo. La clave
    -- ausente y el null explicito valen lo mismo: el default.
    SELECT COALESCE(c.val->>'concepto', '?'),
           CASE WHEN COALESCE(c.val->>'condicion_iva', 'no_gravado') NOT IN ('gravado','exento','no_gravado')
                  THEN 'tiene una condicion_iva invalida (se espera gravado, exento o no_gravado)'
                WHEN COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades')
                  THEN 'tiene una base_prorrateo invalida (se espera monto, cantidad o unidades)'
                ELSE 'tiene en_factura, prorratea_al_costo o afecta_base_ii con un valor que no es booleano'
           END
      INTO v_concepto, v_motivo
      FROM jsonb_array_elements(p_cargos) AS c(val)
     WHERE COALESCE(c.val->>'condicion_iva', 'no_gravado') NOT IN ('gravado','exento','no_gravado')
        OR COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades')
        OR jsonb_typeof(COALESCE(NULLIF(c.val->'en_factura',         'null'::JSONB), 'true'::JSONB))  <> 'boolean'
        OR jsonb_typeof(COALESCE(NULLIF(c.val->'prorratea_al_costo', 'null'::JSONB), 'true'::JSONB))  <> 'boolean'
        OR jsonb_typeof(COALESCE(NULLIF(c.val->'afecta_base_ii',     'null'::JSONB), 'false'::JSONB)) <> 'boolean'
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo "%" %.', v_concepto, v_motivo;
    END IF;

    -- El vector de pesos tiene que ser un objeto {indice: peso}. Ausente ≡ {}.
    SELECT COALESCE(c.val->>'concepto', '?') INTO v_concepto
      FROM jsonb_array_elements(p_cargos) AS c(val)
     WHERE jsonb_typeof(COALESCE(NULLIF(c.val->'pesos', 'null'::JSONB), '{}'::JSONB)) <> 'object'
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo "%" tiene un vector de pesos que no es un objeto {indice: peso}.', v_concepto;
    END IF;

    -- Claves y valores del vector. Las claves NO se castean a int hasta estar
    -- validadas: se comparan como numeric, que no desborda. La forma canonica
    -- importa tanto como el rango — "01" y "1" son claves jsonb distintas que
    -- apuntan a la MISMA linea y le cobrarian el cargo dos veces.
    -- Y el fuera de rango es el agujero que la 193 dejo anotado para esta RPC:
    -- prorratear_cargo reparte igual, pero ese pedazo no matchea ninguna linea y
    -- el cargo se EVAPORA del costo aunque siga contado en el total.
    SELECT COALESCE(c.val->>'concepto', '?'), w.key,
           CASE WHEN w.key !~ '^[0-9]+$'                THEN 'no es un indice de linea'
                WHEN w.key <> (w.key::NUMERIC)::TEXT    THEN format('no esta en forma canonica (sobra un cero a la izquierda: es la misma linea que "%s"), y dos claves que apuntan a la misma linea le cobrarian el cargo dos veces', (w.key::NUMERIC)::TEXT)
                WHEN w.key::NUMERIC > v_n_items - 1     THEN format('apunta a una linea que no existe: la compra tiene %s (indices 0 a %s)', v_n_items, v_n_items - 1)
                ELSE 'tiene un peso que no es un numero finito no negativo; el 0 excluye la linea' END
      INTO v_concepto, v_clave, v_motivo
      FROM jsonb_array_elements(p_cargos) AS c(val)
      CROSS JOIN LATERAL jsonb_each(COALESCE(NULLIF(c.val->'pesos', 'null'::JSONB), '{}'::JSONB)) AS w
     WHERE CASE WHEN w.key !~ '^[0-9]+$'              THEN true
                WHEN w.key <> (w.key::NUMERIC)::TEXT  THEN true
                WHEN w.key::NUMERIC > v_n_items - 1   THEN true
                WHEN jsonb_typeof(w.value) <> 'number' THEN true
                ELSE (w.value #>> '{}')::NUMERIC < 0 END
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo "%": la clave "%" %.', v_concepto, v_clave, v_motivo;
    END IF;

    -- Normalizacion canonica. El monto va a numeric(12,2) y el peso a
    -- numeric(16,4): si el motor calculara con los crudos, el costo persistido no
    -- se podria reproducir despues leyendo las filas. Una sola version para
    -- validar, calcular y guardar.
    SELECT jsonb_agg(jsonb_build_object(
             'orden',              (c.ord - 1)::INT,
             'concepto',           btrim(c.val->>'concepto'),
             'monto',              round((c.val->>'monto')::NUMERIC, 2),
             'condicion_iva',      COALESCE(c.val->>'condicion_iva', 'no_gravado'),
             'en_factura',         COALESCE((c.val->>'en_factura')::BOOLEAN, true),
             'prorratea_al_costo', COALESCE((c.val->>'prorratea_al_costo')::BOOLEAN, true),
             'afecta_base_ii',     COALESCE((c.val->>'afecta_base_ii')::BOOLEAN, false),
             'base_prorrateo',     COALESCE(c.val->>'base_prorrateo', 'unidades'),
             'pesos',              COALESCE((SELECT jsonb_object_agg(w.key, round((w.value #>> '{}')::NUMERIC, 4))
                                               FROM jsonb_each(COALESCE(NULLIF(c.val->'pesos', 'null'::JSONB), '{}'::JSONB)) w),
                                            '{}'::JSONB)
           ) ORDER BY c.ord)
      INTO v_cargos
      FROM jsonb_array_elements(p_cargos) WITH ORDINALITY AS c(val, ord);

    -- Un cargo que prorratea y no apunta a ninguna linea se evaporaria del costo
    -- SIN UN SOLO AVISO: el motor trata el vector vacio como legal (es el estado
    -- de una grilla a medio llenar) y devuelve 0 filas.
    SELECT c.val->>'concepto' INTO v_concepto
      FROM jsonb_array_elements(v_cargos) AS c(val)
     WHERE (c.val->>'prorratea_al_costo')::BOOLEAN
       AND COALESCE((SELECT sum((w.value #>> '{}')::NUMERIC) FROM jsonb_each(c.val->'pesos') w), 0) = 0
     ORDER BY (c.val->>'orden')::INT
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo "%" no tiene ninguna línea asignada', v_concepto;
    END IF;

    -- Y un peso positivo sobre una linea de cantidad 0 lo evapora igual, por la
    -- otra puerta: el unitario se derivaria dividiendo por cero, asi que el motor
    -- lo fuerza a 0 y ese pedazo del cargo no vuelve a salir por ningun lado. Es
    -- la segunda excepcion que la 193 declara y no puede atajar.
    SELECT c.val->>'concepto', w.key INTO v_concepto, v_clave
      FROM jsonb_array_elements(v_cargos) AS c(val)
      CROSS JOIN LATERAL jsonb_each(c.val->'pesos') AS w
     WHERE (c.val->>'prorratea_al_costo')::BOOLEAN
       AND (w.value #>> '{}')::NUMERIC > 0
       AND (p_items->(w.key::INT)->>'cantidad')::NUMERIC = 0
     ORDER BY (c.val->>'orden')::INT, w.key
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo "%" reparte sobre la linea % que tiene cantidad 0: ese importe no se podria expresar en el costo unitario y se perderia.',
        v_concepto, v_clave;
    END IF;

  ELSE
    v_cargos := '[]'::JSONB;
  END IF;

  IF v_usar_motor THEN
    /* EL MOTOR, SOBRE LOS INDICES.

       ACA PASA LA REGLA DE ZZ, y conviene leerla de un renglon porque
       `calcular_costos_compra` NO conoce `tipo_factura`: su costo_real es
       (base_costo + ii + cargos_al_costo) / cantidad, sin una sola rama por tipo
       de factura. Lo que hace que ZZ se comporte distinto es que la tasa de II de
       cada linea le llega en 0 —el CASE de aca abajo la fuerza, igual que el loop
       de mas abajo— y entonces `ii = base_ii x tasa x factor` da 0 cualquiera sea
       la base y cualquiera sea el factor. El cargo, en cambio, viaja en
       base_costo (si es gravado) o en cargos_al_costo (si no lo es), y ninguno de
       los dos mira la tasa: por eso suma igual.
       O sea que la regla —el tipo de factura decide si se agregan IMPUESTOS
       encima, no si se ignoran COSTOS— no esta implementada con un IF adentro del
       motor sino poniendo la tasa en 0 EN EL BORDE. Medido: una ZZ de 4 x 1000
       con flete de 400 y la linea declarando 8,6956 de II da costo_real 1100, no
       1186,96.

       `porcentaje_iva` y `condicion_iva` se normalizan con el mismo CASE del loop
       aunque no muevan el costo_real: asi el motor ve exactamente la fila que se
       va a guardar y no una version paralela.                                    */
    SELECT jsonb_agg(jsonb_build_object(
             'id',                 (e.ord - 1)::INT,
             'cantidad',           (e.val->>'cantidad')::INT,
             'costo_unitario',     COALESCE((e.val->>'costo_unitario')::NUMERIC, 0),
             'bonificacion',       COALESCE((e.val->>'bonificacion')::NUMERIC, 0),
             'impuestos_internos', CASE WHEN v_es_zz THEN 0
                                        ELSE COALESCE((e.val->>'impuestos_internos')::NUMERIC, 0) END,
             'porcentaje_iva',     CASE WHEN v_es_zz OR n.cond <> 'gravado' THEN 0
                                        ELSE COALESCE((e.val->>'porcentaje_iva')::NUMERIC, 21) END,
             'condicion_iva',      n.cond
           ) ORDER BY e.ord)
      INTO v_items_motor
      FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(val, ord)
      CROSS JOIN LATERAL (SELECT CASE
             WHEN v_es_zz THEN 'gravado'
             WHEN COALESCE(e.val->>'condicion_iva', 'gravado') IN ('exento','no_gravado')
               THEN e.val->>'condicion_iva'
             ELSE 'gravado' END AS cond) n;

    v_costos := calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado);

    SELECT jsonb_object_agg(l->>'id', l) INTO v_costos_por_linea
      FROM jsonb_array_elements(v_costos->'lineas') l;

    /* AVISO BLANDO, no bloqueante: el II TOTAL del header y la APERTURA por
       alicuota son dos numeros que el usuario tipea por separado y pueden
       contradecirse. NO se pisa ninguno de los dos, y es deliberado.
       `p_impuestos_internos` es lo que va a compras.impuestos_internos, al cuadre
       contra p_total y a la posicion fiscal; `p_ii_declarado` solo alimenta el
       factor de ajuste. Sobrescribir el header con la suma de la apertura
       cambiaria la posicion fiscal sin que nadie lo haya pedido, y fallar
       bloquearia una carga por una diferencia que puede ser legitima. La RPC no
       tiene como saber cual de los dos esta bien: avisa y deja los dos como
       llegaron. Mismo umbral de 1 peso que el cuadre del total.                  */
    IF v_ii_declarado <> '{}'::JSONB THEN
      SELECT COALESCE(sum((d.value #>> '{}')::NUMERIC), 0) INTO v_ii_suma
        FROM jsonb_each(v_ii_declarado) d;
      IF abs(v_ii_suma - COALESCE(v_ii_hdr, 0)) > 1 THEN
        v_warning_ii := format('El impuesto interno declarado por alicuota suma %s y el total informado es %s.',
                               round(v_ii_suma, 2), round(COALESCE(v_ii_hdr, 0), 2));
      END IF;

      -- Y una tasa declarada que no usa NINGUNA linea: su factor es un no-op
      -- (calculado = 0 => factor 1) y ese importe no se refleja en ningun costo.
      SELECT string_agg(d.key, ', ' ORDER BY d.key) INTO v_clave
        FROM jsonb_each(v_ii_declarado) d
       WHERE NOT EXISTS (
         SELECT 1 FROM jsonb_array_elements(v_items_motor) l
          WHERE round((l->>'impuestos_internos')::NUMERIC, 4) = round((d.key)::NUMERIC, 4));
      IF v_clave IS NOT NULL THEN
        v_warning_ii := COALESCE(v_warning_ii || ' ', '')
          || format('Las tasas declaradas %s no las usa ninguna linea: ese importe no se refleja en ningun costo.', v_clave);
      END IF;
    END IF;
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_idx := v_idx + 1;   /* mig 194 · posicion en p_items, base 1 */

    SELECT id, stock, costo_promedio INTO v_producto$a$,
    'registrar_compra_completa · bloque de cargos');

  -- d) el costo real de la línea sale del motor cuando hay cargos -------------
  --
  -- No se llama a costo_real_unitario() en esa rama, y no es un olvido: esa
  -- función sabe hacer `neto × tasa`, y el motor calcula el II sobre `base_ii`
  -- (que puede incluir cargos) por un factor de ajuste. Además el cargo GRAVADO
  -- que prorratea al costo viaja adentro de `base_costo`, no de `cargos`: pasarle
  -- sólo `cargos` como 4º argumento perdería esa mitad. La 193 documenta la misma
  -- asimetría del lado del motor. Sin cargos la expresión es la de siempre, con
  -- la marca de la 193 intacta: ahí está el forward-only.
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$v_costo_real    := costo_real_unitario(v_costo_neto, v_impuestos_internos, v_tipo_factura, 0 /* mig 193: los cargos entran en la task 9 */);$a$,
    $a$v_cargo_unit    := 0;   /* mig 194 */
    IF v_usar_motor AND v_cantidad > 0 THEN
      v_linea_costos := v_costos_por_linea -> (v_idx - 1)::TEXT;
      IF v_linea_costos IS NULL THEN
        RAISE EXCEPTION 'mig 194 · el motor no devolvio la linea %.', v_idx - 1;
      END IF;
      v_cargo_unit  := round((v_linea_costos->>'cargos')::NUMERIC, 4);
      v_costo_real  := round((v_linea_costos->>'costo_real')::NUMERIC, 4);
    ELSE
      v_costo_real  := costo_real_unitario(v_costo_neto, v_impuestos_internos, v_tipo_factura, 0 /* mig 193: los cargos entran en la task 9 */);
    END IF;$a$,
    'registrar_compra_completa · costo real de la linea');

  -- e) la línea guarda cargos_unitarios y devuelve su id ----------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva
    ) VALUES ($a$,
    $a$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva, cargos_unitarios /* mig 194 */
    ) VALUES ($a$,
    'registrar_compra_completa · columnas de compra_items');

  -- `costo_neto_unitario` se deja como estaba: `round(v_costo_neto, 4)` YA ES el
  -- `costo_neto` que devuelve el motor (neto/cantidad = costo_unitario ×
  -- (1 − bonif/100)), redondeado al mismo lugar. Pisarlo con el del motor sería
  -- escribir el mismo número por otro camino y mover una coma del camino sin
  -- cargos para nada.
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$      round(v_costo_neto, 4),
      v_costo_real,
      v_condicion_iva
    );$a$,
    $a$      round(v_costo_neto, 4),
      v_costo_real,
      v_condicion_iva,
      v_cargo_unit /* mig 194 */
    )
    RETURNING id INTO v_item_id;

    /* mig 194 · el indice del payload (base 0) es v_item_ids[indice + 1]. Es el
       unico puente entre los pesos que mando el cliente y los ids reales. */
    v_item_ids := v_item_ids || v_item_id;$a$,
    'registrar_compra_completa · valores de compra_items');

  -- f) el aviso del II declarado, en la respuesta ----------------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$    'warning_descuadre', v_warning
  );$a$,
    $a$    'warning_descuadre', v_warning,
    'warning_ii_declarado', v_warning_ii /* mig 194 */
  );$a$,
    'registrar_compra_completa · aviso del II declarado');

  -- g) persistir los cargos y sus repartos, ya con los ids reales -------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$  -- Control blando de cuadre contra el total informado$a$,
    $a$  /* mig 194 · la apertura del II, para que el ajuste no se evapore. Se guarda
     el jsonb NORMALIZADO, o sea vacio en ZZ. Una apertura vacia se persiste como
     NULL y no como {}: no ajusta nada, asi que no hay nada que proteger, y
     guardar {} haria que el guard de la edicion rechazara a un cliente viejo por
     una compra que no tiene ajuste ninguno.                                     */
  IF v_ii_declarado <> '{}'::JSONB THEN
    UPDATE compras SET ii_declarado = v_ii_declarado
     WHERE id = v_compra_id AND sucursal_id = v_sucursal;
  END IF;

  /* mig 194 · los cargos, ya con los ids reales de las lineas.
     Los montos y los pesos son los NORMALIZADOS (v_cargos): las mismas cifras con
     las que se calculo el costo de arriba, para que la compra se pueda recalcular
     desde sus filas y de lo mismo.                                             */
  IF v_hay_cargos THEN
    INSERT INTO compra_cargos (
      compra_id, sucursal_id, usuario_id, orden, concepto, monto,
      condicion_iva, en_factura, prorratea_al_costo, afecta_base_ii, base_prorrateo
    )
    SELECT v_compra_id, v_sucursal, p_usuario_id,
           (c.val->>'orden')::INT,
           c.val->>'concepto',
           (c.val->>'monto')::NUMERIC,
           c.val->>'condicion_iva',
           (c.val->>'en_factura')::BOOLEAN,
           (c.val->>'prorratea_al_costo')::BOOLEAN,
           (c.val->>'afecta_base_ii')::BOOLEAN,
           c.val->>'base_prorrateo'
      FROM jsonb_array_elements(v_cargos) AS c(val);

    INSERT INTO compra_cargo_repartos (cargo_id, compra_item_id, compra_id, peso)
    SELECT cc.id, v_item_ids[(w.key)::INT + 1], v_compra_id, (w.value #>> '{}')::NUMERIC
      FROM compra_cargos cc
      JOIN jsonb_array_elements(v_cargos) AS c(val) ON (c.val->>'orden')::INT = cc.orden
      CROSS JOIN LATERAL jsonb_each(c.val->'pesos') AS w
     WHERE cc.compra_id = v_compra_id;
  END IF;

  -- Control blando de cuadre contra el total informado$a$,
    'registrar_compra_completa · persistencia de los cargos');

  EXECUTE v_def;
  EXECUTE format('DROP FUNCTION %s', v_vieja);
END;
$mig$;

-- `pg_get_functiondef` no trae los GRANT: la función nueva nace con los
-- privilegios por defecto del rol que aplique. Sin esto, crear la de 18
-- argumentos puede reabrir a PUBLIC lo que cerraron las migs 188/189 y poner en
-- rojo el gate de permisos de CI. `anon` va nombrado aparte porque una concesión
-- explícita del ALTER DEFAULT PRIVILEGES no se va revocando PUBLIC.
REVOKE ALL ON FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb) TO authenticated, service_role;

COMMENT ON FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb) IS
  'Alta de una compra con stock, costos y costo promedio ponderado. Desde la mig '
  '194 acepta p_cargos: [{concepto, monto, condicion_iva, en_factura, '
  'prorratea_al_costo, afecta_base_ii, base_prorrateo, pesos}]. LOS PESOS VAN POR '
  'INDICE DE p_items, BASE 0 — cuando el cliente arma el payload los compra_items '
  'todavia no existen. Un peso fuera de rango, un cargo que prorratea sin ninguna '
  'linea asignada o un peso positivo sobre una linea de cantidad 0 FALLAN: las '
  'tres formas hacen que el cargo se evapore del costo sin aviso. '
  'Acepta ademas p_ii_declarado {tasa: monto}, la apertura POR ALICUOTA del '
  'impuesto interno de la factura: es lo unico que el factor de ajuste del motor '
  'sabe leer, y sin el ese factor se calculaba en el navegador y se tiraba al '
  'guardar. Si la apertura no suma lo mismo que p_impuestos_internos NO se pisa '
  'ninguno de los dos: se avisa en warning_ii_declarado. La apertura se PERSISTE '
  'en compras.ii_declarado (NULL si viene vacia) para que el ajuste no se pueda '
  'revertir solo en una edicion posterior. Sin p_cargos y sin p_ii_declarado el '
  'costo es identico al de antes de la 194 (forward-only).';

-- ----------------------------------------------------------------------------
-- 2 · TASK 10 · editar una compra ya no le borra los cargos en silencio
--
-- `actualizar_compra_items` hace DELETE + INSERT de las líneas en CADA edición, y
-- por el CASCADE de la 192 eso se lleva puesto TODOS los `compra_cargo_repartos`
-- de la compra. Los `compra_cargos` sobreviven, porque cuelgan de `compra_id`.
-- El estado que queda es el peor posible: cargos vivos con el vector de pesos
-- vacío ⇒ `sum(peso) = 0` ⇒ el flete deja de repartirse. Y el motor trata el
-- vector vacío como LEGAL —es el estado de una grilla a medio llenar—, así que no
-- grita: los cargos se caen del costo sin un solo aviso y la compra pierde el 16%
-- hasta que el check de integridad se ponga rojo.
--
-- POR QUÉ EL DEFAULT ES NULL Y NO '[]', que es lo contrario de la task 9: acá hay
-- que poder distinguir "no me mandaron cargos" (un cliente viejo) de "me mandaron
-- una lista vacía" (el usuario borró todos los cargos). Con '[]' las dos cosas
-- serían la misma y la primera borraría los cargos de la segunda manera.
--
-- El JSON `null` cuenta como NO provisto, igual que la ausencia. Un cliente que
-- manda `p_cargos: undefined` omite la clave; uno que manda `null` casi siempre
-- es un cliente que no conoce la feature, no alguien pidiendo borrar. La lista
-- vacía explícita es `[]` y no se confunde con ninguna de las dos.
--
-- Y el guard no es paranoia: este proyecto estuvo SEIS MESES sin service worker,
-- así que una pestaña abierta puede estar corriendo un bundle viejo por tiempo
-- indefinido. Un chunk viejo del PWA editando una compra con cargos es un
-- escenario real, no teórico.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE
  v_vieja constant text := 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric)';
  v_nueva constant text := 'public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb)';
  v_def   text;
BEGIN
  IF to_regprocedure(v_nueva) IS NOT NULL AND to_regprocedure(v_vieja) IS NULL THEN
    RETURN;
  END IF;
  IF to_regprocedure(v_vieja) IS NULL THEN
    RAISE EXCEPTION 'mig 194 · no existe % en el catálogo. Esta migración parchea el cuerpo vivo: revisá qué le pasó antes de seguir.', v_vieja;
  END IF;

  v_def := pg_get_functiondef(to_regprocedure(v_vieja));

  IF position(', 0 /* mig 193: los cargos entran en la task 9 */)' in v_def) = 0 THEN
    RAISE EXCEPTION 'mig 194 · actualizar_compra_items no tiene la marca de la mig 193. Aplicá la 193 antes que ésta.'
      USING ERRCODE = '22023';
  END IF;

  -- a) firma -----------------------------------------------------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$p_otros_impuestos numeric DEFAULT NULL::numeric)$a$,
    $a$p_otros_impuestos numeric DEFAULT NULL::numeric, p_cargos jsonb DEFAULT NULL::jsonb, p_ii_declarado jsonb DEFAULT NULL::jsonb)$a$,
    'actualizar_compra_items · firma');

  -- b) variables -------------------------------------------------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$  v_warning_cpp JSONB := '[]'::JSONB;
BEGIN$a$,
    $a$  v_warning_cpp JSONB := '[]'::JSONB;
  -- mig 194 · cargos prorrateados
  v_cargos_provistos BOOLEAN := (p_cargos IS NOT NULL AND jsonb_typeof(p_cargos) <> 'null');
  v_ii_provisto      BOOLEAN := (p_ii_declarado IS NOT NULL AND jsonb_typeof(p_ii_declarado) <> 'null');
  v_cargos           JSONB;
  v_hay_cargos       BOOLEAN := false;
  v_items_motor      JSONB;
  v_costos           JSONB;
  v_costos_por_linea JSONB;
  v_linea_costos     JSONB;
  v_idx              INTEGER := 0;
  v_n_items          INTEGER;
  v_item_id          BIGINT;
  v_item_ids         BIGINT[] := '{}';
  v_cargo_unit       NUMERIC := 0;
  v_concepto         TEXT;
  v_clave            TEXT;
  v_motivo           TEXT;
  v_ii_declarado     JSONB;
  v_autoria          JSONB;       -- {definicion_del_cargo: usuario_id} de antes del DELETE
  v_ii_hdr           NUMERIC;
  v_ii_suma          NUMERIC;
  v_usar_motor       BOOLEAN := false;
  v_warning_ii       TEXT;
BEGIN$a$,
    'actualizar_compra_items · declaraciones');

  -- b.1) `v_compra` gana `impuestos_internos` y `ii_declarado` ---------------
  --
  -- El total del header hace falta para comparar contra la apertura por alícuota:
  -- `p_impuestos_internos` tiene DEFAULT NULL y en ese caso la compra CONSERVA el
  -- suyo, así que el total efectivo no sale del parámetro sino de la fila.
  -- Y `ii_declarado` es lo que hace posible el segundo guard: sin traerlo, la RPC
  -- no puede saber si la compra se cargó con un factor de ajuste.
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$  SELECT id, estado, tipo_factura, created_at, fecha_compra
    INTO v_compra$a$,
    $a$  SELECT id, estado, tipo_factura, created_at, fecha_compra, impuestos_internos, ii_declarado /* mig 194 */
    INTO v_compra$a$,
    'actualizar_compra_items · v_compra gana impuestos_internos y ii_declarado');

  -- c) el guard, y después la validación + el motor ---------------------------
  --
  -- El guard va acá y no más abajo porque acá todavía no se movió NADA: los
  -- chequeos de permiso, estado y ventana de 7 días ya pasaron, y el DELETE de
  -- las líneas, los UPDATE de stock y los set_config vienen después. Devuelve
  -- success:false en vez de lanzar, que es como esta RPC comunica los rechazos
  -- de negocio y lo que el front ya sabe mostrar.
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$  v_es_zz := (v_compra.tipo_factura = 'ZZ');
  v_iva_efectivo := CASE WHEN v_es_zz THEN 0 ELSE p_iva END;$a$,
    $a$  v_es_zz := (v_compra.tipo_factura = 'ZZ');
  v_iva_efectivo := CASE WHEN v_es_zz THEN 0 ELSE p_iva END;

  /* mig 194 · el II total EFECTIVO del header: el parametro si lo mandaron, y si
     no el que ya tenia la compra — que es lo que el UPDATE de mas abajo va a
     dejar por su COALESCE. Es contra este numero que se compara la apertura. */
  v_ii_hdr := CASE WHEN v_es_zz THEN 0
                   ELSE COALESCE(p_impuestos_internos, v_compra.impuestos_internos, 0) END;

  /* ── mig 194 · cargos prorrateados ──────────────────────────────────────────
     Un cliente con un chunk viejo del PWA editando una compra con cargos borraria
     los repartos en silencio: el DELETE de compra_items cascadea, los cargos
     sobreviven con el vector vacio y el motor trata el vector vacio como legal.
     Falla explicito.                                                            */
  IF NOT v_cargos_provistos AND EXISTS (
       SELECT 1 FROM compra_cargos WHERE compra_id = p_compra_id) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Esta compra tiene cargos prorrateados. Actualizá la aplicación (recargá la página) antes de editarla.');
  END IF;

  /* mig 194 · el MISMO guard para la apertura del impuesto interno, y hace falta
     por separado: los cargos y el II declarado son dos entradas distintas y una
     compra puede tener la segunda sin la primera —de hecho es el caso normal—.
     Sin este guard, un cliente que no reenvia la apertura recalcula con factor 1
     y el ajuste se revierte SOLO. Es la misma perdida que la de los cargos, y en
     un aspecto es peor: los cargos se pueden reconstruir desde compra_cargos, y
     un factor revertido no deja absolutamente ningun rastro.
     El texto nombra la causa real en vez de repetir el de los cargos: la accion
     que el usuario tiene que hacer es la misma, pero decirle "tiene cargos
     prorrateados" a una compra que no tiene ninguno lo manda a buscar donde no
     hay nada.                                                                   */
  IF NOT v_ii_provisto AND v_compra.ii_declarado IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Esta compra tiene el impuesto interno declarado por alícuota. Actualizá la aplicación (recargá la página) antes de editarla.');
  END IF;

  IF v_cargos_provistos AND jsonb_typeof(p_cargos) <> 'array' THEN
    RAISE EXCEPTION 'p_cargos tiene que ser un array de cargos y llego %.', jsonb_typeof(p_cargos);
  END IF;
  v_hay_cargos := v_cargos_provistos AND jsonb_array_length(p_cargos) > 0;

  /* El impuesto interno DECLARADO por alicuota: {tasa: monto}. Es lo unico que
     el ajuste del motor sabe leer, y sin este parametro el factor se calculaba en
     la vista previa del navegador y se tiraba a la basura al guardar.
     En ZZ se descarta, con el mismo criterio que el IVA, las dos percepciones y
     el II total del header: en ZZ no se agregan impuestos encima. Aunque no se
     descartara daria igual —la tasa de cada linea tambien va en 0 y el II del
     motor es base_ii x tasa x factor—, pero descartarlo lo deja dicho. */
  v_ii_declarado := CASE
    WHEN v_es_zz THEN '{}'::JSONB
    WHEN p_ii_declarado IS NULL OR jsonb_typeof(p_ii_declarado) = 'null' THEN '{}'::JSONB
    ELSE p_ii_declarado END;
  IF jsonb_typeof(v_ii_declarado) <> 'object' THEN
    RAISE EXCEPTION 'p_ii_declarado tiene que ser un objeto {tasa: monto} y llego %.', jsonb_typeof(v_ii_declarado);
  END IF;

  -- Un declarado NEGATIVO daria un factor negativo y le daria vuelta el signo al
  -- II de TODAS las lineas de ese bucket. El 0 si es legal y significa algo: "esa
  -- alicuota no tributa en esta factura". El resto de la forma —que las claves
  -- sean tasas, que los montos sean numeros, que dos claves no colapsen al mismo
  -- bucket de 4 decimales— lo valida el motor con sus propios mensajes.
  SELECT d.key INTO v_clave
    FROM jsonb_each(v_ii_declarado) d
   WHERE jsonb_typeof(d.value) = 'number' AND (d.value #>> '{}')::NUMERIC < 0
   ORDER BY d.key
   LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'El impuesto interno declarado para la tasa % es negativo. El 0 es valido (esa alicuota no tributa en esta factura); un negativo le daria vuelta el signo al II de todas las lineas de esa tasa.', v_clave;
  END IF;

  v_n_items := CASE WHEN jsonb_typeof(p_items_nuevos) = 'array' THEN jsonb_array_length(p_items_nuevos) ELSE 0 END;

  -- El motor corre si hay cargos O si hay II declarado. El ajuste del II es
  -- INDEPENDIENTE de los cargos: una factura sin un solo cargo puede igual
  -- declarar un II que no cuadra con el calculado — es el caso de la factura
  -- testigo, que hoy se ajusta a mano con 1,0496. Sin ninguno de los dos no se
  -- ejecuta una sola linea nueva del camino del costo: ahi esta el forward-only.
  v_usar_motor := (v_hay_cargos OR v_ii_declarado <> '{}'::JSONB) AND v_n_items > 0;

  IF v_hay_cargos THEN
    IF v_n_items = 0 THEN
      RAISE EXCEPTION 'Hay cargos para prorratear pero la compra no tiene lineas.';
    END IF;

    -- Forma del cargo. El CASE fuerza el orden de evaluacion en los dos lados.
    SELECT (c.ord - 1)::TEXT,
           CASE WHEN jsonb_typeof(c.val) <> 'object'                    THEN 'no es un objeto'
                WHEN COALESCE(btrim(c.val->>'concepto'), '') = ''        THEN 'no tiene concepto'
                ELSE 'no tiene un monto numerico' END
      INTO v_clave, v_motivo
      FROM jsonb_array_elements(p_cargos) WITH ORDINALITY AS c(val, ord)
     WHERE CASE WHEN jsonb_typeof(c.val) <> 'object'               THEN true
                WHEN COALESCE(btrim(c.val->>'concepto'), '') = ''  THEN true
                ELSE jsonb_typeof(c.val->'monto') <> 'number' END
     ORDER BY c.ord
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo en la posicion % %.', v_clave, v_motivo;
    END IF;

    -- Dominios y banderas. La clave ausente y el null explicito valen lo mismo:
    -- el default.
    SELECT COALESCE(c.val->>'concepto', '?'),
           CASE WHEN COALESCE(c.val->>'condicion_iva', 'no_gravado') NOT IN ('gravado','exento','no_gravado')
                  THEN 'tiene una condicion_iva invalida (se espera gravado, exento o no_gravado)'
                WHEN COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades')
                  THEN 'tiene una base_prorrateo invalida (se espera monto, cantidad o unidades)'
                ELSE 'tiene en_factura, prorratea_al_costo o afecta_base_ii con un valor que no es booleano'
           END
      INTO v_concepto, v_motivo
      FROM jsonb_array_elements(p_cargos) AS c(val)
     WHERE COALESCE(c.val->>'condicion_iva', 'no_gravado') NOT IN ('gravado','exento','no_gravado')
        OR COALESCE(c.val->>'base_prorrateo', 'unidades') NOT IN ('monto','cantidad','unidades')
        OR jsonb_typeof(COALESCE(NULLIF(c.val->'en_factura',         'null'::JSONB), 'true'::JSONB))  <> 'boolean'
        OR jsonb_typeof(COALESCE(NULLIF(c.val->'prorratea_al_costo', 'null'::JSONB), 'true'::JSONB))  <> 'boolean'
        OR jsonb_typeof(COALESCE(NULLIF(c.val->'afecta_base_ii',     'null'::JSONB), 'false'::JSONB)) <> 'boolean'
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo "%" %.', v_concepto, v_motivo;
    END IF;

    -- El vector de pesos tiene que ser un objeto {indice: peso}. Ausente ≡ {}.
    SELECT COALESCE(c.val->>'concepto', '?') INTO v_concepto
      FROM jsonb_array_elements(p_cargos) AS c(val)
     WHERE jsonb_typeof(COALESCE(NULLIF(c.val->'pesos', 'null'::JSONB), '{}'::JSONB)) <> 'object'
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo "%" tiene un vector de pesos que no es un objeto {indice: peso}.', v_concepto;
    END IF;

    -- Claves y valores del vector: mismo criterio que en registrar_compra_completa.
    -- Las claves NO se castean a int hasta estar validadas: se comparan como
    -- numeric, que no desborda.
    SELECT COALESCE(c.val->>'concepto', '?'), w.key,
           CASE WHEN w.key !~ '^[0-9]+$'                THEN 'no es un indice de linea'
                WHEN w.key <> (w.key::NUMERIC)::TEXT    THEN format('no esta en forma canonica (sobra un cero a la izquierda: es la misma linea que "%s"), y dos claves que apuntan a la misma linea le cobrarian el cargo dos veces', (w.key::NUMERIC)::TEXT)
                WHEN w.key::NUMERIC > v_n_items - 1     THEN format('apunta a una linea que no existe: la compra tiene %s (indices 0 a %s)', v_n_items, v_n_items - 1)
                ELSE 'tiene un peso que no es un numero finito no negativo; el 0 excluye la linea' END
      INTO v_concepto, v_clave, v_motivo
      FROM jsonb_array_elements(p_cargos) AS c(val)
      CROSS JOIN LATERAL jsonb_each(COALESCE(NULLIF(c.val->'pesos', 'null'::JSONB), '{}'::JSONB)) AS w
     WHERE CASE WHEN w.key !~ '^[0-9]+$'              THEN true
                WHEN w.key <> (w.key::NUMERIC)::TEXT  THEN true
                WHEN w.key::NUMERIC > v_n_items - 1   THEN true
                WHEN jsonb_typeof(w.value) <> 'number' THEN true
                ELSE (w.value #>> '{}')::NUMERIC < 0 END
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo "%": la clave "%" %.', v_concepto, v_clave, v_motivo;
    END IF;

    -- Normalizacion canonica: montos a 2 decimales y pesos a 4, que es lo que
    -- guardan las columnas. Una sola version para validar, calcular y guardar.
    SELECT jsonb_agg(jsonb_build_object(
             'orden',              (c.ord - 1)::INT,
             'concepto',           btrim(c.val->>'concepto'),
             'monto',              round((c.val->>'monto')::NUMERIC, 2),
             'condicion_iva',      COALESCE(c.val->>'condicion_iva', 'no_gravado'),
             'en_factura',         COALESCE((c.val->>'en_factura')::BOOLEAN, true),
             'prorratea_al_costo', COALESCE((c.val->>'prorratea_al_costo')::BOOLEAN, true),
             'afecta_base_ii',     COALESCE((c.val->>'afecta_base_ii')::BOOLEAN, false),
             'base_prorrateo',     COALESCE(c.val->>'base_prorrateo', 'unidades'),
             'pesos',              COALESCE((SELECT jsonb_object_agg(w.key, round((w.value #>> '{}')::NUMERIC, 4))
                                               FROM jsonb_each(COALESCE(NULLIF(c.val->'pesos', 'null'::JSONB), '{}'::JSONB)) w),
                                            '{}'::JSONB)
           ) ORDER BY c.ord)
      INTO v_cargos
      FROM jsonb_array_elements(p_cargos) WITH ORDINALITY AS c(val, ord);

    -- Un cargo que prorratea y no apunta a ninguna linea se evaporaria del costo
    -- SIN UN SOLO AVISO.
    SELECT c.val->>'concepto' INTO v_concepto
      FROM jsonb_array_elements(v_cargos) AS c(val)
     WHERE (c.val->>'prorratea_al_costo')::BOOLEAN
       AND COALESCE((SELECT sum((w.value #>> '{}')::NUMERIC) FROM jsonb_each(c.val->'pesos') w), 0) = 0
     ORDER BY (c.val->>'orden')::INT
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo "%" no tiene ninguna línea asignada', v_concepto;
    END IF;

    -- Y un peso positivo sobre una linea de cantidad 0 lo evapora por la otra
    -- puerta. Acá el loop de abajo ya rechaza cantidad <= 0, asi que esto sólo
    -- adelanta el error con un mensaje que nombra el cargo; se deja para que las
    -- dos RPCs validen exactamente lo mismo y no diverjan cuando alguien toque
    -- una sola.
    SELECT c.val->>'concepto', w.key INTO v_concepto, v_clave
      FROM jsonb_array_elements(v_cargos) AS c(val)
      CROSS JOIN LATERAL jsonb_each(c.val->'pesos') AS w
     WHERE (c.val->>'prorratea_al_costo')::BOOLEAN
       AND (w.value #>> '{}')::NUMERIC > 0
       AND (p_items_nuevos->(w.key::INT)->>'cantidad')::NUMERIC = 0
     ORDER BY (c.val->>'orden')::INT, w.key
     LIMIT 1;
    IF FOUND THEN
      RAISE EXCEPTION 'El cargo "%" reparte sobre la linea % que tiene cantidad 0: ese importe no se podria expresar en el costo unitario y se perderia.',
        v_concepto, v_clave;
    END IF;

  ELSE
    v_cargos := '[]'::JSONB;
  END IF;

  IF v_usar_motor THEN
    /* EL MOTOR, SOBRE LOS INDICES.

       ACA PASA LA REGLA DE ZZ, y conviene leerla de un renglon porque
       `calcular_costos_compra` NO conoce `tipo_factura`: su costo_real es
       (base_costo + ii + cargos_al_costo) / cantidad, sin una sola rama por tipo
       de factura. Lo que hace que ZZ se comporte distinto es que la tasa de II de
       cada linea le llega en 0 —el CASE de aca abajo la fuerza, igual que el loop
       de mas abajo— y entonces `ii = base_ii x tasa x factor` da 0 cualquiera sea
       la base y cualquiera sea el factor. El cargo, en cambio, viaja en
       base_costo (si es gravado) o en cargos_al_costo (si no lo es), y ninguno de
       los dos mira la tasa: por eso suma igual.
       O sea que la regla —el tipo de factura decide si se agregan IMPUESTOS
       encima, no si se ignoran COSTOS— no esta implementada con un IF adentro del
       motor sino poniendo la tasa en 0 EN EL BORDE. Medido: una ZZ de 4 x 1000
       con flete de 400 y la linea declarando 8,6956 de II da costo_real 1100, no
       1186,96.

       `porcentaje_iva` y `condicion_iva` se normalizan con el mismo CASE del loop
       aunque no muevan el costo_real: asi el motor ve exactamente la fila que se
       va a guardar y no una version paralela.                                    */
    SELECT jsonb_agg(jsonb_build_object(
             'id',                 (e.ord - 1)::INT,
             'cantidad',           (e.val->>'cantidad')::INT,
             'costo_unitario',     COALESCE((e.val->>'costo_unitario')::NUMERIC, 0),
             'bonificacion',       COALESCE((e.val->>'bonificacion')::NUMERIC, 0),
             'impuestos_internos', CASE WHEN v_es_zz THEN 0
                                        ELSE COALESCE((e.val->>'impuestos_internos')::NUMERIC, 0) END,
             'porcentaje_iva',     CASE WHEN v_es_zz OR n.cond <> 'gravado' THEN 0
                                        ELSE COALESCE((e.val->>'porcentaje_iva')::NUMERIC, 21) END,
             'condicion_iva',      n.cond
           ) ORDER BY e.ord)
      INTO v_items_motor
      FROM jsonb_array_elements(p_items_nuevos) WITH ORDINALITY AS e(val, ord)
      CROSS JOIN LATERAL (SELECT CASE
             WHEN v_es_zz THEN 'gravado'
             WHEN COALESCE(e.val->>'condicion_iva', 'gravado') IN ('exento','no_gravado')
               THEN e.val->>'condicion_iva'
             ELSE 'gravado' END AS cond) n;

    v_costos := calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado);

    SELECT jsonb_object_agg(l->>'id', l) INTO v_costos_por_linea
      FROM jsonb_array_elements(v_costos->'lineas') l;

    /* AVISO BLANDO, no bloqueante: el II TOTAL del header y la APERTURA por
       alicuota son dos numeros que el usuario tipea por separado y pueden
       contradecirse. NO se pisa ninguno de los dos, y es deliberado.
       `p_impuestos_internos` es lo que va a compras.impuestos_internos, al cuadre
       contra p_total y a la posicion fiscal; `p_ii_declarado` solo alimenta el
       factor de ajuste. Sobrescribir el header con la suma de la apertura
       cambiaria la posicion fiscal sin que nadie lo haya pedido, y fallar
       bloquearia una carga por una diferencia que puede ser legitima. La RPC no
       tiene como saber cual de los dos esta bien: avisa y deja los dos como
       llegaron. Mismo umbral de 1 peso que el cuadre del total.                  */
    IF v_ii_declarado <> '{}'::JSONB THEN
      SELECT COALESCE(sum((d.value #>> '{}')::NUMERIC), 0) INTO v_ii_suma
        FROM jsonb_each(v_ii_declarado) d;
      IF abs(v_ii_suma - COALESCE(v_ii_hdr, 0)) > 1 THEN
        v_warning_ii := format('El impuesto interno declarado por alicuota suma %s y el total informado es %s.',
                               round(v_ii_suma, 2), round(COALESCE(v_ii_hdr, 0), 2));
      END IF;

      -- Y una tasa declarada que no usa NINGUNA linea: su factor es un no-op
      -- (calculado = 0 => factor 1) y ese importe no se refleja en ningun costo.
      SELECT string_agg(d.key, ', ' ORDER BY d.key) INTO v_clave
        FROM jsonb_each(v_ii_declarado) d
       WHERE NOT EXISTS (
         SELECT 1 FROM jsonb_array_elements(v_items_motor) l
          WHERE round((l->>'impuestos_internos')::NUMERIC, 4) = round((d.key)::NUMERIC, 4));
      IF v_clave IS NOT NULL THEN
        v_warning_ii := COALESCE(v_warning_ii || ' ', '')
          || format('Las tasas declaradas %s no las usa ninguna linea: ese importe no se refleja en ningun costo.', v_clave);
      END IF;
    END IF;
  END IF;$a$,
    'actualizar_compra_items · guard y bloque de cargos');

  -- d) contador de posición en el payload ------------------------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id        := (v_item->>'producto_id')::BIGINT;$a$,
    $a$  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_idx := v_idx + 1;   /* mig 194 · posicion en p_items_nuevos, base 1 */
    v_producto_id        := (v_item->>'producto_id')::BIGINT;$a$,
    'actualizar_compra_items · contador del loop');

  -- e) el costo real de la línea sale del motor cuando hay cargos -------------
  --
  -- Lo importante de que esto pase ACÁ y no después del loop: el CPP se calcula
  -- tres renglones más abajo con `v_costo_real`, así que con el costo definitivo
  -- ya adentro sale bien de una. Y el warning de "compra vieja" compara contra el
  -- mismo número.
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$v_costo_real    := costo_real_unitario(v_costo_neto, v_impuestos_internos, v_compra.tipo_factura, 0 /* mig 193: los cargos entran en la task 9 */);$a$,
    $a$v_cargo_unit    := 0;   /* mig 194 */
    IF v_usar_motor AND v_cantidad > 0 THEN
      v_linea_costos := v_costos_por_linea -> (v_idx - 1)::TEXT;
      IF v_linea_costos IS NULL THEN
        RAISE EXCEPTION 'mig 194 · el motor no devolvio la linea %.', v_idx - 1;
      END IF;
      v_cargo_unit  := round((v_linea_costos->>'cargos')::NUMERIC, 4);
      v_costo_real  := round((v_linea_costos->>'costo_real')::NUMERIC, 4);
    ELSE
      v_costo_real  := costo_real_unitario(v_costo_neto, v_impuestos_internos, v_compra.tipo_factura, 0 /* mig 193: los cargos entran en la task 9 */);
    END IF;$a$,
    'actualizar_compra_items · costo real de la linea');

  -- f) la línea guarda cargos_unitarios y devuelve su id ----------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva
    ) VALUES (
      p_compra_id, v_producto_id, v_cantidad, v_costo_unitario,
      v_subtotal_item, v_stock_anterior, v_stock_nuevo, v_bonificacion, v_sucursal,
      v_porcentaje_iva, v_impuestos_internos, round(v_costo_neto, 4), v_costo_real,
      v_condicion_iva
    );$a$,
    $a$      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva, cargos_unitarios /* mig 194 */
    ) VALUES (
      p_compra_id, v_producto_id, v_cantidad, v_costo_unitario,
      v_subtotal_item, v_stock_anterior, v_stock_nuevo, v_bonificacion, v_sucursal,
      v_porcentaje_iva, v_impuestos_internos, round(v_costo_neto, 4), v_costo_real,
      v_condicion_iva, v_cargo_unit
    )
    RETURNING id INTO v_item_id;

    /* mig 194 · el indice del payload (base 0) es v_item_ids[indice + 1]. Es el
       unico puente entre los pesos que mando el cliente y los ids reales, y las
       lineas viejas ya no existen: el DELETE de arriba se las llevo. */
    v_item_ids := v_item_ids || v_item_id;$a$,
    'actualizar_compra_items · insert de compra_items');

  -- g) reescribir los cargos junto con las líneas -----------------------------
  --
  -- Ésta es la parte que evita la pérdida: los repartos viejos ya se fueron con
  -- el CASCADE del DELETE, así que los cargos se borran y se vuelven a insertar
  -- enteros contra las líneas NUEVAS. `p_cargos = '[]'` borra y no repone, que es
  -- exactamente "el usuario sacó todos los cargos".
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$  UPDATE compras
     SET subtotal = p_subtotal,$a$,
    $a$  /* mig 194 · los cargos, ya con los ids reales de las lineas nuevas. */
  IF v_cargos_provistos THEN
    /* La AUTORIA se preserva cuando el cargo NO cambio. `usuario_id` existe para
       poder auditar quien movio el costo de los productos, y el DELETE + INSERT
       de aca abajo la reescribiria entera en cada edicion: si Ana carga el flete
       de 1,9 M y Beto despues corrige una cantidad, el flete pasaria a figurar
       como de Beto sin que Beto lo haya tocado.
       La clave del match es la DEFINICION del cargo —orden, concepto, monto,
       condicion frente al IVA y las tres banderas—, NO los pesos: los pesos son
       funcion de las lineas, y las lineas son justamente lo que una edicion
       cambia. Si algo de la definicion cambio, el cargo es otro y lo firma quien
       edita. Degrada solo: sin match queda p_usuario_id, que es lo que hacia
       antes de este bloque.
       La clave va como texto de un jsonb y no concatenada con un separador
       porque un concepto es texto libre: el escapeo de JSON la hace inyectable a
       prueba de conceptos con cualquier contenido.                              */
    SELECT COALESCE(jsonb_object_agg(
             jsonb_build_array(cc.orden, cc.concepto, cc.monto, cc.condicion_iva,
                               cc.en_factura, cc.prorratea_al_costo,
                               cc.afecta_base_ii, cc.base_prorrateo)::TEXT,
             cc.usuario_id), '{}'::JSONB)
      INTO v_autoria
      FROM compra_cargos cc
     WHERE cc.compra_id = p_compra_id AND cc.sucursal_id = v_sucursal
       AND cc.usuario_id IS NOT NULL;

    DELETE FROM compra_cargos WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;

    IF v_hay_cargos THEN
      INSERT INTO compra_cargos (
        compra_id, sucursal_id, usuario_id, orden, concepto, monto,
        condicion_iva, en_factura, prorratea_al_costo, afecta_base_ii, base_prorrateo
      )
      SELECT p_compra_id, v_sucursal,
             COALESCE((v_autoria ->> jsonb_build_array(
                         (c.val->>'orden')::INT,
                         c.val->>'concepto',
                         (c.val->>'monto')::NUMERIC(12,2),
                         c.val->>'condicion_iva',
                         (c.val->>'en_factura')::BOOLEAN,
                         (c.val->>'prorratea_al_costo')::BOOLEAN,
                         (c.val->>'afecta_base_ii')::BOOLEAN,
                         c.val->>'base_prorrateo')::TEXT)::UUID,
                      p_usuario_id) /* mig 194 */,
             (c.val->>'orden')::INT,
             c.val->>'concepto',
             (c.val->>'monto')::NUMERIC,
             c.val->>'condicion_iva',
             (c.val->>'en_factura')::BOOLEAN,
             (c.val->>'prorratea_al_costo')::BOOLEAN,
             (c.val->>'afecta_base_ii')::BOOLEAN,
             c.val->>'base_prorrateo'
        FROM jsonb_array_elements(v_cargos) AS c(val);

      INSERT INTO compra_cargo_repartos (cargo_id, compra_item_id, compra_id, peso)
      SELECT cc.id, v_item_ids[(w.key)::INT + 1], p_compra_id, (w.value #>> '{}')::NUMERIC
        FROM compra_cargos cc
        JOIN jsonb_array_elements(v_cargos) AS c(val) ON (c.val->>'orden')::INT = cc.orden
        CROSS JOIN LATERAL jsonb_each(c.val->'pesos') AS w
       WHERE cc.compra_id = p_compra_id;
    END IF;
  END IF;

  UPDATE compras
     SET ii_declarado = CASE WHEN v_ii_provisto THEN NULLIF(v_ii_declarado, '{}'::JSONB)
                             ELSE ii_declarado END,   /* mig 194 */
         subtotal = p_subtotal,$a$,
    'actualizar_compra_items · persistencia de los cargos y de la apertura');

  -- h) el aviso del II declarado, en la respuesta ----------------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$    'warnings', NULL
  );$a$,
    $a$    'warnings', NULL,
    'warning_ii_declarado', v_warning_ii /* mig 194 */
  );$a$,
    'actualizar_compra_items · aviso del II declarado');

  EXECUTE v_def;
  EXECUTE format('DROP FUNCTION %s', v_vieja);
END;
$mig$;

REVOKE ALL ON FUNCTION public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb) TO authenticated, service_role;

COMMENT ON FUNCTION public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb) IS
  'Edicion de las lineas de una compra (admin, ventana de 7 dias). Desde la mig '
  '194 acepta p_cargos, con los pesos POR INDICE DE p_items_nuevos, BASE 0. El '
  'DEFAULT es NULL y no [] a proposito: NULL (o JSON null) es "no me mandaron '
  'cargos" y [] es "el usuario borro todos". Si no los mandan y la compra TIENE '
  'cargos, la RPC rechaza con success:false en vez de editar: el DELETE de '
  'compra_items cascadea sobre compra_cargo_repartos y dejaria los cargos vivos '
  'con el vector vacio, que el motor considera legal — el flete se caeria del '
  'costo sin un solo aviso. SON DOS GUARDS Y NO UNO: p_ii_declarado tiene el '
  'mismo DEFAULT NULL y el mismo rechazo, porque la apertura del impuesto interno '
  'mueve el costo igual que los cargos y una edicion que no la reenvie recalcula '
  'con factor 1 y revierte el ajuste. Son independientes porque una compra puede '
  'tener apertura sin un solo cargo, que es el caso normal. La apertura se '
  'persiste en compras.ii_declarado; vacia se guarda como NULL, para no rechazar '
  'a un cliente viejo por una compra que no tiene ningun ajuste que perder.';

-- ----------------------------------------------------------------------------
-- 3 · TASK 11 · cambiar_proveedor_compra clona TODO, no sólo los ítems
--
-- Esa RPC anula la compra y la clona con otro proveedor, y las dos copias van con
-- lista de columnas EXPLÍCITA. Medido sobre el catálogo vivo antes de escribir
-- esto: con la 192 y la 194 aplicadas, el clon perdía CUATRO cosas.
--
--   · `compras.ii_declarado`          → la apertura del II desaparecía, y encima el
--     guard de la task 10 no protegía al clon porque su `ii_declarado` era NULL;
--   · `compra_items.cargos_unitarios` → caía al DEFAULT 0;
--   · `compra_cargos` y sus repartos  → no se clonaban (cuelgan de `compra_id`);
--   · y `costo_real_unitario` SÍ se copiaba, con los cargos y el factor adentro.
--
-- La última es la que vuelve grave a las otras tres: quedaba exactamente el estado
-- que el rollback de la 192 describe como irreversible —costos que incluyen cargos
-- sin ningún registro de cuáles fueron— y el check COMPRA-A3 se habría puesto rojo
-- sobre una compra que nadie tocó a mano.
--
-- POR QUÉ EL CLON DE LOS ÍTEMS PASA A SER UN LOOP y deja de ser un INSERT … SELECT:
-- hace falta el mapa `id viejo → id nuevo` para reapuntar los repartos, y un
-- INSERT … SELECT no lo da. `RETURNING` devuelve los ids nuevos pero no dice de qué
-- fila salió cada uno, y aparearlos por posición depende de que el ejecutor inserte
-- en el orden del SELECT: cierto en la práctica, no garantizado, y este archivo no
-- se apoya en eso. Tampoco hay clave natural — una compra puede repetir el mismo
-- producto, medido en prod. El loop es explícito y no cuesta nada: 4 líneas de
-- media por compra, 31 como máximo.
--
-- La firma no cambia, así que acá no hay DROP ni sobrecarga: es un CREATE OR
-- REPLACE puro sobre el cuerpo vivo.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE
  v_firma constant text := 'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)';
  v_def   text;
BEGIN
  IF to_regprocedure(v_firma) IS NULL THEN
    RAISE EXCEPTION 'mig 194 · no existe % en el catálogo.', v_firma;
  END IF;

  v_def := pg_get_functiondef(to_regprocedure(v_firma));

  -- Idempotencia por una marca que sólo puede haber escrito este parche.
  IF position('mig 194 · clonar los cargos' in v_def) > 0 THEN
    RETURN;
  END IF;

  -- a) variables para el mapa de ítems y el clon de los cargos ----------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$  v_nueva_id   BIGINT;
BEGIN$a$,
    $a$  v_nueva_id   BIGINT;
  -- mig 194 · clonar los cargos
  v_item        RECORD;
  v_cargo       RECORD;
  v_item_nuevo  BIGINT;
  v_cargo_nuevo BIGINT;
  v_map_items   JSONB := '{}'::JSONB;   -- {id_viejo: id_nuevo}
BEGIN$a$,
    'cambiar_proveedor_compra · declaraciones');

  -- b) la cabecera se lleva la apertura del II -------------------------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$    otros_impuestos, total, forma_pago, notas, usuario_id, estado, tipo_factura, sucursal_id
  )$a$,
    $a$    otros_impuestos, total, forma_pago, notas, usuario_id, estado, tipo_factura, sucursal_id,
    ii_declarado /* mig 194 */
  )$a$,
    'cambiar_proveedor_compra · columnas de la cabecera');

  v_def := public._mig192_reemplazo_unico(v_def,
    $a$    c.usuario_id, 'recibida', c.tipo_factura, c.sucursal_id
  FROM compras c$a$,
    $a$    c.usuario_id, 'recibida', c.tipo_factura, c.sucursal_id,
    c.ii_declarado /* mig 194 */
  FROM compras c$a$,
    'cambiar_proveedor_compra · valores de la cabecera');

  -- c) los ítems se clonan uno por uno, y detrás van los cargos --------------
  v_def := public._mig192_reemplazo_unico(v_def,
    $a$  -- 2) Clonar items verbatim (incluye snapshots fiscales), SIN mover stock
  INSERT INTO compra_items (
    compra_id, producto_id, cantidad, costo_unitario, subtotal,
    stock_anterior, stock_nuevo, bonificacion, sucursal_id,
    porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
    condicion_iva
  )
  SELECT
    v_nueva_id, ci.producto_id, ci.cantidad, ci.costo_unitario, ci.subtotal,
    ci.stock_anterior, ci.stock_nuevo, ci.bonificacion, ci.sucursal_id,
    ci.porcentaje_iva, ci.impuestos_internos, ci.costo_neto_unitario, ci.costo_real_unitario,
    ci.condicion_iva
  FROM compra_items ci
  WHERE ci.compra_id = p_compra_id AND ci.sucursal_id = v_sucursal;$a$,
    $a$  /* 2) Clonar items verbatim, y ahora SI con todos los snapshots fiscales: la
        mig 194 sumo cargos_unitarios, y sin copiarla la linea diria que no tuvo
        cargos mientras su costo_real_unitario los incluye. SIN mover stock.
        Es un loop y no un INSERT ... SELECT porque hace falta el mapa
        id viejo -> id nuevo para reapuntar los repartos, y RETURNING no dice de
        que fila salio cada id. Media 4 lineas por compra, maximo 31. */
  FOR v_item IN
    SELECT * FROM compra_items
     WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     ORDER BY id
  LOOP
    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      stock_anterior, stock_nuevo, bonificacion, sucursal_id,
      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario,
      condicion_iva, cargos_unitarios
    ) VALUES (
      v_nueva_id, v_item.producto_id, v_item.cantidad, v_item.costo_unitario, v_item.subtotal,
      v_item.stock_anterior, v_item.stock_nuevo, v_item.bonificacion, v_item.sucursal_id,
      v_item.porcentaje_iva, v_item.impuestos_internos, v_item.costo_neto_unitario,
      v_item.costo_real_unitario, v_item.condicion_iva, v_item.cargos_unitarios
    )
    RETURNING id INTO v_item_nuevo;

    v_map_items := v_map_items || jsonb_build_object(v_item.id::TEXT, v_item_nuevo);
  END LOOP;

  /* 2.1) Y los cargos con sus repartos, reapuntados a las lineas nuevas. El
        compra_id del reparto tambien tiene que ser el nuevo: las dos FK
        compuestas de la mig 192 lo exigen y si no rebota.
        usuario_id del cargo se copia tal cual — cambiar el proveedor no cambia
        quien cargo el flete, mismo criterio que la autoria en la edicion. */
  FOR v_cargo IN
    SELECT * FROM compra_cargos
     WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     ORDER BY orden, id
  LOOP
    INSERT INTO compra_cargos (
      compra_id, sucursal_id, usuario_id, orden, concepto, monto,
      condicion_iva, en_factura, prorratea_al_costo, afecta_base_ii, base_prorrateo
    ) VALUES (
      v_nueva_id, v_cargo.sucursal_id, v_cargo.usuario_id, v_cargo.orden, v_cargo.concepto,
      v_cargo.monto, v_cargo.condicion_iva, v_cargo.en_factura, v_cargo.prorratea_al_costo,
      v_cargo.afecta_base_ii, v_cargo.base_prorrateo
    )
    RETURNING id INTO v_cargo_nuevo;

    INSERT INTO compra_cargo_repartos (cargo_id, compra_item_id, compra_id, peso)
    SELECT v_cargo_nuevo, (v_map_items ->> r.compra_item_id::TEXT)::BIGINT, v_nueva_id, r.peso
      FROM compra_cargo_repartos r
     WHERE r.cargo_id = v_cargo.id;
  END LOOP;$a$,
    'cambiar_proveedor_compra · clon de items, cargos y repartos');

  EXECUTE v_def;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 4 · TASK 12 · el check de integridad de los cargos
--
-- ⚠ SE LLAMA `COMPRA-A3` Y NO `COMPRA-A2`: **A2 YA EXISTE** y encima está en rojo
-- —`compras.subtotal = SUM(compra_items.subtotal)`, 5 violaciones legacy,
-- severidad medium—. Se midió antes de escribir esto. Reusar el id habría
-- duplicado una clave que el gate lee por nombre. A3 sigue la familia: A1 es la
-- aritmética del header, A2 la del subtotal contra las líneas, A3 la de los
-- cargos contra lo repartido.
--
-- QUÉ VIGILA, porque la primera versión del plan comparaba cosas distintas —el
-- `monto` del cargo contra la suma de sus PESOS, que son proporciones, no plata—:
--
--   · que `sum(prorratear_cargo(...))` dé `monto` está GARANTIZADO POR
--     CONSTRUCCIÓN: la regla del residuo lo fuerza. Verificarlo sería testear la
--     función, no los datos, y un check que no puede ponerse rojo no vigila nada.
--   · lo que SÍ se desincroniza en producción es lo que quedó GUARDADO en
--     `compra_items.cargos_unitarios` contra lo que los cargos dicen HOY. Un cargo
--     editado a mano sin recalcular las líneas, un reparto que se llevó el CASCADE
--     de una edición, una fila tocada por SQL directo: en los tres casos el costo
--     sigue con los cargos adentro y el desglose ya no los explica. Ése es el
--     drift real, y es exactamente el bug que esta tanda entera viene a evitar.
--
-- Compara POR LÍNEA y no por compra: sumar la compra dejaría que dos errores de
-- signo opuesto se cancelen entre líneas.
--
-- TOLERANCIA, NO IGUALDAD, y no es pereza: `cargos_unitarios` es `numeric(12,4)` y
-- el cargo se divide por la cantidad, así que reconstruirlo multiplicando de vuelta
-- no puede dar exacto. 500 sobre 3 unidades da 166,6667 × 3 = 500,0001. El margen
-- es `1 centavo + 0,0001 × cantidad`: el término de la cantidad cubre el redondeo
-- del unitario con el doble del error máximo teórico (0,00005 × cantidad), y sigue
-- siendo tres órdenes de magnitud más chico que cualquier cargo perdido de verdad.
--
-- NACE EN VERDE, y eso es un requisito y no una expectativa: hoy no hay una sola
-- compra con cargos, así que las 527 líneas tienen `cargos_unitarios = 0` y el
-- reparto esperado es 0. Un check que nace rojo vuelve inútil al gate diario —es
-- lo que le pasó a `COMPRA-A1` antes de la mig 178, y por eso los checks que se
-- agregaban después nacían invisibles—. Verificado corriendo la función, no
-- asumido. Y verificado también que MUERDE: con un `cargos_unitarios` ensuciado a
-- mano, lo cuenta.
--
-- Severidad `high` a propósito: el gate de CI falla con critical/high en rojo, y
-- un desglose que dejó de explicar el costo es plata. Los 7 checks que hoy están
-- en rojo son todos medium/low/info, así que el gate está verde y este check no lo
-- cambia mientras no haya drift.
--
-- Mismo patrón que la mig 178: se lee el cuerpo vivo, se inserta la fila con ancla
-- única, y es idempotente por la presencia del id.
-- ----------------------------------------------------------------------------
DO $mig$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);

  IF position('COMPRA-A3' in v_def) > 0 THEN
    RETURN;
  END IF;

  v_def := public._mig192_reemplazo_unico(v_def,
    $a$    ('COMPRA-A2','medium','compras.subtotal = SUM(compra_items.subtotal) (5 legacy)',$a$,
    $a$    ('COMPRA-A3','high','cargos_unitarios guardado = lo que hoy reparten los cargos no gravados (mig 194)',
      (SELECT count(*) FROM compra_items ci
         JOIN compras c ON c.id=ci.compra_id AND c.estado<>'cancelada'
         LEFT JOIN (
           SELECT r.item_id, sum(r.monto) AS monto
             FROM (SELECT cc.monto AS m,
                          (SELECT jsonb_object_agg(x.compra_item_id::text, x.peso)
                             FROM compra_cargo_repartos x WHERE x.cargo_id=cc.id) AS pesos
                     FROM compra_cargos cc
                     JOIN compras cx ON cx.id=cc.compra_id AND cx.estado<>'cancelada'
                    WHERE cc.condicion_iva<>'gravado' AND cc.prorratea_al_costo) g
             CROSS JOIN LATERAL prorratear_cargo(g.m, g.pesos) r
            GROUP BY r.item_id) rep ON rep.item_id=ci.id
        WHERE abs(COALESCE(rep.monto,0) - COALESCE(ci.cargos_unitarios,0)*ci.cantidad)
              > 0.01 + 0.0001*ci.cantidad)),
    ('COMPRA-A2','medium','compras.subtotal = SUM(compra_items.subtotal) (5 legacy)',$a$,
    'auditoria_integridad · fila de COMPRA-A3');

  EXECUTE v_def;
END;
$mig$;

-- ----------------------------------------------------------------------------
-- 5 · POST-condición
--
-- El DROP por sí solo no protege de nada: los cuerpos plpgsql son strings y
-- Postgres no los valida, así que un parche que no hubiera entrado no falla al
-- aplicar — falla en producción la próxima vez que alguien registra o edita una
-- compra. Por eso además de contar sobrecargas se verifica que el cuerpo tenga
-- las piezas.
-- ----------------------------------------------------------------------------
DO $post$
DECLARE
  v_fn     text;
  v_nargs  integer;
  v_oid    oid;
  v_real   integer;
  v_marca  text;
  v_n      integer;
BEGIN
  FOREACH v_fn IN ARRAY ARRAY['registrar_compra_completa', 'actualizar_compra_items'] LOOP
    v_nargs := CASE v_fn WHEN 'registrar_compra_completa' THEN 19 ELSE 13 END;

    SELECT count(*) INTO v_n
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_fn;
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig 194 · quedaron % sobrecargas de %. Dos con rangos de aridad superpuestos dan PGRST203 en runtime, invisible para tsc y para los tests.', v_n, v_fn
        USING ERRCODE = '22023';
    END IF;

    SELECT p.oid, p.pronargs INTO v_oid, v_real
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = v_fn;

    IF v_real <> v_nargs THEN
      RAISE EXCEPTION 'mig 194 · % quedó con % argumentos y se esperaban %.', v_fn, v_real, v_nargs
        USING ERRCODE = '22023';
    END IF;

    FOREACH v_marca IN ARRAY ARRAY['cargos_unitarios', 'RETURNING id INTO v_item_id;',
                                   -- La llamada COMPLETA, no `calcular_costos_compra(` a
                                   -- secas: lo que hay que verificar no es que el motor se
                                   -- llame, es que el II DECLARADO le llegue. Con un
                                   -- '{}'::JSONB hardcodeado en el 3er argumento el factor
                                   -- se calcularia y se tiraria, que es el bug que la
                                   -- correccion de esta migracion vino a cerrar.
                                   'calcular_costos_compra(v_items_motor, v_cargos, v_ii_declarado)']
    LOOP
      SELECT (length(p.prosrc) - length(replace(p.prosrc, v_marca, ''))) / length(v_marca) INTO v_n
        FROM pg_proc p WHERE p.oid = v_oid;
      IF v_n <> 1 THEN
        RAISE EXCEPTION 'mig 194 · % tiene % veces "%" y se esperaba 1: el parche no quedó como se creía.', v_fn, v_n, v_marca
          USING ERRCODE = '22023';
      END IF;
    END LOOP;

    IF has_function_privilege('anon', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig 194 · % quedó ejecutable por anon.', v_fn
        USING ERRCODE = '22023';
    END IF;
    IF NOT has_function_privilege('authenticated', v_oid, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig 194 · % NO quedó ejecutable por authenticated: la app dejaría de poder operar compras.', v_fn
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- El guard de la task 10, nombrado: es la única pieza cuya ausencia no rompe
  -- nada al aplicar y borra plata en silencio en producción.
  FOREACH v_marca IN ARRAY ARRAY['Esta compra tiene cargos prorrateados.',
                                 'Esta compra tiene el impuesto interno declarado'] LOOP
    SELECT (length(p.prosrc) - length(replace(p.prosrc, v_marca, ''))) / length(v_marca) INTO v_n
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'actualizar_compra_items';
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig 194 · actualizar_compra_items quedó SIN el guard "%" (% ocurrencias). Es la pieza cuya ausencia no rompe nada al aplicar y borra plata en silencio en producción.', v_marca, v_n
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Y que la apertura se PERSISTA en las dos: sin eso el guard de arriba nunca
  -- tendría contra qué disparar.
  SELECT (length(p.prosrc) - length(replace(p.prosrc, 'UPDATE compras SET ii_declarado = v_ii_declarado', '')))
         / length('UPDATE compras SET ii_declarado = v_ii_declarado') INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'registrar_compra_completa';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 194 · registrar_compra_completa no persiste ii_declarado (% ocurrencias).', v_n
      USING ERRCODE = '22023';
  END IF;

  SELECT (length(p.prosrc) - length(replace(p.prosrc, 'SET ii_declarado = CASE WHEN v_ii_provisto', '')))
         / length('SET ii_declarado = CASE WHEN v_ii_provisto') INTO v_n
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
   WHERE n.nspname = 'public' AND p.proname = 'actualizar_compra_items';
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig 194 · actualizar_compra_items no persiste ii_declarado (% ocurrencias).', v_n
      USING ERRCODE = '22023';
  END IF;

  -- Task 11: el clon se lleva las cuatro cosas. `cargos_unitarios` aparece dos
  -- veces (columna y valor), `ii_declarado` dos (columna y valor) y los repartos
  -- una: si alguna cae a 0, el clon vuelve a perder el origen de sus costos.
  FOREACH v_marca IN ARRAY ARRAY['cargos_unitarios', 'ii_declarado',
                                 'INSERT INTO compra_cargo_repartos'] LOOP
    SELECT (length(p.prosrc) - length(replace(p.prosrc, v_marca, ''))) / length(v_marca) INTO v_n
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'cambiar_proveedor_compra';
    IF v_n = 0 THEN
      RAISE EXCEPTION 'mig 194 · cambiar_proveedor_compra no clona "%": el clon quedaria con los costos y sin el origen.', v_marca
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Task 12: el check existe UNA vez, y sigue existiendo el A2 que ya estaba.
  FOREACH v_marca IN ARRAY ARRAY['''COMPRA-A3''', '''COMPRA-A2'''] LOOP
    SELECT (length(p.prosrc) - length(replace(p.prosrc, v_marca, ''))) / length(v_marca) INTO v_n
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.proname = 'auditoria_integridad';
    IF v_n <> 1 THEN
      RAISE EXCEPTION 'mig 194 · auditoria_integridad tiene % veces el check % (se esperaba 1).', v_n, v_marca
        USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Y NACE EN VERDE. Si arranca rojo, el gate diario queda inutil: es lo que le
  -- paso a COMPRA-A1 antes de la mig 178.
  -- `auditoria_integridad()` devuelve un jsonb ESCALAR, no una tabla: se expande
  -- directo. (Lo agarró el ensayo al EJECUTAR; compilar no lo hubiera visto,
  -- que es exactamente por lo que la 193 exige ejecutar y no compilar.)
  SELECT (a.c->>'violaciones')::int INTO v_n
    FROM jsonb_array_elements(auditoria_integridad()->'checks') a(c)
   WHERE a.c->>'id' = 'COMPRA-A3';
  IF v_n IS NULL THEN
    RAISE EXCEPTION 'mig 194 · COMPRA-A3 no aparece en la salida de auditoria_integridad().'
      USING ERRCODE = '22023';
  END IF;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig 194 · COMPRA-A3 nace con % violaciones. Un check que nace rojo vuelve inutil al gate diario: revisa el drift antes de aplicar.', v_n
      USING ERRCODE = '22023';
  END IF;
END;
$post$;

-- El helper es andamiaje de esta migración, no API: se va con ella.
DROP FUNCTION IF EXISTS public._mig192_reemplazo_unico(text, text, text, text);

COMMIT;

-- ----------------------------------------------------------------------------
-- Rollback
--
-- No alcanza con recrear las firmas viejas: hay que volver los DOS CUERPOS al de
-- antes, porque los nuevos referencian compra_cargos y compra_cargo_repartos.
-- El recipe es simétrico al de aplicar —leer el cuerpo vivo y desandar los
-- parches— y sólo es EXACTO mientras ninguna compra tenga cargos todavía. En
-- cuanto los tenga, dropear las firmas nuevas deja los costos con cargos adentro
-- y los repartos sin quien los recalcule: ahí el rollback pasa a ser el de la 192
-- (recálculo de costos y CPP con las tablas todavía en pie).
--
-- Y hay un orden que importa: volver `actualizar_compra_items` a 11 argumentos
-- SIN haber sacado antes los cargos de las compras que los tengan reinstala
-- exactamente el bug que la task 10 vino a tapar — la RPC vieja no conoce el
-- guard y la próxima edición se lleva los repartos puestos.
--
--   BEGIN;
--     -- 1. desandar los parches sobre el cuerpo vivo
--     DO $r$
--     DECLARE v_def text;
--     BEGIN
--       v_def := pg_get_functiondef('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb)'::regprocedure);
--       -- ... quitar el bloque de cargos, el IF del costo real, cargos_unitarios,
--       --     el RETURNING y la persistencia; devolver la firma a 17 argumentos ...
--       EXECUTE v_def;
--     END $r$;
--     DROP FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb);
--     -- 2. y devolverle los privilegios, que el CREATE no restaura solo:
--     REVOKE ALL ON FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric)
--       FROM PUBLIC, anon;
--     GRANT EXECUTE ON FUNCTION public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric)
--       TO authenticated, service_role;
--   COMMIT;
--
-- En la práctica es más barato revertir el commit y re-aplicar 190+191 sobre una
-- base sin cargos que desandar el parche a mano.
-- ----------------------------------------------------------------------------

-- ----------------------------------------------------------------------------
-- Verificación
--
--   -- UNA sola firma de cada una, con 19 y 13 argumentos. Si esto devuelve más
--   -- de dos filas, PostgREST tira PGRST203 en runtime y no lo ve ni tsc ni los
--   -- tests:
--   SELECT proname, pronargs, array_to_string(proacl, ' ')
--     FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
--    WHERE n.nspname = 'public'
--      AND proname IN ('registrar_compra_completa','actualizar_compra_items');
--   -- actualizar_compra_items   | 13 | postgres=X/postgres authenticated=X/postgres service_role=X/postgres
--   -- registrar_compra_completa | 19 | postgres=X/postgres authenticated=X/postgres service_role=X/postgres
--
--   -- FORWARD-ONLY: la misma compra SIN cargos, antes y después de la migración,
--   -- tiene que dar el mismo costo_real_unitario al último decimal.
--   SELECT registrar_compra_completa(NULL,'Testigo','FWD',CURRENT_DATE,
--            1000,210,0,1210,'efectivo',NULL, auth.uid(),
--            '[{"producto_id":<id>,"cantidad":10,"costo_unitario":100,
--               "bonificacion":0,"porcentaje_iva":21,"impuestos_internos":8.6956,
--               "condicion_iva":"gravado"}]'::jsonb);
--   -- costo_real_unitario 108.6956 · cargos_unitarios 0 — igual que antes de la 194.
--
--   -- CON cargos: un flete no gravado de 500 sobre la única línea.
--   SELECT registrar_compra_completa(..., p_cargos =>
--     '[{"concepto":"Flete","monto":500,"condicion_iva":"no_gravado",
--        "en_factura":false,"prorratea_al_costo":true,"afecta_base_ii":false,
--        "pesos":{"0":1}}]'::jsonb);
--   -- cargos_unitarios 50 · costo_real_unitario 158.6956 (108.6956 + 50)
--
--   -- Los tres guards, que tienen que fallar los tres:
--   --   pesos:{}            → El cargo "Flete" no tiene ninguna línea asignada
--   --   pesos:{"7":1}       → El cargo "Flete": la clave "7" apunta a una linea
--   --                          que no existe: la compra tiene 1 (indices 0 a 0)
--   --   linea con cantidad 0 → El cargo "Flete" reparte sobre la linea 0 que
--   --                          tiene cantidad 0 ...
--   --
--   -- Ojo con leerlos: registrar_compra_completa termina en
--   -- `EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('success', false, ...)`,
--   -- así que el RAISE no sale como error de SQL sino como
--   -- {"success": false, "error": "..."} — y el bloque plpgsql revierte todo lo
--   -- que la RPC había escrito. La compra NO queda a medias.
--
--   -- Y que el reparto cuadra contra los unitarios guardados:
--   SELECT cc.concepto, cc.monto,
--          sum(ci.cargos_unitarios * ci.cantidad) AS reconstruido
--     FROM compra_cargos cc
--     JOIN compra_cargo_repartos r ON r.cargo_id = cc.id
--     JOIN compra_items ci ON ci.id = r.compra_item_id
--    WHERE cc.compra_id = <id> AND NOT cc.condicion_iva = 'gravado'
--    GROUP BY cc.concepto, cc.monto;
--   -- El reconstruido puede diferir del monto por menos de un centavo por línea:
--   -- cargos_unitarios es numeric(12,4) y el cargo se reparte por unidad. El
--   -- check de integridad tiene que llevar tolerancia, no exigir igualdad.
--
--   -- ── TASK 10 · el guard ────────────────────────────────────────────────────
--   -- 1) Compra CON cargos, editada SIN p_cargos: rechaza y NO toca nada.
--   SELECT actualizar_compra_items(<id_con_cargos>, '[...]'::jsonb,
--            0,0,0, auth.uid(), 0,0,0,0,0);
--   -- {"error": "Esta compra tiene cargos prorrateados. Actualizá la aplicación
--   --  (recargá la página) antes de editarla.", "success": false}
--   SELECT count(*) FROM compra_cargos         WHERE compra_id = <id_con_cargos>;
--   SELECT count(*) FROM compra_cargo_repartos WHERE compra_id = <id_con_cargos>;
--   -- los dos conteos INTACTOS: el guard devuelve antes del DELETE de las líneas.
--
--   -- 2) Compra SIN cargos, editada SIN p_cargos: el camino viejo sigue andando.
--   SELECT actualizar_compra_items(<id_sin_cargos>, '[...]'::jsonb,
--            0,0,0, auth.uid(), 0,0,0,0,0);
--   -- {"success": true, ...} y el mismo costo_real_unitario que antes de la 194.
--
--   -- 3) Con p_cargos: se borran los cargos viejos y se reponen contra las
--   --    líneas NUEVAS (los repartos viejos ya se los llevó el CASCADE).
--   -- 4) Con p_cargos => '[]': se borran y no se reponen. Es "el usuario sacó
--   --    todos los cargos", y el costo vuelve a ser el de la compra sin cargos.
-- ----------------------------------------------------------------------------
