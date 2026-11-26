-- =========================================================================
-- NNN · LA SALVEDAD QUE CARGA LA OFICINA NACE RESUELTA, Y SE CIERRAN LAS PENDIENTES DE HOY
--       (#1700, Part of #1690)
--
-- Ensayo: scripts/test-salvedades-oficina-1700.sql. Se aplica en LF, en una sola transacción o
-- sentencia por sentencia. Cambia registrar_salvedad() y los datos de salvedades_items (sólo el
-- estado de resolución de las pendientes) y salvedad_historial (una fila por cada una que cierra).
-- Ninguna tabla, ninguna otra función.
--
-- QUÉ PASABA
--   · Hoy las entregas y las salvedades las carga la oficina, y toda salvedad nacía «pendiente»
--     aunque quien la cargaba ya la había resuelto de hecho. El panel de Salvedades tenía 91
--     pendientes (25/11): 83 de un admin, 1 de un encargado y 7 de preventistas con el rol extra
--     de chofer. Cuando los choferes empiecen a cargar en la calle, las de ellos se iban a perder
--     entre las viejas.
--
-- QUÉ CAMBIA (decisiones del dueño del 25/11, en #1700)
--   1 · registrar_salvedad(): la salvedad que carga un ADMIN o un ENCARGADO nace «resuelto_otro»,
--       con la nota «Cargada y resuelta por la oficina», resuelta por quien la cargó y con la fecha
--       de la carga. No mueve plata: ni nota de crédito ni cargo a un empleado. La que carga otro
--       rol (el chofer, el preventista que reparte con el rol extra) nace pendiente, como siempre.
--       · Quién es la oficina lo dice el rol base de quien la carga (perfiles.rol), no si reparte
--         ese pedido: un encargado con el rol extra de chofer sigue siendo la oficina. El extra de
--         perfil_roles es sólo 'transportista', así que un preventista o un chofer nunca lo son.
--       · El rol se lee con es_encargado_o_admin(), que mira activo (#1474, #1490), en vez de leer
--         perfiles.rol a pelo: sale de scripts/rol-sin-activo-permitidas.json en el mismo PR.
--         Para autorizar no cambia nada: un desactivado ya cortaba antes, sin sucursal activa.
--       · La fila se inserta «pendiente» y se resuelve al final, después de recalcular el total:
--         desafectar_sobrepago_pedido() busca la salvedad que está bajando el total por
--         estado_resolucion = 'pendiente' (COB-1 de #1559) para anotarle el cobro que recorta, y
--         anular_salvedad() lo repone con eso. Insertarla ya resuelta perdía ese recorte. La
--         resolución es la misma escritura de resolver_salvedad() (estado, nota, fecha, quién y
--         una fila 'resolucion' en salvedad_historial).
--       · La respuesta suma estado_resolucion (también la del reintento con la misma clave), para
--         que la app diga que quedó resuelta.
--       · Si la oficina quiere otra resolución, la hace aparte, como hoy: una nota de crédito de
--         venta desde el pedido, o anular la salvedad (admin). resolver_salvedad() no se toca y
--         sigue rechazando una resuelta ('Ya resuelta').
--   2 · Limpieza: se cierran TODAS las pendientes de hoy como «resuelto_otro», sin tocar
--       reportado_por ni created_at, con resolucion_fecha = la de la limpieza y una fila
--       'resolucion' en salvedad_historial (como cerrar_salvedades_en_lote):
--       · las que cargó un admin o un encargado (perfiles.rol de reportado_por, hoy): nota
--         «Cargada y resuelta por la oficina», resuelto_por = quien la cargó;
--       · las otras: nota «Cerrada en la limpieza del 25/11: cargada en la calle, revisada por el
--         dueño», resuelto_por NULL (las revisó el dueño, sin un usuario de la app que lo diga;
--         la columna lo acepta y el panel no muestra «Por:»).
--       No mueve plata, stock ni totales: sólo escribe esas columnas. Sobre salvedades_items el
--       UPDATE dispara sólo trigger_salvedades_updated_at (pone updated_at); el de lotes_devueltos
--       es OF lotes_devueltos y no salta. salvedades_items no tiene auditoría (audit_logs).
--
-- PREMISAS: md5(prosrc) de registrar_salvedad() es el de la 548; las anclas aparecen una vez cada
-- una; hay a lo sumo 200 pendientes (en prod, 91). Reaplicarla aborta en la primera premisa.
-- Se parchea por ancla sobre pg_get_functiondef, que conserva SECURITY DEFINER y el
-- SET search_path (public, pg_temp); CREATE OR REPLACE conserva los EXECUTE (postgres,
-- authenticated, service_role; ni PUBLIC ni anon).
--
-- LOCKS: ninguno de tabla explícito. CREATE OR REPLACE toma la fila de pg_proc; el UPDATE de la
-- limpieza toma las filas pendientes de salvedades_items (≤ 200).
-- EMBEDS DE POSTGREST: no hay FK nuevas.
-- =========================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · Premisas: el cuerpo vivo es el de la 548 y cada ancla aparece una vez
-- -------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_fn  regprocedure := 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure;
  v_def text;
  v_md5 text;
  v_a   text;
BEGIN
  v_def := pg_get_functiondef(v_fn);
  v_md5 := (SELECT md5(prosrc) FROM pg_proc WHERE oid = v_fn);
  IF v_md5 IS DISTINCT FROM '32efe3f39800ab49dca64c6fe3017dc9' THEN
    RAISE EXCEPTION 'premisa · registrar_salvedad() no es la de la 548 (md5 %): ¿la migración ya se aplicó, u otra la cambió?', v_md5;
  END IF;
  FOREACH v_a IN ARRAY ARRAY[
    $a$  SELECT EXISTS (
    SELECT 1 FROM perfiles
     WHERE id = v_usuario_id AND rol IN ('admin', 'encargado')
  ) INTO v_es_admin_o_encargado;$a$,
    $a$        'stock_devuelto', v_existing.stock_devuelto,$a$,
    $a$    'recargo_combo', v_recargo_combo,$a$,
    $a$  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);$a$]
  LOOP
    IF (length(v_def) - length(replace(v_def, v_a, ''))) / length(v_a) <> 1 THEN
      RAISE EXCEPTION 'premisa · un ancla de registrar_salvedad() no aparece exactamente una vez: %', left(v_a, 80);
    END IF;
  END LOOP;
END
$premisas$;

-- -------------------------------------------------------------------------
-- 1 · registrar_salvedad(): la que carga la oficina nace resuelta
-- -------------------------------------------------------------------------
DO $registrar$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
BEGIN
  -- El rol con el helper, que mira activo.
  v_def := replace(v_def, $a$  SELECT EXISTS (
    SELECT 1 FROM perfiles
     WHERE id = v_usuario_id AND rol IN ('admin', 'encargado')
  ) INTO v_es_admin_o_encargado;$a$, $n$  -- #1700: el rol con el helper, que mira activo (#1474, #1490). Además de autorizar, dice si
  -- la salvedad la carga la oficina (admin o encargado, por el rol base: también el que reparte
  -- con el rol extra de chofer), que nace resuelta (abajo, al final).
  v_es_admin_o_encargado := public.es_encargado_o_admin();$n$);

  -- El reintento con la misma clave dice en qué estado está.
  v_def := replace(v_def, $a$        'stock_devuelto', v_existing.stock_devuelto,$a$,
    $n$        'stock_devuelto', v_existing.stock_devuelto,
        -- #1700: la de la oficina nace resuelta; la app lo dice al guardar.
        'estado_resolucion', v_existing.estado_resolucion,$n$);

  v_def := replace(v_def, $a$    'recargo_combo', v_recargo_combo,$a$,
    $n$    'recargo_combo', v_recargo_combo,
    -- #1700: la de la oficina nace resuelta; la app lo dice al guardar.
    'estado_resolucion', CASE WHEN v_es_admin_o_encargado THEN 'resuelto_otro' ELSE 'pendiente' END,$n$);

  v_def := replace(v_def, $a$  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);$a$,
    $n$  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);

  -- #1700 (decisión del dueño, 25/11): la salvedad que carga la oficina (admin o encargado) nace
  -- resuelta, como «resuelto_otro», resuelta por quien la cargó y con la fecha de la carga, y no
  -- mueve plata. Si la oficina quiere otra resolución, la hace aparte (una nota de crédito, o
  -- anular la salvedad). La que carga otro rol (el chofer en la calle) queda pendiente.
  -- Se resuelve acá, al final, y no al insertarla: desafectar_sobrepago_pedido() encuentra la
  -- salvedad que está bajando el total por estado 'pendiente' (COB-1 de #1559) para anotarle el
  -- cobro que recorta. Es la escritura de resolver_salvedad().
  IF v_es_admin_o_encargado THEN
    UPDATE salvedades_items SET
      estado_resolucion = 'resuelto_otro',
      resolucion_notas  = 'Cargada y resuelta por la oficina',
      resolucion_fecha  = NOW(),
      resuelto_por      = v_usuario_id,
      updated_at        = NOW()
    WHERE id = v_salvedad_id AND sucursal_id = v_sucursal;
    INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
    VALUES (v_salvedad_id, 'resolucion', 'pendiente', 'resuelto_otro', 'Cargada y resuelta por la oficina',
            v_usuario_id, v_sucursal);
  END IF;$n$);

  EXECUTE v_def;
END
$registrar$;

DO $post_registrar$
DECLARE
  v_fn  regprocedure := 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure;
  v_src text := (SELECT prosrc FROM pg_proc WHERE oid = 'public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
BEGIN
  IF md5(v_src) IS DISTINCT FROM '554ba2aae0f9d845c550273740a2ffae' THEN
    RAISE EXCEPTION 'poscondición · registrar_salvedad() no quedó con el cuerpo esperado (md5 %)', md5(v_src);
  END IF;
  IF v_src ~ 'rol IN \(''admin'', ''encargado''\)' THEN
    RAISE EXCEPTION 'poscondición · registrar_salvedad() sigue leyendo perfiles.rol a pelo';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc
                  WHERE oid = v_fn AND prosecdef AND provolatile = 'v'
                    AND 'search_path=public, pg_temp' = ANY(proconfig)) THEN
    RAISE EXCEPTION 'poscondición · registrar_salvedad() perdió SECURITY DEFINER o el search_path terminado en pg_temp';
  END IF;
  IF NOT has_function_privilege('authenticated', v_fn, 'EXECUTE')
     OR NOT has_function_privilege('service_role', v_fn, 'EXECUTE')
     OR has_function_privilege('anon', v_fn, 'EXECUTE')
     OR (SELECT proacl::text FROM pg_proc WHERE oid = v_fn)
        IS DISTINCT FROM '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}' THEN
    RAISE EXCEPTION 'poscondición · los permisos de registrar_salvedad() no son los de antes';
  END IF;
END
$post_registrar$;

-- -------------------------------------------------------------------------
-- 2 · Limpieza: se cierran todas las pendientes de hoy
-- -------------------------------------------------------------------------
-- Premisa, cierre y poscondición en un solo DO: aplicada sentencia por sentencia, la cuenta de
-- antes y la de después son de la misma foto. Reaplicada sin pendientes no hace nada.
DO $limpieza$
DECLARE
  c_oficina CONSTANT text := 'Cargada y resuelta por la oficina';
  c_calle   CONSTANT text := 'Cerrada en la limpieza del 25/11: cargada en la calle, revisada por el dueño';
  v_total   int;
  v_oficina int;
  v_calle   int;
  v_n       int;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE p.rol IN ('admin', 'encargado')),
         count(*) FILTER (WHERE p.rol IS DISTINCT FROM 'admin' AND p.rol IS DISTINCT FROM 'encargado')
    INTO v_total, v_oficina, v_calle
    FROM salvedades_items s
    LEFT JOIN perfiles p ON p.id = s.reportado_por
   WHERE s.estado_resolucion = 'pendiente';
  IF v_total > 200 THEN
    RAISE EXCEPTION 'premisa · hay % salvedades pendientes (se esperaban 91, a lo sumo 200): revisar antes de cerrarlas', v_total;
  END IF;

  WITH cerradas AS (
    UPDATE salvedades_items s SET
      estado_resolucion = 'resuelto_otro',
      resolucion_notas  = CASE WHEN p.rol IN ('admin', 'encargado') THEN c_oficina ELSE c_calle END,
      resolucion_fecha  = NOW(),
      resuelto_por      = CASE WHEN p.rol IN ('admin', 'encargado') THEN s.reportado_por END,
      updated_at        = NOW()
      FROM perfiles p
     WHERE p.id = s.reportado_por
       AND s.estado_resolucion = 'pendiente'
    RETURNING s.id, s.sucursal_id, s.resolucion_notas, s.resuelto_por
  )
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  SELECT id, 'resolucion', 'pendiente', 'resuelto_otro', resolucion_notas, resuelto_por, sucursal_id
    FROM cerradas;
  GET DIAGNOSTICS v_n = ROW_COUNT;

  IF EXISTS (SELECT 1 FROM salvedades_items WHERE estado_resolucion = 'pendiente') THEN
    RAISE EXCEPTION 'poscondición · quedan % salvedades pendientes',
      (SELECT count(*) FROM salvedades_items WHERE estado_resolucion = 'pendiente');
  END IF;
  IF v_n <> v_total
     OR (SELECT count(*) FROM salvedad_historial
          WHERE accion = 'resolucion' AND notas = c_oficina AND created_at = NOW()
            AND usuario_id IS NOT NULL) <> v_oficina
     OR (SELECT count(*) FROM salvedad_historial
          WHERE accion = 'resolucion' AND notas = c_calle AND created_at = NOW()
            AND usuario_id IS NULL) <> v_calle THEN
    RAISE EXCEPTION 'poscondición · se cerraron % de % (oficina %, calle %) y el historial no cuadra', v_n, v_total, v_oficina, v_calle;
  END IF;
  RAISE NOTICE 'limpieza · % salvedades pendientes cerradas: % de la oficina y % de la calle', v_n, v_oficina, v_calle;
END
$limpieza$;

COMMIT;
