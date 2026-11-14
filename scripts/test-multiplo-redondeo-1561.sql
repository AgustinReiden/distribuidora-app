-- Ensayo de la migración del múltiplo del redondeo de los precios en masa
-- (reauditoría completa del 12/11, #1561: CAT-8; plan #1565, tarjeta 10; decisión del dueño, 13/11).
--
-- Corre SIN dejar rastro (salvo valores de secuencia): un único DO que termina SIEMPRE en una
-- excepción. Antes de aplicar la migración se corre pegado detrás de su cuerpo, sin el BEGIN y el
-- COMMIT; después, solo. Lo que se mide va como `authenticated`, con el JWT y la sucursal del header,
-- igual que por PostgREST.
--
-- Personas: un admin activo de una sucursal activa (sale de la base); el encargado y el preventista
-- los crea el ensayo.
--
--   P1 · arranca en 10 en todas las sucursales; el admin lo cambia a 50 y a 0,01 en su sucursal, y
--        las otras no se mueven.
--   P2 · el encargado y el preventista no pueden (y no cambia nada).
--   P3 · 0, negativo, NaN, más de 10.000 y tres decimales se rechazan, por la RPC y por la columna.
--   P4 · authenticated lee la columna por REST, y no la puede escribir.

DO $t$
DECLARE
  v_adm uuid;
  v_suc bigint;
  v_enc uuid;
  v_pre uuid;
  r jsonb;
  t text;
BEGIN
  SET LOCAL lock_timeout = '5s';

  SELECT p.id, us.sucursal_id INTO v_adm, v_suc
    FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   WHERE p.rol = 'admin' AND p.activo
   ORDER BY us.sucursal_id, p.id
   LIMIT 1;
  IF v_adm IS NULL THEN RAISE EXCEPTION 'el ensayo necesita un admin activo de una sucursal activa'; END IF;

  CREATE FUNCTION pg_temp.como(p_user uuid, p_suc bigint) RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true),
           set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  $f$;
  -- Corre p_sql como authenticated y devuelve el jsonb, o {"error": sqlstate, "mensaje": …}.
  CREATE FUNCTION pg_temp.rpc(p_user uuid, p_suc bigint, p_sql text) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_user, p_suc);
    SET LOCAL ROLE authenticated;
    EXECUTE p_sql INTO v;
    RESET ROLE;
    RETURN v;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN jsonb_build_object('error', SQLSTATE, 'mensaje', SQLERRM);
  END $f$;
  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'ens1561m-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), '{}', now(), now());
    RETURN v;
  END $f$;

  v_enc := pg_temp.u('encargado', v_suc);
  v_pre := pg_temp.u('preventista', v_suc);

  -- P1
  IF EXISTS (SELECT 1 FROM politicas_comerciales WHERE multiplo_redondeo_precio <> 10) THEN
    RAISE EXCEPTION 'P1 · premisa: alguna sucursal no arranca en 10';
  END IF;
  INSERT INTO politicas_comerciales (sucursal_id) SELECT v_suc
   WHERE NOT EXISTS (SELECT 1 FROM politicas_comerciales WHERE sucursal_id = v_suc);
  r := pg_temp.rpc(v_adm, v_suc, 'SELECT to_jsonb(public.actualizar_multiplo_redondeo_precio(50))');
  IF r ? 'error' OR (SELECT multiplo_redondeo_precio FROM politicas_comerciales WHERE sucursal_id = v_suc) <> 50
     OR EXISTS (SELECT 1 FROM politicas_comerciales WHERE sucursal_id <> v_suc AND multiplo_redondeo_precio <> 10) THEN
    RAISE EXCEPTION 'P1 · el admin no lo pudo poner en 50 sólo en su sucursal: %', r;
  END IF;
  r := pg_temp.rpc(v_adm, v_suc, 'SELECT to_jsonb(public.actualizar_multiplo_redondeo_precio(0.01))');
  IF r ? 'error' OR (SELECT multiplo_redondeo_precio FROM politicas_comerciales WHERE sucursal_id = v_suc) <> 0.01 THEN
    RAISE EXCEPTION 'P1 · al centavo: %', r;
  END IF;

  -- P2
  r := pg_temp.rpc(v_enc, v_suc, 'SELECT to_jsonb(public.actualizar_multiplo_redondeo_precio(100))');
  IF NOT (r ? 'error') THEN RAISE EXCEPTION 'P2 · el encargado lo cambió'; END IF;
  r := pg_temp.rpc(v_pre, v_suc, 'SELECT to_jsonb(public.actualizar_multiplo_redondeo_precio(100))');
  IF NOT (r ? 'error') THEN RAISE EXCEPTION 'P2 · el preventista lo cambió'; END IF;

  -- P3
  FOREACH t IN ARRAY ARRAY['0', '-10', '''NaN''::numeric', '10000.01', '1.234'] LOOP
    r := pg_temp.rpc(v_adm, v_suc, format('SELECT to_jsonb(public.actualizar_multiplo_redondeo_precio(%s))', t));
    IF NOT (r ? 'error') THEN RAISE EXCEPTION 'P3 · la RPC aceptó %', t; END IF;
  END LOOP;
  FOREACH t IN ARRAY ARRAY['0', '-10', '''NaN''', '10000.01'] LOOP
    BEGIN
      EXECUTE format('UPDATE politicas_comerciales SET multiplo_redondeo_precio = %s WHERE sucursal_id = %s', t, v_suc);
      RAISE EXCEPTION 'P3 · la columna aceptó %', t;
    EXCEPTION WHEN check_violation THEN NULL;
    END;
  END LOOP;
  IF (SELECT multiplo_redondeo_precio FROM politicas_comerciales WHERE sucursal_id = v_suc) <> 0.01 THEN
    RAISE EXCEPTION 'P2/P3 · un rechazo cambió el múltiplo';
  END IF;

  -- P4
  r := pg_temp.rpc(v_pre, v_suc, format('SELECT to_jsonb(multiplo_redondeo_precio) FROM politicas_comerciales WHERE sucursal_id = %s', v_suc));
  IF r ? 'error' OR r::text <> '0.01' THEN RAISE EXCEPTION 'P4 · authenticated no lee la columna: %', r; END IF;
  r := pg_temp.rpc(v_adm, v_suc, format('UPDATE politicas_comerciales SET multiplo_redondeo_precio = 20 WHERE sucursal_id = %s RETURNING to_jsonb(multiplo_redondeo_precio)', v_suc));
  IF r->>'error' IS DISTINCT FROM '42501' THEN RAISE EXCEPTION 'P4 · authenticated escribió la columna por REST: %', r; END IF;

  RAISE EXCEPTION 'ENSAYO OK: CAT-8 (P1–P4), el múltiplo del redondeo en la política comercial';
END
$t$;
