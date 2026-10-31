-- Ensayo de #1300, #1301 y #1283: el cupo de una promo cuenta el corte, y el
-- cambio de cliente mide el combo contra la foto del pedido original.
--
-- Decision del dueno (2026-10-29): un uso es el CORTE, en la unidad de la promo,
-- no la cantidad de la linea. Sustituir el regalo no mueve el cupo. Como en el
-- ensayo de la 408, el trigger diferido se fuerza con SET CONSTRAINTS IMMEDIATE
-- despues de cada RPC (pg_temp.cp_check).
--
--   C1  · la pura: regalo_usos_de_linea, sin cadena, con cadena, con reparto, y
--         con la linea movida despues de su ultimo eslabon.
--   C2  · limite 10: regalo 4 sustituido por valor a P x19 cuenta 4, entran 6
--         mas, y el siguiente se rechaza con el mensaje que dice que cuenta.
--   C3  · limite 5, cupo lleno: sustituir 5 por 50 pasa (antes "se pasaba"), y
--         sustituir 5 por 1 no libera cupo.
--   C4  · el item 19017: un reparto de 94 en 34+30+30 cuenta 94 en el pedido, y
--         34 en la linea.
--   C5  · edicion de un regalo sustituido: el cambio de sabor 12 -> 12 editado a
--         24 cuenta 24 y pasa el limite 20; editado a 18 cuenta 18. Por valor,
--         A x4 -> P x19 editado a A x6 queda P x29 y cuenta 6.
--   C6  · salvedad sobre una linea sustituida: la parcial libera su parte, y la
--         que deja la linea en 0 libera todo.
--   C7  · la salvedad anulada con el cupo vendido. Sobre el regalo, y sobre la
--         venta que le recorto el regalo: anular_salvedad lo rechaza con
--         'anulacion_toca_promociones' sin escribir el regalo, y el cupo no se
--         mueve. Sobre una venta que no toca el regalo, con la promo en el
--         limite: pasa.
--   C8  · la promo apagada por el limite: la edicion conserva el regalo, el
--         alta no lo acepta para quien no es admin, y cambiar el cliente lo
--         conserva sin liberar cupo ni prender la promo.
--   C9  · el piso del limite cuenta el corte.
--   C10 · #1301: combo A x2 + B x1 que pasa a A x3: cambiar el cliente anda, y el
--         pedido nuevo hereda la foto. Un alta nueva sigue midiendo lo vigente:
--         sin el GUC, y con un GUC que apunta a un pedido sin esa foto o a uno
--         que no existe.
--   C11 · #1301: cambio solo el precio: el pedido nuevo conserva la foto.
--   C12 · #1283: promos_cupo da lo mismo que suma el trigger, y sin sesion no da
--         nada.
--   C13 · permisos de las funciones nuevas.
--
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto: 'ENSAYO FALLO (...)' con la lista de fallas, o, si todo pasa, el
-- unico error es 'ENSAYO_ROLLBACK' (el NOTICE dice ENSAYO OK). Para el ensayo
-- en seco de la migracion, las dos en una sola llamada:
--
--   psql "$DATABASE_URL" -1 -f migrations/NNN_cupo_de_promo_por_corte_y_foto_de_combo.sql \
--                           -f scripts/test-cupo-promo-y-combo-1300-1301-1283.sql

CREATE OR REPLACE FUNCTION pg_temp.cp_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

-- Dispara lo que el trigger diferido tenga pendiente y lo vuelve a diferir.
-- NULL si paso; el mensaje si lo rechazo.
CREATE OR REPLACE FUNCTION pg_temp.cp_check()
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  SET CONSTRAINTS public.trg_limite_usos_promo IMMEDIATE;
  SET CONSTRAINTS public.trg_limite_usos_promo DEFERRED;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_prod(p_suc bigint, p_nombre text, p_cat text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1300 ' || p_nombre, 100, 500, 60, p_suc, 'ZZ ensayo 1300 ' || p_cat)
  RETURNING id;
$fn$;

-- Promo de regalo p_regalo que mueve stock: 10 de p_venta dan p_bonif.
CREATE OR REPLACE FUNCTION pg_temp.cp_promo(p_suc bigint, p_venta bigint, p_regalo bigint, p_limite int, p_bonif int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, limite_usos)
  VALUES ('ZZ ensayo 1300', 'bonificacion', pg_temp.cp_hoy() - 1, p_suc, true, p_regalo, p_limite)
  RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, p_suc), (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, p_venta, p_suc);
  RETURN v_promo;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_items(p_venta bigint, p_cant_venta int, p_regalo bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(
    jsonb_build_object('producto_id', p_venta, 'cantidad', p_cant_venta, 'precio_unitario', 100),
    jsonb_build_object('producto_id', p_regalo, 'cantidad', p_cant, 'precio_unitario', 0,
                       'es_bonificacion', true, 'promocion_id', p_promo));
$fn$;

-- El alta del admin: p_cant_venta de p_venta a $100 mas p_cant de regalo.
CREATE OR REPLACE FUNCTION pg_temp.cp_alta(p_cli bigint, p_adm uuid, p_venta bigint, p_cant_venta int,
                                           p_regalo bigint, p_cant int, p_promo bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, p_cant_venta * 100, p_adm, pg_temp.cp_items(p_venta, p_cant_venta, p_regalo, p_cant, p_promo), 'ensayo 1300');
  PERFORM pg_temp.cp_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_editar(p_ped bigint, p_adm uuid, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_adm);
  PERFORM pg_temp.cp_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_sustituir(p_item bigint, p_prod bigint, p_cant int)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.sustituir_regalo_pedido(p_item, p_prod, p_cant, 'ensayo 1300', NULL, NULL);
  PERFORM pg_temp.cp_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo sustituir: %', v_res;
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_salvedad(p_ped bigint, p_item bigint, p_cant int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, 'cliente_rechaza',
                                     'ensayo 1300: descripcion del caso', NULL, true, NULL);
  PERFORM pg_temp.cp_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo registrar la salvedad: %', v_res;
  END IF;
  RETURN (v_res->>'salvedad_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_regalo(p_ped bigint, p_promo bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND es_bonificacion AND promocion_id = p_promo ORDER BY id LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_venta(p_ped bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND NOT es_bonificacion ORDER BY id LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_usos(p_promo bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT u.usos FROM public._promo_usos(p_promo) u;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_activa(p_promo bigint)
RETURNS boolean LANGUAGE sql AS $fn$
  SELECT activo FROM public.promociones WHERE id = p_promo;
$fn$;

-- Un eslabon para la pura.
CREATE OR REPLACE FUNCTION pg_temp.cp_e(p_id int, p_cadena uuid, p_o numeric, p_s numeric, p_reparto boolean)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('id', p_id, 'cadena_id', p_cadena, 'cantidad_original', p_o,
                            'cantidad_sustituta', p_s,
                            'reparto_id', CASE WHEN p_reparto THEN gen_random_uuid() END);
$fn$;

-- El combo: A xp_a + B x1 a $300.
CREATE OR REPLACE FUNCTION pg_temp.cp_combo(p_a bigint, p_b bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.guardar_combo(jsonb_build_object(
    'nombre', 'ZZ ensayo 1301', 'precio', 300, 'fecha_inicio', pg_temp.cp_hoy() - 1,
    'componentes', jsonb_build_array(
      jsonb_build_object('cantidad', 2, 'productos', jsonb_build_array(p_a)),
      jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p_b)))));
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el combo: %', v_res;
  END IF;
  RETURN (v_res->>'id')::bigint;
END
$fn$;

-- Las lineas de un combo A x2 + B x1, a $100 cada unidad.
CREATE OR REPLACE FUNCTION pg_temp.cp_lineas_combo(p_combo bigint, p_a bigint, p_b bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(
    jsonb_build_object('producto_id', p_a, 'cantidad', 2, 'precio_unitario', 100,
                       'precio_sin_combo_unitario', 120, 'combo_id', p_combo),
    jsonb_build_object('producto_id', p_b, 'cantidad', 1, 'precio_unitario', 100,
                       'precio_sin_combo_unitario', 120, 'combo_id', p_combo));
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.cp_alta_combo(p_cli bigint, p_adm uuid, p_combo bigint, p_a bigint, p_b bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, 300, p_adm, pg_temp.cp_lineas_combo(p_combo, p_a, p_b), 'ensayo 1301');
  PERFORM pg_temp.cp_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido con combo: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- Un pedido de la misma sucursal, sin ninguna foto de combo.
CREATE OR REPLACE FUNCTION pg_temp.cp_alta_combo_sin_foto(p_cli bigint, p_adm uuid, p_prod bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, 120, p_adm, jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', 1, 'precio_unitario', 120)),
    'ensayo 1301');
  PERFORM pg_temp.cp_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido sin foto: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.caso_c1(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  c uuid := gen_random_uuid();
BEGIN
  f := pg_temp.cp_si(f, public.regalo_usos_de_linea(NULL, NULL, 7) = 7, 'sin cadena: la cantidad');
  f := pg_temp.cp_si(f, public.regalo_usos_de_linea('[]', c, 7) = 7, 'cadena sin eslabones: la cantidad');
  f := pg_temp.cp_si(f, public.regalo_usos_de_linea(jsonb_build_array(pg_temp.cp_e(1, c, 4, 19, false)), c, 19) = 4,
                     'A x4 -> P x19: cuenta 4');
  f := pg_temp.cp_si(f, public.regalo_usos_de_linea(jsonb_build_array(pg_temp.cp_e(1, c, 4, 19, false)), c, 29) = 6,
                     'editada a P x29: cuenta 6');
  f := pg_temp.cp_si(f, public.regalo_usos_de_linea(jsonb_build_array(pg_temp.cp_e(1, c, 4, 19, false)), c, 10) = 2,
                     'bajada a P x10: cuenta 2');
  f := pg_temp.cp_si(f, public.regalo_usos_de_linea(jsonb_build_array(pg_temp.cp_e(1, c, 12, 12, false)), c, 24) = 24,
                     'cambio de sabor editado a 24: cuenta 24');
  f := pg_temp.cp_si(f, public.regalo_usos_de_linea(
                          jsonb_build_array(pg_temp.cp_e(1, c, 4, 19, false), pg_temp.cp_e(2, c, 19, 10, false)), c, 10) = 4,
                     'dos eslabones: el corte de la raiz');
  f := pg_temp.cp_si(f, public.regalo_usos_de_linea(jsonb_build_array(pg_temp.cp_e(1, c, 94, 34, true)), c, 34) = 34,
                     'parte de un reparto: su parte, no el total');
  f := pg_temp.cp_si(f, public.regalo_usos_de_linea(
                          jsonb_build_array(pg_temp.cp_e(1, c, 94, 34, true), pg_temp.cp_e(2, c, 34, 10, false)), c, 10) = 34,
                     'parte de un reparto, sustituida: su parte');
  f := pg_temp.cp_si(f, public.regalo_usos_de_linea(jsonb_build_array(pg_temp.cp_e(1, gen_random_uuid(), 4, 19, false)), c, 9) = 9,
                     'el eslabon de otra cadena no cuenta');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c2(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.cp_prod(p_suc, 'C2 venta', 'v');
  r bigint := pg_temp.cp_prod(p_suc, 'C2 regalo', 'a');
  s bigint := pg_temp.cp_prod(p_suc, 'C2 sustituto', 'b');
  p bigint := pg_temp.cp_promo(p_suc, v, r, 10, 4);
  v_ped bigint;
  e text;
BEGIN
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 4, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('regalo 4 de 10 rechazado: %s', e));
  PERFORM pg_temp.cp_sustituir(pg_temp.cp_regalo(v_ped, p), s, 19);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('sustituir por valor rechazado: %s', e));
  f := pg_temp.cp_si(f, (SELECT cantidad FROM public.pedido_items WHERE id = pg_temp.cp_regalo(v_ped, p)) = 19,
                     'la linea no quedo en 19');
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 4, format('la linea sustituida cuenta %s, no 4', pg_temp.cp_usos(p)));
  f := pg_temp.cp_si(f, pg_temp.cp_activa(p), 'la sustitucion apago la promo');

  PERFORM pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 6, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('llegar justo a 10 rechazado: %s', e));
  f := pg_temp.cp_si(f, NOT pg_temp.cp_activa(p), 'al llegar a 10 la promo sigue activa');

  PERFORM pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 1, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e LIKE '%límite de 10 unidades de regalo: quedan 0 y este pedido lleva 1%',
                     format('el que pasa el limite: %s', COALESCE(e, 'paso')));
  f := pg_temp.cp_si(f, e LIKE '%El cupo cuenta el corte de la promo, en su unidad: sustituir el regalo no lo cambia%',
                     format('el rechazo no dice que cuenta: %s', e));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c3(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.cp_prod(p_suc, 'C3 venta', 'v');
  r bigint := pg_temp.cp_prod(p_suc, 'C3 regalo', 'a');
  s bigint := pg_temp.cp_prod(p_suc, 'C3 sustituto', 'b');
  c bigint := pg_temp.cp_prod(p_suc, 'C3 caro', 'c');
  p bigint := pg_temp.cp_promo(p_suc, v, r, 5, 5);
  v_ped bigint;
  e text;
BEGIN
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 5, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL AND NOT pg_temp.cp_activa(p), format('regalo 5 de 5: %s', e));

  PERFORM pg_temp.cp_sustituir(pg_temp.cp_regalo(v_ped, p), s, 50);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('sustituir 5 por 50 con el cupo lleno rechazado: %s', e));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 5, format('5 por 50 cuenta %s, no 5', pg_temp.cp_usos(p)));

  PERFORM pg_temp.cp_sustituir(pg_temp.cp_regalo(v_ped, p), c, 1);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('sustituir por 1 rechazado: %s', e));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 5, format('sustituir por 1 libero cupo: cuenta %s', pg_temp.cp_usos(p)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c4(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.cp_prod(p_suc, 'C4 venta', 'v');
  r bigint := pg_temp.cp_prod(p_suc, 'C4 regalo', 'a');
  y bigint := pg_temp.cp_prod(p_suc, 'C4 sabor Y', 'a');
  z bigint := pg_temp.cp_prod(p_suc, 'C4 sabor Z', 'a');
  p bigint := pg_temp.cp_promo(p_suc, v, r, 94, 94);
  v_ped bigint;
  v_res jsonb;
  e text;
BEGIN
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 94, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('regalo 94 de 94 rechazado: %s', e));

  v_res := public.dividir_regalo_pedido(pg_temp.cp_regalo(v_ped, p),
    jsonb_build_array(jsonb_build_object('producto_id', r, 'cantidad', 34),
                      jsonb_build_object('producto_id', y, 'cantidad', 30),
                      jsonb_build_object('producto_id', z, 'cantidad', 30)), 'ensayo 1300');
  PERFORM pg_temp.cp_reset();
  f := pg_temp.cp_si(f, COALESCE((v_res->>'success')::boolean, false), format('no se pudo repartir: %s', v_res));
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('repartir en el limite rechazado: %s', e));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 94, format('el reparto cuenta %s, no 94', pg_temp.cp_usos(p)));
  f := pg_temp.cp_si(f, (SELECT public.regalo_usos_de_linea(public.regalo_eslabones(pi.pedido_id, pi.promocion_id, pi.sucursal_id),
                                                            pi.regalo_cadena_id, pi.cantidad)
                           FROM public.pedido_items pi
                          WHERE pi.pedido_id = v_ped AND pi.es_bonificacion AND pi.producto_id = r) = 34,
                     'la parte de 34 no cuenta 34');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c5(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.cp_prod(p_suc, 'C5 venta', 'v');
  r bigint := pg_temp.cp_prod(p_suc, 'C5 regalo', 'a');
  y bigint := pg_temp.cp_prod(p_suc, 'C5 sabor Y', 'a');
  q bigint := pg_temp.cp_prod(p_suc, 'C5 sustituto', 'b');
  p  bigint := pg_temp.cp_promo(p_suc, v, r, 20, 12);
  p2 bigint := pg_temp.cp_promo(p_suc, v, r, 100, 4);
  v_ped bigint;
  v_res jsonb;
  e text;
BEGIN
  -- Cambio de sabor 12 -> 12, el de los eslabones de prod.
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 12, p);
  PERFORM pg_temp.cp_sustituir(pg_temp.cp_regalo(v_ped, p), y, 12);
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 12, format('sabor 12 -> 12 cuenta %s', pg_temp.cp_usos(p)));
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('sabor 12 -> 12: %s', e));

  v_res := pg_temp.cp_editar(v_ped, p_adm, pg_temp.cp_items(v, 15, r, 18, p));
  f := pg_temp.cp_si(f, COALESCE((v_res->>'success')::boolean, false), format('editar a 18: %s', v_res));
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('editar a 18 de 20: %s', e));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 18, format('editado a 18 cuenta %s', pg_temp.cp_usos(p)));

  -- Por valor: A x4 -> P x19 editado a A x6 queda P x29 y cuenta 6.
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 4, p2);
  PERFORM pg_temp.cp_sustituir(pg_temp.cp_regalo(v_ped, p2), q, 19);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('por valor: %s', e));
  v_res := pg_temp.cp_editar(v_ped, p_adm, pg_temp.cp_items(v, 15, r, 6, p2));
  f := pg_temp.cp_si(f, COALESCE((v_res->>'success')::boolean, false), format('editar a 6: %s', v_res));
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('editar a 6: %s', e));
  f := pg_temp.cp_si(f, (SELECT cantidad FROM public.pedido_items WHERE id = pg_temp.cp_regalo(v_ped, p2)) = 29,
                     format('la linea quedo en %s, no 29', (SELECT cantidad FROM public.pedido_items WHERE id = pg_temp.cp_regalo(v_ped, p2))));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p2) = 6, format('por valor editado a 6 cuenta %s', pg_temp.cp_usos(p2)));

  -- El que pasa el limite por la edicion de un regalo sustituido se rechaza:
  -- va ultimo, porque el rechazo deja el conteo pasado.
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 1, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('19 de 20: %s', e));
  v_ped := (SELECT min(pi.pedido_id) FROM public.pedido_items pi
             WHERE pi.promocion_id = p AND pi.es_bonificacion AND pi.regalo_cadena_id IS NOT NULL);
  v_res := pg_temp.cp_editar(v_ped, p_adm, pg_temp.cp_items(v, 20, r, 24, p));
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, NOT COALESCE((v_res->>'success')::boolean, false) OR e LIKE '%quedan 19 y este pedido lleva 24%',
                     format('editar el sustituido a 24 de 20: %s / %s', v_res, COALESCE(e, 'paso')));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c6(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.cp_prod(p_suc, 'C6 venta', 'v');
  r bigint := pg_temp.cp_prod(p_suc, 'C6 regalo', 'a');
  q bigint := pg_temp.cp_prod(p_suc, 'C6 sustituto', 'b');
  p bigint := pg_temp.cp_promo(p_suc, v, r, 100, 4);
  v_ped bigint;
  e text;
BEGIN
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 4, p);
  PERFORM pg_temp.cp_sustituir(pg_temp.cp_regalo(v_ped, p), q, 19);
  PERFORM pg_temp.cp_salvedad(v_ped, pg_temp.cp_regalo(v_ped, p), 9);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('salvedad parcial rechazada: %s', e));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 2, format('P x19 bajado a 10 cuenta %s, no 2', pg_temp.cp_usos(p)));
  PERFORM pg_temp.cp_salvedad(v_ped, pg_temp.cp_regalo(v_ped, p), 10);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('salvedad total rechazada: %s', e));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 0, format('la linea en 0 cuenta %s', pg_temp.cp_usos(p)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c7(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.cp_prod(p_suc, 'C7 venta', 'v');
  r bigint := pg_temp.cp_prod(p_suc, 'C7 regalo', 'a');
  p bigint := pg_temp.cp_promo(p_suc, v, r, 5, 5);
  v2 bigint := pg_temp.cp_prod(p_suc, 'C7 venta 2', 'v');
  p2 bigint := pg_temp.cp_promo(p_suc, v2, r, 1, 1);
  v_ped bigint;
  v_salv bigint;
  v_res jsonb;
  v_cant int;
  e text;
BEGIN
  -- Sobre el regalo: 5 de 5, la salvedad libera 2 y otro pedido las vende.
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 5, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL AND NOT pg_temp.cp_activa(p), format('regalo 5 de 5: %s', e));
  v_salv := pg_temp.cp_salvedad(v_ped, pg_temp.cp_regalo(v_ped, p), 2);
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 3, format('la salvedad no libero: cuenta %s', pg_temp.cp_usos(p)));
  UPDATE public.promociones SET activo = true WHERE id = p;
  PERFORM pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 2, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('vender lo liberado: %s', e));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 5, format('cupo vendido cuenta %s', pg_temp.cp_usos(p)));

  v_cant := (SELECT cantidad FROM public.pedido_items WHERE id = pg_temp.cp_regalo(v_ped, p));
  v_res := public.anular_salvedad(v_salv, 'ensayo 1300');
  PERFORM pg_temp.cp_reset();
  f := pg_temp.cp_si(f, v_res->>'codigo' = 'anulacion_toca_promociones', format('anular sobre el regalo: %s', v_res));
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('anular sobre el regalo choco con el cupo: %s', e));
  f := pg_temp.cp_si(f, (SELECT cantidad FROM public.pedido_items WHERE id = pg_temp.cp_regalo(v_ped, p)) = v_cant,
                     'anular movio la linea de regalo');
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 5, format('anular movio el cupo: cuenta %s', pg_temp.cp_usos(p)));

  -- Sobre la venta, con la promo en el limite. 15 dan 1 regalo: bajar 2 no
  -- toca el regalo, y anular pasa aunque el cupo este lleno.
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v2, 15, r, 1, p2);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL AND NOT pg_temp.cp_activa(p2), format('regalo 1 de 1: %s', e));
  v_salv := pg_temp.cp_salvedad(v_ped, pg_temp.cp_venta(v_ped), 2);
  v_res := public.anular_salvedad(v_salv, 'ensayo 1300');
  PERFORM pg_temp.cp_reset();
  f := pg_temp.cp_si(f, COALESCE((v_res->>'success')::boolean, false), format('anular sobre la venta: %s', v_res));
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('anular sobre la venta choco con el cupo: %s', e));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- La venta que le recorta el regalo: 10 dan 1, bajar 1 lo saca, otro pedido
-- vende el cupo, y restituir devolveria el derecho al regalo.
CREATE OR REPLACE FUNCTION pg_temp.caso_c7b(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.cp_prod(p_suc, 'C7b venta', 'v');
  r bigint := pg_temp.cp_prod(p_suc, 'C7b regalo', 'a');
  p bigint := pg_temp.cp_promo(p_suc, v, r, 1, 1);
  v_ped bigint;
  v_salv bigint;
  v_res jsonb;
  e text;
BEGIN
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 1, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL AND NOT pg_temp.cp_activa(p), format('regalo 1 de 1: %s', e));
  v_salv := pg_temp.cp_salvedad(v_ped, pg_temp.cp_venta(v_ped), 1);
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 0, format('la salvedad sobre la venta no recorto: cuenta %s', pg_temp.cp_usos(p)));
  UPDATE public.promociones SET activo = true WHERE id = p;
  PERFORM pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 1, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('vender lo liberado: %s', e));
  v_res := public.anular_salvedad(v_salv, 'ensayo 1300');
  PERFORM pg_temp.cp_reset();
  f := pg_temp.cp_si(f, v_res->>'codigo' = 'anulacion_toca_promociones', format('anular sobre la venta recortada: %s', v_res));
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('anular sobre la venta recortada choco con el cupo: %s', e));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 1, format('anular movio el cupo: cuenta %s', pg_temp.cp_usos(p)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c8(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.cp_prod(p_suc, 'C8 venta', 'v');
  r bigint := pg_temp.cp_prod(p_suc, 'C8 regalo', 'a');
  p bigint := pg_temp.cp_promo(p_suc, v, r, 5, 5);
  v_ped bigint;
  v_res jsonb;
  m text;
  e text;
BEGIN
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 5, p);
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL AND NOT pg_temp.cp_activa(p), format('la promo no se apago al llegar: %s', e));

  -- El server: la edicion conserva el regalo, el alta de quien no es admin no.
  m := public.regalo_fuera_de_promo(pg_temp.cp_items(v, 10, r, 5, p), pg_temp.cp_items(v, 10, r, 5, p),
                                    p_suc, v_ped, pg_temp.cp_hoy());
  f := pg_temp.cp_si(f, m IS NULL, format('la edicion no conserva el regalo apagado: %s', m));
  m := public.regalo_fuera_de_promo(pg_temp.cp_items(v, 10, r, 5, p), pg_temp.cp_items(v, 10, r, 5, p),
                                    p_suc, NULL, pg_temp.cp_hoy());
  f := pg_temp.cp_si(f, m LIKE '%está desactivada%', format('el alta acepto el regalo apagado: %s', COALESCE(m, 'paso')));

  v_res := pg_temp.cp_editar(v_ped, p_adm, pg_temp.cp_items(v, 12, r, 5, p));
  f := pg_temp.cp_si(f, COALESCE((v_res->>'success')::boolean, false), format('editar conservando: %s', v_res));
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('editar conservando rechazado: %s', e));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 5, format('editar conservando cuenta %s', pg_temp.cp_usos(p)));
  f := pg_temp.cp_si(f, NOT pg_temp.cp_activa(p), 'editar prendio la promo');

  v_res := public.cambiar_cliente_pedido(v_ped, p_cli2, p_adm, pg_temp.cp_items(v, 12, r, 5, p), 1200, NULL, 0, 'ensayo 1300');
  PERFORM pg_temp.cp_reset();
  f := pg_temp.cp_si(f, COALESCE((v_res->>'success')::boolean, false), format('cambiar el cliente conservando: %s', v_res));
  e := pg_temp.cp_check();
  f := pg_temp.cp_si(f, e IS NULL, format('cambiar el cliente rechazado: %s', e));
  f := pg_temp.cp_si(f, pg_temp.cp_usos(p) = 5, format('cambiar el cliente cuenta %s', pg_temp.cp_usos(p)));
  f := pg_temp.cp_si(f, NOT pg_temp.cp_activa(p), 'cambiar el cliente prendio la promo');
  f := pg_temp.cp_si(f, pg_temp.cp_regalo((v_res->>'nuevo_pedido_id')::bigint, p) IS NOT NULL,
                     'el pedido nuevo no tiene el regalo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c9(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.cp_prod(p_suc, 'C9 venta', 'v');
  r bigint := pg_temp.cp_prod(p_suc, 'C9 regalo', 'a');
  s bigint := pg_temp.cp_prod(p_suc, 'C9 sustituto', 'b');
  p bigint := pg_temp.cp_promo(p_suc, v, r, 10, 4);
  v_ped bigint;
BEGIN
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 4, p);
  PERFORM pg_temp.cp_sustituir(pg_temp.cp_regalo(v_ped, p), s, 19);
  BEGIN
    UPDATE public.promociones SET limite_usos = 3 WHERE id = p;
    f := f || 'bajar el limite a 3 con 4 de corte paso';
  EXCEPTION WHEN OTHERS THEN
    f := pg_temp.cp_si(f, SQLERRM LIKE '%ya regaló 4 unidades%', format('mensaje al bajar el limite: %s', SQLERRM));
  END;
  UPDATE public.promociones SET limite_usos = 4 WHERE id = p;
  f := pg_temp.cp_si(f, NOT pg_temp.cp_activa(p), 'bajar el limite justo al corte no apago la promo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c10(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  a bigint := pg_temp.cp_prod(p_suc, 'C10 A', 'v');
  b bigint := pg_temp.cp_prod(p_suc, 'C10 B', 'v');
  c bigint := pg_temp.cp_combo(a, b);
  v_ped bigint;
  v_otro bigint;
  v_nuevo bigint;
  v_foto jsonb;
  v_res jsonb;
BEGIN
  UPDATE public.productos SET precio = 120 WHERE id IN (a, b);
  v_ped := pg_temp.cp_alta_combo(p_cli, p_adm, c, a, b);
  v_foto := (SELECT componentes FROM public.pedido_combos WHERE pedido_id = v_ped AND combo_id = c);

  -- El admin cambia el combo a A x3.
  v_res := public.guardar_combo(jsonb_build_object(
    'id', c, 'nombre', 'ZZ ensayo 1301', 'precio', 300, 'fecha_inicio', pg_temp.cp_hoy() - 1,
    'componentes', jsonb_build_array(jsonb_build_object('cantidad', 3, 'productos', jsonb_build_array(a)))));
  f := pg_temp.cp_si(f, COALESCE((v_res->>'success')::boolean, false), format('no se pudo cambiar el combo: %s', v_res));

  v_res := public.cambiar_cliente_pedido(v_ped, p_cli2, p_adm, pg_temp.cp_lineas_combo(c, a, b), 300, NULL, 0, 'ensayo 1301');
  PERFORM pg_temp.cp_reset();
  f := pg_temp.cp_si(f, COALESCE((v_res->>'success')::boolean, false), format('cambiar el cliente con el combo cambiado: %s', v_res));
  v_nuevo := (v_res->>'nuevo_pedido_id')::bigint;
  f := pg_temp.cp_si(f, (SELECT componentes FROM public.pedido_combos WHERE pedido_id = v_nuevo AND combo_id = c) = v_foto,
                     'el pedido nuevo no heredo la estructura de la foto');
  f := pg_temp.cp_si(f, (SELECT cantidad_combos FROM public.pedido_combos WHERE pedido_id = v_nuevo AND combo_id = c) = 1,
                     'el pedido nuevo no tiene 1 combo');
  f := pg_temp.cp_si(f, COALESCE(current_setting('app.combo_foto_pedido', true), '') = '',
                     'el GUC quedo prendido');

  -- Lo que no viene de un cambio de cliente sigue midiendo lo vigente.
  v_res := public.crear_pedido_completo(p_cli, 300, p_adm, pg_temp.cp_lineas_combo(c, a, b), 'ensayo 1301');
  PERFORM pg_temp.cp_reset();
  f := pg_temp.cp_si(f, v_res->>'codigo' = 'combo_fuera_de_regla', format('el alta no midio lo vigente: %s', v_res));

  -- El GUC solo vale si hay una foto de ese combo en esa sucursal.
  PERFORM set_config('app.combo_foto_pedido', '-1', true);
  f := pg_temp.cp_si(f, public.combo_fuera_de_regla(pg_temp.cp_lineas_combo(c, a, b), p_suc, pg_temp.cp_hoy(), NULL, false)
                        LIKE '%no forman un número entero%',
                     'con un pedido que no existe no midio lo vigente');
  v_otro := pg_temp.cp_alta_combo_sin_foto(p_cli, p_adm, a);
  PERFORM set_config('app.combo_foto_pedido', v_otro::text, true);
  f := pg_temp.cp_si(f, public.combo_fuera_de_regla(pg_temp.cp_lineas_combo(c, a, b), p_suc, pg_temp.cp_hoy(), NULL, false)
                        LIKE '%no forman un número entero%',
                     'con un pedido sin la foto no midio lo vigente');
  PERFORM set_config('app.combo_foto_pedido', '', true);
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c11(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  a bigint := pg_temp.cp_prod(p_suc, 'C11 A', 'v');
  b bigint := pg_temp.cp_prod(p_suc, 'C11 B', 'v');
  c bigint := pg_temp.cp_combo(a, b);
  v_ped bigint;
  v_nuevo bigint;
  v_res jsonb;
BEGIN
  UPDATE public.productos SET precio = 120 WHERE id IN (a, b);
  v_ped := pg_temp.cp_alta_combo(p_cli, p_adm, c, a, b);
  UPDATE public.combos SET precio = 270 WHERE id = c;

  v_res := public.cambiar_cliente_pedido(v_ped, p_cli2, p_adm, pg_temp.cp_lineas_combo(c, a, b), 300, NULL, 0, 'ensayo 1301');
  PERFORM pg_temp.cp_reset();
  f := pg_temp.cp_si(f, COALESCE((v_res->>'success')::boolean, false), format('cambiar el cliente con otro precio: %s', v_res));
  v_nuevo := (v_res->>'nuevo_pedido_id')::bigint;
  f := pg_temp.cp_si(f, (SELECT precio FROM public.pedido_combos WHERE pedido_id = v_nuevo AND combo_id = c) = 300,
                     format('la foto nueva quedo a %s, no a 300', (SELECT precio FROM public.pedido_combos WHERE pedido_id = v_nuevo AND combo_id = c)));
  f := pg_temp.cp_si(f, (SELECT total FROM public.pedidos WHERE id = v_nuevo) >= 300, 'el total del pedido nuevo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c12(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v bigint := pg_temp.cp_prod(p_suc, 'C12 venta', 'v');
  r bigint := pg_temp.cp_prod(p_suc, 'C12 regalo', 'a');
  s bigint := pg_temp.cp_prod(p_suc, 'C12 sustituto', 'b');
  p bigint := pg_temp.cp_promo(p_suc, v, r, 10, 4);
  sin bigint := pg_temp.cp_promo(p_suc, v, r, NULL, 4);
  v_ped bigint;
  v_otro bigint;
  v_u bigint;
  v_q bigint;
  v_l int;
  v_jwt text;
BEGIN
  v_ped := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 4, p);
  PERFORM pg_temp.cp_sustituir(pg_temp.cp_regalo(v_ped, p), s, 19);
  v_otro := pg_temp.cp_alta(p_cli, p_adm, v, 10, r, 2, p);

  SELECT c.limite_usos, c.usos, c.quedan INTO v_l, v_u, v_q
    FROM public.promos_cupo(v_ped) c WHERE c.promocion_id = p;
  f := pg_temp.cp_si(f, v_l = 10 AND v_u = 6 AND v_q = 8, format('promos_cupo(pedido): %s / %s / %s', v_l, v_u, v_q));
  SELECT c.usos, c.quedan INTO v_u, v_q FROM public.promos_cupo() c WHERE c.promocion_id = p;
  f := pg_temp.cp_si(f, v_u = 6 AND v_q = 4, format('promos_cupo(): %s / %s', v_u, v_q));
  f := pg_temp.cp_si(f, NOT EXISTS (SELECT 1 FROM public.promos_cupo() c WHERE c.promocion_id = sin),
                     'promos_cupo devuelve una promo sin limite');

  v_jwt := current_setting('request.jwt.claims', true);
  PERFORM set_config('request.jwt.claims', '', true);
  f := pg_temp.cp_si(f, NOT EXISTS (SELECT 1 FROM public.promos_cupo()), 'promos_cupo sin sesion devuelve filas');
  PERFORM set_config('request.jwt.claims', v_jwt, true);
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c13(p_cli bigint, p_cli2 bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
  v_f text;
BEGIN
  FOREACH v_f IN ARRAY ARRAY['public.regalo_usos_de_linea(jsonb,uuid,numeric)', 'public._promo_usos(bigint,bigint)'] LOOP
    f := pg_temp.cp_si(f, NOT has_function_privilege('anon', v_f, 'EXECUTE'), format('anon puede ejecutar %s', v_f));
    f := pg_temp.cp_si(f, NOT has_function_privilege('authenticated', v_f, 'EXECUTE'), format('authenticated puede ejecutar %s', v_f));
  END LOOP;
  f := pg_temp.cp_si(f, NOT has_function_privilege('anon', 'public.promos_cupo(bigint)', 'EXECUTE'), 'anon puede ejecutar promos_cupo');
  f := pg_temp.cp_si(f, has_function_privilege('authenticated', 'public.promos_cupo(bigint)', 'EXECUTE'), 'authenticated no puede ejecutar promos_cupo');
  f := pg_temp.cp_si(f, NOT EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() a WHERE a.firma LIKE 'promos_cupo%'),
                     'promos_cupo sale en SEG-A');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Corrida
-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_admin    uuid;
  v_suc      bigint;
  v_cliente  bigint;
  v_cliente2 bigint;
  v_caso     text;
  v_out      jsonb;
  v_fallas   text[] := '{}';
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
  SELECT c.id INTO v_cliente FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL)
   ORDER BY c.id LIMIT 1;
  SELECT c.id INTO v_cliente2 FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo AND c.id <> v_cliente
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL)
   ORDER BY c.id LIMIT 1;
  IF v_cliente2 IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita dos clientes activos en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['c1', 'c2', 'c3', 'c4', 'c5', 'c6', 'c7', 'c7b', 'c8', 'c9',
                                'c10', 'c11', 'c12', 'c13'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3, $4)', v_caso)
        INTO v_out USING v_cliente, v_cliente2, v_admin, v_suc;
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
  PERFORM set_config('app.omitir_minimo_pedido', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE NOTICE 'ENSAYO OK';
END
$ensayo$;

-- Nada de lo de arriba queda escrito: la transaccion se revierte entera.
DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
