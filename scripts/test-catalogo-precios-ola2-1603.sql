-- Ensayo de la migración «catálogo, precios y mínimos» (tarjeta B6a de la ola 2 del
-- plan #1603: los bajos 1561-b2, b7, b8, b9, c3 y c4 de #1561; CAT-13 y los bajos
-- 1596-b2, b3, b6, b7 y b9 de #1596; y `cambiar_alicuota_ii` sin fecha, que anotó M4).
--
-- Aumento masivo (`actualizar_precios_masivo`):
--   P1 · [F] 1596-b2: un neto mayor que el final no entra, y el producto no cambia. El
--        neto igual al final (exento) sí entra.
--   P2 · [F] 1596-b2: un producto repetido en el lote no se cambia, con un solo aviso;
--        el resto del lote sí.
--   P3 · [F] 1561-c4: la escala de una condición sin productos no cambia aunque venga
--        en el lote.
--   P4 · [R] la escala de una condición cuyos productos cambiaron todos sí cambia.
-- Mínimos:
--   M1 · [F] 1561-b9 (D35): el encargado no cambia la compra mínima, por ninguna de las
--        dos RPCs (42501); el admin sí.
--   M2 · [F] 1596-b3 (D36): la compra mínima va hasta $ 99.999.999, por las dos RPCs
--        (22023 con el motivo) y por el CHECK de la tabla.
--   M3 · [F] 1561-b8: el mensaje del mínimo con un total de 1.500 millones no trae
--        `#`, y la RPC vieja en modo escalas avisa con su motivo en vez del 23514.
--   M4 · [F] 1596-b3: el mínimo de venta masivo va hasta 100.000 (el techo del CHECK de
--        B7, 1596-b1), con su motivo (22023) y no el 23514 del CHECK.
-- Rubros:
--   R1 · [F] 1596-b6: dos rubros que difieren sólo en mayúsculas o espacios chocan
--        (23505), y dos subrubros del mismo rubro también; en rubros distintos, no.
--   R2 · [R] 1561-b7: el texto del rubro de un producto encuentra su rubro aunque
--        difiera en mayúsculas y espacios.
--   R3 · [R] renombrar un rubro sólo en mayúsculas sigue andando.
-- Duplicado de cliente:
--   D1 · [F] 1596-b7: «Mitre 450, Local 1» y «Mitre 450, Local 2» no chocan.
--   D2 · [R] la misma puerta con y sin la ciudad de Google sigue chocando, y un barrio
--        sin altura no tiene clave.
-- Borrar un producto (1561-b2, D32):
--   B1 · [F] con stock no se borra (23503, con el motivo).
--   B2 · [F] con un lote (aunque esté agotado) no se borra.
--   B3 · [F] el regalo de una promoción no se borra.
--   B4 · [R] sin stock, sin lotes y sin promo, se borra.
-- CAT-13 (D30):
--   S1 · [F] en el resumen del bot un stock mínimo de 0 es «sin alerta»; vacío usa 10.
-- Impuestos internos:
--   A1 · [F] cambiar_alicuota_ii sin fecha rechaza con su motivo (22023).
--   K1 · los permisos de las funciones no cambiaron.
--
-- [F] falla sin la migración y pasa con ella; [R] pasa antes y después.
-- Fixtures: un admin activo de una sucursal activa. Todo lo demás nace en el ensayo
-- (un encargado se da de alta en auth.users con su app_metadata).
-- Un único DO que termina SIEMPRE en una excepción: no deja nada. Cada caso corre en
-- un sub-bloque que se revierte.
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplió.
--
--   psql "$DATABASE_URL" -1 -f scripts/test-catalogo-precios-ola2-1603.sql

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

CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_precio numeric DEFAULT 1210, p_stock int DEFAULT 0,
                                          p_categoria text DEFAULT NULL)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, precio_sin_iva, stock, sucursal_id, categoria)
  VALUES ('ZZ ensayo B6a ' || gen_random_uuid(), p_precio, round(p_precio / 1.21, 2), p_stock, p_suc, p_categoria)
  RETURNING id;
$fn$;

-- Como otro usuario: cambia el sub del JWT (la sucursal queda).
CREATE OR REPLACE FUNCTION pg_temp.t_como(p_uid uuid)
RETURNS void LANGUAGE sql AS $fn$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
$fn$;

-- ---------------------------------------------------------------------------
-- Aumento masivo
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.caso_p1(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_res jsonb; v_neto numeric; v_final numeric;
BEGIN
  v_a := pg_temp.t_prod(p_suc);
  v_b := pg_temp.t_prod(p_suc);
  v_res := public.actualizar_precios_masivo(jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'precio_neto', 2000, 'precio_final', 1500),
    jsonb_build_object('producto_id', v_b, 'precio_neto', 1500, 'precio_final', 1500)));
  SELECT precio_sin_iva, precio INTO v_neto, v_final FROM public.productos WHERE id = v_a;
  f := pg_temp.t_si(f, v_neto = 1000 AND v_final = 1210,
                    format('un neto (2000) mayor que el final (1500) entró: quedó %s / %s (%s)', v_neto, v_final, v_res));
  f := pg_temp.t_si(f, (v_res->>'actualizados')::int = 1
                       AND (v_res->'errores')::text ILIKE '%neto%',
                    format('el lote tenía que cambiar sólo el exento y avisar del otro: %s', v_res));
  SELECT precio_sin_iva, precio INTO v_neto, v_final FROM public.productos WHERE id = v_b;
  f := pg_temp.t_si(f, v_neto = 1500 AND v_final = 1500, format('el neto igual al final no entró: %s / %s', v_neto, v_final));
  -- Sólo el neto, contra un final guardado más bajo: tampoco.
  v_res := public.actualizar_precios_masivo(jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'precio_neto', 1300)));
  SELECT precio_sin_iva INTO v_neto FROM public.productos WHERE id = v_a;
  f := pg_temp.t_si(f, v_neto = 1000, format('un neto (1300) por encima del final guardado (1210) entró: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p2(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_b bigint; v_res jsonb; v_final numeric;
BEGIN
  v_a := pg_temp.t_prod(p_suc);
  v_b := pg_temp.t_prod(p_suc);
  v_res := public.actualizar_precios_masivo(jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'precio_neto', 1000, 'precio_final', 1300),
    jsonb_build_object('producto_id', v_b, 'precio_neto', 1000, 'precio_final', 1300),
    jsonb_build_object('producto_id', v_a, 'precio_neto', 1000, 'precio_final', 1400)));
  SELECT precio INTO v_final FROM public.productos WHERE id = v_a;
  f := pg_temp.t_si(f, v_final = 1210, format('el producto repetido cambió a %s (%s)', v_final, v_res));
  SELECT precio INTO v_final FROM public.productos WHERE id = v_b;
  f := pg_temp.t_si(f, v_final = 1300, format('el resto del lote no cambió: %s (%s)', v_final, v_res));
  f := pg_temp.t_si(f, (v_res->>'actualizados')::int = 1 AND jsonb_array_length(v_res->'errores') = 1
                       AND (v_res->'errores'->>0) ILIKE '%más de una vez%',
                    format('tenía que avisar una vez del repetido: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p3(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_g bigint; v_e bigint; v_res jsonb; v_p numeric;
BEGIN
  v_a := pg_temp.t_prod(p_suc);
  INSERT INTO public.grupos_precio (nombre, activo, sucursal_id) VALUES ('ZZ ensayo B6a vacía ' || gen_random_uuid(), true, p_suc)
  RETURNING id INTO v_g;
  INSERT INTO public.grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, activo, sucursal_id)
  VALUES (v_g, 10, 900, true, p_suc) RETURNING id INTO v_e;
  v_res := public.actualizar_precios_masivo(
    jsonb_build_array(jsonb_build_object('producto_id', v_a, 'precio_neto', 1000, 'precio_final', 1300)),
    jsonb_build_array(jsonb_build_object('escala_id', v_e, 'precio_unitario', 5000)));
  SELECT precio_unitario INTO v_p FROM public.grupo_precio_escalas WHERE id = v_e;
  f := pg_temp.t_si(f, v_p = 900, format('la escala de una condición sin productos cambió a %s (%s)', v_p, v_res));
  f := pg_temp.t_si(f, (v_res->>'escalas_actualizadas')::int = 0 AND (v_res->'errores')::text ILIKE '%no tiene productos%',
                    format('tenía que avisar que la condición no tiene productos en el lote: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_p4(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a bigint; v_g bigint; v_e bigint; v_res jsonb; v_p numeric;
BEGIN
  v_a := pg_temp.t_prod(p_suc);
  INSERT INTO public.grupos_precio (nombre, activo, sucursal_id) VALUES ('ZZ ensayo B6a llena ' || gen_random_uuid(), true, p_suc)
  RETURNING id INTO v_g;
  INSERT INTO public.grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id) VALUES (v_g, v_a, p_suc);
  INSERT INTO public.grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, activo, sucursal_id)
  VALUES (v_g, 10, 1100, true, p_suc) RETURNING id INTO v_e;
  v_res := public.actualizar_precios_masivo(
    jsonb_build_array(jsonb_build_object('producto_id', v_a, 'precio_neto', 1100, 'precio_final', 1331)),
    jsonb_build_array(jsonb_build_object('escala_id', v_e, 'precio_unitario', 1210)));
  SELECT precio_unitario INTO v_p FROM public.grupo_precio_escalas WHERE id = v_e;
  f := pg_temp.t_si(f, v_p = 1210 AND (v_res->>'success')::boolean, format('la escala no cambió: %s (%s)', v_p, v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Mínimos
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.caso_m1(p_suc bigint, p_adm uuid, p_enc uuid)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_r text; v_m numeric;
BEGIN
  PERFORM pg_temp.t_como(p_enc);
  v_r := pg_temp.t_err($q$SELECT public.actualizar_politica_minimo_pedido('bloquear', 5000000, 0, 0)$q$);
  f := pg_temp.t_si(f, v_r LIKE '42501%', format('el encargado cambió la política del mínimo: %s', v_r));
  v_r := pg_temp.t_err($q$SELECT public.actualizar_monto_minimo_pedido(5000000)$q$);
  f := pg_temp.t_si(f, v_r LIKE '42501%', format('el encargado cambió el monto mínimo (RPC vieja): %s', v_r));
  PERFORM pg_temp.t_como(p_adm);
  v_r := pg_temp.t_err($q$SELECT public.actualizar_politica_minimo_pedido('bloquear', 5000, 0, 0)$q$);
  SELECT monto_minimo_pedido INTO v_m FROM public.politicas_comerciales WHERE sucursal_id = p_suc;
  f := pg_temp.t_si(f, v_r = 'ok' AND v_m = 5000, format('el admin no pudo cambiar la política: %s (%s)', v_r, v_m));
  v_r := pg_temp.t_err($q$SELECT public.actualizar_monto_minimo_pedido(6000)$q$);
  SELECT monto_minimo_pedido INTO v_m FROM public.politicas_comerciales WHERE sucursal_id = p_suc;
  f := pg_temp.t_si(f, v_r = 'ok' AND v_m = 6000, format('el admin no pudo cambiar el monto (RPC vieja): %s (%s)', v_r, v_m));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_m2(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_r text;
BEGIN
  v_r := pg_temp.t_err($q$SELECT public.actualizar_politica_minimo_pedido('bloquear', 100000000, 0, 0)$q$);
  f := pg_temp.t_si(f, v_r LIKE '22023%99.999.999%', format('la política con un mínimo de 100 millones: %s', v_r));
  v_r := pg_temp.t_err($q$SELECT public.actualizar_politica_minimo_pedido('bloquear', 'NaN', 0, 0)$q$);
  f := pg_temp.t_si(f, v_r LIKE '22023%', format('la política con un mínimo NaN: %s', v_r));
  v_r := pg_temp.t_err($q$SELECT public.actualizar_monto_minimo_pedido(100000000)$q$);
  f := pg_temp.t_si(f, v_r LIKE '22023%99.999.999%', format('la RPC vieja con 100 millones: %s', v_r));
  v_r := pg_temp.t_err($q$SELECT public.actualizar_politica_minimo_pedido('bloquear', 99999999, 0, 0)$q$);
  f := pg_temp.t_si(f, v_r = 'ok', format('la política con el techo justo: %s', v_r));
  v_r := pg_temp.t_err(format($q$UPDATE public.politicas_comerciales SET monto_minimo_pedido = 100000000 WHERE sucursal_id = %s$q$, p_suc));
  f := pg_temp.t_si(f, v_r LIKE '23514%', format('el CHECK de la tabla dejó 100 millones: %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_m3(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_r text; v_msg text;
BEGIN
  PERFORM public.actualizar_politica_minimo_pedido('bloquear', 99999999, 0, 0);
  v_msg := public.pedido_incumple_minimo(1500000000.5, p_suc);
  f := pg_temp.t_si(f, v_msg IS NULL, format('un total de 1.500 millones no llega a un mínimo de 99.999.999: %s', v_msg));
  v_msg := public.pedido_incumple_minimo(5, p_suc);
  f := pg_temp.t_si(f, v_msg IS NOT NULL AND position('#' in v_msg) = 0, format('mensaje del mínimo: %s', v_msg));
  -- El total grande en el mensaje: un mínimo no puede pasar el techo, así que se mira el formato con
  -- la máscara de la función (la del total, que no tiene techo).
  v_msg := to_char(1500000000.5::numeric, 'FM$999G999G999G999D00');
  f := pg_temp.t_si(f, position('#' in v_msg) = 0, format('la máscara nueva no alcanza 1.500 millones: %s', v_msg));
  f := pg_temp.t_si(f, position('FM$999G999G999G999D00' in (SELECT prosrc FROM pg_proc WHERE oid = 'public.pedido_incumple_minimo(numeric,bigint)'::regprocedure)) > 0,
                    'pedido_incumple_minimo no usa la máscara de 12 cifras');
  -- La RPC vieja en modo escalas: el mínimo tiene que quedar por debajo del envío gratis.
  PERFORM public.actualizar_politica_minimo_pedido('escalas', 1000, 5000, 300);
  v_r := pg_temp.t_err($q$SELECT public.actualizar_monto_minimo_pedido(6000)$q$);
  f := pg_temp.t_si(f, v_r LIKE '22023%envío es gratis%', format('la RPC vieja en escalas: %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_m4(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_r text; v_cat uuid; v_p bigint; v_c int;
BEGIN
  INSERT INTO public.categorias (nombre, sucursal_id) VALUES ('ZZ ensayo B6a minimo ' || gen_random_uuid(), p_suc)
  RETURNING id INTO v_cat;
  v_p := pg_temp.t_prod(p_suc, 1210, 0, (SELECT nombre FROM public.categorias WHERE id = v_cat));
  v_r := pg_temp.t_err(format($q$SELECT public.actualizar_minimo_venta_masivo(%L, 100001)$q$, v_cat));
  f := pg_temp.t_si(f, v_r LIKE '22023%100.000%', format('el mínimo de venta de 100.001: %s', v_r));
  v_r := pg_temp.t_err(format($q$SELECT public.actualizar_minimo_venta_masivo(%L, 100000)$q$, v_cat));
  SELECT cantidad_minima_venta INTO v_c FROM public.productos WHERE id = v_p;
  f := pg_temp.t_si(f, v_r = 'ok' AND v_c = 100000, format('el mínimo de venta en el techo: %s (%s)', v_r, v_c));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Rubros
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.caso_r1(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_r text; v_a uuid; v_b uuid;
BEGIN
  INSERT INTO public.categorias (nombre, sucursal_id) VALUES ('ZZ Ensayo Bebidas', p_suc) RETURNING id INTO v_a;
  v_r := pg_temp.t_err(format($q$INSERT INTO public.categorias (nombre, sucursal_id) VALUES ('  zz ensayo BEBIDAS ', %s)$q$, p_suc));
  f := pg_temp.t_si(f, v_r LIKE '23505%', format('un rubro igual salvo mayúsculas y espacios: %s', v_r));
  INSERT INTO public.categorias (nombre, sucursal_id) VALUES ('ZZ Ensayo Limpieza', p_suc) RETURNING id INTO v_b;
  INSERT INTO public.categorias (nombre, sucursal_id, parent_id) VALUES ('Gaseosas', p_suc, v_a);
  v_r := pg_temp.t_err(format($q$INSERT INTO public.categorias (nombre, sucursal_id, parent_id) VALUES ('GASEOSAS ', %s, %L)$q$, p_suc, v_a));
  f := pg_temp.t_si(f, v_r LIKE '23505%', format('dos subrubros iguales en el mismo rubro: %s', v_r));
  v_r := pg_temp.t_err(format($q$INSERT INTO public.categorias (nombre, sucursal_id, parent_id) VALUES ('gaseosas', %s, %L)$q$, p_suc, v_b));
  f := pg_temp.t_si(f, v_r = 'ok', format('el mismo subrubro en otro rubro: %s', v_r));
  v_r := pg_temp.t_err(format($q$UPDATE public.categorias SET nombre = 'zz ensayo limpieza' WHERE id = %L$q$, v_b));
  f := pg_temp.t_si(f, v_r = 'ok', format('cambiarle las mayúsculas a un rubro: %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_r2(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a uuid; v_p bigint; v_c uuid;
BEGIN
  INSERT INTO public.categorias (nombre, sucursal_id) VALUES ('ZZ Ensayo Almacén', p_suc) RETURNING id INTO v_a;
  v_p := pg_temp.t_prod(p_suc, 1210, 0, '  zz ENSAYO almacén ');
  SELECT categoria_id INTO v_c FROM public.productos WHERE id = v_p;
  f := pg_temp.t_si(f, v_c = v_a, format('el producto no encontró su rubro: %s', v_c));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_r3(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_a uuid; v_p bigint; v_r text; v_n text; v_c uuid;
BEGIN
  INSERT INTO public.categorias (nombre, sucursal_id) VALUES ('zz ensayo fiambres', p_suc) RETURNING id INTO v_a;
  v_p := pg_temp.t_prod(p_suc, 1210, 0, 'zz ensayo fiambres');
  v_r := pg_temp.t_err(format($q$SELECT public.renombrar_rubro(%L, NULL, 'ZZ Ensayo Fiambres')$q$, v_a));
  SELECT categoria, categoria_id INTO v_n, v_c FROM public.productos WHERE id = v_p;
  f := pg_temp.t_si(f, v_r = 'ok' AND v_n = 'ZZ Ensayo Fiambres' AND v_c = v_a,
                    format('renombrar sólo en mayúsculas: %s (%s, %s)', v_r, v_n, v_c));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Duplicado de cliente
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.caso_d1(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_res jsonb;
BEGIN
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo B6a uno', 'ZZ ensayo B6a uno', 'Calle Ensayo 450, Local 1, T4000 San Miguel de Tucumán, Tucumán', p_suc);
  v_res := public.verificar_duplicado_cliente(NULL, NULL, 'Calle Ensayo 450, Local 2, T4000 San Miguel de Tucumán, Tucumán');
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'bloquea')::boolean, false),
                    format('«Local 1» y «Local 2» de la misma altura chocan: %s', v_res));
  f := pg_temp.t_si(f, public.clave_direccion_cliente('Calle Ensayo 450, Local 1')
                       IS DISTINCT FROM public.clave_direccion_cliente('Calle Ensayo 450, Local 2'),
                    'la clave de «Local 1» y «Local 2» es la misma');
  f := pg_temp.t_si(f, public.clave_direccion_cliente('Calle Ensayo 450, Dpto. 3 B, Tucumán') = 'calle ensayo 450 dpto 3 b',
                    format('la clave con departamento: %s', public.clave_direccion_cliente('Calle Ensayo 450, Dpto. 3 B, Tucumán')));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_d2(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_res jsonb;
BEGIN
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES ('ZZ ensayo B6a dos', 'ZZ ensayo B6a dos', 'Pasaje Ensayo 2551, T4002AFE San Miguel de Tucumán, Tucumán, Argentina', p_suc);
  v_res := public.verificar_duplicado_cliente(NULL, NULL, 'Pasaje Ensayo 2551');
  f := pg_temp.t_si(f, COALESCE((v_res->>'bloquea')::boolean, false),
                    format('la misma puerta con y sin la ciudad ya no choca: %s', v_res));
  f := pg_temp.t_si(f, public.clave_direccion_cliente('Pje. Ensayo y Prueba 2551, T4002AFE San Miguel de Tucumán, Tucumán, Argentina') = 'pje ensayo y prueba 2551',
                    'la clave de la dirección de Google cambió');
  f := pg_temp.t_si(f, public.clave_direccion_cliente('B° Ensayo, Mz B Casa 12') IS NULL
                       AND public.clave_direccion_cliente('B° Ensayo, Local 4') IS NULL,
                    'un barrio sin altura tiene clave');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Borrar un producto
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.caso_b1(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_p bigint; v_r text;
BEGIN
  v_p := pg_temp.t_prod(p_suc, 1210, 5);
  v_r := pg_temp.t_err(format('DELETE FROM public.productos WHERE id = %s', v_p));
  f := pg_temp.t_si(f, v_r LIKE '23503%stock%', format('un producto con 5 u. en stock se borró: %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_b2(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_p bigint; v_r text;
BEGIN
  v_p := pg_temp.t_prod(p_suc, 1210, 0);
  -- Un lote agotado: lo que quedó de una compra que ya se vendió.
  INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
  VALUES (v_p, p_suc, CURRENT_DATE + 30, 10, 0, 'manual');
  v_r := pg_temp.t_err(format('DELETE FROM public.productos WHERE id = %s', v_p));
  f := pg_temp.t_si(f, v_r LIKE '23503%lote%', format('un producto con un lote se borró: %s', v_r));
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM public.producto_lotes WHERE producto_id = v_p), 'el lote se fue con el producto');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_b3(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_p bigint; v_r text; v_pr bigint;
BEGIN
  v_p := pg_temp.t_prod(p_suc, 1210, 0);
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, producto_regalo_id, activo)
  VALUES ('ZZ ensayo B6a promo', 'bonificacion', CURRENT_DATE, p_suc, v_p, true) RETURNING id INTO v_pr;
  v_r := pg_temp.t_err(format('DELETE FROM public.productos WHERE id = %s', v_p));
  f := pg_temp.t_si(f, v_r LIKE '23503%promoci%', format('el regalo de una promo se borró: %s', v_r));
  f := pg_temp.t_si(f, (SELECT producto_regalo_id FROM public.promociones WHERE id = v_pr) = v_p,
                    'la promo quedó sin regalo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_b4(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_p bigint; v_r text;
BEGIN
  v_p := pg_temp.t_prod(p_suc, 1210, 0);
  v_r := pg_temp.t_err(format('DELETE FROM public.productos WHERE id = %s', v_p));
  f := pg_temp.t_si(f, v_r = 'ok' AND NOT EXISTS (SELECT 1 FROM public.productos WHERE id = v_p),
                    format('un producto sin stock, sin lotes y sin promo no se borró: %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- CAT-13 en el resumen del bot
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.caso_s1(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_antes int; v_despues int; v_cero bigint; v_vacio bigint; v_propio bigint; v_ok bigint;
  v_top jsonb; v_hoy date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
BEGIN
  -- La sucursal limpia para el top: sus productos se apartan (se desactivan).
  UPDATE public.productos SET activo = false WHERE sucursal_id = p_suc AND activo;
  v_antes := (public.bot_metricas_admin_dia(v_hoy, p_suc)->'stock_critico'->>'count')::int;
  v_cero := pg_temp.t_prod(p_suc, 1210, 0);
  UPDATE public.productos SET stock_minimo = 0 WHERE id = v_cero;
  v_vacio := pg_temp.t_prod(p_suc, 1210, 8);
  UPDATE public.productos SET stock_minimo = NULL WHERE id = v_vacio;
  v_propio := pg_temp.t_prod(p_suc, 1210, 3);
  UPDATE public.productos SET stock_minimo = 5 WHERE id = v_propio;
  v_ok := pg_temp.t_prod(p_suc, 1210, 50);
  UPDATE public.productos SET stock_minimo = 10 WHERE id = v_ok;
  v_despues := (public.bot_metricas_admin_dia(v_hoy, p_suc)->'stock_critico'->>'count')::int;
  v_top := (public.bot_metricas_admin_dia(v_hoy, p_suc)->'stock_critico'->'top')::jsonb;
  f := pg_temp.t_si(f, v_despues - v_antes = 2, format('stock crítico tenía que sumar 2 (vacío y propio) y sumó %s: %s', v_despues - v_antes, v_top));
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_top) x WHERE (x->>'id')::bigint = v_cero),
                    format('un mínimo de 0 figura en el stock crítico: %s', v_top));
  f := pg_temp.t_si(f, EXISTS (SELECT 1 FROM jsonb_array_elements(v_top) x WHERE (x->>'id')::bigint = v_vacio),
                    format('un mínimo vacío (10) con 8 u. no figura: %s', v_top));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- cambiar_alicuota_ii sin fecha
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.caso_a1(p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_e bigint; v_r text;
BEGIN
  INSERT INTO public.ii_encuadres (nombre) VALUES ('ZZ ensayo B6a ' || gen_random_uuid()) RETURNING id INTO v_e;
  v_r := pg_temp.t_err(format('SELECT public.cambiar_alicuota_ii(%s, 0.08, NULL)', v_e));
  f := pg_temp.t_si(f, v_r LIKE '22023%fecha%', format('una alícuota sin fecha: %s', v_r));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo$
DECLARE
  v_admin  uuid;
  v_enc    uuid := gen_random_uuid();
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

  -- Un encargado de la misma sucursal (lo crea handle_new_user por su app_metadata).
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v_enc, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated',
          'ensayo-b6a-enc@ensayo.invalid',
          jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email'),
                             'rol', 'encargado', 'sucursal_id', v_suc::text),
          jsonb_build_object('nombre', 'Encargado del ensayo'), now(), now());
  IF NOT EXISTS (SELECT 1 FROM perfiles WHERE id = v_enc AND rol = 'encargado' AND activo)
     OR NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_enc AND sucursal_id = v_suc) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no se pudo dar de alta al encargado del ensayo';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin, 'role', 'authenticated')::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

  FOREACH v_caso IN ARRAY ARRAY['p1', 'p2', 'p3', 'p4', 'm1', 'm2', 'm3', 'm4', 'r1', 'r2', 'r3',
                                'd1', 'd2', 'b1', 'b2', 'b3', 'b4', 's1', 'a1'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.t_como(v_admin);
      IF v_caso = 'm1' THEN
        EXECUTE 'SELECT pg_temp.caso_m1($1, $2, $3)' INTO v_out USING v_suc, v_admin, v_enc;
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

  -- K1 · los permisos no cambiaron (definer, anon nunca, authenticated según la función)
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_precios_masivo(jsonb,jsonb)', true, true),
    ('public.actualizar_minimo_venta_masivo(uuid,integer)', true, true),
    ('public.actualizar_politica_minimo_pedido(text,numeric,numeric,numeric)', true, true),
    ('public.actualizar_monto_minimo_pedido(numeric)', true, true),
    ('public.pedido_incumple_minimo(numeric,bigint)', true, false),
    ('public.sync_producto_categoria_id()', false, false),
    ('public.renombrar_rubro(uuid,text,text)', false, true),
    ('public.eliminar_rubro(uuid,text,boolean)', false, true),
    ('public.clave_direccion_cliente(text)', false, true),
    ('public.verificar_duplicado_cliente(numeric,numeric,text,bigint)', true, true),
    ('public.cambiar_alicuota_ii(bigint,numeric,date)', true, true),
    ('public.bot_metricas_admin_dia(date,bigint)', true, false),
    ('public.productos_rechazar_borrado_con_historial()', true, false)
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
  RAISE EXCEPTION 'ENSAYO OK · aumento masivo (P1-P4), mínimos (M1-M4), rubros (R1-R3), duplicado de cliente (D1-D2), borrar un producto (B1-B4), CAT-13 (S1), alícuota sin fecha (A1) y permisos (K1)';
END
$ensayo$;
