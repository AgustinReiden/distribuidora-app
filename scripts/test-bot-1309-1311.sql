-- Ensayo de #1309, #1310 y #1311 (migración NNN_el_bot_resumen_numeros_y_apagado).
--   1 · A quién le toca el resumen (#1309): desde su hora y no sólo dentro de
--       ella; uno por cada sucursal ACTIVA asignada, con su nombre, y no la de
--       /sucursal; NULL no es la Red; lo enviado no vuelve a salir y un 'error'
--       sí; de dos reservas a la vez gana una.
--   2 · El gate del resumen: auditoria_bot() ve al que no recibió el suyo y deja
--       de verlo cuando le llega, y ve al suscripto sin ninguna sucursal activa.
--       Con dos chats prendidos, el resumen va a uno solo, el más nuevo.
--   3 · El apagado del admin (#1311, decisión del dueño 29/10): el canje no lo
--       prende, ni desde el mismo chat ni desde otro Telegram, ni pasándole el
--       chat a otro perfil; el código no se
--       genera; un UPDATE directo tampoco pasa; el admin lo prende y entonces el
--       canje vuelve a andar; el apagado del propio usuario (/desvincular) no es
--       una marca.
--   4 · Los números del bot (#1310), contra las tablas: el stock crítico sin los
--       dados de baja (con un producto que se da de baja en el ensayo), "Tomados"
--       sin canjes, el ranking y el top sin regalos, el recorrido de
--       bot_recorrido_resumen es el de bot_mi_recorrido, y las compras de la
--       ficha son la venta de CLAUDE.md.
--   5 · El buscador del bot (#1311, BOT-6): el encargado encuentra un cliente
--       que tiene preventista.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que inserta se deshace. Los usuarios del ensayo
-- se dan de alta en auth.users como lo hace GoTrue (ver test-alta-usuario-1243).
--
--   'ENSAYO OK …'    → todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración falla (no existen las funciones nuevas); después, pasa.
--
--   psql "$DATABASE_URL" -f scripts/test-bot-1309-1311.sql

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_otra    bigint;
  v_admin   uuid := gen_random_uuid();   -- el que recibe el resumen y al que se apaga
  v_jefe    uuid := gen_random_uuid();   -- el admin que lo apaga
  v_tg      bigint := -990000001;
  v_tg2     bigint := -990000002;
  v_app     jsonb;
  v_hoy     date := public._tablero_hoy();
  v_fecha   date := public._tablero_hoy() - 1;
  v_dow     int  := EXTRACT(ISODOW FROM public._tablero_hoy())::int;
  v_j       json;
  v_jb      jsonb;
  v_n       int;
  v_m       int;
  v_ok      boolean;
  v_txt     text;
  v_hora    int;
  v_dia     date;
  v_prod    bigint;
  v_num     numeric;
  v_num2    numeric;
  r         record;
BEGIN
  SELECT id INTO v_otra FROM sucursales WHERE id <> 1 AND activa IS TRUE ORDER BY id LIMIT 1;
  IF v_otra IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ: hace falta una sucursal activa además de la 1';
  END IF;

  -- Dos admins nuevos de la 1, y los dos también de la otra.
  v_app := jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'),
                              'rol', 'admin', 'sucursal_id', 1);
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_admin, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-1309-a@ensayo.invalid', v_app, '{"nombre":"Ensayo Resumen"}', now(), now()),
         (v_jefe, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-1309-b@ensayo.invalid', v_app, '{"nombre":"Ensayo Jefe"}', now(), now());
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default)
  VALUES (v_admin, v_otra, false), (v_jefe, v_otra, false)
  ON CONFLICT DO NOTHING;

  -- Vinculado, mirando la otra sucursal con /sucursal. Resumen a las 9, todos los días.
  INSERT INTO bot_usuarios (telegram_user_id, perfil_id, rol, sucursal_id, activo)
  VALUES (v_tg, v_admin, 'admin', v_otra, true);
  INSERT INTO bot_digest_config (perfil_id, activo, hora_local, dias_semana)
  VALUES (v_admin, true, 9, ARRAY[1,2,3,4,5,6,7]::smallint[]);

  -- ------------------------------------------------ 1 · a quién le toca ------
  SELECT count(*) INTO v_n FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 8, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('1.1 · antes de su hora ya le tocaba (%s filas)', v_n);
  END IF;

  SELECT count(*), count(*) FILTER (WHERE e->>'sucursal_nombre' IS NOT NULL)
    INTO v_n, v_m
    FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 9, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 2 OR v_m <> 2 THEN
    v_fallas := v_fallas || format('1.2 · a su hora tenía que tocarle uno por cada sucursal, con nombre (%s filas, %s con nombre)', v_n, v_m);
  END IF;

  -- El cron se salteó las 9: a las 15 le sigue tocando (BOT-1).
  SELECT count(*) INTO v_n FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 15, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 2 THEN
    v_fallas := v_fallas || format('1.3 · después de su hora dejó de tocarle (%s filas)', v_n);
  END IF;

  -- Con dos chats prendidos, un resumen por sucursal y al chat más nuevo.
  INSERT INTO bot_usuarios (telegram_user_id, perfil_id, rol, sucursal_id, activo, vinculado_at)
  VALUES (v_tg2, v_admin, 'admin', 1, true, now() - interval '1 day');
  SELECT count(*), bool_and((e->>'telegram_user_id')::bigint = v_tg) INTO v_n, v_ok
    FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 15, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 2 OR NOT v_ok THEN
    v_fallas := v_fallas || format('1.3b · con dos chats tenía que ser uno por sucursal, al más nuevo (%s filas)', v_n);
  END IF;
  DELETE FROM bot_usuarios WHERE telegram_user_id = v_tg2;

  -- Reservar: la primera gana, la segunda no (BOT-10).
  IF NOT public.bot_digest_reservar(v_admin, 1, v_fecha, v_tg) THEN
    v_fallas := v_fallas || '1.4 · la primera reserva no ganó'::text;
  END IF;
  IF public.bot_digest_reservar(v_admin, 1, v_fecha, v_tg) THEN
    v_fallas := v_fallas || '1.5 · la segunda reserva también ganó: doble envío'::text;
  END IF;
  SELECT count(*), bool_and((e->>'sucursal_id')::bigint = v_otra) INTO v_n, v_ok
    FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 15, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 1 OR NOT v_ok THEN
    v_fallas := v_fallas || format('1.6 · con la marca tomada en la 1 tenía que quedar sólo la otra (%s filas)', v_n);
  END IF;

  -- Un error vuelve a salir y se puede retomar.
  PERFORM public.bot_digest_registrar(v_admin, 1, v_fecha, 'error', '{"stage":"ensayo"}');
  SELECT count(*) INTO v_n FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 15, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 2 THEN
    v_fallas := v_fallas || format('1.7 · un error no volvió a salir (%s filas)', v_n);
  END IF;
  IF NOT public.bot_digest_reservar(v_admin, 1, v_fecha, v_tg) THEN
    v_fallas := v_fallas || '1.8 · una marca en error no se pudo retomar'::text;
  END IF;
  PERFORM public.bot_digest_registrar(v_admin, 1, v_fecha, 'ok');

  -- La sucursal se revalida: sin la otra asignada, no le toca la otra (BOT-2).
  DELETE FROM usuario_sucursales WHERE usuario_id = v_admin AND sucursal_id = v_otra;
  SELECT count(*) INTO v_n FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 15, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('1.9 · le tocó una sucursal que ya no tiene (%s filas)', v_n);
  END IF;
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_admin, v_otra, false);

  -- La sucursal de /sucursal en NULL no es la Red: sigue siendo una por asignada.
  UPDATE bot_usuarios SET sucursal_id = NULL WHERE telegram_user_id = v_tg;
  SELECT count(*), bool_and(e->>'sucursal_id' IS NOT NULL) INTO v_n, v_ok
    FROM json_array_elements(public.bot_digest_pendientes(v_fecha, 15, v_dow)) e
   WHERE (e->>'perfil_id')::uuid = v_admin;
  IF v_n <> 1 OR NOT v_ok THEN
    v_fallas := v_fallas || format('1.10 · con /sucursal en NULL tenía que tocarle la otra sucursal, no la Red (%s filas)', v_n);
  END IF;

  -- -------------------------------------------------- 2 · el gate ------------
  -- La hora de hace 3 horas en Argentina: su resumen de ese día ya tenía que
  -- haber salido (está entre hace 26 y hace 2 horas).
  v_hora := EXTRACT(HOUR FROM (now() - interval '3 hours') AT TIME ZONE 'America/Argentina/Buenos_Aires')::int;
  v_dia  := ((now() - interval '3 hours') AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  UPDATE bot_digest_config SET hora_local = v_hora WHERE perfil_id = v_admin;
  DELETE FROM bot_digests_enviados WHERE admin_perfil_id = v_admin;

  SELECT count(*) INTO v_n FROM jsonb_array_elements(public.auditoria_bot() -> 'digest_faltantes') f
   WHERE (f->>'perfil_id')::uuid = v_admin AND (f->>'fecha_resumida')::date = v_dia - 1;
  IF v_n <> 2 THEN
    v_fallas := v_fallas || format('2.1 · el gate no vio los dos resúmenes que no salieron (%s)', v_n);
  END IF;

  PERFORM public.bot_digest_reservar(v_admin, 1, v_dia - 1, v_tg);
  PERFORM public.bot_digest_registrar(v_admin, 1, v_dia - 1, 'ok');
  PERFORM public.bot_digest_reservar(v_admin, v_otra, v_dia - 1, v_tg);
  PERFORM public.bot_digest_registrar(v_admin, v_otra, v_dia - 1, 'skipped', '{"motivo":"sin_contenido"}');
  SELECT count(*) INTO v_n FROM jsonb_array_elements(public.auditoria_bot() -> 'digest_faltantes') f
   WHERE (f->>'perfil_id')::uuid = v_admin;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('2.2 · con ok y skipped el gate lo sigue viendo (%s)', v_n);
  END IF;

  -- Un día que no es de los suyos no se espera.
  DELETE FROM bot_digests_enviados WHERE admin_perfil_id = v_admin;
  UPDATE bot_digest_config
     SET dias_semana = ARRAY(SELECT d FROM generate_series(1, 7) d
                              WHERE d <> EXTRACT(ISODOW FROM v_dia)::int)::smallint[]
   WHERE perfil_id = v_admin;
  SELECT count(*) INTO v_n FROM jsonb_array_elements(public.auditoria_bot() -> 'digest_faltantes') f
   WHERE (f->>'perfil_id')::uuid = v_admin AND (f->>'fecha_resumida')::date = v_dia - 1;
  IF v_n <> 0 THEN
    v_fallas := v_fallas || format('2.3 · el gate esperó un resumen de un día que no es de los suyos (%s)', v_n);
  END IF;
  DELETE FROM bot_digest_config WHERE perfil_id = v_admin;

  -- Suscripto y sin ninguna sucursal activa: el gate lo nombra.
  CREATE TEMP TABLE _ens_us ON COMMIT DROP AS
    SELECT * FROM usuario_sucursales WHERE usuario_id = v_admin;
  DELETE FROM usuario_sucursales WHERE usuario_id = v_admin;
  SELECT count(*) INTO v_n FROM jsonb_array_elements(public.auditoria_bot() -> 'sin_sucursal') s
   WHERE (s->>'perfil_id')::uuid = v_admin;
  IF v_n <> 1 THEN
    v_fallas := v_fallas || '2.4 · el gate no vio al suscripto sin sucursal'::text;
  END IF;
  INSERT INTO usuario_sucursales SELECT * FROM _ens_us;

  -- ------------------------------------------- 3 · el apagado del admin ------
  UPDATE bot_usuarios SET sucursal_id = 1 WHERE telegram_user_id = v_tg;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_jefe, 'role', 'authenticated')::text, true);
  PERFORM public.bot_admin_toggle_usuario(v_tg, false);
  IF (SELECT activo FROM bot_usuarios WHERE telegram_user_id = v_tg)
     OR NOT EXISTS (SELECT 1 FROM bot_apagados_por_admin WHERE perfil_id = v_admin AND apagado_por = v_jefe) THEN
    v_fallas := v_fallas || '3.1 · apagar desde el panel no dejó el chat apagado con la marca'::text;
  END IF;

  -- El canje desde el mismo chat no lo prende.
  INSERT INTO bot_codigos_vinculacion (codigo, perfil_id) VALUES ('ENSAYO01', v_admin);
  v_jb := public.canjear_codigo_vinculacion_bot('ENSAYO01', v_tg, NULL);
  IF v_jb ->> 'error' IS DISTINCT FROM 'apagado_por_admin'
     OR (SELECT activo FROM bot_usuarios WHERE telegram_user_id = v_tg) THEN
    v_fallas := v_fallas || format('3.2 · el canje lo prendió o no dijo por qué: %s', v_jb);
  END IF;
  IF (SELECT usado_at FROM bot_codigos_vinculacion WHERE codigo = 'ENSAYO01') IS NULL THEN
    v_fallas := v_fallas || '3.3 · el código rechazado quedó vivo para reintentar'::text;
  END IF;
  IF EXISTS (SELECT 1 FROM bot_intentos_vinculacion WHERE telegram_user_id = v_tg) THEN
    v_fallas := v_fallas || '3.4 · el rechazo contó como intento fallido (es un código válido)'::text;
  END IF;

  -- Ni desde otro Telegram.
  INSERT INTO bot_codigos_vinculacion (codigo, perfil_id) VALUES ('ENSAYO02', v_admin);
  v_jb := public.canjear_codigo_vinculacion_bot('ENSAYO02', v_tg2, NULL);
  IF v_jb ->> 'error' IS DISTINCT FROM 'apagado_por_admin'
     OR EXISTS (SELECT 1 FROM bot_usuarios WHERE perfil_id = v_admin AND activo) THEN
    v_fallas := v_fallas || format('3.5 · vincular otro Telegram lo prendió: %s', v_jb);
  END IF;

  -- Ni pasándole el chat a otro perfil: el apagado se quedaría sin fila en el panel.
  INSERT INTO bot_codigos_vinculacion (codigo, perfil_id) VALUES ('ENSAYO04', v_jefe);
  v_jb := public.canjear_codigo_vinculacion_bot('ENSAYO04', v_tg, NULL);
  IF v_jb ->> 'error' IS DISTINCT FROM 'apagado_por_admin'
     OR (SELECT perfil_id FROM bot_usuarios WHERE telegram_user_id = v_tg) IS DISTINCT FROM v_admin THEN
    v_fallas := v_fallas || format('3.5b · el chat de alguien apagado por el admin pasó a otro perfil: %s', v_jb);
  END IF;

  -- Ni un UPDATE directo.
  BEGIN
    UPDATE bot_usuarios SET activo = true WHERE telegram_user_id = v_tg;
    v_fallas := v_fallas || '3.6 · un UPDATE directo prendió un chat apagado por el admin'::text;
  EXCEPTION WHEN check_violation THEN
    NULL;
  END;

  -- Ni se genera el código.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  BEGIN
    PERFORM public.generar_codigo_vinculacion_bot();
    v_fallas := v_fallas || '3.7 · se generó un código para alguien apagado por el admin'::text;
  EXCEPTION WHEN raise_exception THEN
    NULL;
  END;

  -- El gate ve el trigger y nada prendido con marca.
  v_jb := public.auditoria_bot() -> 'apagado';
  IF NOT (v_jb ->> 'trigger_ok')::boolean OR (v_jb ->> 'chats_prendidos_con_marca')::int <> 0 THEN
    v_fallas := v_fallas || format('3.8 · el gate del apagado no da verde: %s', v_jb);
  END IF;

  -- El admin lo prende: sin marca, y el canje vuelve a andar.
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_jefe, 'role', 'authenticated')::text, true);
  PERFORM public.bot_admin_toggle_usuario(v_tg, true);
  IF NOT (SELECT activo FROM bot_usuarios WHERE telegram_user_id = v_tg)
     OR EXISTS (SELECT 1 FROM bot_apagados_por_admin WHERE perfil_id = v_admin) THEN
    v_fallas := v_fallas || '3.9 · prenderlo desde el panel no lo prendió o dejó la marca'::text;
  END IF;

  -- El apagado del propio usuario (/desvincular) no es una marca: el canje lo prende.
  UPDATE bot_usuarios SET activo = false WHERE telegram_user_id = v_tg;
  INSERT INTO bot_codigos_vinculacion (codigo, perfil_id) VALUES ('ENSAYO03', v_admin);
  v_jb := public.canjear_codigo_vinculacion_bot('ENSAYO03', v_tg, NULL);
  IF (v_jb ->> 'success')::boolean IS NOT TRUE OR NOT (SELECT activo FROM bot_usuarios WHERE telegram_user_id = v_tg) THEN
    v_fallas := v_fallas || format('3.10 · tras /desvincular el canje no lo volvió a prender: %s', v_jb);
  END IF;
  -- De acá en más, como el servidor (auth.uid() NULL), que es como llama el bot.
  PERFORM set_config('request.jwt.claims', '{}', true);

  -- --------------------------------------- 4 · los números del bot (#1310) ---
  -- Stock crítico: sólo lo activo, y un producto que se da de baja sale.
  SELECT id INTO v_prod FROM productos
   WHERE sucursal_id = 1 AND activo AND COALESCE(stock, 0) <= COALESCE(stock_minimo, 10)
   ORDER BY id LIMIT 1;
  v_j := public.bot_metricas_admin_dia(v_fecha, 1);
  SELECT count(*) INTO v_n FROM productos
   WHERE sucursal_id = 1 AND activo AND COALESCE(stock, 0) <= COALESCE(stock_minimo, 10);
  IF (v_j -> 'stock_critico' ->> 'count')::int <> v_n THEN
    v_fallas := v_fallas || format('4.1 · stock crítico %s, productos activos bajo el mínimo %s',
                                   v_j -> 'stock_critico' ->> 'count', v_n);
  END IF;
  IF v_prod IS NOT NULL THEN
    UPDATE productos SET activo = false WHERE id = v_prod;
    IF (public.bot_metricas_admin_dia(v_fecha, 1) -> 'stock_critico' ->> 'count')::int <> v_n - 1 THEN
      v_fallas := v_fallas || '4.2 · un producto dado de baja bajo el mínimo sigue en el stock crítico'::text;
    END IF;
    UPDATE productos SET activo = true WHERE id = v_prod;
  END IF;

  -- "Tomados": los pedidos del día sin canjes, sin cancelados y sin VB.
  FOR r IN
    SELECT p.fecha, p.sucursal_id FROM pedidos p
     WHERE p.canal = 'cambio' AND p.estado <> 'cancelado'
     ORDER BY p.id DESC LIMIT 1
  LOOP
    SELECT count(*) INTO v_n FROM pedidos
     WHERE fecha = r.fecha AND sucursal_id = r.sucursal_id AND estado <> 'cancelado'
       AND canal <> 'cambio' AND tipo_factura IS DISTINCT FROM 'VB';
    v_m := (public.bot_metricas_admin_dia(r.fecha, r.sucursal_id) -> 'ventas_dia' ->> 'pedidos')::int;
    IF v_m <> v_n THEN
      v_fallas := v_fallas || format('4.3 · tomados del %s: %s, pedidos sin canjes %s', r.fecha, v_m, v_n);
    END IF;
  END LOOP;

  -- Ranking por producto: sólo unidades vendidas. Con el producto con más
  -- unidades de regalo entregadas en 30 días.
  FOR r IN
    SELECT pi.producto_id, p.sucursal_id FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id
     WHERE pi.es_bonificacion AND p.estado = 'entregado' AND p.fecha >= v_hoy - 30
     GROUP BY 1, 2 ORDER BY sum(pi.cantidad) DESC LIMIT 1
  LOOP
    SELECT COALESCE(sum(pi.cantidad), 0) INTO v_num FROM pedido_items pi JOIN pedidos p ON p.id = pi.pedido_id
     WHERE pi.producto_id = r.producto_id AND p.sucursal_id = r.sucursal_id
       AND p.fecha BETWEEN v_hoy - 30 AND v_hoy AND p.estado = 'entregado' AND p.canal <> 'cambio'
       AND p.tipo_factura IS DISTINCT FROM 'VB' AND pi.es_bonificacion IS NOT TRUE;
    v_num2 := (public.bot_ranking_preventistas_por_producto(ARRAY[r.producto_id], v_hoy - 30, v_hoy, r.sucursal_id, 10)
                ->> 'unidades_total')::numeric;
    IF v_num2 <> v_num THEN
      v_fallas := v_fallas || format('4.4 · ranking: %s unidades, vendidas %s (producto %s)', v_num2, v_num, r.producto_id);
    END IF;
    SELECT (t ->> 'unidades')::numeric INTO v_num2
      FROM json_array_elements(public.bot_ventas_periodo(v_hoy - 30, v_hoy, r.sucursal_id, 1000) -> 'top_productos') t
     WHERE (t ->> 'id')::bigint = r.producto_id;
    IF v_num2 IS DISTINCT FROM v_num AND v_num > 0 THEN
      v_fallas := v_fallas || format('4.5 · top del período: %s unidades, vendidas %s (producto %s)', v_num2, v_num, r.producto_id);
    END IF;
  END LOOP;

  -- El recorrido del resumen es el de bot_mi_recorrido, también con dos en el día.
  FOR r IN
    SELECT transportista_id, sucursal_id, fecha FROM recorridos
     GROUP BY 1, 2, 3 HAVING count(*) > 1 ORDER BY fecha DESC LIMIT 1
  LOOP
    IF (public.bot_recorrido_resumen(r.transportista_id, r.sucursal_id, r.fecha) ->> 'recorrido_id')::bigint
       IS DISTINCT FROM (public.bot_mi_recorrido(r.transportista_id, r.sucursal_id, r.fecha) -> 'recorrido' ->> 'id')::bigint THEN
      v_fallas := v_fallas || format('4.6 · el resumen y "mi recorrido" hablan de recorridos distintos (%s, %s)', r.transportista_id, r.fecha);
    END IF;
  END LOOP;

  -- Las compras de la ficha son la venta: con un cliente que pagó envío.
  FOR r IN
    SELECT cliente_id FROM pedidos WHERE cargo_envio > 0 AND estado = 'entregado' ORDER BY id DESC LIMIT 1
  LOOP
    SELECT COALESCE(sum(GREATEST(total - cargo_envio, 0)), 0) INTO v_num FROM pedidos
     WHERE cliente_id = r.cliente_id AND estado = 'entregado' AND canal <> 'cambio'
       AND tipo_factura IS DISTINCT FROM 'VB';
    v_num2 := (public.obtener_resumen_cuenta_cliente_bot(r.cliente_id::int) ->> 'total_compras')::numeric;
    IF v_num2 <> v_num THEN
      v_fallas := v_fallas || format('4.7 · compras de la ficha %s, venta %s (cliente %s)', v_num2, v_num, r.cliente_id);
    END IF;
  END LOOP;

  -- ------------------------------------------- 5 · el buscador (BOT-6) -------
  FOR r IN
    SELECT c.id, c.sucursal_id, c.nombre_fantasia, c.razon_social FROM clientes c
     WHERE c.activo AND NOT c.reservado_admin
       AND EXISTS (SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id)
       AND COALESCE(NULLIF(c.nombre_fantasia, ''), c.razon_social) IS NOT NULL
     ORDER BY c.id LIMIT 1
  LOOP
    v_txt := COALESCE(NULLIF(r.nombre_fantasia, ''), r.razon_social);
    SELECT count(*) INTO v_n
      FROM public.bot_buscar_cliente(v_txt, gen_random_uuid(), 'encargado', r.sucursal_id, 1000) b
     WHERE b.id = r.id;
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('5.1 · el encargado no encuentra al cliente %s, que tiene preventista', r.id);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK #1309 #1310 #1311 (resumen, números y apagado del bot)';
  ELSE
    RAISE EXCEPTION 'ENSAYO FALLÓ #1309 #1310 #1311: %', array_to_string(v_fallas, ' | ');
  END IF;
END
$ensayo$;
