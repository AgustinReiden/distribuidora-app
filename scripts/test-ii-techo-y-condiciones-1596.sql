-- Ensayo de la migración «el techo del impuesto interno es 99 % nominal y fusionar
-- condiciones mira activo» (tarjeta M4 del plan #1603: CAT-9 y CAT-10 de #1596, y
-- 1561-c5 de #1561).
--
-- CAT-9: `productos.impuestos_internos` es la tasa efectiva, 100·n/(1−n), y su
-- CHECK la topaba en 100: un 50 % nominal o más no se podía usar, y un alza
-- programada así hacía fallar entero refrescar_ii_productos(). Decisión del dueño
-- (15/11): el techo es 99 % nominal, 9900 de efectiva.
--   I1 · [F] un encuadre al 70 % nominal: el alta de un producto en él entra con
--        233,3333, y subir otro encuadre con productos al 55 % entra (122,2222).
--   I2 · [F] el alza programada al 60 % en un encuadre y otra en otro: el refresco
--        del día siguiente actualiza los dos, y II-A no ve deriva en ellos.
--   I3 · [F] un encuadre cuyas fichas no se pueden escribir (un CHECK del ensayo
--        las frena) no impide refrescar los demás: avisa y sigue.
--   I4 · [F] cambiar_alicuota_ii rechaza (22023) una nominal de más de 99 %, negativa,
--        NaN o NULL, y acepta 99 %. El CHECK de ii_alicuotas cierra lo mismo (23514).
--   I5 · [F] los CHECK de productos y compra_items: 9900 entra; 9900,5, −1 y NaN no.
--   I6 · [F] el validador de los renglones de una compra acepta un impuesto interno de
--        233,3333 y rechaza 9900,5 con su mensaje.
--   I7 · [R] H2 de la revisión: el cambio de tasa de un admin (cambiar_alicuota_ii,
--        por el trigger de ii_alicuotas) con una ficha que no se puede refrescar
--        falla entero con el motivo, y la tasa no cambia. Sólo la corrida diaria
--        sigue con los demás encuadres (I3).
-- CAT-10: consolidar_condiciones ignoraba `activo`. Decisión del dueño (15/11):
-- fusionar condiciones con distinto activo se rechaza.
--   C1 · [F] activa en inactiva y al revés: rechaza, y no se mueve nada.
--   C2 · [F] dos escalas de la misma cantidad y precio, una activa y otra no: rechaza.
--   C3 · [R] dos activas con la misma escala: fusiona.
--   C4 · [F] 1561-c5: un id repetido en el origen se fusiona una vez.
--   C5 · [R] H3 de la revisión: un activo NULL es activo (como lo lee
--        precio_fuera_de_politica): un grupo o una escala en NULL se fusionan con
--        los activos.
--   K1 · los permisos de las funciones no cambiaron.
--
-- [F] falla sin la migración y pasa con ella; [R] pasa antes y después.
-- Fixtures: un admin activo de una sucursal activa. Todo lo demás nace en el ensayo.
-- Un único DO que termina SIEMPRE en una excepción: no deja nada. Cada caso corre en
-- un sub-bloque que se revierte.
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplió.
--
--   psql "$DATABASE_URL" -1 -f scripts/test-ii-techo-y-condiciones-1596.sql

-- El día es el argentino, no el de la sesión: entre las 21 y las 24 de Argentina CURRENT_DATE ya es mañana y el
-- sistema (que mide con _tablero_hoy()) rechaza la fecha del ensayo como futura (B13d).
CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Corre una sentencia y devuelve 'ok' (y lo que escribió queda) o el SQLSTATE y el
-- mensaje (y no queda nada).
CREATE OR REPLACE FUNCTION pg_temp.t_err(p_sql text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  EXECUTE p_sql;
  RETURN 'ok';
EXCEPTION WHEN OTHERS THEN
  RETURN SQLSTATE || ' ' || SQLERRM;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_encuadre(p_nombre text, p_tasa numeric, p_desde date)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.ii_encuadres (nombre) VALUES ('ZZ ensayo 1596 ' || p_nombre || ' ' || gen_random_uuid())
  RETURNING id INTO v;
  PERFORM public.cambiar_alicuota_ii(v, p_tasa, p_desde);
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_enc bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, sucursal_id, ii_encuadre_id)
  VALUES ('ZZ ensayo 1596', 3000, 5, p_suc, p_enc) RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_ii(p_prod bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT impuestos_internos FROM public.productos WHERE id = p_prod;
$fn$;

-- Las fichas de unos encuadres con la efectiva distinta de la de hoy (lo que cuenta II-A).
CREATE OR REPLACE FUNCTION pg_temp.t_deriva(p_encs bigint[])
RETURNS int LANGUAGE sql AS $fn$
  SELECT count(*)::int FROM public.productos
   WHERE ii_encuadre_id = ANY (p_encs)
     AND impuestos_internos IS DISTINCT FROM COALESCE(round(public.ii_tasa_efectiva(
           ii_encuadre_id, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date), 4), 0);
$fn$;

-- Corre las vigencias de unos encuadres un día atrás sin disparar el refresco:
-- es "mañana", cuando el job diario corre con las alzas ya vigentes.
CREATE OR REPLACE FUNCTION pg_temp.t_manana(p_encs bigint[])
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  SET LOCAL session_replication_role = replica;
  UPDATE public.ii_alicuotas
     SET vigente_desde = vigente_desde - 1,
         vigente_hasta = vigente_hasta - 1
   WHERE encuadre_id = ANY (p_encs);
  SET LOCAL session_replication_role = origin;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_grupo(p_suc bigint, p_nombre text, p_activo boolean, p_prod bigint,
                                           p_cant int, p_precio numeric, p_escala_activa boolean)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.grupos_precio (nombre, activo, sucursal_id) VALUES ('ZZ ensayo 1596 ' || p_nombre, p_activo, p_suc)
  RETURNING id INTO v;
  INSERT INTO public.grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id) VALUES (v, p_prod, p_suc);
  IF p_cant IS NOT NULL THEN
    INSERT INTO public.grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, activo, sucursal_id)
    VALUES (v, p_cant, p_precio, p_escala_activa, p_suc);
  END IF;
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_prod_simple(p_suc bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, sucursal_id) VALUES ('ZZ ensayo 1596', 100, 100, p_suc) RETURNING id;
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.caso_i1(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_e1 bigint; v_e2 bigint; v_p bigint; v_p2 bigint; v_r text;
BEGIN
  v_e1 := pg_temp.t_encuadre('cigarrillos', 0.70, public._tablero_hoy() - 1);
  v_r := pg_temp.t_err(format('SELECT pg_temp.t_prod(%s, %s)', p_suc, v_e1));
  f := pg_temp.t_si(f, v_r = 'ok', format('el alta en un encuadre al 70 %%: %s', v_r));
  SELECT id INTO v_p FROM public.productos WHERE ii_encuadre_id = v_e1;
  f := pg_temp.t_si(f, pg_temp.t_ii(v_p) = 233.3333, format('la ficha al 70 %% quedó en %s, esperado 233.3333', pg_temp.t_ii(v_p)));
  v_e2 := pg_temp.t_encuadre('alcohol', 0.20, public._tablero_hoy() - 10);
  v_p2 := pg_temp.t_prod(p_suc, v_e2);
  v_r := pg_temp.t_err(format('SELECT public.cambiar_alicuota_ii(%s, 0.55, public._tablero_hoy())', v_e2));
  f := pg_temp.t_si(f, v_r = 'ok' AND pg_temp.t_ii(v_p2) = 122.2222,
                    format('subir al 55 %% con una ficha adentro: %s, ficha %s (esperado 122.2222)', v_r, pg_temp.t_ii(v_p2)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_i2(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_e1 bigint; v_e2 bigint; v_p1 bigint; v_p2 bigint; v_r text;
BEGIN
  v_e1 := pg_temp.t_encuadre('E1', 0.20, public._tablero_hoy() - 30);
  v_e2 := pg_temp.t_encuadre('E2', 0.30, public._tablero_hoy() - 30);
  v_p1 := pg_temp.t_prod(p_suc, v_e1);
  v_p2 := pg_temp.t_prod(p_suc, v_e2);
  v_r := pg_temp.t_err(format('SELECT public.cambiar_alicuota_ii(%s, 0.60, public._tablero_hoy() + 1)', v_e2));
  f := pg_temp.t_si(f, v_r = 'ok', format('programar E2 al 60 %%: %s', v_r));
  PERFORM public.cambiar_alicuota_ii(v_e1, 0.25, public._tablero_hoy() + 1);
  PERFORM pg_temp.t_manana(ARRAY[v_e1, v_e2]);
  v_r := pg_temp.t_err('SELECT public.refrescar_ii_productos()');
  f := pg_temp.t_si(f, v_r = 'ok', format('refrescar_ii_productos(): %s', v_r));
  f := pg_temp.t_si(f, pg_temp.t_ii(v_p1) = 33.3333 AND pg_temp.t_ii(v_p2) = 150,
                    format('después del refresco E1 %s y E2 %s; esperado 33.3333 y 150', pg_temp.t_ii(v_p1), pg_temp.t_ii(v_p2)));
  f := pg_temp.t_si(f, pg_temp.t_deriva(ARRAY[v_e1, v_e2]) = 0,
                    format('II-A ve %s fichas con deriva en los dos encuadres', pg_temp.t_deriva(ARRAY[v_e1, v_e2])));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_i3(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_e1 bigint; v_e2 bigint; v_p1 bigint; v_p2 bigint; v_r text;
BEGIN
  v_e1 := pg_temp.t_encuadre('E1', 0.20, public._tablero_hoy() - 30);
  v_e2 := pg_temp.t_encuadre('E2', 0.30, public._tablero_hoy() - 30);
  v_p1 := pg_temp.t_prod(p_suc, v_e1);
  v_p2 := pg_temp.t_prod(p_suc, v_e2);
  PERFORM public.cambiar_alicuota_ii(v_e1, 0.25, public._tablero_hoy() + 1);
  PERFORM public.cambiar_alicuota_ii(v_e2, 0.40, public._tablero_hoy() + 1);
  PERFORM pg_temp.t_manana(ARRAY[v_e1, v_e2]);
  -- Las fichas de E2 no se pueden escribir: un CHECK del ensayo, que no valida lo que hay.
  EXECUTE format('ALTER TABLE public.productos ADD CONSTRAINT zz_ensayo_1596 CHECK (ii_encuadre_id <> %s OR impuestos_internos < 50) NOT VALID', v_e2);
  v_r := pg_temp.t_err('SELECT public.refrescar_ii_productos()');
  f := pg_temp.t_si(f, v_r = 'ok', format('refrescar_ii_productos() con un encuadre que falla: %s', v_r));
  f := pg_temp.t_si(f, pg_temp.t_ii(v_p1) = 33.3333 AND pg_temp.t_ii(v_p2) = 42.8571,
                    format('E1 %s (esperado 33.3333) y E2 %s (esperado 42.8571, sin refrescar)', pg_temp.t_ii(v_p1), pg_temp.t_ii(v_p2)));
  f := pg_temp.t_si(f, pg_temp.t_deriva(ARRAY[v_e1]) = 0 AND pg_temp.t_deriva(ARRAY[v_e2]) = 1,
                    format('deriva E1 %s y E2 %s; esperado 0 y 1 (la ve II-A)', pg_temp.t_deriva(ARRAY[v_e1]), pg_temp.t_deriva(ARRAY[v_e2])));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_i7(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_e1 bigint; v_e2 bigint; v_p1 bigint; v_p2 bigint; v_r text;
BEGIN
  v_e1 := pg_temp.t_encuadre('E1', 0.20, public._tablero_hoy() - 30);
  v_e2 := pg_temp.t_encuadre('E2', 0.20, public._tablero_hoy() - 30);
  v_p1 := pg_temp.t_prod(p_suc, v_e1);
  v_p2 := pg_temp.t_prod(p_suc, v_e2);
  -- Una regla ajena que frena la ficha de E1 al 30 % (42,8571).
  EXECUTE format('ALTER TABLE public.productos ADD CONSTRAINT zz_ensayo_1596_h2 CHECK (id <> %s OR impuestos_internos <> 42.8571) NOT VALID', v_p1);
  v_r := pg_temp.t_err(format('SELECT public.cambiar_alicuota_ii(%s, 0.30, public._tablero_hoy())', v_e1));
  f := pg_temp.t_si(f, v_r LIKE '23514 %zz_ensayo_1596_h2%', format('el cambio de tasa tendría que fallar con el motivo: %s', v_r));
  f := pg_temp.t_si(f, pg_temp.t_ii(v_p1) = 25
                       AND (SELECT tasa_nominal FROM public.ii_alicuotas WHERE encuadre_id = v_e1 AND vigente_hasta IS NULL) = 0.2,
                    format('la tasa cambió igual: ficha %s, vigente %s', pg_temp.t_ii(v_p1),
                           (SELECT tasa_nominal FROM public.ii_alicuotas WHERE encuadre_id = v_e1 AND vigente_hasta IS NULL)));
  f := pg_temp.t_si(f, pg_temp.t_deriva(ARRAY[v_e1, v_e2]) = 0,
                    format('II-A ve %s fichas con deriva', pg_temp.t_deriva(ARRAY[v_e1, v_e2])));
  -- El otro encuadre se sigue cambiando normalmente.
  v_r := pg_temp.t_err(format('SELECT public.cambiar_alicuota_ii(%s, 0.30, public._tablero_hoy())', v_e2));
  f := pg_temp.t_si(f, v_r = 'ok' AND pg_temp.t_ii(v_p2) = 42.8571, format('el otro encuadre: %s, ficha %s', v_r, pg_temp.t_ii(v_p2)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_i4(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_e bigint; v_r text; c record;
BEGIN
  INSERT INTO public.ii_encuadres (nombre) VALUES ('ZZ ensayo 1596 I4 ' || gen_random_uuid()) RETURNING id INTO v_e;
  FOR c IN SELECT * FROM (VALUES ('0.995'), ('1'), ('-0.01'), ($$'NaN'$$), ('NULL')) AS t(v) LOOP
    v_r := pg_temp.t_err(format('SELECT public.cambiar_alicuota_ii(%s, %s::numeric, public._tablero_hoy())', v_e, c.v));
    f := pg_temp.t_si(f, v_r LIKE '22023 %99 %%', format('cambiar_alicuota_ii con %s: %s', c.v, v_r));
  END LOOP;
  v_r := pg_temp.t_err(format('SELECT public.cambiar_alicuota_ii(%s, 0.99, public._tablero_hoy())', v_e));
  f := pg_temp.t_si(f, v_r = 'ok', format('cambiar_alicuota_ii con 0,99: %s', v_r));
  -- Por la tabla, en un encuadre sin alícuotas (así no choca con la vigencia de arriba).
  INSERT INTO public.ii_encuadres (nombre) VALUES ('ZZ ensayo 1596 I4b ' || gen_random_uuid()) RETURNING id INTO v_e;
  FOR c IN SELECT * FROM (VALUES ('0.995', 1), ($$'NaN'$$, 2), ('-0.01', 3)) AS t(v, n) LOOP
    v_r := pg_temp.t_err(format('INSERT INTO public.ii_alicuotas (encuadre_id, tasa_nominal, vigente_desde, vigente_hasta) VALUES (%s, %s, public._tablero_hoy() + %s, public._tablero_hoy() + %s)', v_e, c.v, c.n, c.n));
    f := pg_temp.t_si(f, v_r LIKE '23514 %ii_alicuotas_tasa_rango%', format('ii_alicuotas con %s: %s', c.v, v_r));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_i5(p_suc bigint, p_adm uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_p bigint; v_c bigint; v_ci bigint; v_r text; c record;
BEGIN
  v_p := pg_temp.t_prod_simple(p_suc);
  INSERT INTO public.compras (sucursal_id, estado, usuario_id) VALUES (p_suc, 'recibida', p_adm) RETURNING id INTO v_c;
  INSERT INTO public.compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, sucursal_id)
  VALUES (v_c, v_p, 1, 10, 10, p_suc) RETURNING id INTO v_ci;
  SET LOCAL session_replication_role = replica;
  FOR c IN SELECT * FROM (VALUES ('9900', true), ('233.3333', true), ('9900.5', false), ('-1', false), ($$'NaN'$$, false)) AS t(v, entra) LOOP
    v_r := pg_temp.t_err(format('UPDATE public.productos SET impuestos_internos = %s WHERE id = %s', c.v, v_p));
    f := pg_temp.t_si(f, (v_r = 'ok') = c.entra AND (c.entra OR v_r LIKE '23514 %productos_impuestos_internos_rango%'),
                      format('productos con %s: %s', c.v, v_r));
    v_r := pg_temp.t_err(format('UPDATE public.compra_items SET impuestos_internos = %s WHERE id = %s', c.v, v_ci));
    f := pg_temp.t_si(f, (v_r = 'ok') = c.entra AND (c.entra OR v_r LIKE '23514 %compra_items_impuestos_internos_rango%'),
                      format('compra_items con %s: %s', c.v, v_r));
  END LOOP;
  SET LOCAL session_replication_role = origin;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_i6(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_p bigint; v jsonb;
BEGIN
  v_p := pg_temp.t_prod_simple(p_suc);
  v := to_jsonb(public._compra_renglones_fuera_de_rango(jsonb_build_array(jsonb_build_object(
         'producto_id', v_p, 'cantidad', 1, 'costo_unitario', 10, 'impuestos_internos', 233.3333)), p_suc));
  f := pg_temp.t_si(f, v IS NULL OR v = 'null'::jsonb, format('un II de 233,3333 da %s, esperado que entre', v));
  v := to_jsonb(public._compra_renglones_fuera_de_rango(jsonb_build_array(jsonb_build_object(
         'producto_id', v_p, 'cantidad', 1, 'costo_unitario', 10, 'impuestos_internos', 9900.5)), p_suc));
  f := pg_temp.t_si(f, v::text LIKE '%9900 % (99 % nominal)%', format('un II de 9900,5 da %s, esperado el techo', v));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c1(p_suc bigint, p_adm uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_r text;
BEGIN
  v_a := pg_temp.t_grupo(p_suc, 'A activa', true, pg_temp.t_prod_simple(p_suc), 10, 90, true);
  v_b := pg_temp.t_grupo(p_suc, 'B inactiva', false, pg_temp.t_prod_simple(p_suc), 10, 90, true);
  v_r := pg_temp.t_err(format('SELECT public.consolidar_condiciones(%s, ARRAY[%s]::bigint[])', v_b, v_a));
  f := pg_temp.t_si(f, v_r LIKE '%«ZZ ensayo 1596 A activa» está activa y la condición destino está inactiva%',
                    format('activa en inactiva: %s', v_r));
  v_r := pg_temp.t_err(format('SELECT public.consolidar_condiciones(%s, ARRAY[%s]::bigint[])', v_a, v_b));
  f := pg_temp.t_si(f, v_r LIKE '%está inactiva y la condición destino está activa%', format('inactiva en activa: %s', v_r));
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.grupos_precio WHERE id IN (v_a, v_b)) = 2
                       AND (SELECT count(*) FROM public.grupo_precio_productos WHERE grupo_precio_id = v_a) = 1
                       AND (SELECT count(*) FROM public.grupo_precio_productos WHERE grupo_precio_id = v_b) = 1,
                    'el rechazo movió algo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c2(p_suc bigint, p_adm uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_r text;
BEGIN
  v_a := pg_temp.t_grupo(p_suc, 'A', true, pg_temp.t_prod_simple(p_suc), 10, 90, true);
  v_b := pg_temp.t_grupo(p_suc, 'B', true, pg_temp.t_prod_simple(p_suc), 10, 90, false);
  v_r := pg_temp.t_err(format('SELECT public.consolidar_condiciones(%s, ARRAY[%s]::bigint[])', v_b, v_a));
  f := pg_temp.t_si(f, v_r LIKE '%la escala de 10 u. está activa en una condición e inactiva en otra%',
                    format('escalas con distinto activo: %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c3(p_suc bigint, p_adm uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_r text;
BEGIN
  v_a := pg_temp.t_grupo(p_suc, 'A', true, pg_temp.t_prod_simple(p_suc), 10, 90, true);
  v_b := pg_temp.t_grupo(p_suc, 'B', true, pg_temp.t_prod_simple(p_suc), 10, 90, true);
  v_r := pg_temp.t_err(format('SELECT public.consolidar_condiciones(%s, ARRAY[%s]::bigint[])', v_b, v_a));
  f := pg_temp.t_si(f, v_r = 'ok' AND NOT EXISTS (SELECT 1 FROM public.grupos_precio WHERE id = v_a)
                       AND (SELECT count(*) FROM public.grupo_precio_productos WHERE grupo_precio_id = v_b) = 2,
                    format('dos activas: %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c4(p_suc bigint, p_adm uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_res jsonb;
BEGIN
  v_a := pg_temp.t_grupo(p_suc, 'A', true, pg_temp.t_prod_simple(p_suc), 10, 90, true);
  v_b := pg_temp.t_grupo(p_suc, 'B', true, pg_temp.t_prod_simple(p_suc), 20, 80, true);
  BEGIN
    v_res := public.consolidar_condiciones(v_b, ARRAY[v_a, v_a]);
  EXCEPTION WHEN OTHERS THEN
    v_res := jsonb_build_object('error', SQLERRM);
  END;
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false) AND (v_res->>'grupos_borrados')::int = 1
                       AND (v_res->>'escalas_movidas')::int = 1
                       AND (SELECT count(*) FROM public.grupo_precio_escalas WHERE grupo_precio_id = v_b) = 2,
                    format('un id repetido: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c5(p_suc bigint, p_adm uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_r text;
BEGIN
  v_a := pg_temp.t_grupo(p_suc, 'A null', NULL, pg_temp.t_prod_simple(p_suc), 10, 90, true);
  v_b := pg_temp.t_grupo(p_suc, 'B activa', true, pg_temp.t_prod_simple(p_suc), 10, 90, true);
  v_r := pg_temp.t_err(format('SELECT public.consolidar_condiciones(%s, ARRAY[%s]::bigint[])', v_b, v_a));
  f := pg_temp.t_si(f, v_r = 'ok', format('grupo con activo NULL en uno activo: %s', v_r));
  v_a := pg_temp.t_grupo(p_suc, 'C', true, pg_temp.t_prod_simple(p_suc), 6, 80, NULL);
  v_b := pg_temp.t_grupo(p_suc, 'D', true, pg_temp.t_prod_simple(p_suc), 6, 80, true);
  v_r := pg_temp.t_err(format('SELECT public.consolidar_condiciones(%s, ARRAY[%s]::bigint[])', v_b, v_a));
  f := pg_temp.t_si(f, v_r = 'ok', format('escala con activo NULL contra una activa: %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo$
DECLARE
  v_admin  uuid;
  v_suc    bigint;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
  r        record;
BEGIN
  SET LOCAL lock_timeout = '5s';

  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un admin activo con una sucursal activa';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  FOREACH v_caso IN ARRAY ARRAY['i1', 'i2', 'i3', 'i4', 'i5', 'i6', 'i7', 'c1', 'c2', 'c3', 'c4', 'c5'] LOOP
    v_out := NULL;
    BEGIN
      IF v_caso IN ('i5', 'c1', 'c2', 'c3', 'c4', 'c5') THEN
        EXECUTE format('SELECT pg_temp.caso_%s($1, $2)', v_caso) INTO v_out USING v_suc, v_admin;
      ELSE
        EXECUTE format('SELECT pg_temp.caso_%s($1)', v_caso) INTO v_out USING v_suc;
      END IF;
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

  -- K1 · los permisos no cambiaron
  FOR r IN SELECT * FROM (VALUES
    ('public.consolidar_condiciones(bigint,bigint[],text)', true, true),
    ('public.cambiar_alicuota_ii(bigint,numeric,date)', true, true),
    ('public.refrescar_ii_productos()', true, false),
    ('public._compra_renglones_fuera_de_rango(jsonb,bigint)', false, false)
  ) AS t(fn, def, auth) LOOP
    IF (SELECT prosecdef FROM pg_proc WHERE oid = r.fn::regprocedure) IS DISTINCT FROM r.def
       OR has_function_privilege('anon', r.fn, 'EXECUTE')
       OR has_function_privilege('authenticated', r.fn, 'EXECUTE') IS DISTINCT FROM r.auth THEN
      v_fallas := v_fallas || format('K1 · cambiaron el definer o los EXECUTE de %s', r.fn);
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · CAT-9 (I1-I7) y CAT-10 (C1-C3, C5) de #1596, 1561-c5 (C4) y permisos (K1)';
END
$ensayo$;
