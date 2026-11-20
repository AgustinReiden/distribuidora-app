-- Ensayo de la tarjeta C6 de la ola 2 del plan #1603 (1564-b7 de #1564, decisión del dueño D51):
-- las facturas escaneadas, de la sucursal activa. Migración: 539_facturas_por_sucursal_activa.
--
-- Necesita storage.objects: sobre una base local, scripts/ci/storage-minimo.sql (como
-- supabase_admin) ANTES de la migración. Sin storage (el CI) da ENSAYO OK con una nota.
-- Un único DO con datos propios que termina SIEMPRE en una excepción. Sin la migración fallan todos
-- los casos menos los que dicen «regresión».
--
--   F1 · un encargado de las sucursales 1 y 2, parado en la 1, no ve la factura de la 2 (y en la
--        2, no ve la de la 1); ve la de la sucursal en la que está (regresión).
--   F2 · el mismo encargado, parado en la 1, no sube a la 2; sube a la 1 (regresión).
--   F3 · con el header de una sucursal que no es suya, no ve nada; sin header, ve la de su
--        default (regresión: es lo que pasa si storage-api no pasa el header).
--   F4 · el preventista no ve ninguna (regresión).
--   F5 · el admin de las dos, parado en la 1, borra la de la 1 y no la de la 2.
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-facturas-sucursal-activa-ola2-1603.sql

DO $ensayo$
DECLARE
  v_adm    uuid;
  v_enc    uuid;
  v_encT   uuid;
  v_pre    uuid;
  v_r      text;
  v_t      text;
  v_fallas text[] := '{}';
BEGIN
 BEGIN
  IF to_regclass('storage.objects') IS NULL THEN
    RAISE EXCEPTION 'ENSAYO OK · nota: sin storage.objects no se prueba (scripts/ci/storage-minimo.sql antes de la migración)'
      USING ERRCODE = 'P0001';
  END IF;
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

  v_adm  := pg_temp.u('admin', 1);
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_adm, 2, false);
  v_enc  := pg_temp.u('encargado', 1);
  v_encT := pg_temp.u('encargado', 1);
  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, es_default) VALUES (v_encT, 2, false);
  v_pre  := pg_temp.u('preventista', 1);
  INSERT INTO storage.objects (bucket_id, name) VALUES ('facturas', '1/c6-uno.pdf'), ('facturas', '2/c6-dos.pdf');

  FOR v_t IN
    SELECT format('%s · %s · %s: %s (esperado %s)', caso, quien, que, s.visto, esperado) FROM (VALUES
        ('F1', 'encargado de las dos, en la 1', v_encT, 1::bigint, 've la de la 1',
         'SELECT count(*)::text FROM storage.objects WHERE name = ''1/c6-uno.pdf''', 'PASA 1'),
        ('F1', 'encargado de las dos, en la 1', v_encT, 1::bigint, 've la de la 2',
         'SELECT count(*)::text FROM storage.objects WHERE name = ''2/c6-dos.pdf''', 'PASA 0'),
        ('F1', 'encargado de las dos, en la 2', v_encT, 2::bigint, 've la de la 2',
         'SELECT count(*)::text FROM storage.objects WHERE name = ''2/c6-dos.pdf''', 'PASA 1'),
        ('F1', 'encargado de las dos, en la 2', v_encT, 2::bigint, 've la de la 1',
         'SELECT count(*)::text FROM storage.objects WHERE name = ''1/c6-uno.pdf''', 'PASA 0'),
        ('F2', 'encargado de las dos, en la 1', v_encT, 1::bigint, 'sube a la 1',
         'INSERT INTO storage.objects (bucket_id, name) VALUES (''facturas'', ''1/c6-sube.pdf'') RETURNING name', 'PASA'),
        ('F2', 'encargado de las dos, en la 1', v_encT, 1::bigint, 'sube a la 2',
         'INSERT INTO storage.objects (bucket_id, name) VALUES (''facturas'', ''2/c6-sube.pdf'') RETURNING name', '42501'),
        ('F3', 'encargado de la 1, con el header de la 2', v_enc, 2::bigint, 've la de la 1',
         'SELECT count(*)::text FROM storage.objects WHERE name = ''1/c6-uno.pdf''', 'PASA 0'),
        ('F3', 'encargado de las dos, sin header', v_encT, NULL::bigint, 've la de la 1 (su default)',
         'SELECT count(*)::text FROM storage.objects WHERE name = ''1/c6-uno.pdf''', 'PASA 1'),
        ('F4', 'preventista', v_pre, 1::bigint, 've la de la 1',
         'SELECT count(*)::text FROM storage.objects WHERE name = ''1/c6-uno.pdf''', 'PASA 0')
      ) AS t(caso, quien, u, suc, que, sql, esperado),
      LATERAL (SELECT pg_temp.intenta(u, suc, sql) AS visto) s
     WHERE s.visto NOT LIKE esperado || '%'
  LOOP
    v_fallas := v_fallas || v_t;
  END LOOP;

  v_r := pg_temp.intenta(v_adm, 1, 'WITH b AS (DELETE FROM storage.objects WHERE name IN (''1/c6-uno.pdf'', ''2/c6-dos.pdf'') RETURNING name) SELECT string_agg(name, '','' ORDER BY name) FROM b');
  IF v_r <> 'PASA 1/c6-uno.pdf' THEN
    v_fallas := v_fallas || ('F5 · el admin de las dos, en la 1, borró: ' || v_r || ' (esperado sólo 1/c6-uno.pdf)');
  END IF;

  IF cardinality(v_fallas) = 0 THEN
    RAISE EXCEPTION 'ENSAYO OK' USING ERRCODE = 'P0001';
  END IF;
  RAISE EXCEPTION 'ENSAYO FALLÓ (%):%', cardinality(v_fallas), E'\n  ' || array_to_string(v_fallas, E'\n  ')
    USING ERRCODE = 'P0001';
 END;
END
$ensayo$;
