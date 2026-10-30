-- =========================================================================
-- 416 · Stock: una planilla de control se aplica una vez (#1295), y cancelar
-- y editar un pedido bloquean los productos por id (#1296).
--
-- Ensayo: scripts/test-stock-planilla-y-locks-1295-1296.sql
--
-- #1295 · Desde la 402 el control de stock entra por diferencia (contado −
-- "Stock Sistema" de la planilla) sobre el stock de ahora, y la diferencia no
-- es idempotente: la planilla no tenía identidad y subir dos veces el mismo
-- archivo la aplicaba dos veces (planilla 12, se cuentan 10: el stock quedaba
-- en 10 y después en 8; con lotes, la segunda bajada volvía a comer FEFO). El
-- modal invitaba a hacerlo: ante una fila rechazada decía "Volvé a contarlos"
-- y ofrecía "Cargar otra planilla".
--   * Cada descarga lleva un id (la celda "ID de planilla", que escribe
--     exportControlStock y lee readControlStockPlanilla).
--   * control_stock_sesiones.planilla_id lo guarda, UNIQUE. Las 9 sesiones de
--     antes quedan en NULL.
--   * aplicar_control_stock recibe p_planilla_id y rechaza entera una planilla
--     que ya se cargó, aunque traiga filas nuevas o corregidas: su "Stock
--     Sistema" ya no es el de hoy, y lo que se rechazó la primera vez se
--     vuelve a contar con una planilla nueva. Sin id tampoco aplica: el bundle
--     viejo del PWA y las planillas bajadas antes de esta migración chocan con
--     un mensaje, como hizo la 402 con stock_planilla.
--   * La firma cambia: se dropea la de dos argumentos (trampa 5: dos
--     sobrecargas con rangos superpuestos son un PGRST203). p_planilla_id va
--     con DEFAULT NULL para que el bundle viejo, que manda sólo p_ajustes y
--     p_observaciones, encuentre la función y lea el mensaje en vez de un
--     PGRST202.
--   El resto del cuerpo es el de la 402 (= prod, md5 verificado abajo).
--
-- #1296 · cancelar_pedido_con_stock devolvía el stock en el orden de las
-- líneas (FOR v_item IN ... sin ORDER BY) y actualizar_pedido_items bloqueaba
-- en el orden del JSON (el FOR UPDATE del pre-chequeo) y en el de las líneas
-- (la devolución y la bajada). La venta bloquea por id: una cancelación o
-- edición [B, A] contra una venta [A, B] se trababan (40P01, y la mutation no
-- reintenta). Ahora las dos bloquean los productos del pedido en orden de id
-- antes del primero que tocan, como registrar_compra_completa desde la 407.
-- Son parches por ancla sobre el cuerpo vivo (molde de la 409): agregan el
-- bloque del lock y nada más. El resto de esas dos funciones es de la tarjeta
-- 6 de #1308, que parte de lo que deja esta migración.
--
-- PERMISOS: sin tablas nuevas ni escritura REST (scripts/grants-rest.json no
-- cambia). planilla_id entra por el GRANT SELECT de tabla que authenticated
-- ya tiene sobre control_stock_sesiones, y el modal la lee para avisar antes
-- de aplicar. La RPC nueva: REVOKE PUBLIC, anon; EXECUTE para authenticated.
--
-- DESPLIEGUE: hasta que llega el front, el control de stock no se puede
-- aplicar (el bundle viejo recibe "Actualizá la app"). Las cancelaciones y
-- ediciones no cambian de firma ni de resultado.
-- =========================================================================

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'mig 416 · el texto de la migración trae CRLF: aplicarla desde la versión LF (git show HEAD:migrations/<archivo>)';
  END IF;
END
$lf$;

-- -------------------------------------------------------------------------
-- 0 · Las tres funciones son las de prod
-- -------------------------------------------------------------------------
-- Molde de la 413: md5(prosrc) de prod al escribir esto (2026-10-29). Si otra
-- migración las cambió en el medio, esta la pisaría sin avisar: se aborta y
-- se rehace sobre la definición viva.
DO $vivas$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.aplicar_control_stock(jsonb,text)',                'c981026e964310c6484eed8be2dab749'),
      ('public.cancelar_pedido_con_stock(bigint,text,uuid,text)', '4cb9277b72122b47a018892b7dd239a0'),
      ('public.actualizar_pedido_items(bigint,jsonb,uuid,text)',  '9947f9a9a668572962c9a0faa6bc55ca')) AS v(firma, md5)
  LOOP
    IF to_regprocedure(r.firma) IS NULL
       OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> r.md5 THEN
      RAISE EXCEPTION 'mig 416 · % no es la de prod del 2026-10-29: rehacer la migración sobre la definición viva', r.firma;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
       WHERE n.nspname = 'public' AND p.proname = 'aplicar_control_stock') <> 1 THEN
    RAISE EXCEPTION 'mig 416 · hay más de un aplicar_control_stock en public: revisar antes de cambiarle la firma';
  END IF;
END
$vivas$;

-- -------------------------------------------------------------------------
-- 1 · #1295 · La sesión guarda el id de la planilla
-- -------------------------------------------------------------------------
ALTER TABLE public.control_stock_sesiones
  ADD COLUMN planilla_id uuid,
  ADD CONSTRAINT control_stock_sesiones_planilla_id_key UNIQUE (planilla_id);

COMMENT ON COLUMN public.control_stock_sesiones.planilla_id IS
  'El id de la descarga ("ID de planilla" en el Excel). Único: una planilla se aplica una vez (#1295). NULL en las sesiones anteriores a la mig 416.';

-- -------------------------------------------------------------------------
-- 2 · #1295 · aplicar_control_stock con p_planilla_id
-- -------------------------------------------------------------------------
DROP FUNCTION public.aplicar_control_stock(jsonb, text);

CREATE FUNCTION public.aplicar_control_stock(p_ajustes jsonb, p_observaciones text DEFAULT NULL::text, p_planilla_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id    bigint;
  v_usuario_id     uuid;
  v_sesion_id      bigint;
  v_previa         record;
  v_total_items    integer := 0;
  v_total_altas    integer := 0;
  v_total_bajas    integer := 0;
  v_movidos        integer := 0;
  v_ajuste         jsonb;
  v_num            numeric;
  v_ids            bigint[];
  v_producto_id    bigint;
  v_stock_real     integer;
  v_stock_planilla integer;
  v_stock_actual   integer;
  v_diferencia     integer;
  v_stock_nuevo    integer;
  v_aplicados      jsonb := '[]'::jsonb;
  v_no_encontrados jsonb := '[]'::jsonb;
  v_rechazados     jsonb := '[]'::jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un administrador puede aplicar ajustes de control de stock';
  END IF;

  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa';
  END IF;
  v_usuario_id := auth.uid();

  IF jsonb_typeof(COALESCE(p_ajustes, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'Los ajustes tienen que venir en una lista';
  END IF;

  /* #1295 · Una planilla se aplica una vez, y para saberlo tiene que traer su
     id (la celda "ID de planilla" de la descarga). El DEFAULT NULL es para el
     bundle viejo del PWA, que no lo manda: encuentra la función y choca acá
     con un mensaje. Lo mismo una planilla bajada antes de la mig 416. */
  IF p_planilla_id IS NULL THEN
    RAISE EXCEPTION 'La planilla no trae su identificador ("ID de planilla"). Actualizá la app, descargá una planilla nueva y volvé a contar.';
  END IF;

  /* #1254 · Todo o nada, antes de tocar el stock. Cada fila contada trae el
     conteo (stock_real) y el stock que tenía el sistema al descargar la
     planilla (stock_planilla, la columna "Stock Sistema"). Los dos tienen que
     ser enteros: un 2,5 quedaba en 3 sin aviso (redondeaban el front y esta
     función), y un conteo de unidades con decimales es un error de tipeo, no
     algo para adivinar. Una fila sin conteo (null o '') es un ítem que no se
     controló y se saltea, como siempre: no se ajusta a 0. Un bundle viejo del
     PWA no manda stock_planilla y choca acá, en vez de pisar el stock. */
  FOR v_ajuste IN SELECT e FROM jsonb_array_elements(COALESCE(p_ajustes, '[]'::jsonb)) e
  LOOP
    IF COALESCE(v_ajuste->>'producto_id', '') !~ '^[0-9]+$' THEN
      RAISE EXCEPTION 'Hay un ajuste sin un producto válido: %', v_ajuste;
    END IF;
    CONTINUE WHEN v_ajuste->>'stock_real' IS NULL OR btrim(v_ajuste->>'stock_real') = '';

    IF jsonb_typeof(v_ajuste->'stock_real') <> 'number' THEN
      RAISE EXCEPTION 'El stock contado del producto % tiene que ser un número entero, y vino %',
        v_ajuste->>'producto_id', v_ajuste->'stock_real';
    END IF;
    v_num := (v_ajuste->>'stock_real')::numeric;
    IF v_num < 0 OR v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'El stock contado del producto % tiene que ser un entero mayor o igual a 0, y vino %',
        v_ajuste->>'producto_id', v_num;
    END IF;

    IF jsonb_typeof(v_ajuste->'stock_planilla') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'Falta el stock que traía la planilla para el producto % (columna "Stock Sistema"). Actualizá la app y volvé a cargar la planilla.',
        v_ajuste->>'producto_id';
    END IF;
    v_num := (v_ajuste->>'stock_planilla')::numeric;
    IF v_num <> trunc(v_num) THEN
      RAISE EXCEPTION 'El stock de la planilla del producto % tiene que ser un número entero, y vino %',
        v_ajuste->>'producto_id', v_num;
    END IF;
  END LOOP;

  -- Con la diferencia, una fila repetida se aplicaría dos veces.
  SELECT (e->>'producto_id')::bigint INTO v_producto_id
    FROM jsonb_array_elements(COALESCE(p_ajustes, '[]'::jsonb)) e
   WHERE e->>'stock_real' IS NOT NULL AND btrim(e->>'stock_real') <> ''
   GROUP BY 1
  HAVING count(*) > 1
   ORDER BY 1
   LIMIT 1;
  IF v_producto_id IS NOT NULL THEN
    RAISE EXCEPTION 'El producto % está más de una vez en la planilla', v_producto_id;
  END IF;

  /* #1295 · La sesión nace con el id de la planilla, que es único. Si ya hay
     una con ese id (o la hay a la par: el INSERT espera a la otra carga y, si
     confirma, no inserta), la planilla ya se aplicó y se rechaza ENTERA,
     aunque traiga filas nuevas o corregidas: su "Stock Sistema" es el de la
     descarga, no el de hoy, y aplicarla otra vez restaba de nuevo la
     diferencia de cada fila. Lo que se rechazó la primera vez se vuelve a
     contar con una planilla nueva. */
  INSERT INTO control_stock_sesiones (usuario_id, sucursal_id, observaciones, planilla_id)
  VALUES (v_usuario_id, v_sucursal_id, p_observaciones, p_planilla_id)
  ON CONFLICT (planilla_id) DO NOTHING
  RETURNING id INTO v_sesion_id;

  IF v_sesion_id IS NULL THEN
    SELECT s.id, s.fecha, s.total_items INTO v_previa
      FROM control_stock_sesiones s
     WHERE s.planilla_id = p_planilla_id;
    RAISE EXCEPTION 'Esta planilla ya se cargó el % (control N° %, % producto(s) ajustado(s)): no se vuelve a aplicar. Para volver a contar, descargá una planilla nueva.',
      to_char(v_previa.fecha AT TIME ZONE 'America/Argentina/Buenos_Aires', 'DD/MM/YYYY HH24:MI'),
      v_previa.id, v_previa.total_items;
  END IF;

  /* mig 240 · el ledger lo escribe el trigger, no esta funcion.
     Antes habia un INSERT a mano en stock_historico ADEMAS del que ya dejaba
     trg_stock_historico por el UPDATE: dos filas por diferencia, una util y
     una 'auto' anonima. Ahora se etiqueta el contexto y la unica fila que
     queda es la del trigger, con la sesion y el usuario adentro --lo mismo que
     lee fetchDetalle, que filtra origen='control_stock'--.
     'control_stock' NO esta en la lista blanca de sincronizar_lotes_stock a
     proposito: un conteo que encuentra unidades de mas no sabe de que lote
     son, y van a la bolsa sin vencimiento, igual que antes con 'auto'. El
     camino de BAJADA del trigger no mira el origen, asi que un conteo a la
     baja sigue consumiendo FEFO como siempre. */
  PERFORM set_config('app.stock_origen',   'control_stock', true);
  PERFORM set_config('app.stock_ref_tipo', 'control_stock_sesion', true);
  PERFORM set_config('app.stock_ref_id',   v_sesion_id::text, true);
  PERFORM set_config('app.stock_user_id',  COALESCE(v_usuario_id::text, ''), true);

  /* #1255 · Los productos en orden de id, todos antes de mover el primero:
     el orden de crear_pedido_completo. En el orden de la planilla, un control
     [B, A] y una venta [A, B] se bloqueaban entre sí (40P01). Cada UPDATE baja
     después a los lotes de su producto (trg_lotes_sincronizar): producto antes
     que lote, como la venta. */
  SELECT array_agg(DISTINCT (e->>'producto_id')::bigint ORDER BY (e->>'producto_id')::bigint)
    INTO v_ids
    FROM jsonb_array_elements(COALESCE(p_ajustes, '[]'::jsonb)) e
   WHERE e->>'stock_real' IS NOT NULL AND btrim(e->>'stock_real') <> '';

  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal_id AND id = ANY(COALESCE(v_ids, '{}'::bigint[]))
    ORDER BY id
      FOR UPDATE;

  FOR v_ajuste IN
    SELECT e FROM jsonb_array_elements(COALESCE(p_ajustes, '[]'::jsonb)) e
     WHERE e->>'stock_real' IS NOT NULL AND btrim(e->>'stock_real') <> ''
     ORDER BY (e->>'producto_id')::bigint
  LOOP
    v_producto_id    := (v_ajuste->>'producto_id')::bigint;
    v_stock_real     := (v_ajuste->>'stock_real')::numeric::integer;
    v_stock_planilla := (v_ajuste->>'stock_planilla')::numeric::integer;

    SELECT stock INTO v_stock_actual
      FROM productos
     WHERE id = v_producto_id AND sucursal_id = v_sucursal_id;

    IF NOT FOUND THEN
      v_no_encontrados := v_no_encontrados || jsonb_build_object('producto_id', v_producto_id);
      CONTINUE;
    END IF;

    /* #1254 · El conteo entra como DIFERENCIA contra lo que decía la planilla,
       sobre el stock de ahora: lo vendido entre el conteo y la carga ya bajó
       el stock y no vuelve. Lo que se movió entre la DESCARGA y el conteo, en
       cambio, queda adentro de la diferencia (la planilla se descarga para
       contar enseguida): por eso cada ajuste dice si el stock se movió desde
       la descarga, y la pantalla lo avisa antes de aplicar. */
    v_diferencia := v_stock_real - v_stock_planilla;
    CONTINUE WHEN v_diferencia = 0;

    v_stock_nuevo := v_stock_actual + v_diferencia;
    IF v_stock_nuevo < 0 THEN
      -- Se contaron menos de los que se vendieron después: el conteo ya no
      -- dice nada del stock de hoy. No se aplica; hay que volver a contar.
      v_rechazados := v_rechazados || jsonb_build_object(
        'producto_id',    v_producto_id,
        'stock_planilla', v_stock_planilla,
        'stock_contado',  v_stock_real,
        'stock_actual',   v_stock_actual,
        'motivo',         'quedaria_negativo'
      );
      CONTINUE;
    END IF;

    UPDATE productos SET stock = v_stock_nuevo, updated_at = now()
    WHERE id = v_producto_id AND sucursal_id = v_sucursal_id;

    v_total_items := v_total_items + 1;
    IF v_diferencia > 0 THEN
      v_total_altas := v_total_altas + v_diferencia;
    ELSE
      v_total_bajas := v_total_bajas + abs(v_diferencia);
    END IF;
    IF v_stock_actual <> v_stock_planilla THEN
      v_movidos := v_movidos + 1;
    END IF;

    v_aplicados := v_aplicados || jsonb_build_object(
      'producto_id', v_producto_id,
      'stock_planilla', v_stock_planilla,
      'stock_contado', v_stock_real,
      'stock_anterior', v_stock_actual,
      'stock_nuevo', v_stock_nuevo,
      'diferencia', v_diferencia,
      'movido_desde_descarga', v_stock_actual <> v_stock_planilla
    );
  END LOOP;

  UPDATE control_stock_sesiones
  SET total_items = v_total_items, total_altas = v_total_altas, total_bajas = v_total_bajas
  WHERE id = v_sesion_id;

  RETURN jsonb_build_object(
    'sesion_id', v_sesion_id,
    'total_items', v_total_items,
    'total_altas', v_total_altas,
    'total_bajas', v_total_bajas,
    'movidos_desde_descarga', v_movidos,
    'aplicados', v_aplicados,
    'no_encontrados', v_no_encontrados,
    'rechazados', v_rechazados
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.aplicar_control_stock(jsonb, text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.aplicar_control_stock(jsonb, text, uuid) TO authenticated;

-- -------------------------------------------------------------------------
-- 3 · #1296 · cancelar_pedido_con_stock bloquea los productos por id
-- -------------------------------------------------------------------------
-- Parche por ancla sobre el cuerpo vivo (verificado por md5 en el paso 0): el
-- bloque del lock entra antes de las dos ramas (la devolución y la merma por
-- falta de stock) y el resto queda idéntico. Al final se comprueba que el
-- cuerpo nuevo sin el bloque es, byte a byte, el de antes.
DO $parche$
DECLARE
  v_firma regprocedure := 'public.cancelar_pedido_con_stock(bigint,text,uuid,text)'::regprocedure;
  v_def   text := pg_get_functiondef(v_firma);
  v_ancla text := $ancla$  IF NOT v_falta_stock THEN
    FOR v_item IN
$ancla$;
  v_lock  text := $lock$  -- #1296 · Los productos del pedido, en orden de id, todos antes de mover
  -- el primero: el orden de la venta. El loop de abajo los tomaba en el orden
  -- de las líneas, y una cancelación [B, A] contra una venta [A, B] se
  -- trababan (40P01, y la mutation no reintenta). Cubre las dos ramas, la
  -- devolución y la merma por falta de stock; los contenedores que mueve el
  -- motor de promos más abajo se siguen bloqueando ahí.
  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT pi.producto_id FROM pedido_items pi
                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal)
    ORDER BY id
      FOR UPDATE;

$lock$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla) <> 1 THEN
    RAISE EXCEPTION 'mig 416 · cancelar_pedido_con_stock cambió: el ancla del loop no aparece exactamente una vez';
  END IF;
  EXECUTE replace(v_def, v_ancla, v_lock || v_ancla);
  IF md5(replace((SELECT prosrc FROM pg_proc WHERE oid = v_firma), v_lock, '')) <> '4cb9277b72122b47a018892b7dd239a0' THEN
    RAISE EXCEPTION 'mig 416 · cancelar_pedido_con_stock: el cuerpo nuevo sin el lock no es el de antes';
  END IF;
END
$parche$;

-- -------------------------------------------------------------------------
-- 4 · #1296 · actualizar_pedido_items bloquea los productos por id
-- -------------------------------------------------------------------------
-- El bloque entra entre el chequeo de productos desactivados (que no
-- bloquea) y el pre-chequeo de stock, que tenía el primer FOR UPDATE de
-- productos. Mismo control que arriba.
DO $parche$
DECLARE
  v_firma regprocedure := 'public.actualizar_pedido_items(bigint,jsonb,uuid,text)'::regprocedure;
  v_def   text := pg_get_functiondef(v_firma);
  v_antes text := $antes$  END LOOP;

$antes$;
  v_resto text := $resto$  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(v_items) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
$resto$;
  v_lock  text := $lock$  -- #1296 · Los productos del pedido, en orden de id, todos antes del
  -- primero que se bloquea o se mueve: el orden de la venta. Abajo se tomaban
  -- en el orden del JSON (el FOR UPDATE del pre-chequeo) y en el de las
  -- líneas (la devolución y la bajada), y una edición [B, A] contra una venta
  -- [A, B] se trababan (40P01, y la mutation no reintenta). Son las líneas de
  -- hoy, las del JSON y los sustitutos de las cadenas de regalo del pedido (el
  -- producto que de verdad se descuenta). Los FOR UPDATE de abajo pasan a ser
  -- re-locks; los contenedores que mueve el motor de promos se siguen
  -- bloqueando donde los mueve.
  PERFORM 1
     FROM productos
    WHERE sucursal_id = v_sucursal
      AND id IN (SELECT pi.producto_id FROM pedido_items pi
                  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
                 UNION
                 SELECT s.producto_sustituto_id FROM pedido_item_sustituciones s
                  WHERE s.pedido_id = p_pedido_id
                 UNION
                 SELECT (e->>'producto_id')::bigint FROM jsonb_array_elements(v_items) e)
    ORDER BY id
      FOR UPDATE;

$lock$;
BEGIN
  IF (length(v_def) - length(replace(v_def, v_antes || v_resto, ''))) / length(v_antes || v_resto) <> 1 THEN
    RAISE EXCEPTION 'mig 416 · actualizar_pedido_items cambió: el ancla del pre-chequeo de stock no aparece exactamente una vez';
  END IF;
  EXECUTE replace(v_def, v_antes || v_resto, v_antes || v_lock || v_resto);
  IF md5(replace((SELECT prosrc FROM pg_proc WHERE oid = v_firma), v_lock, '')) <> '9947f9a9a668572962c9a0faa6bc55ca' THEN
    RAISE EXCEPTION 'mig 416 · actualizar_pedido_items: el cuerpo nuevo sin el lock no es el de antes';
  END IF;
END
$parche$;
