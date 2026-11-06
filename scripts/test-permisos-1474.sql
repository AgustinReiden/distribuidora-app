-- Ensayo de #1474 (tarjeta 7 de #1477): los helpers de rol miran activo, el bucket
-- `facturas` se acota por sucursal, nadie edita su propio perfil, la guarda del último admin
-- y el rol extra de perfil_roles.
--
-- Corre contra prod SIN dejar rastro (salvo los valores de perfil_roles_id_seq que consumen
-- los INSERT de R): un único DO que termina SIEMPRE en una excepción, y cada caso corre en su
-- propio sub-bloque que se revierte al terminar.
--
-- Simula PostgREST como test-columnas-protegidas-1151-1155-1156.sql: `SET LOCAL ROLE
-- authenticated`, el `sub` de un perfil real en request.jwt.claims y la sucursal en
-- x-sucursal-id. Las personas salen de prod: un admin sólo de la 1, uno sólo de la 2, uno de
-- las dos, un encargado, un preventista sólo de la 1 sin extras, uno sólo de la 2, y un
-- preventista con el extra de transportista en su sucursal.
--
-- Sin la migración tiene que FALLAR en H1, H2b, U1, P1, G1, R1, R2, S1, S2a y S3a.
-- H2a, P2, R3, S2b y S3b pasan antes y después (regresiones). A1 falla sin la migración
-- (no existe auditoria_storage). Con la migración (inline antes del DO) da 'ENSAYO OK'.
--
-- Helpers (SEG-F-2)
--   H1  · un admin activo: es_admin, es_encargado_o_admin, es_preventista, es_transportista
--         true y current_sucursal_id = su sucursal; desactivado (con el token vivo): los
--         cuatro false, current_sucursal_id NULL y no ve ningún cliente
--   H2a · multi-rol (trampa 4): el admin es preventista y transportista, el encargado es
--         preventista y no transportista, el preventista con el extra es transportista en
--         su sucursal
--   H2b · el mismo preventista con el extra, desactivado: no es transportista ni preventista
-- usuario_sucursales.rol (SEG-F-3)
--   U1  · rol NULL → 23502 y rol fuera de dominio → 23514; ningún miembro tiene
--         _rol_en_sucursal NULL
-- perfiles (SEG-F-4)
--   P1  · un preventista PATCH de su nombre, su email o su zona → 0 filas
--   P2  · el admin de sus sucursales PATCH del nombre del preventista y del suyo → 1 fila
-- Último admin (SEG-F-6)
--   G1  · con un único admin activo: quitarle el rol, desactivarlo o borrarlo → excepción
--         de la guarda; con dos, degradar a uno pasa
-- perfil_roles (SEG-F-7)
--   R1  · el admin de la 1 le da el extra en la 1 a un preventista sólo de la 2 → rechazado
--   R2  · el admin de las dos le da el extra en la 2 a un preventista sólo de la 1 (no es
--         miembro de la 2) → rechazado
--   R3  · el admin de la 1 le da el extra en la 1 a un preventista de la 1 → 1 fila
-- Storage (SEG-F-1)
--   S1  · el admin de la 1 lista sólo los objetos `1/…` de `facturas`; el de la 2 y el
--         encargado de la 2, sólo los `2/…`; los `facturas/…` viejos no los ve nadie
--   S2a · el admin de la 1 sube a `2/<uuid>.jpg` → rechazado
--   S2b · el admin de la 1 sube a `1/<uuid>.jpg` → 1 fila
--   S3a · el admin de la 1 borra un objeto `2/…` → 0 filas
--   S3b · el admin de la 2 borra ese objeto → 1 fila
-- Gate
--   A1  · auditoria_storage() devuelve las tres policies de `facturas`, las tres nombran
--         usuario_sucursales, y no la ejecuta ni anon ni authenticated
--
-- Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ …' con la lista de fallas. Con el GUC
-- ensayo.continuar = '1' el OK sale como NOTICE (para encadenar un rollback).
--
--   psql "$DATABASE_URL" -f scripts/test-permisos-1474.sql

DO $ensayo$
DECLARE
  v_a1     uuid;  -- admin sólo de la 1
  v_a2     uuid;  -- admin sólo de la 2
  v_a12    uuid;  -- admin de la 1 y la 2
  v_e      uuid;  -- encargado
  v_e_suc  bigint;
  v_p1     uuid;  -- preventista sólo de la 1, sin extras
  v_p2     uuid;  -- preventista sólo de la 2
  v_px     uuid;  -- preventista con el extra de transportista en su sucursal
  v_px_suc bigint;
  v_err    text;
  v_res    text;
  v_n      bigint;
  v_t      text;
  v_obj    text;
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  -- ------------------------------------------------------------- personas ---
  CREATE FUNCTION pg_temp.sucs(p uuid) RETURNS text LANGUAGE sql AS $f$
    SELECT string_agg(sucursal_id::text, ',' ORDER BY sucursal_id) FROM public.usuario_sucursales WHERE usuario_id = p
  $f$;
  SELECT id INTO v_a1  FROM perfiles WHERE rol = 'admin' AND activo AND pg_temp.sucs(id) = '1'   ORDER BY id LIMIT 1;
  SELECT id INTO v_a2  FROM perfiles WHERE rol = 'admin' AND activo AND pg_temp.sucs(id) = '2'   ORDER BY id LIMIT 1;
  SELECT id INTO v_a12 FROM perfiles WHERE rol = 'admin' AND activo AND pg_temp.sucs(id) = '1,2' ORDER BY id LIMIT 1;
  SELECT p.id, us.sucursal_id INTO v_e, v_e_suc
    FROM perfiles p JOIN usuario_sucursales us ON us.usuario_id = p.id
   WHERE p.rol = 'encargado' AND p.activo ORDER BY p.id LIMIT 1;
  SELECT id INTO v_p1 FROM perfiles p WHERE rol = 'preventista' AND activo AND pg_temp.sucs(id) = '1'
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = p.id) ORDER BY id LIMIT 1;
  SELECT id INTO v_p2 FROM perfiles p WHERE rol = 'preventista' AND activo AND pg_temp.sucs(id) = '2'
     AND NOT EXISTS (SELECT 1 FROM perfil_roles pr WHERE pr.usuario_id = p.id AND pr.sucursal_id = 1) ORDER BY id LIMIT 1;
  SELECT p.id, pr.sucursal_id INTO v_px, v_px_suc
    FROM perfiles p
    JOIN perfil_roles pr ON pr.usuario_id = p.id AND pr.rol = 'transportista'
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.sucursal_id = pr.sucursal_id
   WHERE p.rol = 'preventista' AND p.activo ORDER BY p.id LIMIT 1;
  IF v_a1 IS NULL OR v_a2 IS NULL OR v_a12 IS NULL OR v_e IS NULL OR v_p1 IS NULL OR v_p2 IS NULL OR v_px IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin fixtures: a1 % a2 % a12 % e % p1 % p2 % px %',
      v_a1, v_a2, v_a12, v_e, v_p1, v_p2, v_px;
  END IF;

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;
  -- Sin usuario (como el servidor): auth.uid() NULL.
  CREATE FUNCTION pg_temp.servidor() RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', '{}', true);
    PERFORM set_config('request.headers', '{}', true);
  END $f$;
  -- Filas afectadas como PostgREST, o 'SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.rest_n(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v bigint;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql;
    GET DIAGNOSTICS v = ROW_COUNT;
    EXECUTE 'RESET ROLE';
    RETURN v::text;
  EXCEPTION WHEN OTHERS THEN
    RETURN SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Un SELECT escalar como PostgREST, o 'ERR SQLSTATE mensaje'.
  CREATE FUNCTION pg_temp.rest_val(p_sql text) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v text;
  BEGIN
    EXECUTE 'SET LOCAL ROLE authenticated';
    EXECUTE p_sql INTO v;
    EXECUTE 'RESET ROLE';
    RETURN COALESCE(v, '(null)');
  EXCEPTION WHEN OTHERS THEN
    RETURN 'ERR ' || SQLSTATE || ' ' || SQLERRM;
  END $f$;
  -- Los cuatro helpers de rol y la sucursal activa, en una línea.
  CREATE FUNCTION pg_temp.roles() RETURNS text LANGUAGE sql AS $f$
    SELECT format('admin=%s enc=%s prev=%s transp=%s suc=%s',
                  public.es_admin()::text, public.es_encargado_o_admin()::text, public.es_preventista()::text,
                  public.es_transportista()::text, COALESCE(public.current_sucursal_id()::text, 'null'))
  $f$;

  -- ------------------------------------------------------------------- H1 ---
  BEGIN
    PERFORM pg_temp.como(v_a1, 1);
    v_res := pg_temp.roles();
    IF v_res <> 'admin=true enc=true prev=true transp=true suc=1' THEN
      v_fallas := v_fallas || format('H1 · admin activo: %s', v_res);
    END IF;
    v_n := pg_temp.rest_val('SELECT count(*) FROM public.clientes')::bigint;
    IF v_n = 0 THEN
      v_fallas := v_fallas || text 'H1 · el admin activo no ve clientes (fixture)';
    END IF;
    PERFORM pg_temp.servidor();
    UPDATE perfiles SET activo = false WHERE id = v_a1;
    PERFORM pg_temp.como(v_a1, 1);
    v_res := pg_temp.roles();
    IF v_res <> 'admin=false enc=false prev=false transp=false suc=null' THEN
      v_fallas := v_fallas || format('H1 · admin desactivado: %s', v_res);
    END IF;
    v_res := pg_temp.rest_val('SELECT count(*) FROM public.clientes');
    IF v_res <> '0' THEN
      v_fallas := v_fallas || format('H1 · el admin desactivado ve %s clientes', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('H1 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ H2 ---
  BEGIN
    PERFORM pg_temp.como(v_a12, 1);
    IF NOT (public.es_preventista() AND public.es_transportista()) THEN
      v_fallas := v_fallas || format('H2a · admin: %s', pg_temp.roles());
    END IF;
    PERFORM pg_temp.como(v_e, v_e_suc);
    IF NOT public.es_preventista() OR public.es_transportista() <> EXISTS (
         SELECT 1 FROM perfil_roles WHERE usuario_id = v_e AND sucursal_id = v_e_suc AND rol = 'transportista') THEN
      v_fallas := v_fallas || format('H2a · encargado: %s', pg_temp.roles());
    END IF;
    PERFORM pg_temp.como(v_px, v_px_suc);
    v_res := pg_temp.roles();
    IF v_res <> format('admin=false enc=false prev=true transp=true suc=%s', v_px_suc) THEN
      v_fallas := v_fallas || format('H2a · preventista con extra: %s', v_res);
    END IF;
    PERFORM pg_temp.servidor();
    UPDATE perfiles SET activo = false WHERE id = v_px;
    PERFORM pg_temp.como(v_px, v_px_suc);
    v_res := pg_temp.roles();
    IF v_res <> 'admin=false enc=false prev=false transp=false suc=null' THEN
      v_fallas := v_fallas || format('H2b · preventista con extra desactivado: %s', v_res);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('H2 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- U1 ---
  BEGIN
    PERFORM pg_temp.servidor();
    BEGIN
      UPDATE usuario_sucursales SET rol = NULL WHERE usuario_id = v_p1;
      v_fallas := v_fallas || text 'U1 · rol NULL en usuario_sucursales pasó';
    EXCEPTION WHEN not_null_violation THEN NULL;
    END;
    BEGIN
      UPDATE usuario_sucursales SET rol = 'jefe' WHERE usuario_id = v_p1;
      v_fallas := v_fallas || text 'U1 · rol ''jefe'' en usuario_sucursales pasó';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    SELECT count(*) INTO v_n FROM usuario_sucursales WHERE public._rol_en_sucursal(usuario_id, sucursal_id) IS NULL;
    IF v_n > 0 THEN
      v_fallas := v_fallas || format('U1 · %s miembros con _rol_en_sucursal NULL', v_n);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('U1 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ P1-2 --
  BEGIN
    PERFORM pg_temp.como(v_p1, 1);
    FOREACH v_t IN ARRAY ARRAY['nombre = nombre || '' (yo)''', 'email = ''otro@ejemplo.com''', 'zona = ''ZZ''']
    LOOP
      v_err := pg_temp.rest_n(format('UPDATE public.perfiles SET %s WHERE id = %L', v_t, v_p1));
      IF v_err <> '0' THEN
        v_fallas := v_fallas || format('P1 · el preventista se cambia %s: %s', v_t, v_err);
      END IF;
    END LOOP;
    PERFORM pg_temp.como(v_a1, 1);
    v_err := pg_temp.rest_n(format('UPDATE public.perfiles SET nombre = nombre WHERE id = %L', v_p1));
    IF v_err <> '1' THEN
      v_fallas := v_fallas || format('P2 · el admin edita a su preventista: %s', v_err);
    END IF;
    v_err := pg_temp.rest_n(format('UPDATE public.perfiles SET nombre = nombre WHERE id = %L', v_a1));
    IF v_err <> '1' THEN
      v_fallas := v_fallas || format('P2 · el admin edita su propio nombre: %s', v_err);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('P · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- G1 ---
  BEGIN
    PERFORM pg_temp.servidor();
    -- Con dos o más, degradar pasa: quedan v_a1 y nadie más.
    UPDATE perfiles SET rol = 'encargado' WHERE rol = 'admin' AND id <> v_a1;
    SELECT count(*) INTO v_n FROM perfiles WHERE rol = 'admin' AND COALESCE(activo, true);
    IF v_n <> 1 THEN
      v_fallas := v_fallas || format('G1 · quedaron %s admins activos, no 1', v_n);
    END IF;
    BEGIN
      UPDATE perfiles SET rol = 'preventista' WHERE id = v_a1;
      v_fallas := v_fallas || text 'G1 · se le quitó el rol al último admin';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM NOT LIKE '%ultimo administrador%' THEN v_fallas := v_fallas || ('G1 · rol: ' || SQLERRM); END IF;
    END;
    BEGIN
      UPDATE perfiles SET activo = false WHERE id = v_a1;
      v_fallas := v_fallas || text 'G1 · se desactivó al último admin';
    EXCEPTION WHEN raise_exception THEN
      IF SQLERRM NOT LIKE '%ultimo administrador%' THEN v_fallas := v_fallas || ('G1 · activo: ' || SQLERRM); END IF;
    END;
    BEGIN
      DELETE FROM perfiles WHERE id = v_a1;
      v_fallas := v_fallas || text 'G1 · se borró al último admin';
    EXCEPTION WHEN OTHERS THEN
      IF SQLERRM NOT LIKE '%ultimo administrador%' THEN v_fallas := v_fallas || ('G1 · borrado: ' || SQLERRM); END IF;
    END;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('G1 · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ R1-3 --
  BEGIN
    PERFORM pg_temp.como(v_a1, 1);
    v_err := pg_temp.rest_n(format(
      'INSERT INTO public.perfil_roles (usuario_id, sucursal_id, rol) VALUES (%L, 1, ''transportista'')', v_p2));
    IF v_err = '1' THEN
      v_fallas := v_fallas || text 'R1 · el admin de la 1 le dio el extra a un preventista de la 2';
    END IF;
    PERFORM pg_temp.como(v_a12, 2);
    v_err := pg_temp.rest_n(format(
      'INSERT INTO public.perfil_roles (usuario_id, sucursal_id, rol) VALUES (%L, 2, ''transportista'')', v_p1));
    IF v_err = '1' THEN
      v_fallas := v_fallas || text 'R2 · el extra en la 2 a un preventista que no es miembro de la 2';
    END IF;
    PERFORM pg_temp.como(v_a1, 1);
    v_err := pg_temp.rest_n(format(
      'INSERT INTO public.perfil_roles (usuario_id, sucursal_id, rol) VALUES (%L, 1, ''transportista'')', v_p1));
    IF v_err <> '1' THEN
      v_fallas := v_fallas || format('R3 · el admin de la 1 le da el extra a su preventista: %s', v_err);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('R · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------ S1-3 --
  BEGIN
    FOR v_t, v_res IN
      SELECT * FROM (VALUES (v_a1::text, '1'), (v_a2::text, '2'), (v_e::text, v_e_suc::text)) AS t(u, s)
    LOOP
      PERFORM pg_temp.como(v_t::uuid, v_res::bigint);
      v_err := pg_temp.rest_val('SELECT count(*) FROM storage.objects WHERE bucket_id = ''facturas''');
      SELECT count(*) INTO v_n FROM storage.objects o
       WHERE o.bucket_id = 'facturas'
         AND split_part(o.name, '/', 1) IN (SELECT sucursal_id::text FROM usuario_sucursales WHERE usuario_id = v_t::uuid);
      IF v_err <> v_n::text THEN
        v_fallas := v_fallas || format('S1 · %s (sucursal %s) lista %s objetos de facturas, no %s', v_t, v_res, v_err, v_n);
      END IF;
    END LOOP;

    PERFORM pg_temp.como(v_a1, 1);
    v_err := pg_temp.rest_n(format(
      'INSERT INTO storage.objects (bucket_id, name, owner) VALUES (''facturas'', %L, %L)',
      '2/' || gen_random_uuid() || '.jpg', v_a1));
    IF v_err = '1' THEN
      v_fallas := v_fallas || text 'S2a · el admin de la 1 subió a 2/…';
    END IF;
    v_err := pg_temp.rest_n(format(
      'INSERT INTO storage.objects (bucket_id, name, owner) VALUES (''facturas'', %L, %L)',
      '1/' || gen_random_uuid() || '.jpg', v_a1));
    IF v_err <> '1' THEN
      v_fallas := v_fallas || format('S2b · el admin de la 1 sube a 1/…: %s', v_err);
    END IF;

    PERFORM pg_temp.servidor();
    v_obj := '2/' || gen_random_uuid() || '.jpg';
    INSERT INTO storage.objects (bucket_id, name, owner) VALUES ('facturas', v_obj, v_a2);
    PERFORM set_config('storage.allow_delete_query', 'true', true);
    PERFORM pg_temp.como(v_a1, 1);
    v_err := pg_temp.rest_n(format('DELETE FROM storage.objects WHERE bucket_id = ''facturas'' AND name = %L', v_obj));
    IF v_err <> '0' THEN
      v_fallas := v_fallas || format('S3a · el admin de la 1 borra un objeto de la 2: %s', v_err);
    END IF;
    PERFORM pg_temp.como(v_a2, 2);
    v_err := pg_temp.rest_n(format('DELETE FROM storage.objects WHERE bucket_id = ''facturas'' AND name = %L', v_obj));
    IF v_err <> '1' THEN
      v_fallas := v_fallas || format('S3b · el admin de la 2 borra su objeto: %s', v_err);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('S · error inesperado: ' || SQLERRM);
  END;

  -- ------------------------------------------------------------------- A1 ---
  BEGIN
    PERFORM pg_temp.servidor();
    IF to_regprocedure('public.auditoria_storage()') IS NULL THEN
      v_fallas := v_fallas || text 'A1 · no existe auditoria_storage()';
    ELSE
      EXECUTE $q$
        SELECT count(*) FROM jsonb_array_elements(public.auditoria_storage()->'politicas') p
         WHERE p->>'policy' LIKE 'facturas\_%'
           AND coalesce(p->>'using', '') || coalesce(p->>'check', '') LIKE '%usuario_sucursales%'
      $q$ INTO v_n;
      IF v_n <> 3 THEN
        v_fallas := v_fallas || format('A1 · %s policies de facturas nombran usuario_sucursales, no 3', v_n);
      END IF;
      IF has_function_privilege('anon', 'public.auditoria_storage()', 'EXECUTE')
         OR has_function_privilege('authenticated', 'public.auditoria_storage()', 'EXECUTE') THEN
        v_fallas := v_fallas || text 'A1 · auditoria_storage() la ejecuta anon o authenticated';
      END IF;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
    WHEN OTHERS THEN v_fallas := v_fallas || ('A1 · error inesperado: ' || SQLERRM);
  END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas: %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format('ENSAYO OK (todo revertido) · notas: %s', array_to_string(v_notas, ' | '));
 EXCEPTION WHEN SQLSTATE 'ZZ0OK' OR SQLSTATE 'ZZ0FA' THEN
  GET STACKED DIAGNOSTICS v_t = MESSAGE_TEXT;
  IF v_t LIKE 'ENSAYO OK%' AND current_setting('ensayo.continuar', true) = '1' THEN
    RAISE NOTICE '%', v_t;
  ELSE
    RAISE EXCEPTION '%', v_t;
  END IF;
 END;
END
$ensayo$;
