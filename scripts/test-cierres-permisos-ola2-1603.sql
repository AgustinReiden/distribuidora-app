-- Ensayo de la tarjeta C6 de la ola 2 del plan #1603: los cierres de permisos que esperan a que
-- no queden bundles viejos (1601-b5, 1564-b6 parte 2, 1595-b6 residual). La RPC de emails la
-- prueba scripts/test-linaje-pagos-metas-y-emails-ola2-1603.sql; las facturas,
-- scripts/test-facturas-sucursal-activa-ola2-1603.sql.
-- Migración: NNN_cierres_de_permisos_sin_bundles_viejos.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Cada caso corre
-- como un usuario (SET LOCAL ROLE authenticated + request.jwt.claims + el header de la sucursal).
-- Sin la migración fallan todos los casos menos los que dicen «regresión».
--
--   E2 · 1601-b5  el preventista y el admin no leen perfiles.email por REST (ni con `*`, que es
--                 lo que pide un bundle viejo: falla la consulta entera); leen las columnas del
--                 front (PERFIL_COLUMNAS, con el embed de usuario_sucursales) (regresión), y el
--                 admin edita un usuario devolviendo esas columnas (regresión).
--   E3 · 1564-b6  el preventista y el chofer no leen las columnas reservadas de la política
--                 comercial; leen POLITICA_COLUMNAS_PARA_VENDER (regresión); el admin recibe lo
--                 reservado por politica_comercial_reservada() (regresión).
--   E4 · 1595-b6  un PATCH de pedidos que manda updated_at da 42501; el que manda notas anda y el
--                 server mueve la versión (regresión).
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-cierres-permisos-ola2-1603.sql

DO $ensayo$
DECLARE
  v_adm    uuid;
  v_enc    uuid;
  v_pre    uuid;
  v_tra    uuid;
  v_cli    bigint;
  v_ped    bigint;
  v_r      text;
  v_t      text;
  v_ver    timestamptz;
  v_ver2   timestamptz;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'c6-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'C6 ' || p_rol), now(), now());
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims',
                       CASE WHEN p_uid IS NULL THEN '' ELSE json_build_object('sub', p_uid, 'role', 'authenticated')::text END, true);
    PERFORM set_config('request.jwt.claim.sub', COALESCE(p_uid::text, ''), true);
    PERFORM set_config('request.headers',
                       CASE WHEN p_suc IS NULL THEN '' ELSE json_build_object('x-sucursal-id', p_suc::text)::text END, true);
  END $f$;
  -- Corre p_sql como p_uid (authenticated) parado en p_suc; devuelve 'PASA <valor>' o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.intenta(p_uid uuid, p_suc bigint, p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE r text; x text;
  BEGIN
    PERFORM pg_temp.como(p_uid, p_suc);
    EXECUTE 'SET LOCAL ROLE authenticated';
    BEGIN
      EXECUTE p_sql INTO x;
      r := 'PASA ' || COALESCE(x, '');
    EXCEPTION WHEN OTHERS THEN
      r := SQLSTATE || ' ' || SQLERRM;
    END;
    EXECUTE 'RESET ROLE';
    PERFORM pg_temp.como(NULL, NULL);
    RETURN r;
  END $f$;

  -- --------------------------------------------------------------- fixtures -
  v_adm  := pg_temp.u('admin', 1);
  v_enc  := pg_temp.u('encargado', 1);
  v_pre  := pg_temp.u('preventista', 1);
  v_tra  := pg_temp.u('transportista', 1);
  -- El email que guarda perfiles (handle_new_user lo copia de auth.users).
  UPDATE perfiles SET email = 'c6-' || id || '@ensayo.invalid' WHERE id IN (v_adm, v_enc, v_pre, v_tra) AND email IS NULL;

  -- La política comercial de la 1 (la base local puede no tenerla).
  INSERT INTO politicas_comerciales (sucursal_id) VALUES (1) ON CONFLICT DO NOTHING;
  INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('C6 cierres', 'C6 cierres', 'Calle Falsa 9', 1) RETURNING id INTO v_cli;
  INSERT INTO pedidos (cliente_id, sucursal_id, usuario_id, total, estado, fecha, canal, tipo_factura)
  VALUES (v_cli, 1, v_pre, 0, 'pendiente', public._tablero_hoy(), 'app', 'ZZ') RETURNING id INTO v_ped;

  -- -------------------------------------------------------------------- E2 -
  FOR v_t IN
    SELECT format('%s · %s: %s (esperado %s)', quien, que, s.visto, esperado) FROM (VALUES
        ('preventista', v_pre, 'email de otro', format('SELECT email FROM perfiles WHERE id = %L', v_tra), '42501'),
        ('admin', v_adm, 'email de otro', format('SELECT email FROM perfiles WHERE id = %L', v_pre), '42501'),
        ('admin', v_adm, 'select * (bundle viejo)', format('SELECT to_jsonb(p)::text FROM perfiles p WHERE id = %L', v_adm), '42501'),
        ('preventista', v_pre, 'columnas del front', format('SELECT nombre FROM perfiles WHERE id = %L', v_tra), 'PASA C6'),
        ('encargado', v_enc, 'el embed de la lista', format(
           'SELECT p.nombre FROM perfiles p JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = 1 WHERE p.id = %L', v_tra), 'PASA C6'),
        ('admin', v_adm, 'editar y devolver PERFIL_COLUMNAS', format(
           'UPDATE perfiles SET zona = ''C6'' WHERE id = %L RETURNING id::text || nombre || rol || activo::text || zona', v_pre), 'PASA')
      ) AS t(quien, u, que, sql, esperado),
      LATERAL (SELECT pg_temp.intenta(u, 1, sql) AS visto) s
     WHERE s.visto NOT LIKE esperado || '%'
  LOOP
    v_fallas := v_fallas || ('E2 · ' || v_t);
  END LOOP;

  -- -------------------------------------------------------------------- E3 -
  FOR v_t IN
    SELECT format('%s · %s: %s (esperado %s)', quien, que, s.visto, esperado) FROM (VALUES
        ('preventista', v_pre, 'comision_pct_otros', 'SELECT comision_pct_otros::text FROM politicas_comerciales LIMIT 1', '42501'),
        ('chofer', v_tra, 'ventana_precio_anterior_horas', 'SELECT ventana_precio_anterior_horas::text FROM politicas_comerciales LIMIT 1', '42501'),
        ('admin', v_adm, 'select * (bundle viejo)', 'SELECT to_jsonb(p)::text FROM politicas_comerciales p LIMIT 1', '42501'),
        ('preventista', v_pre, 'POLITICA_COLUMNAS_PARA_VENDER',
         'SELECT count(*)::text FROM (SELECT monto_minimo_pedido, modo_minimo_pedido, monto_envio_gratis, cargo_envio_pedido, dias_alerta_vencimiento, dias_critico_vencimiento, mostrar_sin_stock, dias_atras_fecha_pedido, multiplo_redondeo_precio FROM politicas_comerciales) x', 'PASA'),
        ('admin', v_adm, 'politica_comercial_reservada()',
         'SELECT (count(*) = 1)::text FROM public.politica_comercial_reservada()', 'PASA true')
      ) AS t(quien, u, que, sql, esperado),
      LATERAL (SELECT pg_temp.intenta(u, 1, sql) AS visto) s
     WHERE s.visto NOT LIKE esperado || '%'
  LOOP
    v_fallas := v_fallas || ('E3 · ' || v_t);
  END LOOP;

  -- -------------------------------------------------------------------- E4 -
  SELECT updated_at INTO v_ver FROM pedidos WHERE id = v_ped;
  v_r := pg_temp.intenta(v_enc, 1, format(
    'UPDATE pedidos SET notas = ''C6'', updated_at = ''2020-01-01'' WHERE id = %s RETURNING id::text', v_ped));
  IF v_r NOT LIKE '42501%' THEN
    v_fallas := v_fallas || ('E4 · un PATCH con updated_at entró: ' || v_r);
  END IF;
  -- El de notas anda, y la versión la pone el server (now() de la transacción, no la del cliente).
  v_r := pg_temp.intenta(v_enc, 1, format('UPDATE pedidos SET notas = ''C6 bis'' WHERE id = %s RETURNING id::text', v_ped));
  SELECT updated_at INTO v_ver2 FROM pedidos WHERE id = v_ped;
  IF v_r NOT LIKE 'PASA%' OR v_ver2 IS DISTINCT FROM now() THEN
    v_fallas := v_fallas || format('E4 · el PATCH de notas: %s, versión %s -> %s', v_r, v_ver, v_ver2);
  END IF;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK' USING ERRCODE = 'P0001';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ (%):%', cardinality(v_fallas), E'\n  ' || array_to_string(v_fallas, E'\n  ')
    USING ERRCODE = 'P0001';
 END;
END
$ensayo$;
