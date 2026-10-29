-- Ensayo de #1260: en la edicion, la vigencia de un combo se mide en
-- LEAST(fecha del pedido, hoy), como en el alta y como regalo_fuera_de_promo
-- (#1152). Antes la edicion medía en la fecha del pedido sin tope.
--
-- Fixture: combo M (1 + 1 a $90) que empieza manana y combo H (igual) que
-- empieza hoy. Las lineas llevan el reparto exacto (45 / 45).
--
--   F1 · edicion de un pedido con fecha hoy + 5 (sin foto del combo), combo M:
--        "no esta vigente" (antes pasaba: M ya empezo para hoy + 5).
--   F2 · el mismo combo M en el alta: "no esta vigente" (no cambia).
--   F3 · edicion con fecha hoy + 5, combo H: pasa.
--   F4 · edicion con fecha hoy - 3, combo H: pasa (vigente hoy, la regla "o en
--        hoy" de siempre).
--
-- Corre contra prod SIN dejar rastro: todo termina en un RAISE. Veredicto:
-- 'ENSAYO FALLO (...)' o, si todo pasa, el unico error es 'ENSAYO_ROLLBACK'
-- (el NOTICE dice ENSAYO OK). Para el ensayo en seco:
--
--   psql "$DATABASE_URL" -1 -f migrations/408_combos_exactos_y_limite_de_usos.sql \
--                           -f scripts/test-combo-fecha-1260.sql

CREATE OR REPLACE FUNCTION pg_temp.cf_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cf_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cf_prod(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1260 ' || p_nombre, 50, 100, 30, p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cf_combo(p_inicio date, p_a bigint, p_b bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.guardar_combo(jsonb_build_object(
    'nombre', 'ZZ ensayo 1260', 'precio', 90, 'fecha_inicio', p_inicio,
    'componentes', jsonb_build_array(
      jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p_a)),
      jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p_b)))));
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el combo: %', v_res;
  END IF;
  RETURN (v_res->>'id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cf_items(p_combo bigint, p_a bigint, p_b bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(
    jsonb_build_object('producto_id', p_a, 'cantidad', 1, 'precio_unitario', 45, 'precio_sin_combo_unitario', 50, 'combo_id', p_combo),
    jsonb_build_object('producto_id', p_b, 'cantidad', 1, 'precio_unitario', 45, 'precio_sin_combo_unitario', 50, 'combo_id', p_combo));
$fn$;

DO $ensayo$
DECLARE
  v_admin  uuid;
  v_suc    bigint;
  a        bigint;
  b        bigint;
  v_m      bigint;
  v_h      bigint;
  e        text;
  f        text[] := '{}';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  a := pg_temp.cf_prod(v_suc, 'A');
  b := pg_temp.cf_prod(v_suc, 'B');
  v_m := pg_temp.cf_combo(pg_temp.cf_hoy() + 1, a, b);
  v_h := pg_temp.cf_combo(pg_temp.cf_hoy(), a, b);

  -- F1: un pedido que no tiene foto de M (id -1: ninguno).
  e := public.combo_fuera_de_regla(pg_temp.cf_items(v_m, a, b), v_suc, pg_temp.cf_hoy() + 5, -1, true);
  f := pg_temp.cf_si(f, e LIKE '%no está vigente%', format('F1 · edicion hoy+5, combo de manana: %s', COALESCE(e, 'paso')));
  e := public.combo_fuera_de_regla(pg_temp.cf_items(v_m, a, b), v_suc, pg_temp.cf_hoy() + 5, NULL, true);
  f := pg_temp.cf_si(f, e LIKE '%no está vigente%', format('F2 · alta hoy+5, combo de manana: %s', COALESCE(e, 'paso')));
  e := public.combo_fuera_de_regla(pg_temp.cf_items(v_h, a, b), v_suc, pg_temp.cf_hoy() + 5, -1, true);
  f := pg_temp.cf_si(f, e IS NULL, format('F3 · edicion hoy+5, combo de hoy: %s', e));
  e := public.combo_fuera_de_regla(pg_temp.cf_items(v_h, a, b), v_suc, pg_temp.cf_hoy() - 3, -1, true);
  f := pg_temp.cf_si(f, e IS NULL, format('F4 · edicion hoy-3, combo de hoy: %s', e));

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);

  IF cardinality(f) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(f), array_to_string(f, E'\n- ');
  END IF;
  RAISE NOTICE 'ENSAYO OK';
END
$ensayo$;

DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
