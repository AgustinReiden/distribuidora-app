-- Ensayo de la migración 550_ola3_rutas_paradas_canjes (tarjeta T3 de la ola 3, #1677;
-- puntos Rut-B3, B4, B5, B6, B8, B10, B11, B13 y B14 de #1554, y permisos-B1 = 1564-b9).
--
-- Un único DO que arma sus propios datos (gente, un cliente, productos y pedidos nuevos en la
-- sucursal 1, y un encargado de la 2) y termina SIEMPRE en una excepción (ENSAYO OK / ENSAYO
-- FALLÓ): no deja rastro. Corre sobre la base de CI sin datos. Sin la migración falla; con
-- ella, ENSAYO OK. Usa el día argentino (`_tablero_hoy()`), nunca CURRENT_DATE.
--
-- Gente: E (encargado de la 1), E2 (encargado de la 2), E12 (encargado de las dos), choferes
-- A, B, C, D, G (sin ruta), H, M1, M2 y M3 de la 1, y PV (preventista de la 1, sin el extra de
-- chofer).
--
--   B13 · El canje K que E crea para la ruta (crear_pedido_cambio_en_ruta) nace con
--         creado_por = E, como todo pedido.
--   B4  · K sale en la ruta de B; A tiene una parada vieja de K (una ruta cerrada de ayer,
--         'reasignado'). A no puede aplicar el cambio («No autorizado», sin mover el stock); B sí.
--         Y una condición por vez, con las otras dos bien: B4a no es el chofer del canje, B4b
--         su ruta no está en curso, B4c su parada no está viva. Los tres se rechazan.
--   B5  · P1, P2, P3 y P5 salen en la ruta de A (decisión del dueño, #1554: la entrega a nombre
--         de otro chofer mueve la parada sólo si ese chofer tiene ruta en curso ese día).
--         B5a · una masiva a nombre de G, sin ruta, entrega P1: la parada de A queda entregada
--               (1/4), como en la 547.
--         B5b · una masiva a nombre de B, que tiene ruta hoy, entrega P5: cuenta en la de B
--               (entregado, 1/2) y la de A queda 'reasignado' (1/3).
--         La masiva a nombre de A de P2 marca su parada (control).
--   B5r · Se revierte la entrega de P5, vuelve a A y A lo entrega: A entregado (4/4), B
--         reasignado (0/1), una sola parada viva.
--   B5c · Rearmar una ruta en curso con un pedido de parada 'reasignado' la reabre (pendiente).
--   B5v · Revertir una entrega que no dejó parada viva vuelve a pendiente la 'reasignado' de la
--         ruta en curso.
--   B5d-f · Los filtros de la ruta de quien entrega, uno por caso (P7, P8, P9 en la ruta de
--         A2): X1 con una ruta en curso de ayer, X2 con una de hoy completada, X3 con una en
--         curso en la otra sucursal. Ninguno «tiene ruta»: la parada de A2 queda entregada.
--   B5g · Un pedido sin ruta entregado por B (con ruta) no entra a la de B.
--   B5h · Un pedido con sólo una parada de historia (reasignado, ruta cerrada) tampoco.
--   B5i · marcar_no_entregado no marca la parada 'reasignado' de otro chofer.
--   B3b · cerrar_recorridos_vencidos cierra una ruta de ayer con sólo una parada 'reasignado'.
--   B3c · y NO cierra la de una parada 'no_entregado' cuyo pedido volvió a 'asignado' (como la 548).
--   B11 · P3 (1000) se cobra 700 en efectivo y 300 con saldo a favor aplicado, y A lo entrega:
--         lo cobrado de la ruta de A es 700 (la plata), no 1000 (monto_pagado), en la función y
--         en la columna de la ruta.
--   B6  · aplicar_orden_ruta con la fecha de hace 400 días o de dentro de 61 se rechaza
--         (22023, la regla de la entrega programada: de hoy a 60 días); mañana pasa.
--   P1  · permisos-B1: E2, parado en la 2, no recalcula la ruta de A (de la 1): 42501. E sí.
--   B3  · cerrar_recorridos_vencidos cierra la ruta de ayer de C a las 23:59 de Argentina
--         (02:59 UTC del día siguiente), con la sesión en UTC como en prod.
--   B8  · registrar_cambio_producto con la misma clave dos veces: un solo canje, el mismo id,
--         el stock movido una vez; la misma clave con otro contenido, 22023. Sin clave (un PWA
--         viejo, los siete parámetros por nombre) anda como antes: dos llamadas, dos canjes.
--         La misma clave del mismo usuario (E12) desde la otra sucursal: 22023.
--         Queda UNA sola firma (sin dos sobrecargas: PGRST203).
--   B10 · crear_recorrido ya no existe.
--   B14 · optimizar_ruta_consumir_cupo: sin EXECUTE para anon, con EXECUTE para authenticated;
--         con tope 2 por minuto, la tercera llamada de A dice por_minuto; PV (sin rol de chofer
--         ni de encargado) se rechaza (42501). Su tabla no tiene grants ni para authenticated.
--   AUD · RUTA-A y RUTA-B de auditoria_integridad() quedan en 0 después de todo lo anterior.

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_tag    text := 'T3 ' || left(gen_random_uuid()::text, 8);
  v_enc    uuid := gen_random_uuid();
  v_enc2   uuid := gen_random_uuid();
  v_a      uuid := gen_random_uuid();
  v_b      uuid := gen_random_uuid();
  v_c      uuid := gen_random_uuid();
  v_d      uuid := gen_random_uuid();
  v_pv     uuid := gen_random_uuid();
  v_e12    uuid := gen_random_uuid();
  v_g      uuid := gen_random_uuid();
  v_h      uuid := gen_random_uuid();
  v_m1     uuid := gen_random_uuid();
  v_m2     uuid := gen_random_uuid();
  v_m3     uuid := gen_random_uuid();
  v_p5     bigint;
  v_p6     bigint;
  v_k1     bigint;
  v_k2     bigint;
  v_k3     bigint;
  v_rh     bigint;
  v_r2     bigint;
  v_r3     bigint;
  v_clave2 uuid := gen_random_uuid();
  v_a2     uuid := gen_random_uuid();
  v_x1     uuid := gen_random_uuid();
  v_x2     uuid := gen_random_uuid();
  v_x3     uuid := gen_random_uuid();
  v_y      uuid := gen_random_uuid();
  v_c2     uuid := gen_random_uuid();
  v_c3     uuid := gen_random_uuid();
  v_p14    bigint;
  v_rc3    bigint;
  v_p7     bigint;
  v_p8     bigint;
  v_p9     bigint;
  v_p10    bigint;
  v_p11    bigint;
  v_p12    bigint;
  v_p13    bigint;
  v_ra2    bigint;
  v_rx1    bigint;
  v_rx2    bigint;
  v_rx3    bigint;
  v_ry     bigint;
  v_rc2    bigint;
  v_cli    bigint;
  v_dev    bigint;
  v_ent    bigint;
  v_k      bigint;
  v_p1     bigint;
  v_p2     bigint;
  v_p3     bigint;
  v_p4     bigint;
  v_ra     bigint;
  v_rb     bigint;
  v_rold   bigint;
  v_rc     bigint;
  v_pago   bigint;
  v_txt    text;
  v_n      bigint;
  v_num    numeric;
  v_ts     timestamptz;
  v_tz     text;
  v_j      jsonb;
  v_clave  uuid := gen_random_uuid();
  v_id1    bigint;
  v_id2    bigint;
  v_st0    integer;
  v_st1    integer;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  SELECT u.id, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
         't3-' || u.id || '@ensayo.invalid',
         jsonb_build_object('rol', u.rol, 'sucursal_id', u.suc),
         jsonb_build_object('nombre', v_tag || ' ' || u.que), now(), now()
    FROM (VALUES (v_enc, 'encargado', 1, 'E'), (v_enc2, 'encargado', 2, 'E2'),
                 (v_a, 'transportista', 1, 'A'), (v_b, 'transportista', 1, 'B'),
                 (v_c, 'transportista', 1, 'C'), (v_d, 'transportista', 1, 'D'),
                 (v_pv, 'preventista', 1, 'PV'), (v_e12, 'encargado', 1, 'E12'),
                 (v_g, 'transportista', 1, 'G'), (v_h, 'transportista', 1, 'H'),
                 (v_m1, 'transportista', 1, 'M1'), (v_m2, 'transportista', 1, 'M2'),
                 (v_m3, 'transportista', 1, 'M3'), (v_a2, 'transportista', 1, 'A2'),
                 (v_x1, 'transportista', 1, 'X1'), (v_x2, 'transportista', 1, 'X2'),
                 (v_x3, 'transportista', 1, 'X3'), (v_y, 'transportista', 1, 'Y'),
                 (v_c2, 'transportista', 1, 'C2'), (v_c3, 'transportista', 1, 'C3')) AS u(id, rol, suc, que);
  -- X3 también es de la sucursal 2 (tiene ahí una ruta en curso, B5f).
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_x3, 2) ON CONFLICT DO NOTHING;
  -- E12 es encargado de las dos sucursales (para la clave del canje usada en la otra).
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id) VALUES (v_e12, 2) ON CONFLICT DO NOTHING;

  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (v_tag, v_tag, 'Calle T3 1', 1) RETURNING id INTO v_cli;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (v_tag || ' devuelto', 100, 1000, 60, 1) RETURNING id INTO v_dev;
  INSERT INTO productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES (v_tag || ' entregado', 100, 1000, 60, 1) RETURNING id INTO v_ent;

  INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por, sucursal_id)
  VALUES (v_cli, v_hoy, 'pendiente', 1000, 0, 'pendiente', 'app', v_enc, v_enc, 1) RETURNING id INTO v_p1;
  INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por, sucursal_id)
  VALUES (v_cli, v_hoy, 'pendiente', 1000, 0, 'pendiente', 'app', v_enc, v_enc, 1) RETURNING id INTO v_p2;
  INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por, sucursal_id)
  VALUES (v_cli, v_hoy, 'pendiente', 1000, 0, 'pendiente', 'app', v_enc, v_enc, 1) RETURNING id INTO v_p3;
  INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por, sucursal_id)
  VALUES (v_cli, v_hoy, 'pendiente', 1000, 0, 'pendiente', 'app', v_enc, v_enc, 1) RETURNING id INTO v_p4;
  INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por, sucursal_id)
  VALUES (v_cli, v_hoy, 'pendiente', 1000, 0, 'pendiente', 'app', v_enc, v_enc, 1) RETURNING id INTO v_p5;
  INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por, sucursal_id)
  VALUES (v_cli, v_hoy, 'pendiente', 1000, 0, 'pendiente', 'app', v_enc, v_enc, 1) RETURNING id INTO v_p6;
  FOR v_n IN 7..13 LOOP
    INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por, sucursal_id,
                         transportista_id)
    VALUES (v_cli, v_hoy, CASE WHEN v_n = 12 THEN 'asignado' ELSE 'pendiente' END, 1000, 0, 'pendiente', 'app', v_enc, v_enc, 1,
            CASE WHEN v_n = 12 THEN v_c END)
    RETURNING id INTO v_num;
    CASE v_n
      WHEN 7 THEN v_p7 := v_num;   WHEN 8 THEN v_p8 := v_num;   WHEN 9 THEN v_p9 := v_num;
      WHEN 10 THEN v_p10 := v_num; WHEN 11 THEN v_p11 := v_num; WHEN 12 THEN v_p12 := v_num;
      ELSE v_p13 := v_num;
    END CASE;
  END LOOP;

  -- B3c · el pedido de una parada 'no_entregado' que volvió a 'asignado' (lo reprogramaron).
  INSERT INTO pedidos (cliente_id, fecha, estado, total, monto_pagado, estado_pago, canal, usuario_id, creado_por, sucursal_id,
                       transportista_id)
  VALUES (v_cli, v_hoy, 'asignado', 1000, 0, 'pendiente', 'app', v_enc, v_enc, 1, v_c3) RETURNING id INTO v_p14;

  -- ---------------------------------------------------------------- helpers -
  CREATE OR REPLACE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN ''
                            ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
    IF p_uid IS NULL THEN
      EXECUTE 'RESET ROLE';
    ELSE
      EXECUTE 'SET LOCAL ROLE authenticated';
    END IF;
  END $f$;
  -- Corre p_sql como p_uid parado en p_suc: 'PASA' o el SQLSTATE y el mensaje.
  CREATE OR REPLACE FUNCTION pg_temp.r(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    BEGIN
      EXECUTE p_sql;
      v := 'PASA';
    EXCEPTION WHEN OTHERS THEN
      v := SQLSTATE || ' ' || SQLERRM;
    END;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN v;
  END $f$;
  -- El valor de p_sql como p_uid parado en p_suc (sin atajar errores).
  CREATE OR REPLACE FUNCTION pg_temp.v(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    EXECUTE p_sql INTO r;
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.ruta(p_chofer uuid, p_pedidos bigint[], p_f date) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.aplicar_orden_ruta(%L::uuid, %L::jsonb, NULL, NULL, NULL, %L::date)',
                  p_chofer,
                  (SELECT jsonb_agg(jsonb_build_object('pedido_id', x.id, 'orden_entrega', x.n) ORDER BY x.n)
                     FROM unnest(p_pedidos) WITH ORDINALITY AS x(id, n)),
                  p_f);
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.parada(p_ruta bigint, p_pedido bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT COALESCE((SELECT estado_entrega::text FROM public.recorrido_pedidos
                      WHERE recorrido_id = p_ruta AND pedido_id = p_pedido), '-');
  $f$;
  -- 'entregados/total' de una ruta, como los guarda la ruta.
  CREATE OR REPLACE FUNCTION pg_temp.cuenta(p_ruta bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT pedidos_entregados || '/' || total_pedidos FROM public.recorridos WHERE id = p_ruta;
  $f$;
  CREATE OR REPLACE FUNCTION pg_temp.masiva(p_pedido bigint, p_chofer uuid, p_f date) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.marcar_entregas_masivo(ARRAY[%s]::bigint[], %L::uuid, %L::date)', p_pedido, p_chofer, p_f);
  $f$;
  -- Un chofer intenta aplicar un canje: '' si se rechazó sin mover nada; si no, lo que pasó.
  CREATE OR REPLACE FUNCTION pg_temp.canje_ajeno(p_chofer uuid, p_canje bigint, p_ent bigint) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v_st0 int := (SELECT stock FROM public.productos WHERE id = p_ent);
    v_txt text := pg_temp.r(p_chofer, 1, format('SELECT public.aplicar_cambio_de_parada(%s, NULL, NULL)', p_canje));
  BEGIN
    IF v_txt ~ 'No autorizado para aplicar el cambio'
       AND (SELECT aplicado_at FROM public.recorrido_cambios WHERE pedido_id = p_canje) IS NULL
       AND (SELECT stock FROM public.productos WHERE id = p_ent) = v_st0 THEN
      RETURN '';
    END IF;
    RETURN format('%s (stock %s → %s)', v_txt, v_st0, (SELECT stock FROM public.productos WHERE id = p_ent));
  END $f$;
  CREATE OR REPLACE FUNCTION pg_temp.canje(p_clave uuid, p_cant int, p_obs text) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.registrar_cambio_producto(p_cliente_id => %s, p_producto_devuelto_id => %s, '
                  'p_cantidad_devuelta => %s, p_producto_entregado_id => %s, p_cantidad_entregada => %s, '
                  'p_observaciones => %L, p_motivo => %L%s)::text',
                  current_setting('et3.cli'), current_setting('et3.dev'), p_cant, current_setting('et3.ent'), p_cant,
                  p_obs, 'erroneo',
                  CASE WHEN p_clave IS NULL THEN '' ELSE format(', p_clave => %L::uuid', p_clave) END);
  $f$;
  PERFORM set_config('et3.cli', v_cli::text, true);
  PERFORM set_config('et3.dev', v_dev::text, true);
  PERFORM set_config('et3.ent', v_ent::text, true);

  -- ------------------------------------------------------------------ B13 ---
  v_k := pg_temp.v(v_enc, 1, format('SELECT public.crear_pedido_cambio_en_ruta(%s, %s, 2, %s, 2, %L, %L)::text',
                                    v_cli, v_dev, v_ent, v_tag || ' parada', 'erroneo'))::bigint;
  IF (SELECT creado_por FROM pedidos WHERE id = v_k) IS DISTINCT FROM v_enc THEN
    v_fallas := v_fallas || format('B13 · el canje #%s nació con creado_por %s (se esperaba E)',
                                   v_k, COALESCE((SELECT creado_por::text FROM pedidos WHERE id = v_k), 'NULL'));
  END IF;

  -- ------------------------------------------------------------------- B4 ---
  v_rb := pg_temp.v(v_enc, 1, pg_temp.ruta(v_b, ARRAY[v_k], v_hoy))::bigint;
  v_ra := pg_temp.v(v_enc, 1, pg_temp.ruta(v_a, ARRAY[v_p1, v_p2, v_p3, v_p5], v_hoy))::bigint;
  -- La ruta vieja de A, cerrada, con la parada de K que pasó a B.
  INSERT INTO recorridos (transportista_id, fecha, estado, sucursal_id, completed_at)
  VALUES (v_a, v_hoy - 1, 'completado', 1, now() - interval '1 day') RETURNING id INTO v_rold;
  INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, estado_entrega, sucursal_id)
  VALUES (v_rold, v_k, 1, 'reasignado', 1);

  SELECT stock INTO v_st0 FROM productos WHERE id = v_ent;
  v_txt := pg_temp.r(v_a, 1, format('SELECT public.aplicar_cambio_de_parada(%s, NULL, NULL)', v_k));
  SELECT stock INTO v_st1 FROM productos WHERE id = v_ent;
  IF v_txt !~ 'No autorizado para aplicar el cambio' OR (SELECT aplicado_at FROM recorrido_cambios WHERE pedido_id = v_k) IS NOT NULL
     OR v_st1 IS DISTINCT FROM v_st0 THEN
    v_fallas := v_fallas || format('B4 · A (parada vieja del canje) aplicó el cambio o no se rechazó: %s (stock %s → %s)',
                                   v_txt, v_st0, v_st1);
  END IF;
  -- Cada una de las tres condiciones por separado, con las otras dos bien. M1, M2 y M3 tienen
  -- cada uno su canje en su ruta de hoy, y a cada uno le falta una sola cosa:
  --   B4a · no es el chofer del canje (el canje pasó a B sin mover la parada);
  --   B4b · su ruta ya no está en curso (cerrada con la parada pendiente);
  --   B4c · su parada no está viva (quedó 'reasignado').
  v_k1 := pg_temp.v(v_enc, 1, format('SELECT public.crear_pedido_cambio_en_ruta(%s, %s, 1, %s, 1, %L, %L)::text',
                                     v_cli, v_dev, v_ent, v_tag || ' B4a', 'erroneo'))::bigint;
  v_k2 := pg_temp.v(v_enc, 1, format('SELECT public.crear_pedido_cambio_en_ruta(%s, %s, 1, %s, 1, %L, %L)::text',
                                     v_cli, v_dev, v_ent, v_tag || ' B4b', 'erroneo'))::bigint;
  v_k3 := pg_temp.v(v_enc, 1, format('SELECT public.crear_pedido_cambio_en_ruta(%s, %s, 1, %s, 1, %L, %L)::text',
                                     v_cli, v_dev, v_ent, v_tag || ' B4c', 'erroneo'))::bigint;
  PERFORM pg_temp.v(v_enc, 1, pg_temp.ruta(v_m1, ARRAY[v_k1], v_hoy));
  v_r2 := pg_temp.v(v_enc, 1, pg_temp.ruta(v_m2, ARRAY[v_k2], v_hoy))::bigint;
  v_r3 := pg_temp.v(v_enc, 1, pg_temp.ruta(v_m3, ARRAY[v_k3], v_hoy))::bigint;
  UPDATE pedidos SET transportista_id = v_b WHERE id = v_k1;
  UPDATE recorridos SET estado = 'completado', completed_at = now() WHERE id = v_r2;
  UPDATE recorrido_pedidos SET estado_entrega = 'reasignado' WHERE recorrido_id = v_r3 AND pedido_id = v_k3;
  v_txt := pg_temp.canje_ajeno(v_m1, v_k1, v_ent);
  IF v_txt <> '' THEN
    v_fallas := v_fallas || ('B4a · M1, con su parada viva en su ruta en curso pero sin ser el chofer del canje, lo aplicó: ' || v_txt);
  END IF;
  v_txt := pg_temp.canje_ajeno(v_m2, v_k2, v_ent);
  IF v_txt <> '' THEN
    v_fallas := v_fallas || ('B4b · M2, chofer del canje con la parada pendiente en una ruta cerrada, lo aplicó: ' || v_txt);
  END IF;
  v_txt := pg_temp.canje_ajeno(v_m3, v_k3, v_ent);
  IF v_txt <> '' THEN
    v_fallas := v_fallas || ('B4c · M3, chofer del canje en su ruta en curso con la parada reasignada, lo aplicó: ' || v_txt);
  END IF;

  v_txt := pg_temp.r(v_b, 1, format('SELECT public.aplicar_cambio_de_parada(%s, NULL, NULL)', v_k));
  IF v_txt <> 'PASA' OR (SELECT aplicado_at FROM recorrido_cambios WHERE pedido_id = v_k) IS NULL THEN
    v_fallas := v_fallas || ('B4 · B (su parada viva) no pudo aplicar el cambio: ' || v_txt);
  END IF;

  -- ------------------------------------------------------------------- B5 ---
  -- Decisión del dueño (#1554): la entrega a nombre de otro chofer mueve la parada sólo si
  -- ese chofer tiene una ruta en curso ese día.
  -- B5a · G no tiene ruta: P1 queda entregado en la ruta de A, como en la 547.
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p1, v_g, v_hoy));
  IF v_txt <> 'PASA' OR (SELECT estado FROM pedidos WHERE id = v_p1) <> 'entregado' THEN
    v_fallas := v_fallas || ('B5a · la masiva a nombre de G no entregó P1: ' || v_txt);
  ELSIF pg_temp.parada(v_ra, v_p1) <> 'entregado' OR pg_temp.cuenta(v_ra) <> '1/4' THEN
    v_fallas := v_fallas || format('B5a · P1, entregado por G (sin ruta), dejó la parada de A en %s y la ruta de A en %s (se esperaba entregado y 1/4)',
                                   pg_temp.parada(v_ra, v_p1), pg_temp.cuenta(v_ra));
  END IF;
  -- B5b · B tiene ruta hoy (la del canje K): P5 cuenta en la de B, y la de A queda reasignado.
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p5, v_b, v_hoy));
  IF v_txt <> 'PASA' OR (SELECT estado FROM pedidos WHERE id = v_p5) <> 'entregado' THEN
    v_fallas := v_fallas || ('B5b · la masiva a nombre de B no entregó P5: ' || v_txt);
  ELSIF pg_temp.parada(v_ra, v_p5) <> 'reasignado' OR pg_temp.parada(v_rb, v_p5) <> 'entregado'
        OR pg_temp.cuenta(v_ra) <> '1/3' OR pg_temp.cuenta(v_rb) <> '1/2' THEN
    v_fallas := v_fallas || format('B5b · P5, entregado por B (con ruta), dejó A en %s (%s) y B en %s (%s); se esperaba reasignado (1/3) y entregado (1/2)',
                                   pg_temp.parada(v_ra, v_p5), pg_temp.cuenta(v_ra), pg_temp.parada(v_rb, v_p5), pg_temp.cuenta(v_rb));
  END IF;
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p2, v_a, v_hoy));
  IF v_txt <> 'PASA' OR pg_temp.parada(v_ra, v_p2) <> 'entregado' THEN
    v_fallas := v_fallas || format('B5 · control: P2 entregado por A dejó su parada en %s: %s', pg_temp.parada(v_ra, v_p2), v_txt);
  END IF;

  -- ------------------------------------------------------------------ B11 ---
  -- 700 en efectivo, y 300 de un crédito suelto que se aplica a la boleta (de_saldo_a_favor lo
  -- pone el trigger al pasar el pago de suelto a la boleta).
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, sucursal_id, usuario_id)
  VALUES (v_cli, v_p3, 700, 'efectivo', v_hoy, 1, v_enc);
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, sucursal_id, usuario_id)
  VALUES (v_cli, NULL, 300, 'efectivo', v_hoy, 1, v_enc) RETURNING id INTO v_pago;
  UPDATE pagos SET pedido_id = v_p3 WHERE id = v_pago;
  IF NOT (SELECT de_saldo_a_favor FROM pagos WHERE id = v_pago) THEN
    v_fallas := v_fallas || 'B11 · el crédito aplicado no quedó marcado de_saldo_a_favor: el caso no prueba nada'::text;
  END IF;
  v_txt := pg_temp.r(v_enc, 1, format('SELECT public.marcar_entregas_masivo(ARRAY[%s]::bigint[], %L::uuid, %L::date)',
                                      v_p3, v_a, v_hoy));
  SELECT total_cobrado INTO v_num FROM public._recorrido_contadores(v_ra);
  IF v_txt <> 'PASA' OR v_num IS DISTINCT FROM 700::numeric
     OR (SELECT total_cobrado FROM recorridos WHERE id = v_ra) IS DISTINCT FROM 700::numeric THEN
    v_fallas := v_fallas || format('B11 · lo cobrado de la ruta de A es %s (columna %s), se esperaba 700: el saldo a favor no es plata del chofer (%s)',
                                   v_num, (SELECT total_cobrado FROM recorridos WHERE id = v_ra), v_txt);
  END IF;

  -- ------------------------------------------------------------------ B5r ---
  -- Revertir la entrega de P5 (la de B), devolvérselo a A y que A lo entregue: cuenta en la
  -- de A (su parada 'reasignado' se toma de nuevo) y la de B queda reasignado. Ninguna parada
  -- queda pegada, y el pedido vive en una sola ruta.
  UPDATE pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = v_p5;
  IF pg_temp.parada(v_rb, v_p5) <> 'pendiente' OR pg_temp.parada(v_ra, v_p5) <> 'reasignado' THEN
    v_fallas := v_fallas || format('B5r · revertir la entrega de P5 dejó B en %s y A en %s (se esperaba pendiente y reasignado)',
                                   pg_temp.parada(v_rb, v_p5), pg_temp.parada(v_ra, v_p5));
  END IF;
  UPDATE pedidos SET transportista_id = v_a WHERE id = v_p5;
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p5, v_a, v_hoy));
  IF v_txt <> 'PASA' OR pg_temp.parada(v_ra, v_p5) <> 'entregado' OR pg_temp.parada(v_rb, v_p5) <> 'reasignado'
     OR pg_temp.cuenta(v_ra) <> '4/4' OR pg_temp.cuenta(v_rb) <> '0/1'
     OR (SELECT count(*) FROM recorrido_pedidos WHERE pedido_id = v_p5 AND estado_entrega IN ('pendiente', 'entregado')) <> 1 THEN
    v_fallas := v_fallas || format('B5r · A volvió a entregar P5: A en %s (%s), B en %s (%s); se esperaba entregado (4/4) y reasignado (0/1). %s',
                                   pg_temp.parada(v_ra, v_p5), pg_temp.cuenta(v_ra),
                                   pg_temp.parada(v_rb, v_p5), pg_temp.cuenta(v_rb), v_txt);
  END IF;

  -- ------------------------------------------------------------------ B5c ---
  -- Rearmar una ruta en curso con un pedido cuya parada quedó 'reasignado': se reabre
  -- (pendiente), como una 'no_entregado'.
  v_rh := pg_temp.v(v_enc, 1, pg_temp.ruta(v_h, ARRAY[v_p6], v_hoy))::bigint;
  UPDATE recorrido_pedidos SET estado_entrega = 'reasignado' WHERE recorrido_id = v_rh AND pedido_id = v_p6;
  v_txt := pg_temp.r(v_enc, 1, pg_temp.ruta(v_h, ARRAY[v_p6], v_hoy));
  IF v_txt <> 'PASA' OR pg_temp.parada(v_rh, v_p6) <> 'pendiente' OR pg_temp.cuenta(v_rh) <> '0/1' THEN
    v_fallas := v_fallas || format('B5c · rearmar la ruta de H dejó la parada reasignada de P6 en %s (%s): %s',
                                   pg_temp.parada(v_rh, v_p6), pg_temp.cuenta(v_rh), v_txt);
  END IF;

  -- ------------------------------------------------------------------ B5v ---
  -- Revertir una entrega que no dejó parada viva: B (con ruta) entrega P6, la parada de H
  -- queda 'reasignado'; la de B ya no está (se borra acá a mano). Al revertir, la de H, que
  -- es de una ruta en curso, vuelve a pendiente: no queda pegada.
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p6, v_b, v_hoy));
  DELETE FROM recorrido_pedidos WHERE recorrido_id = v_rb AND pedido_id = v_p6;
  PERFORM public.recalcular_recorrido(v_rb);  -- los contadores de B, sin esa parada
  UPDATE pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = v_p6;
  IF v_txt <> 'PASA' OR pg_temp.parada(v_rh, v_p6) <> 'pendiente' OR pg_temp.cuenta(v_rh) <> '0/1' THEN
    v_fallas := v_fallas || format('B5v · revertir P6 sin parada viva dejó la de H en %s (%s): %s',
                                   pg_temp.parada(v_rh, v_p6), pg_temp.cuenta(v_rh), v_txt);
  END IF;

  -- ------------------------------------------------------------ B5d a B5i ---
  -- Los filtros de «la ruta en curso de quien entrega, ese día» (v_ruta_chofer), uno por
  -- caso. P7, P8, P9 y P13 salen en la ruta de A2; cada entrega la hace un chofer al que le
  -- falta una sola cosa para tener ruta, así que la parada de A2 queda entregada (la 547).
  v_ra2 := pg_temp.v(v_enc, 1, pg_temp.ruta(v_a2, ARRAY[v_p7, v_p8, v_p9, v_p13], v_hoy))::bigint;
  INSERT INTO recorridos (transportista_id, fecha, estado, sucursal_id)
  VALUES (v_x1, v_hoy - 1, 'en_curso', 1) RETURNING id INTO v_rx1;
  INSERT INTO recorridos (transportista_id, fecha, estado, sucursal_id, completed_at)
  VALUES (v_x2, v_hoy, 'completado', 1, now()) RETURNING id INTO v_rx2;
  INSERT INTO recorridos (transportista_id, fecha, estado, sucursal_id)
  VALUES (v_x3, v_hoy, 'en_curso', 2) RETURNING id INTO v_rx3;
  -- B5d · X1 tiene una ruta en curso, pero de ayer.
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p7, v_x1, v_hoy));
  IF v_txt <> 'PASA' OR pg_temp.parada(v_ra2, v_p7) <> 'entregado' OR pg_temp.parada(v_rx1, v_p7) <> '-' THEN
    v_fallas := v_fallas || format('B5d · X1 con una ruta en curso de ayer: A2 en %s, X1 en %s (se esperaba entregado y sin parada): %s',
                                   pg_temp.parada(v_ra2, v_p7), pg_temp.parada(v_rx1, v_p7), v_txt);
  END IF;
  -- B5e · X2 tiene una ruta de hoy, pero completada.
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p8, v_x2, v_hoy));
  IF v_txt <> 'PASA' OR pg_temp.parada(v_ra2, v_p8) <> 'entregado' OR pg_temp.parada(v_rx2, v_p8) <> '-' THEN
    v_fallas := v_fallas || format('B5e · X2 con una ruta de hoy completada: A2 en %s, X2 en %s (se esperaba entregado y sin parada): %s',
                                   pg_temp.parada(v_ra2, v_p8), pg_temp.parada(v_rx2, v_p8), v_txt);
  END IF;
  -- B5f · X3 tiene una ruta de hoy en curso, pero de la otra sucursal.
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p9, v_x3, v_hoy));
  IF v_txt <> 'PASA' OR pg_temp.parada(v_ra2, v_p9) <> 'entregado' OR pg_temp.parada(v_rx3, v_p9) <> '-' THEN
    v_fallas := v_fallas || format('B5f · X3 con una ruta en curso de la otra sucursal: A2 en %s, X3 en %s (se esperaba entregado y sin parada): %s',
                                   pg_temp.parada(v_ra2, v_p9), pg_temp.parada(v_rx3, v_p9), v_txt);
  END IF;
  -- B5g · un pedido sin ruta, entregado por B (con ruta): no entra a la de B.
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p10, v_b, v_hoy));
  IF v_txt <> 'PASA' OR pg_temp.parada(v_rb, v_p10) <> '-' THEN
    v_fallas := v_fallas || format('B5g · un pedido sin ruta entregado por B dejó la ruta de B en %s (se esperaba sin parada): %s',
                                   pg_temp.parada(v_rb, v_p10), v_txt);
  END IF;
  -- B5h · un pedido con sólo una parada de historia ('reasignado' en una ruta cerrada de Y),
  --       entregado por B: tampoco entra a la de B.
  INSERT INTO recorridos (transportista_id, fecha, estado, sucursal_id, completed_at)
  VALUES (v_y, v_hoy - 2, 'completado', 1, now() - interval '2 days') RETURNING id INTO v_ry;
  INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, estado_entrega, sucursal_id)
  VALUES (v_ry, v_p11, 1, 'reasignado', 1);
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p11, v_b, v_hoy));
  IF v_txt <> 'PASA' OR pg_temp.parada(v_rb, v_p11) <> '-' OR pg_temp.parada(v_ry, v_p11) <> 'reasignado' THEN
    v_fallas := v_fallas || format('B5h · un pedido con sólo una parada de historia entregado por B: B en %s, Y en %s (se esperaba sin parada y reasignado): %s',
                                   pg_temp.parada(v_rb, v_p11), pg_temp.parada(v_ry, v_p11), v_txt);
  END IF;
  -- B5i · marcar_no_entregado no toca la parada 'reasignado' de otro chofer: B (con ruta)
  --       entrega P13 de la ruta de A2, se revierte, y B lo marca no entregado. La de B queda
  --       no entregada; la de A2 sigue reasignada (A2 no hizo ese intento).
  v_txt := pg_temp.r(v_enc, 1, pg_temp.masiva(v_p13, v_b, v_hoy));
  UPDATE pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = v_p13;
  v_txt := v_txt || ' / ' || pg_temp.r(v_b, 1, format('SELECT public.marcar_no_entregado(%s, %L, NULL)', v_p13, 'cerrado'));
  IF v_txt <> 'PASA / PASA' OR pg_temp.parada(v_rb, v_p13) <> 'no_entregado' OR pg_temp.parada(v_ra2, v_p13) <> 'reasignado' THEN
    v_fallas := v_fallas || format('B5i · B marcó no entregado P13: B en %s, A2 en %s (se esperaba no_entregado y reasignado): %s',
                                   pg_temp.parada(v_rb, v_p13), pg_temp.parada(v_ra2, v_p13), v_txt);
  END IF;

  -- ------------------------------------------------------------------- B6 ---
  v_txt := pg_temp.r(v_enc, 1, pg_temp.ruta(v_d, ARRAY[v_p4], v_hoy - 400));
  IF v_txt !~ '^22023 .*no puede ser anterior' THEN
    v_fallas := v_fallas || ('B6 · una ruta de hace 400 días no se rechazó: ' || v_txt);
  END IF;
  v_txt := pg_temp.r(v_enc, 1, pg_temp.ruta(v_d, ARRAY[v_p4], v_hoy + 61));
  IF v_txt !~ '^22023 .*no puede ser posterior' THEN
    v_fallas := v_fallas || ('B6 · una ruta de dentro de 61 días no se rechazó: ' || v_txt);
  END IF;
  v_txt := pg_temp.r(v_enc, 1, pg_temp.ruta(v_d, ARRAY[v_p4], v_hoy + 1));
  IF v_txt <> 'PASA' THEN
    v_fallas := v_fallas || ('B6 · control: la ruta de mañana no pasó: ' || v_txt);
  END IF;

  -- ------------------------------------------------------------------- P1 ---
  v_txt := pg_temp.r(v_enc2, 2, format('SELECT public.recalcular_recorrido(%s)', v_ra));
  IF v_txt !~ '^42501 ' THEN
    v_fallas := v_fallas || ('P1 · un encargado de la sucursal 2 recalculó una ruta de la 1: ' || v_txt);
  END IF;
  v_txt := pg_temp.r(v_enc, 1, format('SELECT public.recalcular_recorrido(%s)', v_ra));
  IF v_txt <> 'PASA' THEN
    v_fallas := v_fallas || ('P1 · control: E no pudo recalcular su ruta: ' || v_txt);
  END IF;

  -- ------------------------------------------------------------------- B3 ---
  INSERT INTO recorridos (transportista_id, fecha, estado, sucursal_id)
  VALUES (v_c, v_hoy - 1, 'en_curso', 1) RETURNING id INTO v_rc;
  -- B3b · la ruta de ayer de C2 tiene sólo una parada 'reasignado' de un pedido que sigue
  --       asignado (sale en otra ruta): no la traba, se cierra igual.
  INSERT INTO recorridos (transportista_id, fecha, estado, sucursal_id)
  VALUES (v_c2, v_hoy - 1, 'en_curso', 1) RETURNING id INTO v_rc2;
  INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, estado_entrega, sucursal_id)
  VALUES (v_rc2, v_p12, 1, 'reasignado', 1);
  -- B3c · la ruta de ayer de C3 tiene una parada 'no_entregado' cuyo pedido volvió a 'asignado'
  --       (lo reprogramaron): sigue pendiente, la ruta NO se cierra (como en la 548). Un
  --       filtro `estado_entrega IN ('pendiente','entregado')` sacaría también la no_entregado.
  INSERT INTO recorridos (transportista_id, fecha, estado, sucursal_id)
  VALUES (v_c3, v_hoy - 1, 'en_curso', 1) RETURNING id INTO v_rc3;
  INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, estado_entrega, sucursal_id)
  VALUES (v_rc3, v_p14, 1, 'no_entregado', 1);
  v_tz := current_setting('TimeZone');
  PERFORM set_config('TimeZone', 'UTC', true);
  PERFORM public.cerrar_recorridos_vencidos(1);
  PERFORM set_config('TimeZone', v_tz, true);
  SELECT completed_at INTO v_ts FROM recorridos WHERE id = v_rc;
  IF (SELECT estado FROM recorridos WHERE id = v_rc) <> 'completado'
     OR v_ts IS DISTINCT FROM (((v_hoy - 1) + TIME '23:59') AT TIME ZONE 'America/Argentina/Buenos_Aires') THEN
    v_fallas := v_fallas || format('B3 · la ruta de ayer de C se cerró a las %s UTC (se esperaba %s UTC, las 23:59 de Argentina)',
                                   to_char(v_ts AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI'),
                                   to_char((((v_hoy - 1) + TIME '23:59') AT TIME ZONE 'America/Argentina/Buenos_Aires') AT TIME ZONE 'UTC',
                                           'YYYY-MM-DD HH24:MI'));
  END IF;
  IF (SELECT estado FROM recorridos WHERE id = v_rc2) <> 'completado' THEN
    v_fallas := v_fallas || format('B3b · la ruta de ayer de C2, con sólo una parada reasignada, quedó %s (se esperaba completado)',
                                   (SELECT estado FROM recorridos WHERE id = v_rc2));
  END IF;
  IF (SELECT estado FROM recorridos WHERE id = v_rc3) <> 'en_curso' THEN
    v_fallas := v_fallas || format('B3c · la ruta de ayer de C3, con una parada no_entregado de un pedido asignado, quedó %s (se esperaba en_curso)',
                                   (SELECT estado FROM recorridos WHERE id = v_rc3));
  END IF;

  -- ------------------------------------------------------------------- B8 ---
  SELECT count(*) INTO v_n FROM pg_proc WHERE pronamespace = 'public'::regnamespace AND proname = 'registrar_cambio_producto';
  IF v_n <> 1 OR to_regprocedure('public.registrar_cambio_producto(integer,bigint,integer,bigint,integer,text,text,uuid)') IS NULL THEN
    v_fallas := v_fallas || format('B8 · registrar_cambio_producto tiene %s firma(s) y no la de la clave', v_n);
  ELSE
    SELECT stock INTO v_st0 FROM productos WHERE id = v_ent;
    BEGIN
      v_id1 := pg_temp.v(v_enc, 1, pg_temp.canje(v_clave, 2, v_tag || ' b8'))::bigint;
      v_id2 := pg_temp.v(v_enc, 1, pg_temp.canje(v_clave, 2, v_tag || ' b8'))::bigint;
    EXCEPTION WHEN OTHERS THEN
      PERFORM pg_temp.como(NULL, NULL);
      v_fallas := v_fallas || ('B8 · el canje con clave falló: ' || SQLERRM);
    END;
    SELECT stock INTO v_st1 FROM productos WHERE id = v_ent;
    SELECT count(*) INTO v_n FROM cambios_productos WHERE cliente_id = v_cli AND observaciones = v_tag || ' b8';
    IF v_id1 IS NULL OR v_id1 IS DISTINCT FROM v_id2 OR v_n <> 1 OR v_st1 IS DISTINCT FROM v_st0 - 2 THEN
      v_fallas := v_fallas || format('B8 · dos toques con la misma clave: ids %s y %s, %s canje(s), stock entregado %s → %s (se esperaba uno, −2)',
                                     v_id1, v_id2, v_n, v_st0, v_st1);
    END IF;
    v_txt := pg_temp.r(v_enc, 1, pg_temp.canje(v_clave, 3, v_tag || ' b8'));
    IF v_txt !~ '^22023 ' THEN
      v_fallas := v_fallas || ('B8 · la misma clave con otra cantidad no se rechazó: ' || v_txt);
    END IF;
    v_txt := pg_temp.r(v_enc, 1, pg_temp.canje(NULL, 1, v_tag || ' b8 sin clave'));
    v_txt := v_txt || ' / ' || pg_temp.r(v_enc, 1, pg_temp.canje(NULL, 1, v_tag || ' b8 sin clave'));
    SELECT count(*) INTO v_n FROM cambios_productos WHERE cliente_id = v_cli AND observaciones = v_tag || ' b8 sin clave';
    IF v_txt <> 'PASA / PASA' OR v_n <> 2 THEN
      v_fallas := v_fallas || format('B8 · sin clave (un PWA viejo) tenía que andar como antes: %s, %s canje(s)', v_txt, v_n);
    END IF;
    -- La misma clave, el mismo usuario y lo mismo, pero desde la otra sucursal: no es el
    -- reintento (la clave es de la sucursal en la que se registró): 22023, sin devolver el
    -- canje de la sucursal 1.
    BEGIN
      v_id1 := pg_temp.v(v_e12, 1, pg_temp.canje(v_clave2, 1, v_tag || ' b8 sucursal'))::bigint;
    EXCEPTION WHEN OTHERS THEN
      PERFORM pg_temp.como(NULL, NULL);
      v_fallas := v_fallas || ('B8 · el canje de E12 en la sucursal 1 falló: ' || SQLERRM);
    END;
    v_txt := pg_temp.r(v_e12, 2, pg_temp.canje(v_clave2, 1, v_tag || ' b8 sucursal'));
    IF v_txt !~ '^22023 ' THEN
      v_fallas := v_fallas || ('B8 · la misma clave usada desde la otra sucursal no se rechazó: ' || v_txt);
    END IF;
    IF has_function_privilege('anon', 'public.registrar_cambio_producto(integer,bigint,integer,bigint,integer,text,text,uuid)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.registrar_cambio_producto(integer,bigint,integer,bigint,integer,text,text,uuid)', 'EXECUTE') THEN
      v_fallas := v_fallas || 'B8 · los permisos de registrar_cambio_producto no son los de antes (authenticated sí, anon no)'::text;
    END IF;
  END IF;

  -- ------------------------------------------------------------------ B10 ---
  IF to_regproc('public.crear_recorrido') IS NOT NULL THEN
    v_fallas := v_fallas || 'B10 · crear_recorrido sigue existiendo (código muerto, sin validación de rol)'::text;
  END IF;

  -- ------------------------------------------------------------------ B14 ---
  IF to_regprocedure('public.optimizar_ruta_consumir_cupo(integer,integer)') IS NULL THEN
    v_fallas := v_fallas || 'B14 · no existe optimizar_ruta_consumir_cupo (el cupo por usuario de optimizar-ruta)'::text;
  ELSE
    IF has_function_privilege('anon', 'public.optimizar_ruta_consumir_cupo(integer,integer)', 'EXECUTE')
       OR NOT has_function_privilege('authenticated', 'public.optimizar_ruta_consumir_cupo(integer,integer)', 'EXECUTE') THEN
      v_fallas := v_fallas || 'B14 · optimizar_ruta_consumir_cupo: anon no y authenticated sí'::text;
    END IF;
    IF has_table_privilege('authenticated', 'public.optimizar_ruta_cupo_uso', 'SELECT')
       OR has_table_privilege('authenticated', 'public.optimizar_ruta_cupo_uso', 'INSERT')
       OR has_table_privilege('anon', 'public.optimizar_ruta_cupo_uso', 'SELECT') THEN
      v_fallas := v_fallas || 'B14 · optimizar_ruta_cupo_uso tiene grants para la API'::text;
    END IF;
    v_j := NULL;
    FOR v_n IN 1..3 LOOP
      v_j := pg_temp.v(v_a, 1, 'SELECT public.optimizar_ruta_consumir_cupo(2, 100)::text')::jsonb;
    END LOOP;
    IF COALESCE((v_j->>'ok')::boolean, true) OR v_j->>'motivo' IS DISTINCT FROM 'por_minuto' THEN
      v_fallas := v_fallas || ('B14 · la tercera llamada con tope 2 por minuto no se frenó: ' || COALESCE(v_j::text, 'NULL'));
    END IF;
    v_txt := pg_temp.r(v_pv, 1, 'SELECT public.optimizar_ruta_consumir_cupo(2, 100)');
    IF v_txt !~ '^42501 ' THEN
      v_fallas := v_fallas || ('B14 · un preventista sin rol de chofer consumió cupo de optimizar-ruta: ' || v_txt);
    END IF;
  END IF;

  -- ------------------------------------------------------------------ AUD ---
  SELECT string_agg(format('%s=%s', e->>'id', e->>'violaciones'), ', ')
    INTO v_txt
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') e
   WHERE e->>'id' IN ('RUTA-A', 'RUTA-B') AND (e->>'violaciones')::bigint <> 0;
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || ('AUD · ' || v_txt);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = 'ENSAYO FALLÓ · ' || array_to_string(v_fallas, ' | ');
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK',
    MESSAGE = format('ENSAYO OK · B13 B4 B4a B4b B4c B5a B5b B11 B5r B5c B5v B5d B5e B5f B5g B5h B5i B6 P1 B3 B3b B3c B8 B10 B14 AUD (hoy %s; canje %s, rutas A %s, B %s, C %s)',
                     v_hoy, v_k, v_ra, v_rb, v_rc);
 END;
END
$ensayo$;
