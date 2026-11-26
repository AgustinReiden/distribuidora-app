-- Ensayo de la limpieza de la migración de las salvedades de la oficina (#1700, Part of #1690).
--
-- La migración cierra sólo las pendientes que midió y revisó el dueño (25/11 y 26/11): las 86 que cargó un
-- admin o un encargado, y las 7 de preventistas cargadas del 10/10 al 17/10 (día argentino). Una
-- pendiente de la calle fuera de eso (la de un chofer cargada hoy, antes de aplicar) queda
-- pendiente. Si los conteos no dan 86 y 7, aborta; sin ninguna pendiente no hace nada.
--
-- El bloque de la migración es un DO, que no se puede llamar: acá va el MISMO cuerpo como
-- pg_temp.limpieza_1700(). Que sea el mismo, byte a byte, lo fija
-- src/test/limpiezaSalvedades1700.contract.test.ts. Este ensayo no depende de que la migración esté
-- aplicada: arma sus propias pendientes (por INSERT directo, como el server) y las deja como
-- estaban.
--
-- Casos:
--   K1 · 85 del admin + 1 del encargado + 7 de un preventista en el rango (con los dos bordes del
--        día argentino), y afuera: una del chofer cargada hoy, una del preventista del 09/10 23:30
--        (ya 10/10 en UTC) y una del 18/10 00:30. Cierra 93 con su nota, su resuelto_por y su fila
--        de historial; las tres de afuera quedan pendientes.
--   K2 · 85 de la oficina (falta una): aborta en la premisa y no cierra nada.
--   K3 · 8 de la calle en el rango (sobra una): aborta en la premisa.
--   K4 · sin ninguna pendiente: no hace nada y no aborta.
--   K5 · sólo pendientes que no son de la limpieza (un chofer hoy): aborta (no son 86 y 7).
--
-- Un único DO que termina siempre en una excepción; cada caso en un sub-bloque que se revierte.
-- Fixtures: una sucursal activa con un admin, un encargado, un preventista y un chofer activos y
-- un cliente activo que no sea de vale blanco.

CREATE OR REPLACE FUNCTION pg_temp.limpieza_1700()
RETURNS void LANGUAGE plpgsql AS $limpieza$
DECLARE
  c_oficina   CONSTANT text := 'Cargada y resuelta por la oficina';
  c_calle     CONSTANT text := 'Cerrada en la limpieza de la ola 3: cargada en la calle, revisada por el dueño';
  -- Lo medido en prod el 26/11 (#1700): 86 de la oficina (admin o encargado; las 2 de más que el
  -- 25/11 son de ese día, y el dueño decidió cerrarlas también), y 7 de preventistas con el rol
  -- extra de chofer, cargadas del 10/10 al 17/10 (día argentino).
  c_n_oficina CONSTANT int := 86;
  c_n_calle   CONSTANT int := 7;
  c_desde     CONSTANT date := DATE '2026-10-10';
  c_hasta     CONSTANT date := DATE '2026-10-17';
  v_total     int;
  v_oficina   int;
  v_calle     int;
  v_n         int;
  v_h_oficina int;
  v_h_calle   int;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE p.rol IN ('admin', 'encargado')),
         count(*) FILTER (WHERE p.rol = 'preventista'
                            AND (s.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                                BETWEEN c_desde AND c_hasta)
    INTO v_total, v_oficina, v_calle
    FROM salvedades_items s
    LEFT JOIN perfiles p ON p.id = s.reportado_por
   WHERE s.estado_resolucion = 'pendiente';
  -- Sin ninguna pendiente (la base de CI, sin datos) no hay nada que cerrar.
  IF v_total = 0 THEN
    RAISE NOTICE 'limpieza · no hay salvedades pendientes: nada que cerrar';
    RETURN;
  END IF;
  IF v_oficina <> c_n_oficina OR v_calle <> c_n_calle THEN
    RAISE EXCEPTION 'premisa · hay % pendientes de la oficina y % de la calle del % al % (se midieron % y %): volver a medir antes de cerrarlas',
      v_oficina, v_calle, c_desde, c_hasta, c_n_oficina, c_n_calle;
  END IF;

  -- Sólo las que se midieron: una pendiente de la calle fuera de esas (la de un chofer cargada
  -- hoy) no la revisó nadie y queda pendiente.
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
       AND (p.rol IN ('admin', 'encargado')
            OR (p.rol = 'preventista'
                AND (s.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                    BETWEEN c_desde AND c_hasta))
    RETURNING s.id, s.sucursal_id, s.resolucion_notas, s.resuelto_por
  ), historial AS (
    INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
    SELECT id, 'resolucion', 'pendiente', 'resuelto_otro', resolucion_notas, resuelto_por, sucursal_id
      FROM cerradas
    RETURNING notas, usuario_id
  )
  SELECT count(*),
         count(*) FILTER (WHERE notas = c_oficina AND usuario_id IS NOT NULL),
         count(*) FILTER (WHERE notas = c_calle AND usuario_id IS NULL)
    INTO v_n, v_h_oficina, v_h_calle
    FROM historial;

  IF v_n <> c_n_oficina + c_n_calle OR v_h_oficina <> c_n_oficina OR v_h_calle <> c_n_calle THEN
    RAISE EXCEPTION 'poscondición · se cerraron % (oficina %, calle %), se esperaban % y %',
      v_n, v_h_oficina, v_h_calle, c_n_oficina, c_n_calle;
  END IF;
  IF EXISTS (SELECT 1 FROM salvedades_items s JOIN perfiles p ON p.id = s.reportado_por
              WHERE s.estado_resolucion = 'pendiente'
                AND (p.rol IN ('admin', 'encargado')
                     OR (p.rol = 'preventista'
                         AND (s.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                             BETWEEN c_desde AND c_hasta))) THEN
    RAISE EXCEPTION 'poscondición · quedó pendiente una de la oficina o de la calle del % al %', c_desde, c_hasta;
  END IF;
  RAISE NOTICE 'limpieza · % salvedades cerradas: % de la oficina y % de la calle; quedan % pendientes',
    v_n, v_h_oficina, v_h_calle, v_total - v_n;
END
$limpieza$;

CREATE OR REPLACE FUNCTION pg_temp.lz_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Un pedido con una línea para colgarle las salvedades. Devuelve {pedido, item, producto}.
CREATE OR REPLACE FUNCTION pg_temp.lz_pedido(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_suc  bigint := (r->>'suc')::bigint;
  v_prod bigint;
  v_res  jsonb;
  v_ped  bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1700 limpieza ' || gen_random_uuid(), 100, 50, 60, v_suc)
  RETURNING id INTO v_prod;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', r->>'adm', 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  v_res := public.crear_pedido_completo(
    (r->>'cli')::bigint, 500, (r->>'adm')::uuid,
    jsonb_build_array(jsonb_build_object('producto_id', v_prod, 'cantidad', 5, 'precio_unitario', 100)),
    'ensayo 1700 limpieza');
  PERFORM set_config('request.jwt.claims', '', true);
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  UPDATE public.pedidos SET estado = 'asignado', transportista_id = (r->>'tra')::uuid WHERE id = v_ped;
  RETURN jsonb_build_object('pedido', v_ped, 'producto', v_prod,
    'item', (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped ORDER BY id LIMIT 1));
END
$fn$;

-- p_n pendientes de p_uid, cargadas en p_cuando, como las escribe el server. Devuelve sus ids.
CREATE OR REPLACE FUNCTION pg_temp.lz_poner(x jsonb, p_suc bigint, p_uid uuid, p_n int, p_cuando timestamptz)
RETURNS bigint[] LANGUAGE sql AS $fn$
  WITH n AS (
    INSERT INTO public.salvedades_items (
      pedido_id, pedido_item_id, producto_id, cantidad_original, cantidad_afectada, cantidad_entregada,
      motivo, descripcion, monto_afectado, precio_unitario, reportado_por, estado_resolucion, sucursal_id,
      created_at, updated_at)
    SELECT (x->>'pedido')::bigint, (x->>'item')::bigint, (x->>'producto')::bigint, 5, 1, 4,
           'cliente_rechaza', 'ensayo 1700 limpieza', 100, 100, p_uid, 'pendiente', p_suc,
           p_cuando, p_cuando
      FROM generate_series(1, p_n)
    RETURNING id
  )
  SELECT COALESCE(array_agg(id ORDER BY id), '{}') FROM n;
$fn$;

-- Las pendientes que haya de antes (otro ensayo) no cuentan: el caso las da por resueltas (y se
-- revierte con el caso).
CREATE OR REPLACE FUNCTION pg_temp.lz_vaciar()
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.salvedades_items SET estado_resolucion = 'resuelto_otro' WHERE estado_resolucion = 'pendiente';
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lz_pendientes()
RETURNS int LANGUAGE sql AS $fn$
  SELECT count(*)::int FROM public.salvedades_items WHERE estado_resolucion = 'pendiente';
$fn$;

-- Corre la limpieza y devuelve el error, o NULL si no abortó.
CREATE OR REPLACE FUNCTION pg_temp.lz_correr()
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM pg_temp.limpieza_1700();
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END
$fn$;

-- El rango con sus bordes: 10/10 00:30 y 17/10 23:30 son de adentro en el día argentino.
CREATE OR REPLACE FUNCTION pg_temp.lz_calle_en_rango(x jsonb, p_suc bigint, p_pre uuid, p_n int)
RETURNS bigint[] LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN pg_temp.lz_poner(x, p_suc, p_pre, 1, timestamptz '2026-10-10 00:30-03')
      || pg_temp.lz_poner(x, p_suc, p_pre, 1, timestamptz '2026-10-17 23:30-03')
      || pg_temp.lz_poner(x, p_suc, p_pre, p_n - 2, timestamptz '2026-10-12 12:00-03');
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lz_caso_k1(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f       text[] := '{}';
  v_suc   bigint := (r->>'suc')::bigint;
  x       jsonb;
  v_adm   bigint[];
  v_enc   bigint[];
  v_calle bigint[];
  v_fuera bigint[];
  v_err   text;
BEGIN
  PERFORM pg_temp.lz_vaciar();
  x := pg_temp.lz_pedido(r);
  v_adm   := pg_temp.lz_poner(x, v_suc, (r->>'adm')::uuid, 85, timestamptz '2026-09-20 10:00-03');
  v_enc   := pg_temp.lz_poner(x, v_suc, (r->>'enc')::uuid, 1, now());
  v_calle := pg_temp.lz_calle_en_rango(x, v_suc, (r->>'pre')::uuid, 7);
  v_fuera := pg_temp.lz_poner(x, v_suc, (r->>'tra')::uuid, 1, now())
          || pg_temp.lz_poner(x, v_suc, (r->>'pre')::uuid, 1, timestamptz '2026-10-09 23:30-03')
          || pg_temp.lz_poner(x, v_suc, (r->>'pre')::uuid, 1, timestamptz '2026-10-18 00:30-03');
  v_err := pg_temp.lz_correr();
  f := pg_temp.lz_si(f, v_err IS NULL, format('la limpieza abortó: %s', v_err));
  f := pg_temp.lz_si(f,
         (SELECT count(*) FROM public.salvedades_items
           WHERE id = ANY (v_adm || v_enc) AND estado_resolucion = 'resuelto_otro'
             AND resolucion_notas = 'Cargada y resuelta por la oficina'
             AND resuelto_por = reportado_por AND resolucion_fecha = now()) = 86,
         'las 86 de la oficina no quedaron resuelto_otro, con su nota y resueltas por quien las cargó');
  f := pg_temp.lz_si(f,
         (SELECT count(*) FROM public.salvedades_items
           WHERE id = ANY (v_calle) AND estado_resolucion = 'resuelto_otro'
             AND resolucion_notas = 'Cerrada en la limpieza de la ola 3: cargada en la calle, revisada por el dueño'
             AND resuelto_por IS NULL AND resolucion_fecha = now()) = 7,
         'las 7 de la calle no quedaron resuelto_otro, con su nota y sin resuelto_por');
  f := pg_temp.lz_si(f,
         (SELECT count(*) FROM public.salvedades_items WHERE id = ANY (v_fuera) AND estado_resolucion = 'pendiente') = 3
         AND pg_temp.lz_pendientes() = 3,
         format('las de afuera (el chofer de hoy, el 09/10 23:30 y el 18/10 00:30) no quedaron pendientes: %s',
                (SELECT string_agg(estado_resolucion, ', ' ORDER BY id) FROM public.salvedades_items
                  WHERE id = ANY (v_fuera))));
  f := pg_temp.lz_si(f,
         (SELECT count(*) FROM public.salvedad_historial
           WHERE salvedad_id = ANY (v_adm || v_enc || v_calle) AND accion = 'resolucion'
             AND estado_anterior = 'pendiente' AND estado_nuevo = 'resuelto_otro') = 93
         AND NOT EXISTS (SELECT 1 FROM public.salvedad_historial WHERE salvedad_id = ANY (v_fuera)),
         'el historial no tiene una resolución por cada una de las 93 (y ninguna de las de afuera)');
  f := pg_temp.lz_si(f,
         (SELECT count(*) FROM public.salvedades_items
           WHERE id = ANY (v_adm || v_enc || v_calle || v_fuera)
             AND reportado_por IS NOT NULL AND created_at < now() + interval '1 second') = 96
         AND (SELECT min(created_at) FROM public.salvedades_items WHERE id = ANY (v_adm)) = timestamptz '2026-09-20 10:00-03',
         'la limpieza tocó reportado_por o created_at');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lz_caso_k2(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb;
  v_err text;
BEGIN
  PERFORM pg_temp.lz_vaciar();
  x := pg_temp.lz_pedido(r);
  PERFORM pg_temp.lz_poner(x, v_suc, (r->>'adm')::uuid, 85, now());
  PERFORM pg_temp.lz_calle_en_rango(x, v_suc, (r->>'pre')::uuid, 7);
  v_err := pg_temp.lz_correr();
  f := pg_temp.lz_si(f, v_err LIKE 'premisa · hay 85 pendientes de la oficina y 7 de la calle%',
         format('con 85 de la oficina no abortó en la premisa: %s', v_err));
  f := pg_temp.lz_si(f, pg_temp.lz_pendientes() = 92, format('cerró algo: quedan %s pendientes', pg_temp.lz_pendientes()));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lz_caso_k3(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb;
  v_err text;
BEGIN
  PERFORM pg_temp.lz_vaciar();
  x := pg_temp.lz_pedido(r);
  PERFORM pg_temp.lz_poner(x, v_suc, (r->>'adm')::uuid, 85, now());
  PERFORM pg_temp.lz_poner(x, v_suc, (r->>'enc')::uuid, 1, now());
  PERFORM pg_temp.lz_calle_en_rango(x, v_suc, (r->>'pre')::uuid, 8);
  v_err := pg_temp.lz_correr();
  f := pg_temp.lz_si(f, v_err LIKE 'premisa · hay 86 pendientes de la oficina y 8 de la calle%',
         format('con 8 de la calle no abortó en la premisa: %s', v_err));
  f := pg_temp.lz_si(f, pg_temp.lz_pendientes() = 94, format('cerró algo: quedan %s pendientes', pg_temp.lz_pendientes()));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lz_caso_k4(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_err text;
  v_h   bigint;
BEGIN
  PERFORM pg_temp.lz_vaciar();
  v_h := (SELECT count(*) FROM public.salvedad_historial);
  v_err := pg_temp.lz_correr();
  f := pg_temp.lz_si(f, v_err IS NULL, format('sin pendientes abortó: %s', v_err));
  f := pg_temp.lz_si(f, (SELECT count(*) FROM public.salvedad_historial) = v_h, 'sin pendientes escribió el historial');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.lz_caso_k5(r jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f     text[] := '{}';
  v_suc bigint := (r->>'suc')::bigint;
  x     jsonb;
  v_err text;
BEGIN
  PERFORM pg_temp.lz_vaciar();
  x := pg_temp.lz_pedido(r);
  PERFORM pg_temp.lz_poner(x, v_suc, (r->>'tra')::uuid, 1, now());
  v_err := pg_temp.lz_correr();
  f := pg_temp.lz_si(f, v_err LIKE 'premisa · hay 0 pendientes de la oficina y 0 de la calle%',
         format('con sólo la del chofer de hoy no abortó en la premisa: %s', v_err));
  f := pg_temp.lz_si(f, pg_temp.lz_pendientes() = 1, 'la del chofer de hoy no quedó pendiente');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1700l$
DECLARE
  v_suc    bigint;
  v_r      jsonb;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
BEGIN
  SELECT s.id INTO v_suc
    FROM sucursales s
   WHERE s.activa
     AND EXISTS (SELECT 1 FROM clientes c WHERE c.sucursal_id = s.id AND c.activo
                                            AND c.tipo_factura_default IS DISTINCT FROM 'VB')
     AND (SELECT count(DISTINCT p.rol) FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
           WHERE us.sucursal_id = s.id AND p.activo
             AND p.rol IN ('admin', 'encargado', 'transportista', 'preventista')) = 4
   ORDER BY s.id LIMIT 1;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · hace falta una sucursal activa con admin, encargado, chofer y preventista activos y un cliente activo';
  END IF;
  SELECT jsonb_build_object(
           'suc', v_suc,
           'cli', (SELECT id FROM clientes WHERE sucursal_id = v_suc AND activo
                     AND tipo_factura_default IS DISTINCT FROM 'VB' ORDER BY id LIMIT 1),
           'adm', (SELECT p.id FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
                    WHERE us.sucursal_id = v_suc AND p.activo AND p.rol = 'admin' ORDER BY p.id LIMIT 1),
           'enc', (SELECT p.id FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
                    WHERE us.sucursal_id = v_suc AND p.activo AND p.rol = 'encargado' ORDER BY p.id LIMIT 1),
           'tra', (SELECT p.id FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
                    WHERE us.sucursal_id = v_suc AND p.activo AND p.rol = 'transportista' ORDER BY p.id LIMIT 1),
           'pre', (SELECT p.id FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
                    WHERE us.sucursal_id = v_suc AND p.activo AND p.rol = 'preventista' ORDER BY p.id LIMIT 1))
    INTO v_r;

  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['k1', 'k2', 'k3', 'k4', 'k5'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.lz_caso_%s($1)', v_caso) INTO v_out USING v_r;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas):\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK';
END
$ensayo1700l$;
