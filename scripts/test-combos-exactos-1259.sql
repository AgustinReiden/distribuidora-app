-- Ensayo de #1259: un combo cobra exacto su precio.
--
--   P1 · _combo_prorrateo cierra exacto cuando ninguna linea divide el resto:
--        3 + 2 a $100,01 da 20,01 / 19,99 (antes 20 / 20,01, $100,02); 2 + 3 a
--        $1.000,01 da 227,26 / 181,83 (antes $1.000,00); 6 + 10 + 15 a
--        $4.000,01 da 226,41 / 150,95 / 75,47. "2 por $999,99" da NULL.
--   P2 · barrido de 400 casos al azar (1 a 4 lineas, cantidades 1 a 24): con el
--        mcd de las cantidades dividiendo el total, Σ cantidad × precio = total
--        siempre, y ningun precio se aleja mas de 30 centavos de su proporcion.
--   P3 · guardar_combo rechaza "2 por $999,99" (sugiere $999,98 o $1000,00) y
--        un 4 + 6 a $10,01; acepta "2 por $999,98" y un 2 + 3 a $1.000,01.
--   P4 · combo_fuera_de_regla, combo 2 + 3 a $1.000,01: las lineas del reparto
--        exacto pasan; las del reparto viejo (227,27 / 181,82, que suman
--        $1.000,00) no. Con 10 combos y cada precio corrido 0,0009 (dentro de
--        la tolerancia linea por linea) la suma no cierra y lo rechaza.
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto: 'ENSAYO FALLO (...)' o, si todo pasa, el unico error es
-- 'ENSAYO_ROLLBACK' (el NOTICE dice ENSAYO OK). Para el ensayo en seco:
--
--   psql "$DATABASE_URL" -1 -f migrations/408_combos_exactos_y_limite_de_usos.sql \
--                           -f scripts/test-combos-exactos-1259.sql

CREATE OR REPLACE FUNCTION pg_temp.cx_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cx_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Lo que cobran las lineas con el reparto, en centavos.
CREATE OR REPLACE FUNCTION pg_temp.cx_cobrado(p_lineas jsonb, p_prorr jsonb)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT sum((l->>'cantidad')::numeric * round((p_prorr->>(l->>'producto_id'))::numeric * 100))
    FROM jsonb_array_elements(p_lineas) l;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cx_prod(p_suc bigint, p_nombre text, p_lista numeric)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1259 ' || p_nombre, p_lista, 100, round(p_lista * 0.6, 2), p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cx_combo(p_precio numeric, p_comp jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.guardar_combo(jsonb_build_object('nombre', 'ZZ ensayo 1259', 'precio', p_precio,
                                                 'fecha_inicio', pg_temp.cx_hoy(), 'componentes', p_comp));
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.caso_p1(p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  r jsonb;
BEGIN
  r := public._combo_prorrateo(100.01, '[{"producto_id":7,"cantidad":3,"ref":10},{"producto_id":8,"cantidad":2,"ref":10}]');
  f := pg_temp.cx_si(f, r = '{"7":20.01,"8":19.99}'::jsonb, format('3 + 2 a 100,01: %s', r));
  r := public._combo_prorrateo(1000.01, '[{"producto_id":1,"cantidad":2,"ref":250},{"producto_id":2,"cantidad":3,"ref":200}]');
  f := pg_temp.cx_si(f, r = '{"1":227.26,"2":181.83}'::jsonb, format('2 + 3 a 1.000,01: %s', r));
  r := public._combo_prorrateo(4000.01, '[{"producto_id":1,"cantidad":6,"ref":300},{"producto_id":2,"cantidad":10,"ref":200},{"producto_id":3,"cantidad":15,"ref":100}]');
  f := pg_temp.cx_si(f, r = '{"1":226.41,"2":150.95,"3":75.47}'::jsonb, format('6 + 10 + 15 a 4.000,01: %s', r));
  r := public._combo_prorrateo(999.99, '[{"producto_id":1,"cantidad":2,"ref":600}]');
  f := pg_temp.cx_si(f, r IS NULL, format('2 por 999,99 deberia dar NULL: %s', r));
  -- Lo de siempre no cambia: con una linea que divide el resto, al centavo igual.
  r := public._combo_prorrateo(14000, '[{"producto_id":2,"cantidad":2,"ref":2500},{"producto_id":1,"cantidad":1,"ref":10000}]');
  f := pg_temp.cx_si(f, r = '{"1":9333.34,"2":2333.33}'::jsonb, format('2 + 1 a 14.000 cambio: %s', r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p2(p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  i integer;
  j integer;
  n integer;
  v_lineas jsonb;
  v_g integer;
  v_ref numeric;
  v_t numeric;
  v_prorr jsonb;
  v_desvio numeric;
BEGIN
  PERFORM setseed(0.1259);
  FOR i IN 1..400 LOOP
    n := 1 + floor(random() * 4)::int;
    SELECT jsonb_agg(jsonb_build_object('producto_id', k, 'cantidad', 1 + floor(random() * 24)::int,
                                        'ref', (100 + floor(random() * 50000)) / 100))
      INTO v_lineas FROM generate_series(1, n) k;
    v_g := 0;
    FOR j IN 0..n - 1 LOOP v_g := gcd(v_g, (v_lineas->j->>'cantidad')::int); END LOOP;
    SELECT sum((l->>'cantidad')::numeric * round((l->>'ref')::numeric * 100)) INTO v_ref
      FROM jsonb_array_elements(v_lineas) l;
    v_t := GREATEST(floor((v_ref / 2 + floor(random() * (v_ref / 2))) / v_g), 1) * v_g;
    v_prorr := public._combo_prorrateo(v_t / 100, v_lineas);
    IF v_prorr IS NULL OR pg_temp.cx_cobrado(v_lineas, v_prorr) <> v_t THEN
      f := f || format('no cierra: total %s lineas %s -> %s', v_t / 100, v_lineas, v_prorr);
      CONTINUE;
    END IF;
    SELECT max(abs(round((v_prorr->>(l->>'producto_id'))::numeric * 100)
                   - v_t * round((l->>'ref')::numeric * 100) / v_ref))
      INTO v_desvio FROM jsonb_array_elements(v_lineas) l;
    IF v_desvio > 30 THEN
      f := f || format('se aleja %s centavos: total %s lineas %s -> %s', round(v_desvio, 2), v_t / 100, v_lineas, v_prorr);
    END IF;
    EXIT WHEN cardinality(f) >= 5;
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p3(p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  a bigint := pg_temp.cx_prod(p_suc, 'P3 A', 600);
  b bigint := pg_temp.cx_prod(p_suc, 'P3 B', 250);
  c bigint := pg_temp.cx_prod(p_suc, 'P3 C', 200);
  r jsonb;
BEGIN
  r := pg_temp.cx_combo(999.99, jsonb_build_array(jsonb_build_object('cantidad', 2, 'productos', jsonb_build_array(a))));
  f := pg_temp.cx_si(f, NOT COALESCE((r->>'success')::boolean, false), '2 por $999,99 se guardo');
  f := pg_temp.cx_si(f, r->>'error' LIKE '%múltiplo de $0,02%' AND r->>'error' LIKE '%$999,98 o $1000,00%',
                     format('mensaje de 2 por $999,99: %s', r->>'error'));
  r := pg_temp.cx_combo(10.01, jsonb_build_array(
         jsonb_build_object('cantidad', 4, 'productos', jsonb_build_array(b)),
         jsonb_build_object('cantidad', 6, 'productos', jsonb_build_array(c))));
  f := pg_temp.cx_si(f, NOT COALESCE((r->>'success')::boolean, false), '4 + 6 a $10,01 se guardo');
  r := pg_temp.cx_combo(999.98, jsonb_build_array(jsonb_build_object('cantidad', 2, 'productos', jsonb_build_array(a))));
  f := pg_temp.cx_si(f, COALESCE((r->>'success')::boolean, false), format('2 por $999,98 rechazado: %s', r));
  r := pg_temp.cx_combo(1000.01, jsonb_build_array(
         jsonb_build_object('cantidad', 2, 'productos', jsonb_build_array(b)),
         jsonb_build_object('cantidad', 3, 'productos', jsonb_build_array(c))));
  f := pg_temp.cx_si(f, COALESCE((r->>'success')::boolean, false), format('2 + 3 a $1.000,01 rechazado: %s', r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p4(p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  b bigint := pg_temp.cx_prod(p_suc, 'P4 B', 250);
  c bigint := pg_temp.cx_prod(p_suc, 'P4 C', 200);
  v_combo bigint;
  v_res jsonb;
  v_prorr jsonb;
  e text;
BEGIN
  v_res := pg_temp.cx_combo(1000.01, jsonb_build_array(
             jsonb_build_object('cantidad', 2, 'productos', jsonb_build_array(b)),
             jsonb_build_object('cantidad', 3, 'productos', jsonb_build_array(c))));
  v_combo := (v_res->>'id')::bigint;
  IF v_combo IS NULL THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('no se pudo crear el combo: %s', v_res)));
  END IF;

  e := public.combo_fuera_de_regla(jsonb_build_array(
         jsonb_build_object('producto_id', b, 'cantidad', 2, 'precio_unitario', 227.26, 'precio_sin_combo_unitario', 250, 'combo_id', v_combo),
         jsonb_build_object('producto_id', c, 'cantidad', 3, 'precio_unitario', 181.83, 'precio_sin_combo_unitario', 200, 'combo_id', v_combo)),
         p_suc, pg_temp.cx_hoy(), NULL, true);
  f := pg_temp.cx_si(f, e IS NULL, format('el reparto exacto rechazado: %s', e));

  e := public.combo_fuera_de_regla(jsonb_build_array(
         jsonb_build_object('producto_id', b, 'cantidad', 2, 'precio_unitario', 227.27, 'precio_sin_combo_unitario', 250, 'combo_id', v_combo),
         jsonb_build_object('producto_id', c, 'cantidad', 3, 'precio_unitario', 181.82, 'precio_sin_combo_unitario', 200, 'combo_id', v_combo)),
         p_suc, pg_temp.cx_hoy(), NULL, true);
  f := pg_temp.cx_si(f, e IS NOT NULL, 'el reparto viejo ($1.000,00) paso');

  -- 10 combos: cada precio corrido 0,0009 pasa linea por linea, pero 20 + 30
  -- unidades corren la suma 0,045.
  v_prorr := public._combo_prorrateo(10000.10, jsonb_build_array(
               jsonb_build_object('producto_id', b, 'cantidad', 20, 'ref', 250),
               jsonb_build_object('producto_id', c, 'cantidad', 30, 'ref', 200)));
  e := public.combo_fuera_de_regla(jsonb_build_array(
         jsonb_build_object('producto_id', b, 'cantidad', 20, 'precio_sin_combo_unitario', 250, 'combo_id', v_combo,
                            'precio_unitario', (v_prorr->>b::text)::numeric + 0.0009),
         jsonb_build_object('producto_id', c, 'cantidad', 30, 'precio_sin_combo_unitario', 200, 'combo_id', v_combo,
                            'precio_unitario', (v_prorr->>c::text)::numeric + 0.0009)),
         p_suc, pg_temp.cx_hoy(), NULL, true);
  f := pg_temp.cx_si(f, e LIKE '%no suman su precio%', format('la suma corrida 0,045 no se rechazo por la suma: %s', e));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Corrida
-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_admin  uuid;
  v_suc    bigint;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
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

  FOREACH v_caso IN ARRAY ARRAY['p1', 'p2', 'p3', 'p4'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2)', v_caso) INTO v_out USING v_admin, v_suc;
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

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE NOTICE 'ENSAYO OK';
END
$ensayo$;

DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
