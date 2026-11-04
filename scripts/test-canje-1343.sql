-- Ensayo de la migración "el canje se cierra con el cambio aplicado y sobre un día
-- abierto" (#1343). Todo con la sesión de cada rol, como PostgREST:
--   K1 crear_pedido_cambio_en_ruta rechaza a un cliente dado de baja;
--   K2 y lo crea para uno activo (camino feliz), pendiente y sin aplicar;
--   P1 el PATCH a 'entregado' del encargado sin aplicar el cambio se rechaza;
--   P2 el del admin también;
--   P3 el del server (postgres) también: el trigger corre para todos;
--   P4 y el del chofer del canje, también;
--   A1 aplicar_cambio_de_parada sobre un día controlado se rechaza (42501) sin mover
--      stock ni marcar el cambio;
--   A2 con un chofer que no existe en la sucursal, se rechaza (42501);
--   A5 con alguien de la sucursal que no actúa como chofer (el encargado), se rechaza
--      (42501) sin mover stock: la entrega daría 23514 en pedidos_entrega_con_chofer;
--   A6 si el canje ya tiene chofer y el front manda otro (pantalla vieja), 40001 sin
--      mover stock (sólo si la sucursal tiene dos choferes);
--   A7 sobre un pedido que no es canje, se rechaza;
--   A8 sobre un canje cancelado, se rechaza;
--   A9 desde otra sucursal activa, se rechaza (42501) (sólo si el admin tiene otra);
--   A3 sobre un día libre aplica: mueve el stock y marca aplicado_at;
--   A4 la segunda llamada devuelve el mismo cambio sin mover el stock;
--   E1 después, el PATCH a 'entregado' entra;
--   E2 revertir y volver a entregar un canje aplicado sigue entrando;
--   V1 la llamada vieja (sólo p_pedido_id, un bundle viejo) sigue aplicando;
--   L1 el orden: la rendición (try, compartida) antes del pedido, y el pedido antes del
--      cambio. El 40001 del try y el del chofer que cambia entre la lectura y el lock no
--      se pueden provocar desde una sola sesión: los mide el arnés.
--
-- Corre contra prod SIN dejar rastro: un único DO que termina SIEMPRE en RAISE
-- EXCEPTION, así que todo lo que escriba se deshace. Las fechas de entrega van en 2099
-- para no pisar ningún control real.
--
--   'ENSAYO OK …'    → todas las aserciones pasaron (dice cuántas y cuáles se saltearon).
--   'ENSAYO FALLÓ …' → lista de lo que no se cumplió.
--
-- Antes de la migración tiene que FALLAR en K1, P1–P4, A1, A2, A5–A9 y L1 (y A3, A4 y V1
-- en cascada: la firma de tres parámetros no existe); después, pasar. Medido en una base
-- local con el schema de prod (huella cero).
--
--   psql "$DATABASE_URL" -f scripts/test-canje-1343.sql

CREATE OR REPLACE FUNCTION pg_temp.t5_como(p_uid uuid, p_suc bigint) RETURNS void
LANGUAGE sql AS $fn$
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true),
         set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$fn$;

-- Corre p_sql como authenticated con la sesión de p_uid en la sucursal p_suc.
-- 'ok <valor>' (un UPDATE con RETURNING que no tocó filas da 'ok -'), o 'SQLSTATE mensaje'.
CREATE OR REPLACE FUNCTION pg_temp.t5_sql(p_uid uuid, p_suc bigint, p_sql text,
                                          p_a bigint DEFAULT NULL, p_b uuid DEFAULT NULL, p_c date DEFAULT NULL)
RETURNS text LANGUAGE plpgsql AS $fn$
DECLARE
  v_n bigint;
  v   text;
BEGIN
  PERFORM pg_temp.t5_como(p_uid, p_suc);
  EXECUTE 'SET LOCAL ROLE authenticated';
  BEGIN
    EXECUTE p_sql INTO v_n USING p_a, p_b, p_c;
    v := 'ok ' || COALESCE(v_n::text, '-');
  EXCEPTION WHEN OTHERS THEN v := SQLSTATE || ' ' || SQLERRM;
  END;
  EXECUTE 'RESET ROLE';
  RETURN v;
END
$fn$;

DO $ensayo$
DECLARE
  v_fallas  text[] := '{}';
  v_salteo  text[] := '{}';
  v_hechas  int := 0;

  v_suc     bigint;
  v_suc2    bigint; -- otra sucursal del admin, si tiene
  v_chofer  uuid;   -- reparte en v_suc, no es admin ni encargado
  v_chofer2 uuid;   -- otro chofer de v_suc, si hay
  v_enc     uuid;   -- encargado (o admin si no hay) de v_suc
  v_admin   uuid;   -- admin de v_suc
  v_cli     bigint; -- cliente activo de v_suc
  v_baja    bigint; -- cliente dado de baja de v_suc
  v_dev     bigint; -- producto que devuelve el cliente
  v_ent     bigint; -- producto que se le entrega
  v_sdev    int;
  v_sent    int;
  v_ped     bigint; -- canje sin chofer
  v_ped2    bigint; -- canje para la llamada vieja
  v_ped3    bigint; -- canje con chofer
  v_ped4    bigint; -- canje cancelado
  v_comun   bigint; -- pedido común con un detalle de cambio colgado
  v_cambio  bigint;
  v_res     text;
  v_src     text;
  v_caso    record;
  c_crear   CONSTANT text := $q$SELECT public.crear_pedido_cambio_en_ruta($1::int, %s, 1, %s, 1, 'ensayo #1343', 'erroneo')$q$;
  c_aplicar CONSTANT text := $q$SELECT public.aplicar_cambio_de_parada($1, $2, $3)$q$;
  c_entrega CONSTANT text := $q$UPDATE public.pedidos SET estado = 'entregado', fecha_entrega = ($3::text || ' 12:00-03')::timestamptz, transportista_id = COALESCE($2, transportista_id) WHERE id = $1 RETURNING id$q$;
BEGIN
  -- ---------------------------------------------------------------- datos ---
  SELECT pf.id, us.sucursal_id INTO v_chofer, v_suc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE COALESCE(pf.activo, true) AND pf.rol NOT IN ('admin', 'encargado')
     AND public._actua_como_transportista(pf.id, us.sucursal_id)
     AND EXISTS (SELECT 1 FROM perfiles p3 JOIN usuario_sucursales u3 ON u3.usuario_id = p3.id
                  WHERE u3.sucursal_id = us.sucursal_id AND p3.rol = 'admin' AND COALESCE(p3.activo, true))
   ORDER BY us.sucursal_id, pf.id LIMIT 1;
  IF v_chofer IS NULL THEN
    RAISE EXCEPTION 'ENSAYO SIN DATOS: no hay una sucursal con chofer (no staff) y admin';
  END IF;
  SELECT pf.id INTO v_chofer2
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE us.sucursal_id = v_suc AND pf.id <> v_chofer AND COALESCE(pf.activo, true)
     AND pf.rol NOT IN ('admin', 'encargado') AND public._actua_como_transportista(pf.id, v_suc)
   ORDER BY pf.id LIMIT 1;

  SELECT pf.id INTO v_admin
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'admin' AND COALESCE(pf.activo, true)
   ORDER BY pf.id LIMIT 1;
  SELECT pf.id INTO v_enc
    FROM perfiles pf JOIN usuario_sucursales us ON us.usuario_id = pf.id
   WHERE us.sucursal_id = v_suc AND pf.rol = 'encargado' AND COALESCE(pf.activo, true)
   ORDER BY pf.id LIMIT 1;
  v_enc := COALESCE(v_enc, v_admin);
  SELECT us.sucursal_id INTO v_suc2 FROM usuario_sucursales us
   WHERE us.usuario_id = v_admin AND us.sucursal_id <> v_suc ORDER BY us.sucursal_id LIMIT 1;

  SELECT c.id INTO v_cli FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND NOT COALESCE(c.reservado_admin, false)
   ORDER BY c.id LIMIT 1;
  SELECT c.id INTO v_baja FROM clientes c
   WHERE c.sucursal_id = v_suc AND NOT c.activo ORDER BY c.id LIMIT 1;
  IF v_baja IS NULL THEN
    SELECT c.id INTO v_baja FROM clientes c
     WHERE c.sucursal_id = v_suc AND c.activo AND c.id <> v_cli ORDER BY c.id DESC LIMIT 1;
    UPDATE clientes SET activo = false WHERE id = v_baja;
  END IF;

  SELECT id INTO v_dev FROM productos
   WHERE sucursal_id = v_suc AND activo AND stock >= 3 ORDER BY id LIMIT 1;
  SELECT id INTO v_ent FROM productos
   WHERE sucursal_id = v_suc AND activo AND stock >= 3 AND id <> v_dev ORDER BY id LIMIT 1;
  IF v_dev IS NULL OR v_ent IS NULL THEN
    RAISE EXCEPTION 'ENSAYO SIN DATOS: no hay dos productos con stock en la sucursal %', v_suc;
  END IF;

  RAISE NOTICE 'datos: sucursal % (otra: %) · chofer % (otro: %) · encargado % · admin % · cliente % · baja % · productos %/%',
    v_suc, v_suc2, v_chofer, v_chofer2, v_enc, v_admin, v_cli, v_baja, v_dev, v_ent;

  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, estado, created_at, controlada_at, controlada_por)
  VALUES (DATE '2099-01-05', v_chofer, v_suc, 'confirmada', now(), now(), v_admin);

  -- ------------------------------------------------- K · crear en ruta ---
  v_res := pg_temp.t5_sql(v_admin, v_suc, format(c_crear, v_dev, v_ent), v_baja);
  v_hechas := v_hechas + 1;
  IF v_res NOT LIKE 'P0001%dado de baja%' THEN
    v_fallas := v_fallas || ('K1 el canje en ruta nació contra un cliente dado de baja: ' || v_res);
  END IF;

  v_res := pg_temp.t5_sql(v_admin, v_suc, format(c_crear, v_dev, v_ent), v_cli);
  v_hechas := v_hechas + 1;
  v_ped := CASE WHEN v_res LIKE 'ok %' THEN substr(v_res, 4)::bigint END;
  IF v_ped IS NULL OR NOT EXISTS (SELECT 1 FROM pedidos p JOIN recorrido_cambios rc ON rc.pedido_id = p.id
                                   WHERE p.id = v_ped AND p.canal = 'cambio' AND p.estado = 'pendiente'
                                     AND rc.aplicado_at IS NULL) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ en K2 (no se pudo crear el canje para un cliente activo): %', v_res;
  END IF;
  v_ped2  := substr(pg_temp.t5_sql(v_admin, v_suc, format(c_crear, v_dev, v_ent), v_cli), 4)::bigint;
  v_ped3  := substr(pg_temp.t5_sql(v_admin, v_suc, format(c_crear, v_dev, v_ent), v_cli), 4)::bigint;
  UPDATE pedidos SET estado = 'asignado', transportista_id = v_chofer WHERE id = v_ped3;

  -- ------------------------------------------ P · cerrar sin aplicar ---
  FOR v_caso IN
    SELECT * FROM (VALUES ('P1 el encargado', v_enc, v_ped, v_chofer),
                          ('P2 el admin', v_admin, v_ped, v_chofer),
                          ('P4 el chofer del canje', v_chofer, v_ped3, NULL::uuid)) AS t(nombre, actor, pedido, chofer)
  LOOP
    v_res := pg_temp.t5_sql(v_caso.actor, v_suc, c_entrega, v_caso.pedido, v_caso.chofer, DATE '2099-02-10');
    v_hechas := v_hechas + 1;
    IF v_res NOT LIKE 'P0001%sin aplicar el cambio%' THEN
      v_fallas := v_fallas || format('%s cerró el canje sin aplicar el cambio (%s)', v_caso.nombre, v_res);
    END IF;
  END LOOP;

  BEGIN
    UPDATE pedidos SET estado = 'entregado', fecha_entrega = '2099-02-10 12:00-03', transportista_id = v_chofer
     WHERE id = v_ped;
    v_res := 'ok';
  EXCEPTION WHEN OTHERS THEN v_res := SQLSTATE || ' ' || SQLERRM;
  END;
  v_hechas := v_hechas + 1;
  IF v_res NOT LIKE 'P0001%sin aplicar el cambio%' THEN
    v_fallas := v_fallas || ('P3 el server cerró el canje sin aplicar el cambio: ' || v_res);
  END IF;

  -- ----------------------------------------- A · aplicar, rechazos ---
  SELECT stock INTO v_sdev FROM productos WHERE id = v_dev;
  SELECT stock INTO v_sent FROM productos WHERE id = v_ent;

  FOR v_caso IN
    SELECT * FROM (VALUES
      ('A1 aplicó el cambio sobre un día controlado', v_admin, v_suc, v_ped, v_chofer, DATE '2099-01-05', '42501%ya fue controlada%'),
      ('A2 aceptó un chofer que no existe en la sucursal', v_admin, v_suc, v_ped, '00000000-0000-0000-0000-000000001343'::uuid, DATE '2099-02-10', '42501%no es chofer de esta sucursal%'),
      ('A5 aceptó como chofer a alguien que no reparte (el encargado)', v_admin, v_suc, v_ped, v_enc, DATE '2099-02-10', '42501%no es chofer de esta sucursal%'),
      ('A8 aplicó el cambio de un canje cancelado', v_admin, v_suc, NULL::bigint, v_chofer, DATE '2099-02-10', 'P0001%cancelado%')
    ) AS t(nombre, actor, suc, pedido, chofer, dia, espera)
  LOOP
    IF v_caso.pedido IS NULL THEN
      -- A8: un canje propio, cancelado por el server.
      v_ped4 := substr(pg_temp.t5_sql(v_admin, v_suc, format(c_crear, v_dev, v_ent), v_cli), 4)::bigint;
      UPDATE pedidos SET estado = 'cancelado', motivo_cancelacion = 'ensayo #1343' WHERE id = v_ped4;
      v_res := pg_temp.t5_sql(v_caso.actor, v_caso.suc, c_aplicar, v_ped4, v_caso.chofer, v_caso.dia);
    ELSE
      v_res := pg_temp.t5_sql(v_caso.actor, v_caso.suc, c_aplicar, v_caso.pedido, v_caso.chofer, v_caso.dia);
    END IF;
    v_hechas := v_hechas + 1;
    IF v_res NOT LIKE v_caso.espera
       OR (SELECT stock FROM productos WHERE id = v_dev) <> v_sdev
       OR (SELECT stock FROM productos WHERE id = v_ent) <> v_sent
       OR EXISTS (SELECT 1 FROM recorrido_cambios WHERE pedido_id IN (v_ped, v_ped3, v_ped4) AND aplicado_at IS NOT NULL) THEN
      v_fallas := v_fallas || format('%s (%s)', v_caso.nombre, v_res);
    END IF;
  END LOOP;

  -- A6 · el canje tiene chofer y el front manda otro: pantalla vieja.
  IF v_chofer2 IS NOT NULL THEN
    v_res := pg_temp.t5_sql(v_admin, v_suc, c_aplicar, v_ped3, v_chofer2, DATE '2099-02-10');
    v_hechas := v_hechas + 1;
    IF v_res NOT LIKE '40001%otro transportista%'
       OR (SELECT stock FROM productos WHERE id = v_ent) <> v_sent THEN
      v_fallas := v_fallas || ('A6 aplicó con un chofer distinto del del canje: ' || v_res);
    END IF;
  ELSE
    v_salteo := v_salteo || text 'A6 (la sucursal tiene un solo chofer)';
  END IF;

  -- A7 · un pedido común con un detalle de cambio colgado (como el server).
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, creado_por, fecha, total, total_neto, total_iva,
                       total_real, tipo_factura, estado, stock_descontado, forma_pago, estado_pago)
  VALUES (v_cli, v_suc, v_admin, v_admin, public._tablero_hoy(), 100, 100, 0, 100, 'ZZ', 'pendiente', true, 'efectivo', 'pendiente')
  RETURNING id INTO v_comun;
  INSERT INTO recorrido_cambios (pedido_id, cliente_id, producto_devuelto_id, producto_devuelto_nombre, cantidad_devuelta,
                                 producto_entregado_id, producto_entregado_nombre, cantidad_entregada, sucursal_id, motivo)
  VALUES (v_comun, v_cli, v_dev, 'x', 1, v_ent, 'y', 1, v_suc, 'erroneo');
  v_res := pg_temp.t5_sql(v_admin, v_suc, c_aplicar, v_comun, NULL, DATE '2099-02-10');
  v_hechas := v_hechas + 1;
  IF v_res NOT LIKE 'P0001%no es un canje%' OR (SELECT stock FROM productos WHERE id = v_ent) <> v_sent THEN
    v_fallas := v_fallas || ('A7 aplicó un cambio sobre un pedido que no es canje: ' || v_res);
  END IF;

  -- A9 · desde otra sucursal activa del admin.
  IF v_suc2 IS NOT NULL THEN
    v_res := pg_temp.t5_sql(v_admin, v_suc2, c_aplicar, v_ped, v_chofer, DATE '2099-02-10');
    v_hechas := v_hechas + 1;
    IF v_res NOT LIKE '42501%no es de la sucursal activa%' OR (SELECT stock FROM productos WHERE id = v_ent) <> v_sent THEN
      v_fallas := v_fallas || ('A9 aplicó un canje desde otra sucursal activa: ' || v_res);
    END IF;
  ELSE
    v_salteo := v_salteo || text 'A9 (el admin tiene una sola sucursal)';
  END IF;

  -- ------------------------------------------- A · aplicar, camino feliz ---
  v_res := pg_temp.t5_sql(v_admin, v_suc, c_aplicar, v_ped, v_chofer, DATE '2099-02-10');
  v_hechas := v_hechas + 1;
  v_cambio := CASE WHEN v_res LIKE 'ok %' THEN substr(v_res, 4)::bigint END;
  IF v_cambio IS NULL
     OR (SELECT stock FROM productos WHERE id = v_dev) <> v_sdev + 1
     OR (SELECT stock FROM productos WHERE id = v_ent) <> v_sent - 1
     OR (SELECT cambio_producto_id FROM recorrido_cambios WHERE pedido_id = v_ped AND aplicado_at IS NOT NULL) IS DISTINCT FROM v_cambio THEN
    v_fallas := v_fallas || format('A3 no aplicó el cambio en un día libre (%s, stock %s/%s)', v_res,
      (SELECT stock FROM productos WHERE id = v_dev), (SELECT stock FROM productos WHERE id = v_ent));
  END IF;

  v_res := pg_temp.t5_sql(v_admin, v_suc, c_aplicar, v_ped, v_chofer, DATE '2099-02-10');
  v_hechas := v_hechas + 1;
  IF v_res IS DISTINCT FROM ('ok ' || v_cambio) OR (SELECT stock FROM productos WHERE id = v_ent) <> v_sent - 1 THEN
    v_fallas := v_fallas || ('A4 la segunda llamada volvió a aplicar el cambio: ' || v_res);
  END IF;

  -- ---------------------------------------------------- E · entregar ---
  v_res := pg_temp.t5_sql(v_enc, v_suc, c_entrega, v_ped, v_chofer, DATE '2099-02-10');
  v_hechas := v_hechas + 1;
  IF v_res <> 'ok ' || v_ped THEN v_fallas := v_fallas || ('E1 el canje aplicado no se pudo entregar: ' || v_res); END IF;

  v_res := pg_temp.t5_sql(v_enc, v_suc,
    $q$UPDATE public.pedidos SET estado = 'asignado', fecha_entrega = NULL WHERE id = $1 RETURNING id$q$, v_ped);
  IF v_res = 'ok ' || v_ped THEN
    v_res := pg_temp.t5_sql(v_enc, v_suc, c_entrega, v_ped, NULL, DATE '2099-02-11');
  END IF;
  v_hechas := v_hechas + 1;
  IF v_res <> 'ok ' || v_ped THEN v_fallas := v_fallas || ('E2 revertido, el canje aplicado no se pudo volver a entregar: ' || v_res); END IF;

  -- --------------------------------------------- V · la llamada vieja ---
  v_res := pg_temp.t5_sql(v_admin, v_suc, $q$SELECT public.aplicar_cambio_de_parada(p_pedido_id => $1)$q$, v_ped2);
  v_hechas := v_hechas + 1;
  IF v_res NOT LIKE 'ok %' OR v_res = 'ok -'
     OR (SELECT stock FROM productos WHERE id = v_ent) <> v_sent - 2 THEN
    v_fallas := v_fallas || ('V1 la llamada con sólo p_pedido_id no aplicó el cambio: ' || v_res);
  END IF;

  -- ------------------------------------------------------- L · orden ---
  SELECT prosrc INTO v_src FROM pg_proc
   WHERE oid = to_regprocedure('public.aplicar_cambio_de_parada(bigint,uuid,date)');
  v_hechas := v_hechas + 2;
  IF v_src IS NULL
     OR position('pg_try_advisory_xact_lock_shared' in v_src) = 0
     OR position('pg_advisory_xact_lock(' in v_src) > 0
     OR position('pg_try_advisory_xact_lock_shared' in v_src) > position('FOR UPDATE' in v_src)
     OR position('FOR UPDATE' in v_src) > position('_aplicar_cambio_producto' in v_src) THEN
    v_fallas := v_fallas || text 'L1 aplicar_cambio_de_parada no toma la rendición (try) antes del pedido, o el pedido después del cambio';
  END IF;
  IF to_regprocedure('public.aplicar_cambio_de_parada(bigint)') IS NOT NULL THEN
    v_fallas := v_fallas || text 'L1 sigue viva la firma vieja (bigint): dos sobrecargas dan PGRST203';
  END IF;

  -- ---------------------------------------------------------- resultado ---
  IF array_length(v_fallas, 1) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% de %):\n%', array_length(v_fallas, 1), v_hechas, array_to_string(v_fallas, E'\n');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK: % aserciones (#1343 K1, K2, P1–P4, A1–A9, E1, E2, V1, L1 ×2)%', v_hechas,
    CASE WHEN array_length(v_salteo, 1) > 0 THEN '; salteadas: ' || array_to_string(v_salteo, ', ') ELSE '' END;
END
$ensayo$;
