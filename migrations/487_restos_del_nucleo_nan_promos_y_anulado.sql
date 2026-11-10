-- 487 · Restos del núcleo: el NaN, las promos y el estado 'anulado' (tarjeta 9 de #1524; #1515, #1520).
--
-- QUÉ PASABA
--   · PAT-1-1 y PAT-1-2 (#1520). 'NaN'::numeric es mayor que todo número: pasa toda guarda `< 0` o `<= 0` y todo
--     CHECK de piso (`>= 0`, `> 0`). Lo dejaban entrar cinco RPCs de admin (actualizar_politica_minimo_pedido,
--     actualizar_monto_minimo_pedido, crear_condicion_para_producto, guardar_meta_gerencial y
--     guardar_meta_preventista) y actualizar_precios_masivo, que castea los precios sin validar. Los CHECK de
--     politicas_comerciales, grupo_precio_escalas y las metas tampoco lo frenaban, y productos no tenía CHECK de precio.
--     Con un cargo_envio_pedido en NaN se rechazaban todas las altas de la sucursal; con un precio en NaN,
--     precio_fuera_de_politica se quedaba sin techo. Hoy hay 0 filas con NaN en las columnas numeric de public.
--   · PAT-7-1 (#1520). pedidos_estado_check admitía 'anulado', que no escribe nadie (0 filas) y que unas 15 funciones
--     no cuentan como baja.
--   · PRM-3 (#1515). ajustar_stock_promocion_completo no la llama ninguna pantalla ni ninguna función. Tenía EXECUTE
--     para authenticated y, en modo A, descontaba el regalo dos veces.
--   · PRM-4 (#1515). Una promo se guardaba sin que el server mirara los valores. promocion_reglas.valor no tenía CHECK:
--     un 2,5 se lee 3 en _promo_reglas_vigentes (::int), 2,5 en regalo_fuera_de_promo y 2 en el front (parseInt).
--     Pasaban también limite_usos <= 0, fecha_fin < fecha_inicio y unidades_por_bloque <= 0. Los datos de hoy
--     están limpios.
--   · PRM-5 (#1515). sustituir_regalo_pedido y dividir_regalo_pedido contestaban el reintento antes de mirar el rol, y
--     lo hacían sin acotarlo a la sucursal ni a la línea y sin comparar el contenido. Es lo mismo que #1050 y #1327
--     arreglaron en registrar_salvedad. El reintento de la carrera (el handler de unique_violation) tampoco acotaba.
--
-- QUÉ CAMBIA
--   1. NaN. El freno vive en la columna, porque así cubre todo camino: las seis RPCs, el REST y los triggers. Las
--      RPCs no se tocan. Un NaN sólo llega de un cliente que manda el string 'NaN': JSON no tiene NaN, y supabase-js
--      manda null, que las RPCs ya rechazan. Por eso alcanza con el mensaje del CHECK, y actualizar_precios_masivo lo
--      informa por producto en su lista de errores.
--        · productos_precios_no_nan: precio, precio_sin_iva e impuestos_internos.
--        · grupo_precio_escalas_precio_unitario_no_nan.
--        · politicas_comerciales_montos_no_nan: monto_minimo_pedido, monto_envio_gratis y cargo_envio_pedido. Las
--          comisiones y los porcentajes de combos ya tienen techo (<= 100), y el techo deja afuera al NaN.
--        · metas_gerenciales_valor_finito y metas_preventista_valor_objetivo_finito. Son numeric sin precisión: además
--          del NaN, aceptan 'Infinity'.
--      Para lo que venga, la regla va en CLAUDE.md, y el gate es la cuarta batería de scripts/check-integridad.mjs,
--      que lee auditoria_nan() (más abajo).
--   2. pedidos_estado_check sin 'anulado' (decisión del dueño, 10/11). Los IN de SQL que lo nombran, y los otros tres
--      CHECK de pedidos que lo nombran, quedan como código muerto: se limpian cuando alguien toque esa función o ese
--      CHECK, sin refactor de paso. El tipo EstadoPedido del front sale en un PR aparte, después de las tarjetas 1, 2,
--      6 y 7, que tocan sus archivos.
--   3. Las promos se validan en la tabla, que cubre el alta por REST (createPromocion) y la edición por
--      cambiar_regalo_promocion. Esa RPC re-lanza todo check_violation que no sea el del contenedor, así que el
--      rechazo llega con el nombre del CHECK. El modal ya valida lo que el usuario puede escribir.
--        · promociones_limite_usos_positivo: NULL (sin límite) o > 0.
--        · promociones_fechas_en_orden: sin fin, o el fin no antes del inicio.
--        · promociones_factor_positivo: unidades_por_bloque y stock_por_bloque, NULL o > 0. El segundo va también:
--          es la otra mitad del factor y el modal manda 1.
--        · promocion_reglas_valor_entero: un entero entre 1 y 2147483647. Es lo que lee _promo_reglas_vigentes (::int),
--          y el rango deja afuera al NaN y al infinito.
--   4. DROP de ajustar_stock_promocion_completo (decisión del dueño, 10/11). No tiene llamadores en SQL. El hook del
--      front que la envolvía, sin pantalla, sale en el mismo PR, junto con sus variantes del arnés (T14a y T14b).
--   5. El reintento de sustituir_regalo_pedido y de dividir_regalo_pedido contesta después del rol y sólo dentro de la
--      sucursal activa. Si la clave es de otra línea, de otro producto o cantidad, o de otras partes, contesta
--      success false con su código ('sustitucion_ya_registrada' o 'reparto_ya_registrado'), como registrar_salvedad.
--      La línea se compara sólo si sigue viva: una edición posterior la borra y deja pedido_item_id en NULL (FK SET
--      NULL). En dividir, el reintento va después de leer las partes, porque las compara. El handler de
--      unique_violation acota a la sucursal y a la línea. Son parches por ancla sobre el cuerpo vivo, con premisa de
--      md5.
--   6. Dos funciones de servidor para los gates. Son sólo de la service_role, así que se revocan a las tres mitades:
--        · auditoria_nan(): cuenta, en cada columna numeric de public, las filas en NaN o infinito. La lee
--          scripts/check-integridad.mjs.
--        · auditoria_locks(): devuelve cada sentencia con un lock de fila (FOR UPDATE / NO KEY UPDATE / SHARE / KEY
--          SHARE), sin comentarios y con los literales vacíos. La lee scripts/check-locks.mjs, que marca la que toma
--          varias filas sin ORDER BY (#1520, gate 4).
--
-- QUÉ NO CAMBIA
--   Las seis RPCs del NaN, cambiar_regalo_promocion, el resto de sustituir y dividir, los EXECUTE y los grants de
--   las tablas. promo_ajustes queda: la escribe aplicar_uso_promo_acumulador.
--
-- Ensayo: scripts/test-restos-nucleo-1520.sql (corre en prod sin dejar rastro). Se aplica en LF.

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- Los ALTER TABLE toman ACCESS EXCLUSIVE un instante. Si hay una transacción larga adelante, mejor fallar y reintentar
-- que dejar la cola de locks de pedidos y productos trabada detrás.
SET LOCAL lock_timeout = '5s';

-- ---------------------------------------------------------------------------
-- Premisas (leídas en prod el 10/11)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_llamadores text;
BEGIN
  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure)
     <> '0e7af929266e7516e3fb368e2bf09c70' THEN
    RAISE EXCEPTION 'sustituir_regalo_pedido cambió en prod desde que se leyó: rehacer sobre la definición vigente';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure)
     <> '183bd2fbe66b6431bb08bc986806849d' THEN
    RAISE EXCEPTION 'dividir_regalo_pedido cambió en prod desde que se leyó: rehacer sobre la definición vigente';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc
       WHERE oid = 'public.ajustar_stock_promocion_completo(bigint,bigint,integer,integer,uuid,text)'::regprocedure)
     <> 'ae715049d22943a572d7ce7a0383637a' THEN
    RAISE EXCEPTION 'ajustar_stock_promocion_completo cambió en prod desde que se leyó';
  END IF;
  SELECT string_agg(p.oid::regprocedure::text, ', ') INTO v_llamadores
    FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname <> 'ajustar_stock_promocion_completo'
     AND p.prosrc ~ 'ajustar_stock_promocion_completo';
  IF v_llamadores IS NOT NULL THEN
    RAISE EXCEPTION 'ajustar_stock_promocion_completo tiene llamadores en SQL: %', v_llamadores;
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = 'public.pedidos'::regclass AND conname = 'pedidos_estado_check')
     IS DISTINCT FROM 'CHECK ((estado = ANY (ARRAY[''pendiente''::text, ''en_preparacion''::text, ''asignado''::text, ''entregado''::text, ''cancelado''::text, ''anulado''::text])))' THEN
    RAISE EXCEPTION 'pedidos_estado_check no es el que se leyó';
  END IF;
  IF to_regprocedure('public.auditoria_nan()') IS NOT NULL OR to_regprocedure('public.auditoria_locks()') IS NOT NULL THEN
    RAISE EXCEPTION 'auditoria_nan() o auditoria_locks() ya existen';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · NaN en las columnas (PAT-1-1, PAT-1-2)
-- ---------------------------------------------------------------------------
-- `x <> 'NaN'` es NULL con x NULL, y un CHECK NULL pasa: las columnas que admiten NULL lo siguen admitiendo.
-- Las de productos y politicas_comerciales tienen precisión: no guardan infinito.
ALTER TABLE public.productos
  ADD CONSTRAINT productos_precios_no_nan
  CHECK (precio <> 'NaN'::numeric AND precio_sin_iva <> 'NaN'::numeric AND impuestos_internos <> 'NaN'::numeric);

ALTER TABLE public.grupo_precio_escalas
  ADD CONSTRAINT grupo_precio_escalas_precio_unitario_no_nan
  CHECK (precio_unitario <> 'NaN'::numeric);

ALTER TABLE public.politicas_comerciales
  ADD CONSTRAINT politicas_comerciales_montos_no_nan
  CHECK (monto_minimo_pedido <> 'NaN'::numeric
         AND monto_envio_gratis <> 'NaN'::numeric
         AND cargo_envio_pedido <> 'NaN'::numeric);

-- numeric sin precisión: también el infinito ('-Infinity' ya lo frena el piso).
ALTER TABLE public.metas_gerenciales
  ADD CONSTRAINT metas_gerenciales_valor_finito
  CHECK (valor <> 'NaN'::numeric AND valor <> 'Infinity'::numeric);

ALTER TABLE public.metas_preventista
  ADD CONSTRAINT metas_preventista_valor_objetivo_finito
  CHECK (valor_objetivo <> 'NaN'::numeric AND valor_objetivo <> 'Infinity'::numeric);

-- ---------------------------------------------------------------------------
-- 2 · 'anulado' sale del estado de un pedido (PAT-7-1)
-- ---------------------------------------------------------------------------
ALTER TABLE public.pedidos
  DROP CONSTRAINT pedidos_estado_check,
  ADD CONSTRAINT pedidos_estado_check
  CHECK (estado = ANY (ARRAY['pendiente'::text, 'en_preparacion'::text, 'asignado'::text, 'entregado'::text,
                             'cancelado'::text]));

-- ---------------------------------------------------------------------------
-- 3 · Los valores de una promo (PRM-4)
-- ---------------------------------------------------------------------------
ALTER TABLE public.promociones
  ADD CONSTRAINT promociones_limite_usos_positivo
  CHECK (limite_usos IS NULL OR limite_usos > 0),
  ADD CONSTRAINT promociones_fechas_en_orden
  CHECK (fecha_fin IS NULL OR fecha_fin >= fecha_inicio),
  ADD CONSTRAINT promociones_factor_positivo
  CHECK ((unidades_por_bloque IS NULL OR unidades_por_bloque > 0)
         AND (stock_por_bloque IS NULL OR stock_por_bloque > 0));

-- 'NaN' es mayor que todo número y 'Infinity' no entra en el rango: los dos quedan afuera.
ALTER TABLE public.promocion_reglas
  ADD CONSTRAINT promocion_reglas_valor_entero
  CHECK (valor = trunc(valor) AND valor >= 1 AND valor <= 2147483647);

-- ---------------------------------------------------------------------------
-- 4 · ajustar_stock_promocion_completo (PRM-3)
-- ---------------------------------------------------------------------------
DROP FUNCTION public.ajustar_stock_promocion_completo(bigint, bigint, integer, integer, uuid, text);

-- ---------------------------------------------------------------------------
-- 5 · El reintento de sustituir y repartir un regalo (PRM-5)
-- ---------------------------------------------------------------------------
DO $parche_sustituir$
DECLARE
  v_def text := pg_get_functiondef('public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure);
  v_ancla text;
  v_reemplazo text;
  v_n int;
BEGIN
  -- a) El reintento baja de arriba de todo a después del rol, acotado y comparando el contenido.
  v_ancla := $a$  IF p_client_request_id IS NOT NULL THEN
    SELECT id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id, 'idempotent_replay', true);
    END IF;
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  -- #1056: con `NOT IN` un rol NULL daba NULL y dejaba pasar.
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin o encargado pueden sustituir regalos');
  END IF;
$a$;
  v_reemplazo := $r$  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
  -- #1056: con `NOT IN` un rol NULL daba NULL y dejaba pasar.
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin o encargado pueden sustituir regalos');
  END IF;
  -- PRM-5 (#1515): el reintento contesta después de saber quién pregunta, y sólo el de esta
  -- sucursal, esta línea y este cambio, como registrar_salvedad (#1050, #1327). Antes corría
  -- arriba de todo y le contestaba "hecho" a cualquiera que tuviera la clave, de cualquier
  -- sucursal, aunque fuera de otra línea o de otro producto.
  IF p_client_request_id IS NOT NULL THEN
    SELECT id, pedido_item_id, producto_sustituto_id, cantidad_sustituta INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id
       AND sucursal_id = v_sucursal;
    -- La sustitución conserva la línea. pedido_item_id queda NULL sólo si una edición
    -- posterior la borró (FK SET NULL), y entonces la línea ya no se puede comparar.
    IF FOUND AND (v_existing.pedido_item_id <> p_pedido_item_id
                  OR v_existing.producto_sustituto_id IS DISTINCT FROM p_producto_nuevo_id
                  OR v_existing.cantidad_sustituta IS DISTINCT FROM p_cantidad_nueva) THEN
      RETURN jsonb_build_object('success', false, 'codigo', 'sustitucion_ya_registrada', 'error',
        'Este cambio de regalo ya se había registrado con otra línea, otro producto u otra cantidad: recargá el pedido para ver cómo quedó.');
    END IF;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id, 'idempotent_replay', true);
    END IF;
  END IF;
$r$;
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'sustituir_regalo_pedido · el ancla del reintento aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  v_def := replace(v_def, v_ancla, v_reemplazo);

  -- b) El que pierde la carrera de la misma clave contesta el replay sólo si el que ganó es de esta sucursal y línea.
  v_ancla := $a$    SELECT id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id, 'idempotent_replay', true);
    END IF;
    RAISE;
$a$;
  v_reemplazo := $r$    -- PRM-5 (#1515): sólo si el que ganó es de esta sucursal y esta línea.
    SELECT id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id
       AND sucursal_id = v_sucursal
       AND pedido_item_id = p_pedido_item_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id, 'idempotent_replay', true);
    END IF;
    RAISE;
$r$;
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'sustituir_regalo_pedido · el ancla del handler aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_reemplazo);
END
$parche_sustituir$;

DO $parche_dividir$
DECLARE
  v_def text := pg_get_functiondef('public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure);
  v_ancla text;
  v_reemplazo text;
  v_n int;
BEGIN
  -- a) Sale el reintento de arriba de todo.
  v_ancla := $a$  -- Idempotencia: el client_request_id va en la PRIMERA fila del reparto (el
  -- indice unico es por fila, y las N comparten reparto_id).
  IF p_client_request_id IS NOT NULL THEN
    SELECT id, reparto_id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id,
        'reparto_id', v_existing.reparto_id, 'idempotent_replay', true);
    END IF;
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
$a$;
  v_reemplazo := $r$  -- PRM-5 (#1515): el reintento se contesta más abajo, después del rol y de leer las partes.
  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_user_id;
$r$;
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'dividir_regalo_pedido · el ancla del reintento aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  v_def := replace(v_def, v_ancla, v_reemplazo);

  -- b) Vuelve después de leer las partes, acotado y comparándolas, antes de tomar la línea.
  v_ancla := $a$  SELECT sum(x) INTO v_suma FROM unnest(v_cant) AS x;
$a$;
  v_reemplazo := $r$  SELECT sum(x) INTO v_suma FROM unnest(v_cant) AS x;

  -- Idempotencia: el client_request_id va en la PRIMERA fila del reparto (el
  -- indice unico es por fila, y las N comparten reparto_id).
  -- PRM-5 (#1515): contesta después de saber quién pregunta, y sólo el de esta sucursal,
  -- esta línea y estas partes, como registrar_salvedad (#1050, #1327). Antes corría arriba
  -- de todo y le contestaba "hecho" a cualquiera que tuviera la clave.
  IF p_client_request_id IS NOT NULL THEN
    SELECT id, reparto_id, pedido_item_id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id
       AND sucursal_id = v_sucursal;
    -- El reparto conserva la línea. pedido_item_id queda NULL sólo si una edición posterior
    -- la borró (FK SET NULL). Las partes son las filas del reparto, en el orden en que entraron.
    IF FOUND AND (v_existing.pedido_item_id <> p_pedido_item_id
                  OR (SELECT array_agg(s.producto_sustituto_id ORDER BY s.id)
                        FROM pedido_item_sustituciones s
                       WHERE s.reparto_id = v_existing.reparto_id AND s.sucursal_id = v_sucursal)
                     IS DISTINCT FROM v_prod
                  OR (SELECT array_agg(s.cantidad_sustituta ORDER BY s.id)
                        FROM pedido_item_sustituciones s
                       WHERE s.reparto_id = v_existing.reparto_id AND s.sucursal_id = v_sucursal)
                     IS DISTINCT FROM v_cant) THEN
      RETURN jsonb_build_object('success', false, 'codigo', 'reparto_ya_registrado', 'error',
        'Este reparto del regalo ya se había registrado con otra línea u otras partes: recargá el pedido para ver cómo quedó.');
    END IF;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id,
        'reparto_id', v_existing.reparto_id, 'idempotent_replay', true);
    END IF;
  END IF;
$r$;
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'dividir_regalo_pedido · el ancla de las partes aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  v_def := replace(v_def, v_ancla, v_reemplazo);

  -- c) El que pierde la carrera de la misma clave contesta el replay sólo si el que ganó es de esta sucursal y línea.
  v_ancla := $a$    SELECT id, reparto_id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id,
        'reparto_id', v_existing.reparto_id, 'idempotent_replay', true);
    END IF;
    RAISE;
$a$;
  v_reemplazo := $r$    -- PRM-5 (#1515): sólo si el que ganó es de esta sucursal y esta línea.
    SELECT id, reparto_id INTO v_existing
      FROM pedido_item_sustituciones
     WHERE client_request_id = p_client_request_id
       AND sucursal_id = v_sucursal
       AND pedido_item_id = p_pedido_item_id;
    IF FOUND THEN
      RETURN jsonb_build_object('success', true, 'sustitucion_id', v_existing.id,
        'reparto_id', v_existing.reparto_id, 'idempotent_replay', true);
    END IF;
    RAISE;
$r$;
  v_n := (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'dividir_regalo_pedido · el ancla del handler aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(v_def, v_ancla, v_reemplazo);
END
$parche_dividir$;

-- ---------------------------------------------------------------------------
-- 6 · Los gates: auditoria_nan() y auditoria_locks()
-- ---------------------------------------------------------------------------
-- La lee scripts/check-integridad.mjs (cuarta batería). Cuenta, en cada columna numeric de cada tabla de public, las
-- filas en NaN o en infinito ('NaN'::numeric = 'NaN'::numeric es verdadero en Postgres). Un SELECT por tabla, con
-- un count FILTER por columna. Recorre también las de precisión, que no guardan infinito: así no hay que mantener
-- una lista.
CREATE FUNCTION public.auditoria_nan()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  r      record;
  v_fila jsonb;
  v_out  jsonb := '[]'::jsonb;
  v_cols int := 0;
BEGIN
  FOR r IN
    SELECT c.relname, array_agg(a.attname::text ORDER BY a.attnum) AS cols
      FROM pg_class c
      JOIN pg_attribute a ON a.attrelid = c.oid
     WHERE c.relnamespace = 'public'::regnamespace
       AND c.relkind IN ('r', 'p')
       AND a.attnum > 0
       AND NOT a.attisdropped
       AND a.atttypid = 'numeric'::regtype
     GROUP BY c.relname
     ORDER BY c.relname
  LOOP
    v_cols := v_cols + cardinality(r.cols);
    EXECUTE format('SELECT jsonb_build_object(%s) FROM public.%I',
                   (SELECT string_agg(format('%L, count(*) FILTER (WHERE %I IN (''NaN''::numeric, ''Infinity''::numeric, ''-Infinity''::numeric))',
                                             col, col), ', ')
                      FROM unnest(r.cols) AS col),
                   r.relname)
      INTO v_fila;
    v_out := v_out || COALESCE((SELECT jsonb_agg(jsonb_build_object('tabla', r.relname, 'columna', e.k, 'filas', e.v::bigint)
                                                 ORDER BY e.k)
                                  FROM jsonb_each_text(v_fila) AS e(k, v)
                                 WHERE e.v::bigint > 0), '[]'::jsonb);
  END LOOP;
  RETURN jsonb_build_object('generado_at', now(), 'columnas', v_cols, 'con_nan', v_out);
END
$function$;

COMMENT ON FUNCTION public.auditoria_nan() IS
  'Gate de #1520 (scripts/check-integridad.mjs): filas en NaN o infinito en las columnas numeric de public. '
  'Sólo de servidor.';

-- La lee scripts/check-locks.mjs (#1520, gate 4), que aplica el criterio y la lista blanca
-- (scripts/locks-permitidas.json, sólo se achica). Lee texto, no ejecuta, igual que auditoria_rol_sin_activo():
-- antes de partir por `;` saca los comentarios y vacía los literales. Devuelve todas las sentencias con un lock de
-- fila; cuál toma varias filas lo decide el script, que tiene sus tests.
CREATE FUNCTION public.auditoria_locks()
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path TO 'public', 'pg_catalog'
AS $function$
  WITH f AS (
    SELECT p.oid::regprocedure::text AS firma,
           regexp_replace(regexp_replace(regexp_replace(p.prosrc,
             '/\*.*?\*/', ' ', 'g'),
             '--[^\n]*', ' ', 'g'),
             '''[^'']*''', '''''', 'g') AS src
      FROM pg_proc p
     WHERE p.pronamespace = 'public'::regnamespace
       AND p.prokind IN ('f', 'p')
       AND p.prolang IN (SELECT l.oid FROM pg_language l WHERE l.lanname IN ('sql', 'plpgsql'))
  ), sentencias AS (
    SELECT DISTINCT f.firma, btrim(regexp_replace(s.texto, '\s+', ' ', 'g')) AS sentencia
      FROM f
      CROSS JOIN LATERAL regexp_split_to_table(f.src, ';') AS s(texto)
     WHERE s.texto ~* '\mFOR\s+(NO\s+KEY\s+UPDATE|UPDATE|KEY\s+SHARE|SHARE)\M'
  )
  SELECT jsonb_build_object(
    'generado_at', now(),
    'funciones', (SELECT count(*) FROM f),
    'sentencias', COALESCE((
      SELECT jsonb_agg(jsonb_build_object('firma', firma, 'sentencia', sentencia) ORDER BY firma, sentencia)
        FROM sentencias), '[]'::jsonb)
  );
$function$;

COMMENT ON FUNCTION public.auditoria_locks() IS
  'Gate de #1520 (scripts/check-locks.mjs): las sentencias con un lock de fila de las funciones de public. '
  'Sólo de servidor.';

-- Sólo las corre el CI, con la service_role: las tres mitades.
REVOKE EXECUTE ON FUNCTION public.auditoria_nan() FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON FUNCTION public.auditoria_locks() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.auditoria_nan() TO service_role;
GRANT EXECUTE ON FUNCTION public.auditoria_locks() TO service_role;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  v_faltan text;
BEGIN
  SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS d INTO r
    FROM pg_proc WHERE oid = 'public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)'::regprocedure;
  IF r.h <> 'e8bb5ef19d2c922b389d3fc62c7b1d2e' OR r.a IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
     OR NOT r.d THEN
    RAISE EXCEPTION 'sustituir_regalo_pedido no quedó como en el repo (md5 %, acl %, definer %)', r.h, r.a, r.d;
  END IF;
  SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS d INTO r
    FROM pg_proc WHERE oid = 'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'::regprocedure;
  IF r.h <> 'bf401dfb728c720e066d06c17cc1e0c2' OR r.a IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'
     OR NOT r.d THEN
    RAISE EXCEPTION 'dividir_regalo_pedido no quedó como en el repo (md5 %, acl %, definer %)', r.h, r.a, r.d;
  END IF;

  IF to_regprocedure('public.ajustar_stock_promocion_completo(bigint,bigint,integer,integer,uuid,text)') IS NOT NULL THEN
    RAISE EXCEPTION 'ajustar_stock_promocion_completo sigue existiendo';
  END IF;

  SELECT string_agg(e.n, ', ') INTO v_faltan
    FROM unnest(ARRAY['productos_precios_no_nan', 'grupo_precio_escalas_precio_unitario_no_nan',
                      'politicas_comerciales_montos_no_nan', 'metas_gerenciales_valor_finito',
                      'metas_preventista_valor_objetivo_finito', 'promociones_limite_usos_positivo',
                      'promociones_fechas_en_orden', 'promociones_factor_positivo',
                      'promocion_reglas_valor_entero']) AS e(n)
   WHERE NOT EXISTS (SELECT 1 FROM pg_constraint c
                      WHERE c.conname = e.n AND c.connamespace = 'public'::regnamespace
                        AND c.contype = 'c' AND c.convalidated);
  IF v_faltan IS NOT NULL THEN
    RAISE EXCEPTION 'faltan los CHECK (o no están validados): %', v_faltan;
  END IF;
  IF (SELECT pg_get_constraintdef(oid) FROM pg_constraint
       WHERE conrelid = 'public.pedidos'::regclass AND conname = 'pedidos_estado_check')
     IS DISTINCT FROM 'CHECK ((estado = ANY (ARRAY[''pendiente''::text, ''en_preparacion''::text, ''asignado''::text, ''entregado''::text, ''cancelado''::text])))' THEN
    RAISE EXCEPTION 'pedidos_estado_check no quedó sin anulado';
  END IF;

  IF has_function_privilege('anon', 'public.auditoria_nan()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_nan()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.auditoria_locks()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.auditoria_locks()', 'EXECUTE') THEN
    RAISE EXCEPTION 'auditoria_nan() o auditoria_locks() quedó ejecutable desde la API';
  END IF;
  IF jsonb_array_length(public.auditoria_nan()->'con_nan') <> 0 THEN
    RAISE EXCEPTION 'hay filas en NaN o infinito: %', public.auditoria_nan()->'con_nan';
  END IF;
  IF jsonb_array_length(public.auditoria_locks()->'sentencias') = 0 THEN
    RAISE EXCEPTION 'auditoria_locks() no encontró ninguna sentencia con lock';
  END IF;
END
$post$;

COMMIT;
