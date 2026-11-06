-- 472 · Guardar una promo vuelve a ser una sola transacción (#1491, tarjeta 14 de #1477).
--
-- QUÉ PASABA
--   Desde la 467 (#1473, ADV-2), authenticated no escribe por REST producto_regalo_id ni
--   ajuste_producto_id, y el front guardaba una promo en dos transacciones: primero
--   cambiar_regalo_promocion (el regalo, el contenedor y ajuste_automatico, con la rotación de la
--   barra) y después el UPDATE REST del resto. Si el segundo paso fallaba, el regalo nuevo ya
--   había quedado: el admin veía el error, creía que no se había guardado nada, y las ventas
--   siguientes regalaban el producto nuevo con los bloques viejos. El segundo paso falla:
--   · cuando el factor nuevo cierra bloques y el contenedor no alcanza:
--     renormalizar_bloques_por_cambio_factor baja el stock sin tope y, desde la 466, el CHECK
--     productos_stock_no_negativo lo rechaza con un 23514 crudo;
--   · cuando se baja limite_usos por debajo de lo ya regalado (trg_limite_usos_no_baja);
--   · cuando se corta la red entre las dos llamadas.
--   Los productos y las reglas de la promo iban, además, en otras cuatro llamadas REST.
--
-- QUÉ CAMBIA
--   · cambiar_regalo_promocion suma un quinto parámetro, p_datos jsonb DEFAULT NULL, con todo lo
--     demás que edita el modal: nombre, tipo, fechas, límite, prioridad, tipo de regalo, modo de
--     exclusión, factor (unidades_por_bloque, stock_por_bloque), descripción, y opcionalmente
--     producto_ids y reglas ([{clave, valor}]). Con p_datos, un solo UPDATE escribe la promo
--     entera (el regalo y el factor juntos: los AFTER de fila corren por nombre, y la barra rota
--     antes de renormalizarse, como en el UPDATE único de antes de la 467) y en la misma
--     transacción se concilian los productos y las reglas. Un rechazo de los triggers vuelve
--     como {success: false, error} y no deja nada escrito:
--       - el 23514 del contenedor, como «El contenedor «X» no tiene stock para el factor nuevo»;
--       - los RAISE de negocio (el del límite de usos), con su mensaje.
--   · Sin p_datos hace exactamente lo de la 467: un bundle viejo del PWA (que llama con cuatro
--     argumentos y después manda el UPDATE REST) sigue andando, igual que hoy. La firma vieja de
--     cuatro argumentos se dropea: dos sobrecargas con rangos superpuestos dan PGRST203
--     (CLAUDE.md, trampa 5). PostgREST resuelve la llamada de cuatro argumentos con nombre contra
--     la de cinco por el DEFAULT.
--   · El orden de locks es el global (460, 467): los productos juntos y por id, después la promo.
--     Con p_datos, el UPDATE nombra unidades_por_bloque y stock_por_bloque, así que corre
--     trg_promo_factor_bloquea_contenedores, que toma FOR UPDATE los contenedores de todas las
--     promos de la sucursal. Dentro de la RPC la promo ya está tomada cuando corre ese trigger, así
--     que la RPC los toma antes, junto con los que renormalizar puede pedir además (el contenedor
--     nuevo y el regalo viejo, que la rotación vuelve contenedor de su barra), en la misma
--     pasada por id que los KEY SHARE del regalo, el contenedor y los productos que se suman a
--     la promo (la FK de promocion_productos).
--   · PROMO-C (auditoria_funciones_modo_regalo_vivo): con p_datos la RPC escribe
--     regalo_mueve_stock, que es la definición de la promo y no el modo de un pedido. Entra a
--     la lista de excepciones, con previsualizar_cambio_factor y renormalizar.
--
-- QUÉ NO CAMBIA
--   Los triggers de promociones, las barras, los grants REST por columna de la 467 (el toggle de
--   activo sigue por REST) y el alta de una promo.
--
-- Ensayo: scripts/test-guardar-promo-atomica-1491.sql (corre en prod sin dejar rastro), y la
-- clave t6 del arnés (scripts/concurrencia: T6k a T6n).
-- Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  IF to_regprocedure('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean)') IS NULL THEN
    RAISE EXCEPTION 'mig 472 · no está cambiar_regalo_promocion(bigint,bigint,bigint,boolean) de la 467';
  END IF;
  IF to_regprocedure('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)') IS NOT NULL
     OR (SELECT count(*) FROM pg_proc WHERE proname = 'cambiar_regalo_promocion'
                                        AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'mig 472 · cambiar_regalo_promocion ya tiene otra firma';
  END IF;

  -- La RPC de la 467 y los triggers de promociones de los que depende el UPDATE único.
  FOR v_f IN
    SELECT x.firma, x.md5, md5(p.prosrc) AS md5_vivo
      FROM (VALUES
        ('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean)',  '58aa734161804d91bed158b6095615d1'),
        ('public.promo_factor_bloquea_contenedores()',                      '132df7f62ce68c73171bb7f7190f69bf'),
        ('public.renormalizar_bloques_por_cambio_factor()',                 '0f5c089fdcd140cc865b0255d4183c13'),
        ('public.rotar_barra_default_de_promo()',                           'b44fa3a31c94f3a2387d3319bb1dde2f'),
        ('public.limite_usos_no_baja_de_lo_regalado()',                     'b4a595f5e8cce46f5a279fe210f5d576'),
        ('public.auditoria_funciones_modo_regalo_vivo()',                   '9142f0f4bb61b4b6208426850b88bb46')
      ) AS x(firma, md5)
      JOIN pg_proc p ON p.oid = x.firma::regprocedure
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig 472 · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  -- Los AFTER de fila corren por nombre: rotar antes que renormalizar.
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.promociones'::regclass
                    AND tgname = 'trg_promo_rotar_barra_default' AND tgenabled = 'O')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.promociones'::regclass
                    AND tgname = 'trg_renormalizar_bloques_por_cambio_factor' AND tgenabled = 'O')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.promociones'::regclass
                    AND tgname = 'trg_promo_factor_bloquea_contenedores' AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'mig 472 · los triggers de promociones no son los que se leyeron';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.productos'::regclass
                    AND conname = 'productos_stock_no_negativo') THEN
    RAISE EXCEPTION 'mig 472 · no está el CHECK productos_stock_no_negativo de la 466';
  END IF;

  IF public.auditoria_funciones_modo_regalo_vivo() <> 0 THEN
    RAISE EXCEPTION 'mig 472 · PROMO-C ya está en rojo antes de la migración';
  END IF;

  -- Las claves de la conciliación.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.promocion_productos'::regclass
                    AND contype = 'u' AND pg_get_constraintdef(oid) = 'UNIQUE (promocion_id, producto_id)')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.promocion_reglas'::regclass
                    AND contype = 'u' AND pg_get_constraintdef(oid) = 'UNIQUE (promocion_id, clave)') THEN
    RAISE EXCEPTION 'mig 472 · faltan las UNIQUE de promocion_productos o de promocion_reglas';
  END IF;
END
$premisas$;

DROP FUNCTION public.cambiar_regalo_promocion(bigint, bigint, bigint, boolean);

CREATE FUNCTION public.cambiar_regalo_promocion(
  p_promocion_id bigint,
  p_producto_regalo_id bigint,
  p_ajuste_producto_id bigint,
  p_ajuste_automatico boolean,
  p_datos jsonb DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal     BIGINT  := current_sucursal_id();
  v_ajuste       BOOLEAN := COALESCE(p_ajuste_automatico, false);
  v_previa       RECORD;
  v_promo        RECORD;
  v_fila         promociones%ROWTYPE;
  v_cambio       BOOLEAN;
  v_comparte     BIGINT[] := '{}';
  v_actualiza    BIGINT[] := '{}';
  v_prod_ids     BIGINT[];
  v_reglas       JSONB;
  v_claves       TEXT[];
  v_id           BIGINT;
  v_constraint   TEXT;
  v_detalle      TEXT;
  v_cont_id      BIGINT;
  v_cont_nombre  TEXT;
  v_cont_stock   INT;
BEGIN
  -- La policy mt_promociones_all: admin, y la promo de la sucursal activa.
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: sólo un administrador cambia una promoción');
  END IF;
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay una sucursal activa: recargá la página e intentá de nuevo');
  END IF;

  IF p_producto_regalo_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM productos WHERE id = p_producto_regalo_id AND sucursal_id = v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error', 'El producto de regalo no existe en esta sucursal');
  END IF;
  IF p_ajuste_producto_id IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM productos WHERE id = p_ajuste_producto_id AND sucursal_id = v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error', 'El producto contenedor no existe en esta sucursal');
  END IF;

  -- #1473 (ADV-2): el regalo y el contenedor nuevos, KEY SHARE (el lock de la FK)
  -- antes que la promo. La venta toma esos productos (FOR UPDATE) y después la promo.
  v_comparte := ARRAY[p_producto_regalo_id, p_ajuste_producto_id];

  -- #1491: con p_datos la promo se guarda entera, en esta transacción.
  IF p_datos IS NOT NULL THEN
    IF jsonb_typeof(p_datos) <> 'object' THEN
      RETURN jsonb_build_object('success', false, 'error', 'Los datos de la promoción no tienen la forma esperada');
    END IF;
    IF p_datos ? 'nombre' AND COALESCE(btrim(p_datos->>'nombre'), '') = '' THEN
      RETURN jsonb_build_object('success', false, 'error', 'La promoción necesita un nombre');
    END IF;
    IF p_datos ? 'fecha_inicio' AND NULLIF(p_datos->>'fecha_inicio', '') IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'La promoción necesita una fecha de inicio');
    END IF;

    IF p_datos ? 'producto_ids' THEN
      IF jsonb_typeof(p_datos->'producto_ids') <> 'array' THEN
        RETURN jsonb_build_object('success', false, 'error', 'Los productos de la promoción no tienen la forma esperada');
      END IF;
      SELECT COALESCE(array_agg(DISTINCT (e #>> '{}')::bigint), '{}')
        INTO v_prod_ids
        FROM jsonb_array_elements(p_datos->'producto_ids') e;
      IF (SELECT count(*) FROM productos WHERE sucursal_id = v_sucursal AND id = ANY (v_prod_ids))
         <> cardinality(v_prod_ids) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Algún producto de la promoción no existe en esta sucursal');
      END IF;
      -- Los que se suman toman KEY SHARE en la FK de promocion_productos: van con los demás.
      v_comparte := v_comparte || ARRAY(
        SELECT x FROM unnest(v_prod_ids) x
         WHERE NOT EXISTS (SELECT 1 FROM promocion_productos pp
                            WHERE pp.promocion_id = p_promocion_id AND pp.producto_id = x));
    END IF;

    IF p_datos ? 'reglas' THEN
      v_reglas := p_datos->'reglas';
      IF jsonb_typeof(v_reglas) <> 'array'
         OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_reglas) r
                     WHERE jsonb_typeof(r) <> 'object'
                        OR COALESCE(btrim(r->>'clave'), '') = ''
                        OR COALESCE(jsonb_typeof(r->'valor'), '') <> 'number') THEN
        RETURN jsonb_build_object('success', false, 'error', 'Las reglas de la promoción no tienen la forma esperada');
      END IF;
      SELECT COALESCE(array_agg(r->>'clave'), '{}') INTO v_claves FROM jsonb_array_elements(v_reglas) r;
      IF cardinality(v_claves) <> (SELECT count(DISTINCT c) FROM unnest(v_claves) c) THEN
        RETURN jsonb_build_object('success', false, 'error', 'Una regla de la promoción está repetida');
      END IF;
    END IF;

    -- El UPDATE nombra el factor: trg_promo_factor_bloquea_contenedores (sentencia) toma
    -- FOR UPDATE los contenedores de todas las promos de la sucursal, y acá correría con la
    -- promo ya tomada. Se toman antes, con lo que renormalizar puede pedir además: el
    -- contenedor nuevo y el regalo viejo (la rotación lo vuelve contenedor de su barra
    -- cuando la promo no tenía contenedor). Lectura sin lock: es el pre-bloqueo.
    SELECT producto_regalo_id, ajuste_producto_id INTO v_previa
      FROM promociones WHERE id = p_promocion_id AND sucursal_id = v_sucursal;
    v_actualiza := ARRAY(
        SELECT p.ajuste_producto_id FROM promociones p
         WHERE p.ajuste_producto_id IS NOT NULL AND p.sucursal_id = v_sucursal
        UNION
        SELECT a.ajuste_producto_id FROM promo_acumuladores a
         WHERE a.ajuste_producto_id IS NOT NULL AND a.sucursal_id = v_sucursal)
      || ARRAY[p_ajuste_producto_id, v_previa.producto_regalo_id, v_previa.ajuste_producto_id];
  END IF;

  -- Una sola pasada por id: FOR UPDATE lo que puede bajar de stock, KEY SHARE lo demás.
  FOR v_id IN
    SELECT id FROM productos
     WHERE sucursal_id = v_sucursal
       AND (id = ANY (v_comparte) OR id = ANY (v_actualiza))
     ORDER BY id
  LOOP
    IF v_id = ANY (v_actualiza) THEN
      PERFORM 1 FROM productos WHERE id = v_id FOR UPDATE;
    ELSE
      PERFORM 1 FROM productos WHERE id = v_id FOR KEY SHARE;
    END IF;
  END LOOP;

  SELECT id, producto_regalo_id, ajuste_producto_id, ajuste_automatico INTO v_promo
    FROM promociones
   WHERE id = p_promocion_id AND sucursal_id = v_sucursal
     FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Promoción no encontrada');
  END IF;

  v_cambio := v_promo.producto_regalo_id IS DISTINCT FROM p_producto_regalo_id
              OR v_promo.ajuste_producto_id IS DISTINCT FROM p_ajuste_producto_id
              OR v_promo.ajuste_automatico IS DISTINCT FROM v_ajuste;

  IF p_datos IS NULL THEN
    -- Lo de la 467, para el bundle viejo: trg_promo_rotar_barra_default mira el
    -- ajuste_automatico NUEVO, así que va en el mismo UPDATE. Sin cambios no escribe.
    IF v_cambio THEN
      UPDATE promociones
         SET producto_regalo_id = p_producto_regalo_id,
             ajuste_producto_id = p_ajuste_producto_id,
             ajuste_automatico = v_ajuste
       WHERE id = p_promocion_id AND sucursal_id = v_sucursal;
    END IF;
    RETURN jsonb_build_object('success', true, 'promocion_id', p_promocion_id, 'cambio', v_cambio);
  END IF;

  -- #1491: todo o nada. Un rechazo de los triggers deshace el bloque entero y vuelve
  -- como un error legible.
  BEGIN
    UPDATE promociones
       SET nombre              = CASE WHEN p_datos ? 'nombre' THEN btrim(p_datos->>'nombre') ELSE nombre END,
           tipo                = CASE WHEN p_datos ? 'tipo' THEN p_datos->>'tipo' ELSE tipo END,
           fecha_inicio        = CASE WHEN p_datos ? 'fecha_inicio' THEN (p_datos->>'fecha_inicio')::date ELSE fecha_inicio END,
           fecha_fin           = CASE WHEN p_datos ? 'fecha_fin' THEN NULLIF(p_datos->>'fecha_fin', '')::date ELSE fecha_fin END,
           limite_usos         = CASE WHEN p_datos ? 'limite_usos' THEN (p_datos->>'limite_usos')::int ELSE limite_usos END,
           prioridad           = CASE WHEN p_datos ? 'prioridad' THEN COALESCE((p_datos->>'prioridad')::int, 0) ELSE prioridad END,
           regalo_mueve_stock  = CASE WHEN p_datos ? 'regalo_mueve_stock' THEN COALESCE((p_datos->>'regalo_mueve_stock')::boolean, false) ELSE regalo_mueve_stock END,
           modo_exclusion      = CASE WHEN p_datos ? 'modo_exclusion' THEN COALESCE(p_datos->>'modo_exclusion', 'acumulable') ELSE modo_exclusion END,
           unidades_por_bloque = CASE WHEN p_datos ? 'unidades_por_bloque' THEN (p_datos->>'unidades_por_bloque')::int ELSE unidades_por_bloque END,
           stock_por_bloque    = CASE WHEN p_datos ? 'stock_por_bloque' THEN (p_datos->>'stock_por_bloque')::int ELSE stock_por_bloque END,
           descripcion_regalo  = CASE WHEN p_datos ? 'descripcion_regalo' THEN p_datos->>'descripcion_regalo' ELSE descripcion_regalo END,
           producto_regalo_id  = p_producto_regalo_id,
           ajuste_producto_id  = p_ajuste_producto_id,
           ajuste_automatico   = v_ajuste
     WHERE id = p_promocion_id AND sucursal_id = v_sucursal;

    IF v_prod_ids IS NOT NULL THEN
      DELETE FROM promocion_productos
       WHERE promocion_id = p_promocion_id AND sucursal_id = v_sucursal
         AND producto_id <> ALL (v_prod_ids);
      INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id)
      SELECT p_promocion_id, x, v_sucursal FROM unnest(v_prod_ids) x ORDER BY x
      ON CONFLICT (promocion_id, producto_id) DO NOTHING;
    END IF;

    IF v_claves IS NOT NULL THEN
      DELETE FROM promocion_reglas
       WHERE promocion_id = p_promocion_id AND sucursal_id = v_sucursal
         AND clave <> ALL (v_claves);
      INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
      SELECT p_promocion_id, r->>'clave', (r->>'valor')::numeric, v_sucursal
        FROM jsonb_array_elements(v_reglas) r
      ON CONFLICT (promocion_id, clave) DO UPDATE
         SET valor = EXCLUDED.valor
       WHERE promocion_reglas.valor IS DISTINCT FROM EXCLUDED.valor;
    END IF;
  EXCEPTION
    WHEN check_violation THEN
      GET STACKED DIAGNOSTICS v_constraint = CONSTRAINT_NAME, v_detalle = PG_EXCEPTION_DETAIL;
      IF v_constraint IS DISTINCT FROM 'productos_stock_no_negativo' THEN
        RAISE;
      END IF;
      -- renormalizar_bloques_por_cambio_factor bajó el contenedor por debajo de 0. La
      -- fila rechazada empieza por su id ("Failing row contains (id, ...").
      v_cont_id := NULLIF(substring(v_detalle FROM '\((\d+),'), '')::bigint;
      SELECT nombre, stock INTO v_cont_nombre, v_cont_stock
        FROM productos WHERE id = v_cont_id AND sucursal_id = v_sucursal;
      RETURN jsonb_build_object(
        'success', false,
        'codigo', 'contenedor_sin_stock',
        'error', CASE WHEN v_cont_nombre IS NOT NULL
                      THEN format('El contenedor «%s» no tiene stock para el factor nuevo (hay %s): el cambio cierra bloques que no se pueden descontar. No se guardó ningún cambio de la promoción.',
                                  v_cont_nombre, COALESCE(v_cont_stock, 0))
                      ELSE 'El contenedor no tiene stock para el factor nuevo: el cambio cierra bloques que no se pueden descontar. No se guardó ningún cambio de la promoción.'
                 END);
    WHEN raise_exception THEN
      -- Los rechazos de negocio de los triggers (el límite de usos, entre otros).
      RETURN jsonb_build_object('success', false,
        'error', SQLERRM || ' No se guardó ningún cambio de la promoción.');
  END;

  SELECT * INTO v_fila FROM promociones WHERE id = p_promocion_id AND sucursal_id = v_sucursal;
  RETURN jsonb_build_object('success', true, 'promocion_id', p_promocion_id, 'cambio', v_cambio,
                            'promocion', to_jsonb(v_fila));
END
$function$;

REVOKE EXECUTE ON FUNCTION public.cambiar_regalo_promocion(bigint, bigint, bigint, boolean, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cambiar_regalo_promocion(bigint, bigint, bigint, boolean, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- PROMO-C · la RPC escribe la definición de la promo
-- ---------------------------------------------------------------------------
-- Con p_datos, cambiar_regalo_promocion escribe promociones.regalo_mueve_stock (lo que
-- antes hacía el UPDATE REST). Es la definición de la promo, no el modo de un pedido:
-- va a la lista de excepciones de PROMO-C, con previsualizar_cambio_factor y
-- renormalizar_bloques_por_cambio_factor. Parche por ancla sobre el cuerpo vivo (la
-- premisa ya garantiza su md5).
DO $promo_c$
DECLARE
  d   text := pg_get_functiondef('public.auditoria_funciones_modo_regalo_vivo()'::regprocedure);
  pat text := '       ''validar_cambio_unidades_por_bulto'',' || chr(10);
  rep text := '       ''validar_cambio_unidades_por_bulto'', ''cambiar_regalo_promocion'',' || chr(10);
BEGIN
  IF (length(d) - length(replace(d, pat, ''))) / length(pat) <> 1 THEN
    RAISE EXCEPTION 'mig 472 · el ancla de auditoria_funciones_modo_regalo_vivo no aparece una sola vez';
  END IF;
  EXECUTE replace(d, pat, rep);
END
$promo_c$;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_md5 text;
  v_acl text;
BEGIN
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'cambiar_regalo_promocion'
                                     AND pronamespace = 'public'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'mig 472 · cambiar_regalo_promocion quedó con más de una firma';
  END IF;
  SELECT md5(p.prosrc), p.proacl::text || '/' || p.prosecdef::text INTO v_md5, v_acl
    FROM pg_proc p
   WHERE p.oid = 'public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)'::regprocedure;
  IF v_md5 <> 'b26fc2b93c6180e56e7a1780f69cda36'
     OR v_acl <> '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}/true' THEN
    RAISE EXCEPTION 'mig 472 · cambiar_regalo_promocion no quedó como en el repo (md5 %, acl %)', v_md5, v_acl;
  END IF;

  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'public.auditoria_funciones_modo_regalo_vivo()'::regprocedure) <> 'd3ff72dbbd49fdcd112b3a7d015193fe'
     OR public.auditoria_funciones_modo_regalo_vivo() <> 0 THEN
    RAISE EXCEPTION 'mig 472 · PROMO-C no quedó en verde con la RPC en su lista';
  END IF;

  -- Los grants REST de la 467 no cambian.
  IF has_column_privilege('authenticated', 'public.promociones', 'producto_regalo_id', 'UPDATE')
     OR has_column_privilege('authenticated', 'public.promociones', 'ajuste_producto_id', 'UPDATE')
     OR NOT has_column_privilege('authenticated', 'public.promociones', 'activo', 'UPDATE') THEN
    RAISE EXCEPTION 'mig 472 · los grants de UPDATE de promociones cambiaron';
  END IF;
END
$post$;

COMMIT;
