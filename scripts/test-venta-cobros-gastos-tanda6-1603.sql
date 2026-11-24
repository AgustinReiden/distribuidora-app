-- Ensayo de la migración 542_venta_cobros_stock_gastos_tanda6 (plan #1603, tanda 6, tarjeta D:
-- los bajos de venta, cobros, stock y gastos/personal de la reauditoría del 24/11).
--
-- No deja rastro (salvo valores de secuencia): un único DO que termina SIEMPRE en una excepción.
-- Antes de aplicar la migración tiene que FALLAR en V1, V3, V4, C1, C2, C4, C5, C6, S3, G1, G2, G3 y
-- G4; después, dar 'ENSAYO OK'. Corre en una base local con la semilla mínima (un admin activo de
-- las dos sucursales) o en una copia de prod. Usa el día argentino (_tablero_hoy()).
--
-- venta-B1 · la edición no conserva el precio de escala si un producto con mínimo por producto baja
--   y queda por debajo de ese mínimo. Las altas y ediciones de V1, E3 y E8 las hace un ENCARGADO: no
--   es admin (el piso y el techo le rigen igual) y no tiene el corte de las 15:30 del preventista,
--   así que el ensayo no depende de la hora en que corre.
--   V1 · escala de 20 u. con 2 distintos y 10 de cada uno, a $80 (lista $100). El encargado da de
--        alta A×10 + B×10 a $80 (entra). Editar a A×19 + B×1 a $80 no entra («por debajo»: el total
--        y los distintos no se achican, pero B dejó de cumplir su mínimo); a A×11 + B×10 a $80 entra.
--        Con la escala desactivada, editar a A×12 + B×10 a $80 sigue entrando (el precio guardado se
--        conserva: nadie bajó).
--   E3 (control de la lente) · escala de 20 u. con B ≥ 10, a $80; alta A×10 + B×13; la escala pasa a
--        $90; editar a A×12 + B×11 a $80 ENTRA (B baja pero sigue cumpliendo su mínimo).
--   E8 (control de la lente) · el mínimo (F ≥ 5) está sólo en una escala apagada; la activa (20 u.,
--        sin mínimo) pasa de $80 a $90; alta E×10 + F×10; editar a E×11 + F×9 a $80 ENTRA.
-- venta-B3 · anular una salvedad que borró la línea entera de un producto que hoy no tiene lista.
--   V3 · A×4 + B×1 entregado; salvedad de A×4 (borra la línea); A queda con lista 0; anular la
--        salvedad entra y A vuelve ×4 a su precio. Después, la marca de la edición queda vacía.
-- venta-B4 · la edición con un renglón sin producto contesta con su motivo, sin error crudo.
--   V4 · editar con {"producto_id": null} da success=false y el motivo «sin producto».
-- cobros-B1 · imputar un crédito: la misma clave con otra boleta u otro monto no es un reintento.
--   C1 · clave K imputa 10 a la boleta P1: entra. K con 10 sobre P2: 22023 y no imputa. K con 7 sobre
--        P1: 22023. K con 10 sobre P1 otra vez: replay.
-- cobros-B2 · el cobro+entrega masivo no le pisa la forma de pago a una boleta que ya estaba cobrada.
--   C2 · b cobrada entera en transferencia; el lote [a, b] en cheque: a queda en cheque, b con la
--        forma que tenía.
-- cobros-B4 · FIFO de la ficha con un cliente de otra sucursal: «Cliente no encontrado», no un 23503.
-- cobros-B5 · el aviso «supera lo que falta» con un monto de diez cifras muestra el número, no «#».
-- cobros-B6 · FIFO de la ficha: el reintento con 5.00 en vez de 5 es el mismo cobro (replay).
-- stock-STK-3 · etiquetar unidades de la bolsa en un lote manual deja su fila en el ledger.
--   S3 · crear_lote_manual de 15 (lote nuevo) y de 5 más con la misma fecha (lo suma al mismo lote):
--        una fila cada uno, con stock anterior = nuevo y el lote como referencia; STK-A cierra.
-- reportes-R1 · un gasto de más de 999.999.999.999,99 dice el tope, no «mayor a cero».
--   G1
-- reportes-R2 · editar un empleado sin mandar cuil, teléfono, ingreso, usuario, cliente ni vehículo
--   los conserva; mandarlos en null los borra.
--   G2
-- reportes-R3 · el alta de un gasto y de un empleado con la clave del formulario no se duplica.
--   G3 · gasto: la clave K dos veces con lo mismo da un solo gasto (el mismo id); con otro monto,
--        22023; sin clave, dos gastos (un PWA de antes).
--   G4 · empleado: la clave dos veces da un solo empleado; la clave de un gasto no sirve para un
--        empleado (22023).
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas, siempre como excepción.
--
--   docker exec -i <contenedor> psql -U postgres -d postgres -f - < scripts/test-venta-cobros-gastos-tanda6-1603.sql

DO $ensayo$
DECLARE
  v_hoy    date := public._tablero_hoy();
  v_adm    uuid;
  v_enc    uuid := gen_random_uuid();
  v_tra    uuid := gen_random_uuid();
  v_otro   uuid := gen_random_uuid();
  v_cli    bigint;
  v_cli2   bigint;
  v_a      bigint;
  v_b      bigint;
  v_g      bigint;
  v_esc    bigint;
  v_ped    bigint;
  v_ped2   bigint;
  v_item   bigint;
  v_sal    bigint;
  v_pago   bigint;
  v_rubro  bigint;
  v_veh    bigint;
  v_emp    bigint;
  v_id1    bigint;
  v_id2    bigint;
  v_n      int;
  v_n0     int;
  v_k      uuid;
  v_t      text;
  v_j      jsonb;
  v_fp     text;
  v_lote   bigint;
  v_stock  int;
  v_fallas text[] := '{}';
  r        record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ------------------------------------------------------------- personas ---
  SELECT p.id INTO v_adm
    FROM perfiles p
   WHERE p.rol = 'admin' AND p.activo
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = 1)
     AND EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = p.id AND us.sucursal_id = 2)
   ORDER BY p.id LIMIT 1;
  IF v_adm IS NULL OR (SELECT count(*) FROM sucursales WHERE id IN (1, 2) AND activa) < 2 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: hace falta un admin activo de las sucursales 1 y 2, activas';
  END IF;
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_enc, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6d-' || v_enc || '@ensayo.invalid',
          jsonb_build_object('rol', 'encargado', 'sucursal_id', 1), '{}', now(), now()),
         (v_tra, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6d-' || v_tra || '@ensayo.invalid',
          jsonb_build_object('rol', 'transportista', 'sucursal_id', 1), '{}', now(), now()),
         (v_otro, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6d-' || v_otro || '@ensayo.invalid',
          jsonb_build_object('rol', 'preventista', 'sucursal_id', 1), '{}', now(), now());
  PERFORM set_config('et6d.adm', v_adm::text, true);

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.limpiar() RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('app.stock_origen', '', true), set_config('app.stock_ref_tipo', '', true),
           set_config('app.stock_ref_id', '', true), set_config('app.stock_user_id', '', true),
           set_config('app.stock_pedido_item_id', '', true), set_config('app.omitir_minimo_venta', '', true),
           set_config('app.regalo_corte_manual', '', true), set_config('app.cambio_cliente_desde', '', true);
  $f$;
  -- Una RPC como el front: rol authenticated, como p_uid (el admin si es NULL), parado en p_suc.
  CREATE FUNCTION pg_temp.como(p_sql text, p_uid uuid DEFAULT NULL, p_suc bigint DEFAULT 1) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE
    v text;
  BEGIN
    PERFORM set_config('request.jwt.claims',
      json_build_object('sub', COALESCE(p_uid, current_setting('et6d.adm')::uuid), 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    PERFORM pg_temp.limpiar();
    RETURN v;
  END $f$;
  -- NULL si la RPC anda; si no, 'SQLSTATE: mensaje'.
  CREATE FUNCTION pg_temp.err(p_sql text, p_uid uuid DEFAULT NULL, p_suc bigint DEFAULT 1) RETURNS text LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(p_sql, p_uid, p_suc);
    RETURN NULL;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    PERFORM pg_temp.limpiar();
    RETURN SQLSTATE || ': ' || SQLERRM;
  END $f$;
  CREATE FUNCTION pg_temp.chk(p_ok boolean, p_que text) RETURNS text[] LANGUAGE sql AS $f$
    SELECT CASE WHEN p_ok IS TRUE THEN '{}'::text[] ELSE ARRAY[p_que] END;
  $f$;
  CREATE FUNCTION pg_temp.it(p_prod bigint, p_cant int, p_precio numeric) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio);
  $f$;
  CREATE FUNCTION pg_temp.prod(p_precio numeric, p_stock int, p_suc bigint DEFAULT 1) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES ('ZZ t6d ' || gen_random_uuid(), p_precio, p_stock, 50, 50, 50, 50, p_suc) RETURNING id;
  $f$;
  CREATE FUNCTION pg_temp.cli(p_suc bigint DEFAULT 1) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('ZZ t6d', 'ZZ t6d ' || gen_random_uuid(), 'calle 1', p_suc) RETURNING id;
  $f$;
  -- El alta como el front, con el total = la suma de las líneas.
  CREATE FUNCTION pg_temp.alta(p_uid uuid, p_cli bigint, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v jsonb;
  BEGIN
    v := pg_temp.como(format('SELECT public.crear_pedido_completo(p_cliente_id => %s, p_total => %s, p_usuario_id => %L, p_items => %L::jsonb)::text',
                             p_cli,
                             (SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0)
                                FROM jsonb_array_elements(p_items) e),
                             p_uid, p_items), p_uid)::jsonb;
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'ENSAYO FALLÓ · el alta de fixture no entró: %', v;
    END IF;
    RETURN (v->>'pedido_id')::bigint;
  END $f$;
  CREATE FUNCTION pg_temp.edit(p_uid uuid, p_ped bigint, p_items jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT pg_temp.como(format('SELECT public.actualizar_pedido_items(%s, %L::jsonb, %L)::text', p_ped, p_items, p_uid), p_uid)::jsonb;
  $f$;
  CREATE FUNCTION pg_temp.ok(p jsonb) RETURNS boolean LANGUAGE sql AS $f$
    SELECT COALESCE((p->>'success')::boolean, false);
  $f$;
  -- La foto de un pedido: producto×cantidad@precio de cada línea de venta.
  CREATE FUNCTION pg_temp.lin(p_ped bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT string_agg(format('%s×%s@%s', producto_id, cantidad, precio_unitario), ' ' ORDER BY producto_id, cantidad)
      FROM public.pedido_items WHERE pedido_id = p_ped AND NOT COALESCE(es_bonificacion, false);
  $f$;

  v_cli  := pg_temp.cli(1);
  v_cli2 := pg_temp.cli(2);

  -- ======================================================= V1 · venta-B1 ===
  v_a := pg_temp.prod(100, 1000);
  v_b := pg_temp.prod(100, 1000);
  INSERT INTO grupos_precio (nombre, sucursal_id, activo) VALUES ('ZZ t6d grupo', 1, true) RETURNING id INTO v_g;
  INSERT INTO grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id) VALUES (v_g, v_a, 1), (v_g, v_b, 1);
  INSERT INTO grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, activo, sucursal_id, min_productos_distintos)
  VALUES (v_g, 20, 80, true, 1, 2) RETURNING id INTO v_esc;
  INSERT INTO grupo_precio_escala_minimos (escala_id, producto_id, cantidad_minima_por_item, sucursal_id)
  VALUES (v_esc, v_a, 10, 1), (v_esc, v_b, 10, 1);
  v_ped := pg_temp.alta(v_enc, v_cli, jsonb_build_array(pg_temp.it(v_a, 10, 80), pg_temp.it(v_b, 10, 80)));
  -- Desde A×10 + B×10: el total (20) y los distintos (2) no se achican, pero B baja de su mínimo.
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 19, 80), pg_temp.it(v_b, 1, 80)));
  v_fallas := v_fallas || pg_temp.chk(NOT pg_temp.ok(v_j) AND v_j::text LIKE '%por debajo%',
                                      'V1 · A×19 + B×1 a $80 no tenía que entrar (B no cumple su mínimo): ' || v_j::text);
  v_fallas := v_fallas || pg_temp.chk(pg_temp.lin(v_ped) = format('%s×10@80.00 %s×10@80.00', v_a, v_b),
                                      'V1 · el pedido tenía que seguir A×10 + B×10: ' || COALESCE(pg_temp.lin(v_ped), '-'));
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 11, 80), pg_temp.it(v_b, 10, 80)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j), 'V1 · A×11 + B×10 a $80 tenía que entrar: ' || v_j::text);
  UPDATE grupo_precio_escalas SET activo = false WHERE id = v_esc;
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 12, 80), pg_temp.it(v_b, 10, 80)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j),
                                      'V1 · con la escala apagada, A×12 + B×10 a $80 conserva el precio guardado: ' || v_j::text);

  -- E3 (lente): B baja de 13 a 11 y sigue cumpliendo su mínimo de 10: conserva los $80.
  v_a := pg_temp.prod(100, 1000);
  v_b := pg_temp.prod(100, 1000);
  INSERT INTO grupos_precio (nombre, sucursal_id, activo) VALUES ('ZZ t6d grupo E3', 1, true) RETURNING id INTO v_g;
  INSERT INTO grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id) VALUES (v_g, v_a, 1), (v_g, v_b, 1);
  INSERT INTO grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, activo, sucursal_id, min_productos_distintos)
  VALUES (v_g, 20, 80, true, 1, 2) RETURNING id INTO v_esc;
  INSERT INTO grupo_precio_escala_minimos (escala_id, producto_id, cantidad_minima_por_item, sucursal_id)
  VALUES (v_esc, v_b, 10, 1);
  v_ped := pg_temp.alta(v_enc, v_cli, jsonb_build_array(pg_temp.it(v_a, 10, 80), pg_temp.it(v_b, 13, 80)));
  -- La escala sube a $90: sólo la conservación deja los $80.
  UPDATE grupo_precio_escalas SET precio_unitario = 90 WHERE id = v_esc;
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 12, 80), pg_temp.it(v_b, 11, 80)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j),
                                      'V1/E3 · B 13 → 11 sigue cumpliendo su mínimo: A×12 + B×11 a $80 tenía que entrar: ' || v_j::text);

  -- E8 (lente): el mínimo (F ≥ 5) está sólo en una escala apagada; F baja de 10 a 9 y lo sigue cumpliendo.
  v_a := pg_temp.prod(100, 1000);
  v_b := pg_temp.prod(100, 1000);
  INSERT INTO grupos_precio (nombre, sucursal_id, activo) VALUES ('ZZ t6d grupo E8', 1, true) RETURNING id INTO v_g;
  INSERT INTO grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id) VALUES (v_g, v_a, 1), (v_g, v_b, 1);
  INSERT INTO grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, activo, sucursal_id, min_productos_distintos)
  VALUES (v_g, 50, 70, false, 1, 1) RETURNING id INTO v_esc;
  INSERT INTO grupo_precio_escala_minimos (escala_id, producto_id, cantidad_minima_por_item, sucursal_id)
  VALUES (v_esc, v_b, 5, 1);
  INSERT INTO grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, activo, sucursal_id, min_productos_distintos)
  VALUES (v_g, 20, 80, true, 1, 1) RETURNING id INTO v_esc;
  v_ped := pg_temp.alta(v_enc, v_cli, jsonb_build_array(pg_temp.it(v_a, 10, 80), pg_temp.it(v_b, 10, 80)));
  UPDATE grupo_precio_escalas SET precio_unitario = 90 WHERE id = v_esc;
  v_j := pg_temp.edit(v_enc, v_ped, jsonb_build_array(pg_temp.it(v_a, 11, 80), pg_temp.it(v_b, 9, 80)));
  v_fallas := v_fallas || pg_temp.chk(pg_temp.ok(v_j),
                                      'V1/E8 · mínimo sólo en una escala apagada y F 10 → 9 lo sigue cumpliendo: tenía que entrar: ' || v_j::text);

  -- ======================================================= V3 · venta-B3 ===
  v_a := pg_temp.prod(100, 1000);
  v_b := pg_temp.prod(250, 1000);
  v_ped := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.it(v_a, 4, 100), pg_temp.it(v_b, 1, 250)));
  UPDATE pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = now() WHERE id = v_ped;
  SELECT id INTO v_item FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_a;
  v_j := pg_temp.como(format('SELECT public.registrar_salvedad(%s, %s, 4, %L, %L, NULL, true, NULL)::text',
                             v_ped, v_item, 'cliente_rechaza', 'ensayo t6d'))::jsonb;
  v_sal := (v_j->>'salvedad_id')::bigint;
  IF v_sal IS NULL OR EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_a) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture V3: la salvedad no borró la línea: %', v_j;
  END IF;
  UPDATE productos SET precio = 0 WHERE id = v_a;
  v_t := pg_temp.err(format('SELECT public.anular_salvedad(%s, %L)::text', v_sal, 'ensayo t6d'));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'V3 · anular la salvedad con A sin lista tenía que entrar: ' || COALESCE(v_t, ''));
  v_fallas := v_fallas || pg_temp.chk(EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = v_ped AND producto_id = v_a
                                                AND cantidad = 4 AND precio_unitario = 100),
                                      'V3 · A tenía que volver ×4 a $100: ' || COALESCE(pg_temp.lin(v_ped), '-'));
  v_fallas := v_fallas || pg_temp.chk(COALESCE(current_setting('app.edicion_precio_conservado', true), '') = '',
                                      'V3 · la marca de precio conservado tenía que quedar vacía: '
                                      || COALESCE(current_setting('app.edicion_precio_conservado', true), ''));
  -- Regresión: un alta nueva de A sin lista sigue sin entrar.
  v_t := pg_temp.err(format('SELECT public.crear_pedido_completo(p_cliente_id => %s, p_total => 100, p_usuario_id => %L, p_items => %L::jsonb)::text',
                            v_cli, v_adm, jsonb_build_array(pg_temp.it(v_a, 1, 100))));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%pendiente de carga de precio%', 'V3 · un alta de A sin lista tenía que seguir rechazándose: ' || COALESCE(v_t, 'entró'));

  -- ======================================================= V4 · venta-B4 ===
  v_a := pg_temp.prod(100, 1000);
  v_ped := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.it(v_a, 2, 100)));
  BEGIN
    v_j := pg_temp.edit(v_adm, v_ped, jsonb_build_array(jsonb_build_object('producto_id', NULL, 'cantidad', 1, 'precio_unitario', 100),
                                                        pg_temp.it(v_a, 2, 100)));
    v_fallas := v_fallas || pg_temp.chk(NOT pg_temp.ok(v_j) AND v_j::text LIKE '%sin producto%',
                                        'V4 · el renglón sin producto tenía que rechazarse con su motivo: ' || v_j::text);
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    v_fallas := v_fallas || ('V4 · el renglón sin producto dio un error crudo: ' || SQLERRM);
  END;
  v_fallas := v_fallas || pg_temp.chk(pg_temp.lin(v_ped) = format('%s×2@100.00', v_a), 'V4 · el pedido no tenía que cambiar');

  -- ====================================================== C1 · cobros-B1 ===
  v_a := pg_temp.prod(100, 1000);
  v_ped  := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.it(v_a, 1, 100)));
  v_ped2 := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.it(v_a, 1, 100)));
  INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
  VALUES (v_cli, NULL, 50, 'efectivo', v_hoy, v_adm, 1) RETURNING id INTO v_pago;
  v_k := gen_random_uuid();
  v_t := pg_temp.err(format('SELECT public.imputar_credito_a_pedido(%s, %s, 10, %L)::text', v_pago, v_ped, v_k));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'C1 · imputar 10 a P1 tenía que entrar: ' || COALESCE(v_t, ''));
  v_t := pg_temp.err(format('SELECT public.imputar_credito_a_pedido(%s, %s, 10, %L)::text', v_pago, v_ped2, v_k));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '22023:%', 'C1 · la misma clave sobre otra boleta tenía que dar 22023: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('SELECT public.imputar_credito_a_pedido(%s, %s, 7, %L)::text', v_pago, v_ped, v_k));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '22023:%', 'C1 · la misma clave con otro monto tenía que dar 22023: ' || COALESCE(v_t, 'entró'));
  v_j := pg_temp.como(format('SELECT public.imputar_credito_a_pedido(%s, %s, 10, %L)::text', v_pago, v_ped, v_k))::jsonb;
  v_fallas := v_fallas || pg_temp.chk(COALESCE((v_j->>'idempotent_replay')::boolean, false), 'C1 · el mismo pedido tenía que ser replay: ' || v_j::text);
  v_fallas := v_fallas || pg_temp.chk((SELECT COALESCE(sum(monto), 0) FROM pagos WHERE pedido_id = v_ped2) = 0
                                      AND (SELECT COALESCE(sum(monto), 0) FROM pagos WHERE pedido_id = v_ped) = 10,
                                      'C1 · sólo P1 tenía que recibir 10');

  -- ====================================================== C2 · cobros-B2 ===
  v_a := pg_temp.prod(100, 1000);
  v_ped  := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.it(v_a, 1, 100)));
  v_ped2 := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.it(v_a, 1, 100)));
  v_t := pg_temp.err(format('SELECT public.registrar_pagos_pedido(%s, %L::jsonb, %L::date)::text',
                            v_ped2, jsonb_build_array(jsonb_build_object('forma_pago', 'transferencia', 'monto', 100)), v_hoy));
  IF v_t IS NOT NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · fixture C2: el cobro de b no entró: %', v_t;
  END IF;
  SELECT forma_pago INTO v_fp FROM pedidos WHERE id = v_ped2;
  v_t := pg_temp.err(format('SELECT public.marcar_entrega_y_pago_masivo(ARRAY[%s, %s]::bigint[], %L, %L, %L::date)::text',
                            v_ped, v_ped2, v_tra, 'cheque', v_hoy));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'C2 · el lote tenía que entrar: ' || COALESCE(v_t, ''));
  v_fallas := v_fallas || pg_temp.chk(v_fp IS DISTINCT FROM 'cheque', 'C2 · fixture: b no tenía que estar ya en cheque');
  v_fallas := v_fallas || pg_temp.chk((SELECT forma_pago FROM pedidos WHERE id = v_ped) = 'cheque',
                                      'C2 · a tenía que quedar en cheque');
  v_fallas := v_fallas || pg_temp.chk((SELECT forma_pago FROM pedidos WHERE id = v_ped2) IS NOT DISTINCT FROM v_fp,
                                      format('C2 · b tenía que quedar en %s y quedó en %s', v_fp, (SELECT forma_pago FROM pedidos WHERE id = v_ped2)));
  v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM pedidos WHERE id IN (v_ped, v_ped2) AND estado = 'entregado') = 2,
                                      'C2 · las dos tenían que quedar entregadas');

  -- ====================================================== C4 · cobros-B4 ===
  v_t := pg_temp.err(format('SELECT public.registrar_pago_cliente_fifo(%s, 100, %L)::text', v_cli2, 'efectivo'));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%Cliente no encontrado%',
                                      'C4 · el FIFO con un cliente de otra sucursal tenía que decir «Cliente no encontrado»: ' || COALESCE(v_t, 'entró'));

  -- ====================================================== C5 · cobros-B5 ===
  v_a := pg_temp.prod(100, 1000);
  v_ped := pg_temp.alta(v_adm, v_cli, jsonb_build_array(pg_temp.it(v_a, 1, 100)));
  v_t := pg_temp.err(format('SELECT public.registrar_pagos_pedido(%s, %L::jsonb, %L::date)::text',
                            v_ped, jsonb_build_array(jsonb_build_object('forma_pago', 'efectivo', 'monto', 1234567890)), v_hoy));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%supera lo que falta%' AND v_t LIKE '%1234567890.00%' AND v_t NOT LIKE '%##%',
                                      'C5 · el aviso tenía que mostrar 1234567890.00: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(format('SELECT public.registrar_pagos_pedido(%s, %L::jsonb, %L::date)::text',
                            v_ped, jsonb_build_array(jsonb_build_object('forma_pago', 'efectivo', 'monto', 100.01)), v_hoy));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%El pago (100.01) supera lo que falta cobrar del pedido #' || v_ped || ' (100.00)%',
                                      'C5 · el aviso de siempre tenía que seguir igual: ' || COALESCE(v_t, 'entró'));

  -- ====================================================== C6 · cobros-B6 ===
  v_cli := pg_temp.cli(1);
  v_k := gen_random_uuid();
  v_t := pg_temp.err(format('SELECT public.registrar_pago_cliente_fifo(%s, 5::numeric, %L, %L::date, NULL, NULL, %L)::text',
                            v_cli, 'efectivo', v_hoy, v_k));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'C6 · el FIFO de 5 tenía que entrar: ' || COALESCE(v_t, ''));
  v_t := pg_temp.err(format('SELECT public.registrar_pago_cliente_fifo(%s, 5.00::numeric, %L, %L::date, NULL, NULL, %L)::text',
                            v_cli, 'efectivo', v_hoy, v_k));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'C6 · el reintento con 5.00 tenía que ser replay: ' || COALESCE(v_t, ''));
  v_t := pg_temp.err(format('SELECT public.registrar_pago_cliente_fifo(%s, 6::numeric, %L, %L::date, NULL, NULL, %L)::text',
                            v_cli, 'efectivo', v_hoy, v_k));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '22023:%', 'C6 · la misma clave con 6 tenía que dar 22023: ' || COALESCE(v_t, 'entró'));
  v_fallas := v_fallas || pg_temp.chk((SELECT COALESCE(sum(monto), 0) FROM pagos WHERE cliente_id = v_cli) = 5,
                                      'C6 · el cliente tenía que tener 5 cobrados');

  -- ===================================================== S3 · stock-STK-3 ===
  v_a := pg_temp.prod(100, 0);
  UPDATE productos SET stock = 40 WHERE id = v_a;
  SELECT count(*) INTO v_n0 FROM stock_historico WHERE producto_id = v_a;
  v_j := pg_temp.como(format('SELECT public.crear_lote_manual(%s, %L::date, 15)::text', v_a, v_hoy + 90))::jsonb;
  v_lote := (v_j->>'lote_id')::bigint;
  v_j := pg_temp.como(format('SELECT public.crear_lote_manual(%s, %L::date, 5)::text', v_a, v_hoy + 90))::jsonb;
  SELECT count(*) INTO v_n FROM stock_historico WHERE producto_id = v_a;
  v_fallas := v_fallas || pg_temp.chk(v_n - v_n0 = 2, format('S3 · etiquetar dos veces tenía que dejar 2 filas en el ledger y dejó %s', v_n - v_n0));
  v_fallas := v_fallas || pg_temp.chk(NOT EXISTS (
                SELECT 1 FROM (SELECT * FROM stock_historico WHERE producto_id = v_a ORDER BY id DESC LIMIT v_n - v_n0) h
                 WHERE h.stock_anterior <> 40 OR h.stock_nuevo <> 40 OR h.referencia_tipo IS DISTINCT FROM 'producto_lotes'
                    OR h.referencia_id IS DISTINCT FROM v_lote OR h.usuario_id IS DISTINCT FROM v_adm)
              AND v_n > v_n0,
              'S3 · las filas tenían que ser 40 → 40, con el lote y quien lo hizo');
  v_fallas := v_fallas || pg_temp.chk((SELECT cantidad_restante FROM producto_lotes WHERE id = v_lote) = 20
                                      AND (SELECT stock FROM productos WHERE id = v_a) = 40,
                                      'S3 · el lote tenía que quedar con 20 y el stock en 40');
  v_fallas := v_fallas || pg_temp.chk((SELECT stock_nuevo FROM stock_historico WHERE producto_id = v_a ORDER BY id DESC LIMIT 1) = 40,
                                      'S3 · STK-A: la última fila del ledger tenía que ser el stock');

  -- ================================================ G1-G4 · gastos/personal ===
  INSERT INTO gasto_rubros (nombre, grupo) VALUES ('ZZ t6d ' || gen_random_uuid(), 'otros') RETURNING id INTO v_rubro;
  PERFORM set_config('et6d.rubro', v_rubro::text, true);
  CREATE FUNCTION pg_temp.gg(p jsonb) RETURNS text LANGUAGE sql AS $f$
    SELECT format('SELECT public.guardar_gasto(p_gasto => %L::jsonb)::text',
      jsonb_build_object('sucursal_id', 1, 'compartido', false, 'fecha', public._tablero_hoy(),
                         'rubro_id', current_setting('et6d.rubro')::bigint, 'monto_total', 1210,
                         'comprobante', 'ninguno', 'repartir_meses', 1, 'origen_pago', 'oficina',
                         'observacion', 'ensayo t6d') || p);
  $f$;

  -- G1 · reportes-R1
  v_t := pg_temp.err(pg_temp.gg(jsonb_build_object('monto_total', 1000000000000)));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%no puede pasar de%', 'G1 · un gasto de un billón tenía que decir el tope: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(pg_temp.gg(jsonb_build_object('monto_total', 0)));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '%mayor a cero%', 'G1 · un gasto de 0 tenía que seguir diciendo «mayor a cero»: ' || COALESCE(v_t, 'entró'));
  v_t := pg_temp.err(pg_temp.gg(jsonb_build_object('monto_total', 999999999999.99)));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'G1 · el tope exacto tenía que entrar: ' || COALESCE(v_t, ''));

  -- G2 · reportes-R2
  INSERT INTO vehiculos (sucursal_id, patente, descripcion, creado_por) VALUES (1, 'ZT' || lpad(floor(random() * 1e6)::int::text, 6, '0'), 'ensayo t6d', v_adm)
  RETURNING id INTO v_veh;
  INSERT INTO empleados (sucursal_id, nombre, puesto, cuil, fecha_ingreso, telefono, usuario_id, cliente_id, vehiculo_id, creado_por)
  VALUES (1, 'ZZ t6d empleado', 'ayudante', '20123456789', v_hoy - 30, '381-000', v_otro, v_cli, v_veh, v_adm)
  RETURNING id INTO v_emp;
  v_t := pg_temp.err(format('SELECT public.guardar_empleado(%L::jsonb)::text',
                            jsonb_build_object('id', v_emp, 'nombre', 'ZZ t6d empleado (editado)', 'puesto', 'ayudante')));
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL, 'G2 · la edición tenía que entrar: ' || COALESCE(v_t, ''));
  SELECT * INTO r FROM empleados WHERE id = v_emp;
  v_fallas := v_fallas || pg_temp.chk(r.nombre = 'ZZ t6d empleado (editado)' AND r.cuil = '20123456789' AND r.fecha_ingreso = v_hoy - 30
                                      AND r.telefono = '381-000' AND r.usuario_id = v_otro AND r.cliente_id = v_cli
                                      AND r.vehiculo_id = v_veh,
                                      format('G2 · lo que no vino tenía que quedar: cuil=%s ingreso=%s tel=%s usuario=%s cliente=%s vehiculo=%s',
                                             r.cuil, r.fecha_ingreso, r.telefono, r.usuario_id, r.cliente_id, r.vehiculo_id));
  v_t := pg_temp.err(format('SELECT public.guardar_empleado(%L::jsonb)::text',
                            jsonb_build_object('id', v_emp, 'nombre', 'ZZ t6d empleado', 'puesto', 'ayudante',
                                               'telefono', NULL, 'vehiculo_id', NULL, 'cuil', NULL)));
  SELECT * INTO r FROM empleados WHERE id = v_emp;
  v_fallas := v_fallas || pg_temp.chk(v_t IS NULL AND r.telefono IS NULL AND r.vehiculo_id IS NULL AND r.cuil IS NULL
                                      AND r.usuario_id = v_otro AND r.cliente_id = v_cli AND r.fecha_ingreso = v_hoy - 30,
                                      format('G2 · un null explícito borra sólo lo suyo: %s · tel=%s veh=%s cuil=%s usuario=%s cliente=%s ingreso=%s',
                                             COALESCE(v_t, 'ok'), r.telefono, r.vehiculo_id, r.cuil, r.usuario_id, r.cliente_id, r.fecha_ingreso));

  -- G3 · reportes-R3, gastos
  v_k := gen_random_uuid();
  SELECT count(*) INTO v_n0 FROM gastos WHERE rubro_id = v_rubro;
  v_id1 := pg_temp.como(pg_temp.gg(jsonb_build_object('monto_total', 777, 'clave', v_k)))::bigint;
  v_id2 := pg_temp.como(pg_temp.gg(jsonb_build_object('monto_total', 777, 'clave', v_k)))::bigint;
  SELECT count(*) INTO v_n FROM gastos WHERE rubro_id = v_rubro AND monto_total = 777;
  v_fallas := v_fallas || pg_temp.chk(v_id1 = v_id2 AND v_n = 1,
                                      format('G3 · la misma clave dos veces tenía que dar un solo gasto: ids %s y %s, %s gastos', v_id1, v_id2, v_n));
  v_t := pg_temp.err(pg_temp.gg(jsonb_build_object('monto_total', 778, 'clave', v_k)));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '22023:%', 'G3 · la misma clave con otro monto tenía que dar 22023: ' || COALESCE(v_t, 'entró'));
  PERFORM pg_temp.como(pg_temp.gg(jsonb_build_object('monto_total', 779)));
  PERFORM pg_temp.como(pg_temp.gg(jsonb_build_object('monto_total', 779)));
  v_fallas := v_fallas || pg_temp.chk((SELECT count(*) FROM gastos WHERE rubro_id = v_rubro AND monto_total = 779) = 2,
                                      'G3 · sin clave (un PWA de antes) cada llamada carga un gasto');

  -- G4 · reportes-R3, empleados
  v_j := jsonb_build_object('nombre', 'ZZ t6d alta', 'puesto', 'ayudante', 'sucursal_id', 1,
                            'arreglo', jsonb_build_object('vigente_desde', v_hoy, 'sueldo', 1000, 'frecuencia', 'mensual'),
                            'clave', gen_random_uuid());
  v_id1 := pg_temp.como(format('SELECT public.guardar_empleado(%L::jsonb)::text', v_j))::bigint;
  v_id2 := pg_temp.como(format('SELECT public.guardar_empleado(%L::jsonb)::text', v_j))::bigint;
  v_fallas := v_fallas || pg_temp.chk(v_id1 = v_id2 AND (SELECT count(*) FROM empleados WHERE nombre = 'ZZ t6d alta') = 1
                                      AND (SELECT count(*) FROM empleado_arreglos WHERE empleado_id = v_id1) = 1,
                                      format('G4 · la misma clave dos veces tenía que dar un solo empleado: ids %s y %s', v_id1, v_id2));
  v_t := pg_temp.err(format('SELECT public.guardar_empleado(%L::jsonb)::text', v_j || jsonb_build_object('clave', v_k)));
  v_fallas := v_fallas || pg_temp.chk(v_t LIKE '22023:%', 'G4 · la clave de un gasto no sirve para un empleado: ' || COALESCE(v_t, 'entró'));

  -- ------------------------------------------------------------- veredicto ---
  SET CONSTRAINTS ALL IMMEDIATE;
  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK · tanda 6, tarjeta D (V1 V3 V4 C1 C2 C4 C5 C6 S3 G1 G2 G3 G4)';
  END IF;
  RAISE EXCEPTION E'ENSAYO FALLÓ · %', array_to_string(v_fallas, E'\n  · ');
END
$ensayo$;
