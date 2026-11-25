-- Ensayo de la tarjeta B de la tanda 6 del plan #1603 (reauditoría del 24/11):
-- migrations/544_promos_tipo_con_bloques_y_sustituto_con_bulto.sql.
--
--   A · PRM-1 (decisión del dueño del 24/11): una promo de fracción cuya barra ya
--       cerró bloques, con pedidos abiertos en esa barra, no pasa a unidad entera.
--       Promo «10 V dan 6 R», contenedor Cont (6 R = 1 Cont), Cont en 100. P1 =
--       V×10 + R×6 cierra un bloque (Cont 99), P2 = V×10 + R×4.
--       A1 · el admin la pasa a unidad entera como la pantalla (cambiar_regalo_promocion):
--            se rechaza con el motivo y los 2 pedidos; la promo sigue de fracción; al
--            cancelar P1 y P2, Cont vuelve a 100 y no quedan bloques vivos.
--       A2 · lo mismo con un UPDATE directo (un bundle viejo, o a mano): se rechaza.
--       A3 · sin bloques cerrados (sólo V×10 + R×4) se puede, como siempre (#1324).
--       A4 · con el bloque cerrado por un pedido ya entregado y ningún abierto, se puede
--            (el molde de D2: los entregados no traban el cambio).
--       A5 · de unidad entera a fracción, con pedidos abiertos, se puede.
--   B · promos-B1: en una promo de fracción con unidades por bloque, el sustituto del
--       mismo rubro sin «unidades por bulto» no hereda el empaque de la promo.
--       Promo «5 V dan 2 R», R es su propio contenedor (6 R = 1 R). Pedido V×10 + R×4.
--       B1 · el encargado cambia R×4 por X×80 (X del mismo rubro, sin bulto): se rechaza
--            con «unidades por bulto» y no cambia nada.
--       B2 · con X1 (mismo rubro, bulto 1): anda, y descuenta 4 X1.
--       B3 · con Y (mismo rubro, sin bulto) descontando del contenedor de la promo: anda.
--       B4 · el reparto R×4 → R×2 + X×2 (X sin bulto): se rechaza igual.
--       B5 · el reparto R×4 → R×2 + Z×2 (Z con bulto 6, el de la promo): anda.
--   C · promos-B3: la edición de una promo valida lo que valida el alta.
--       C1 · `reglas: []` se rechaza y las reglas quedan.
--       C2 · `producto_ids: []` se rechaza y los productos quedan.
--       C3 · con ajuste automático y sin contenedor, se rechaza.
--       C4 · con ajuste automático y sin unidades por bloque, se rechaza.
--       C5 · el guardado completo, sin cambios, anda.
--       C6 · unidad entera sin producto de regalo, y fracción sin descripción del regalo, se
--            rechazan (H6 de la lente).
--   D · promos-B2 (decisión del dueño del 24/11): el tope del sustituto se mide contra el
--       regalo DEL PEDIDO (lo que daba la promo y lo que valía cuando se armó), no contra el
--       regalo de hoy de la promo. D1 · pasarse se rechaza; D2 · lo justo anda; D3 · la RPC
--       de la pantalla (regalo_referencia_de_linea) da ese regalo. D4 · una edición sin
--       cambios no lo mueve (H1 de la lente); D5 · un cambio sólo del contenedor tampoco
--       (H2: old_data trae sólo lo que cambió).
--   E · promos-B6 (decisión del dueño del 24/11): el regalo de una promo apagada se conserva
--       pero no crece. E1 · V×20 + R×8 se rechaza; E2 · V×20 + R×4 anda; E3 · bajar la venta
--       lo sigue recortando.
--
-- Arma sus propios usuarios, clientes, productos y promos en la primera sucursal
-- activa. Todo se deshace: el veredicto es el RAISE final, 'ENSAYO OK …' o
-- 'ENSAYO FALLÓ (n)' con la lista. Se corre en una base local armada con
-- scripts/concurrencia/docker-local.mjs, nunca contra prod (escribe en auth.users):
--
--   tr -d '\r' < scripts/test-promos-tanda6-1603.sql | docker exec -i <contenedor> psql -U postgres -d postgres -q
--
-- Sin la migración falla en A1, A2, B1, B4, C1, C2, C3, C4, C6, D1, D3, D4, D5 (la RPC no existe) y E1.

SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION pg_temp.t6b_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_u(p_rol text, p_suc bigint)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE
  v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6b-' || v || '@ensayo.invalid',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 't6b ' || p_rol), now(), now());
  RETURN v;
END
$f$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_claims(p_user uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_cli(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo tanda 6', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_prod(p_suc bigint, p_nombre text, p_cat text, p_precio numeric, p_stock int,
                                           p_bulto int DEFAULT NULL)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria, unidades_por_bulto)
  VALUES ('ZZ t6b ' || p_nombre, p_precio, p_stock, 10, p_suc, p_cat, p_bulto)
  RETURNING id;
$fn$;

-- «p_compra de p_venta dan p_bonif de p_regalo»; fracción con contenedor si p_cont no es NULL.
CREATE OR REPLACE FUNCTION pg_temp.t6b_promo(p_suc bigint, p_venta bigint, p_regalo bigint, p_compra int, p_bonif int,
                                            p_mueve boolean, p_cont bigint DEFAULT NULL, p_upb int DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, ajuste_producto_id,
                                  unidades_por_bloque, stock_por_bloque, descripcion_regalo)
  VALUES ('ZZ t6b promo', 'bonificacion', public._tablero_hoy() - 1, p_suc, p_mueve, p_regalo,
          p_cont IS NOT NULL, p_cont, p_upb, CASE WHEN p_cont IS NOT NULL THEN 1 END,
          CASE WHEN p_cont IS NOT NULL THEN '1 botella de ensayo' END)
  RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', p_compra, p_suc), (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, p_venta, p_suc);
  RETURN v_promo;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_items(p_venta bigint, p_cv int, p_regalo bigint, p_cr int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_venta, 'cantidad', p_cv, 'precio_unitario', 100))
         || CASE WHEN p_cr > 0 THEN jsonb_build_array(
              jsonb_build_object('producto_id', p_regalo, 'cantidad', p_cr, 'precio_unitario', 0,
                                 'es_bonificacion', true, 'promocion_id', p_promo)) ELSE '[]'::jsonb END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_alta(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_tot numeric;
BEGIN
  PERFORM pg_temp.t6b_claims(p_user, p_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
    FROM jsonb_array_elements(p_items) e;
  v_res := public.crear_pedido_completo(p_cli, v_tot, p_user, p_items, 'ensayo tanda 6');
  PERFORM pg_temp.t6b_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'alta falló: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_cancelar(p_user uuid, p_suc bigint, p_ped bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.t6b_claims(p_user, p_suc);
  j := public.cancelar_pedido_con_stock(p_ped, 'ensayo tanda 6', p_user, NULL);
  PERFORM pg_temp.t6b_reset();
  RETURN j;
END $fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_sust(p_user uuid, p_suc bigint, p_item bigint, p_prod bigint, p_cant numeric,
                                           p_cont bigint DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.t6b_claims(p_user, p_suc);
  j := public.sustituir_regalo_pedido(p_item, p_prod, p_cant, 'ensayo', p_cont, NULL);
  PERFORM pg_temp.t6b_reset();
  RETURN j;
END $fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_dividir(p_user uuid, p_suc bigint, p_item bigint, p_partes jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.t6b_claims(p_user, p_suc);
  j := public.dividir_regalo_pedido(p_item, p_partes, 'ensayo', NULL);
  PERFORM pg_temp.t6b_reset();
  RETURN j;
END $fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_editar(p_user uuid, p_suc bigint, p_ped bigint, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.t6b_claims(p_user, p_suc);
  j := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.t6b_reset();
  RETURN j;
END $fn$;

-- Guarda la promo como el front (cambiar_regalo_promocion con p_datos, como authenticated),
-- cambiando sólo lo que diga p_cambios.
CREATE OR REPLACE FUNCTION pg_temp.t6b_guardar(p_user uuid, p_suc bigint, p_promo bigint, p_cambios jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE j jsonb; p record; v_datos jsonb;
BEGIN
  SELECT * INTO p FROM public.promociones WHERE id = p_promo;
  v_datos := jsonb_build_object(
    'nombre', p.nombre, 'tipo', p.tipo, 'fecha_inicio', p.fecha_inicio, 'fecha_fin', p.fecha_fin,
    'limite_usos', p.limite_usos, 'prioridad', p.prioridad, 'regalo_mueve_stock', p.regalo_mueve_stock,
    'modo_exclusion', p.modo_exclusion, 'unidades_por_bloque', p.unidades_por_bloque, 'stock_por_bloque', p.stock_por_bloque,
    'descripcion_regalo', p.descripcion_regalo,
    'producto_ids', (SELECT jsonb_agg(producto_id) FROM public.promocion_productos WHERE promocion_id = p_promo),
    'reglas', (SELECT jsonb_agg(jsonb_build_object('clave', clave, 'valor', valor)) FROM public.promocion_reglas WHERE promocion_id = p_promo))
    || (p_cambios - 'producto_regalo_id' - 'ajuste_producto_id' - 'ajuste_automatico');
  PERFORM pg_temp.t6b_claims(p_user, p_suc);
  SET LOCAL ROLE authenticated;
  j := public.cambiar_regalo_promocion(p_promo,
         CASE WHEN p_cambios ? 'producto_regalo_id' THEN (p_cambios->>'producto_regalo_id')::bigint ELSE p.producto_regalo_id END,
         CASE WHEN p_cambios ? 'ajuste_producto_id' THEN (p_cambios->>'ajuste_producto_id')::bigint ELSE p.ajuste_producto_id END,
         COALESCE((p_cambios->>'ajuste_automatico')::boolean, p.ajuste_automatico), v_datos);
  RESET ROLE;
  PERFORM pg_temp.t6b_reset();
  RETURN j;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RETURN jsonb_build_object('success', false, 'excepcion', SQLERRM);
END $fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6b_bloques(p_promo bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT COALESCE(sum(bloques_vivos), 0) FROM public.promo_ajustes WHERE promocion_id = p_promo AND bloques_vivos > 0;
$fn$;

DO $ensayo$
DECLARE
  v_suc bigint;
  v_adm uuid; v_enc uuid; v_cli bigint;
  V bigint; R bigint; C bigint; X bigint; X1 bigint; Y bigint; Z bigint;
  p bigint; p1 bigint; p2 bigint; it bigint;
  j jsonb; v_txt text; v_n int;
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';
  SELECT id INTO v_suc FROM public.sucursales WHERE COALESCE(activa, true) ORDER BY id LIMIT 1;
  v_adm := pg_temp.t6b_u('admin', v_suc);
  v_enc := pg_temp.t6b_u('encargado', v_suc);
  v_cli := pg_temp.t6b_cli(v_suc, 'ZZ t6b cliente');

  -- =====================================================================
  -- A · PRM-1
  -- =====================================================================
  V := pg_temp.t6b_prod(v_suc, 'A V', 'ZZ t6b venta', 100, 500);
  R := pg_temp.t6b_prod(v_suc, 'A R', 'ZZ t6b regalo', 10, 500);
  C := pg_temp.t6b_prod(v_suc, 'A Cont', 'ZZ t6b cont', 600, 100);
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 6, false, C, 6);
  p1 := pg_temp.t6b_alta(v_cli, v_adm, v_suc, pg_temp.t6b_items(V, 10, R, 6, p));
  p2 := pg_temp.t6b_alta(v_cli, v_adm, v_suc, pg_temp.t6b_items(V, 10, R, 4, p));
  IF (SELECT stock FROM public.productos WHERE id = C) <> 99 OR pg_temp.t6b_bloques(p) <> 1 THEN
    RAISE EXCEPTION 'A · preparación: Cont %, bloques % (esperaba 99 y 1)',
      (SELECT stock FROM public.productos WHERE id = C), pg_temp.t6b_bloques(p);
  END IF;

  -- A1 · como la pantalla: unidad entera, sin ajuste automático ni contenedor
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{"regalo_mueve_stock": true, "ajuste_automatico": false, "ajuste_producto_id": null}');
  v_txt := COALESCE(j->>'error', j->>'excepcion', '');
  IF COALESCE((j->>'success')::boolean, false)
     OR v_txt NOT LIKE '%No se puede pasar la promo%a unidad entera%'
     OR v_txt NOT LIKE '%2 pedido(s) sin entregar%'
     OR v_txt NOT LIKE '%#' || p1 || ', #' || p2 || '%' THEN
    v_fallas := v_fallas || format('A1: pasar a unidad entera con un bloque cerrado y 2 pedidos abiertos tenía que rechazarse con el motivo (%s)', j);
  END IF;
  IF (SELECT regalo_mueve_stock OR NOT ajuste_automatico FROM public.promociones WHERE id = p) THEN
    v_fallas := v_fallas || 'A1: la promo dejó de ser de fracción'::text;
  END IF;

  -- A2 · un UPDATE directo
  BEGIN
    UPDATE public.promociones SET regalo_mueve_stock = true WHERE id = p;
    v_txt := NULL;
  EXCEPTION WHEN raise_exception THEN
    v_txt := SQLERRM;
  END;
  IF v_txt IS NULL OR v_txt NOT LIKE '%No se puede pasar la promo%' THEN
    v_fallas := v_fallas || format('A2: el UPDATE directo tenía que rechazarse (%s)', COALESCE(v_txt, 'pasó'));
  END IF;

  -- A1 (sigue) · cancelados los dos, Cont vuelve a 100 y no quedan bloques; ahí se puede
  PERFORM pg_temp.t6b_cancelar(v_adm, v_suc, p1);
  PERFORM pg_temp.t6b_cancelar(v_adm, v_suc, p2);
  IF (SELECT stock FROM public.productos WHERE id = C) <> 100 OR pg_temp.t6b_bloques(p) <> 0 THEN
    v_fallas := v_fallas || format('A1: al cancelar P1 y P2, Cont %s y bloques %s (esperaba 100 y 0)',
      (SELECT stock FROM public.productos WHERE id = C), pg_temp.t6b_bloques(p));
  END IF;
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{"regalo_mueve_stock": true, "ajuste_automatico": false, "ajuste_producto_id": null}');
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('A1: sin pedidos abiertos el cambio de tipo tenía que andar (%s)', j);
  END IF;

  -- A3 · sin bloques cerrados (#1324)
  V := pg_temp.t6b_prod(v_suc, 'A3 V', 'ZZ t6b venta', 100, 500);
  R := pg_temp.t6b_prod(v_suc, 'A3 R', 'ZZ t6b regalo', 10, 500);
  C := pg_temp.t6b_prod(v_suc, 'A3 Cont', 'ZZ t6b cont', 600, 100);
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 6, false, C, 6);
  p2 := pg_temp.t6b_alta(v_cli, v_adm, v_suc, pg_temp.t6b_items(V, 10, R, 4, p));
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{"regalo_mueve_stock": true, "ajuste_automatico": false, "ajuste_producto_id": null}');
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('A3: sin bloques cerrados el cambio de tipo tenía que andar (%s)', j);
  END IF;
  -- A5 · y volver a fracción con ese pedido abierto, también
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, format('{"regalo_mueve_stock": false, "ajuste_automatico": true, "ajuste_producto_id": %s}', C)::jsonb);
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('A5: de unidad entera a fracción tenía que andar (%s)', j);
  END IF;

  -- A4 · el bloque lo cerró un pedido entregado y no hay abiertos
  V := pg_temp.t6b_prod(v_suc, 'A4 V', 'ZZ t6b venta', 100, 500);
  R := pg_temp.t6b_prod(v_suc, 'A4 R', 'ZZ t6b regalo', 10, 500);
  C := pg_temp.t6b_prod(v_suc, 'A4 Cont', 'ZZ t6b cont', 600, 100);
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 6, false, C, 6);
  p1 := pg_temp.t6b_alta(v_cli, v_adm, v_suc, pg_temp.t6b_items(V, 10, R, 6, p));
  UPDATE public.pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = now() WHERE id = p1;
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{"regalo_mueve_stock": true, "ajuste_automatico": false, "ajuste_producto_id": null}');
  IF NOT COALESCE((j->>'success')::boolean, false) OR pg_temp.t6b_bloques(p) <> 1 THEN
    v_fallas := v_fallas || format('A4: con el bloque de un pedido entregado y ninguno abierto, el cambio tenía que andar (%s, bloques %s)',
      j, pg_temp.t6b_bloques(p));
  END IF;

  -- =====================================================================
  -- B · promos-B1
  -- =====================================================================
  V  := pg_temp.t6b_prod(v_suc, 'B V', 'ZZ t6b venta', 100, 500);
  R  := pg_temp.t6b_prod(v_suc, 'B R', 'ZZ t6b rubro B', 100, 500);
  X  := pg_temp.t6b_prod(v_suc, 'B X', 'ZZ t6b rubro B', 5, 500);
  X1 := pg_temp.t6b_prod(v_suc, 'B X1', 'ZZ t6b rubro B', 5, 500, 1);
  Y  := pg_temp.t6b_prod(v_suc, 'B Y', 'ZZ t6b rubro B', 100, 500);
  Z  := pg_temp.t6b_prod(v_suc, 'B Z', 'ZZ t6b rubro B', 100, 500, 6);
  p := pg_temp.t6b_promo(v_suc, V, R, 5, 2, false, R, 6);

  -- B1 · R×4 → X×80, X sin bulto
  p1 := pg_temp.t6b_alta(v_cli, v_enc, v_suc, pg_temp.t6b_items(V, 10, R, 4, p));
  it := (SELECT id FROM public.pedido_items WHERE pedido_id = p1 AND es_bonificacion);
  j := pg_temp.t6b_sust(v_enc, v_suc, it, X, 80);
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'error', '') NOT LIKE '%unidades por bulto%' THEN
    v_fallas := v_fallas || format('B1: el sustituto del mismo rubro sin bulto tenía que rechazarse (%s)', j);
  END IF;
  IF (SELECT producto_id FROM public.pedido_items WHERE id = it) <> R
     OR (SELECT stock FROM public.productos WHERE id = X) <> 500 THEN
    v_fallas := v_fallas || 'B1: el rechazo cambió la línea o el stock de X'::text;
  END IF;

  -- B2 · R×4 → X1×4, X1 con bulto 1: anda y descuenta 4
  j := pg_temp.t6b_sust(v_enc, v_suc, it, X1, 4);
  IF NOT COALESCE((j->>'success')::boolean, false) OR (SELECT stock FROM public.productos WHERE id = X1) <> 496 THEN
    v_fallas := v_fallas || format('B2: con bulto 1 el cambio tenía que andar y descontar 4 (%s, stock %s)',
      j, (SELECT stock FROM public.productos WHERE id = X1));
  END IF;
  PERFORM pg_temp.t6b_cancelar(v_adm, v_suc, p1);

  -- B3 · R×4 → Y×4, Y sin bulto, descontando del contenedor de la promo (R)
  p1 := pg_temp.t6b_alta(v_cli, v_enc, v_suc, pg_temp.t6b_items(V, 10, R, 4, p));
  it := (SELECT id FROM public.pedido_items WHERE pedido_id = p1 AND es_bonificacion);
  j := pg_temp.t6b_sust(v_enc, v_suc, it, Y, 4, R);
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('B3: el sustituto que descuenta del contenedor de la promo tenía que andar (%s)', j);
  END IF;
  PERFORM pg_temp.t6b_cancelar(v_adm, v_suc, p1);

  -- B4 · el reparto R×4 → R×2 + X×2
  p1 := pg_temp.t6b_alta(v_cli, v_enc, v_suc, pg_temp.t6b_items(V, 10, R, 4, p));
  it := (SELECT id FROM public.pedido_items WHERE pedido_id = p1 AND es_bonificacion);
  j := pg_temp.t6b_dividir(v_enc, v_suc, it, jsonb_build_array(
         jsonb_build_object('producto_id', R, 'cantidad', 2), jsonb_build_object('producto_id', X, 'cantidad', 2)));
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'error', '') NOT LIKE '%unidades por bulto%' THEN
    v_fallas := v_fallas || format('B4: el reparto con un sabor sin bulto tenía que rechazarse (%s)', j);
  END IF;
  SELECT count(*) INTO v_n FROM public.pedido_items WHERE pedido_id = p1 AND es_bonificacion;
  IF v_n <> 1 THEN
    v_fallas := v_fallas || format('B4: el rechazo dejó %s líneas de regalo', v_n);
  END IF;

  -- B5 · el reparto R×4 → R×2 + Z×2, Z con bulto 6
  j := pg_temp.t6b_dividir(v_enc, v_suc, it, jsonb_build_array(
         jsonb_build_object('producto_id', R, 'cantidad', 2), jsonb_build_object('producto_id', Z, 'cantidad', 2)));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('B5: el reparto con un sabor con su bulto tenía que andar (%s)', j);
  END IF;
  PERFORM pg_temp.t6b_cancelar(v_adm, v_suc, p1);

  -- =====================================================================
  -- C · promos-B3 (una promo nueva por caso)
  -- =====================================================================
  V := pg_temp.t6b_prod(v_suc, 'C V', 'ZZ t6b venta', 100, 500);
  R := pg_temp.t6b_prod(v_suc, 'C R', 'ZZ t6b regalo', 10, 500);
  C := pg_temp.t6b_prod(v_suc, 'C Cont', 'ZZ t6b cont', 600, 100);

  -- C1 · reglas vacías
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 6, false, C, 6);
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{"reglas": []}');
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'error', '') NOT LIKE '%cantidad de compra y la de bonificación%' THEN
    v_fallas := v_fallas || format('C1: reglas vacías tenían que rechazarse (%s)', j);
  END IF;
  SELECT count(*) INTO v_n FROM public.promocion_reglas WHERE promocion_id = p;
  IF v_n <> 2 THEN
    v_fallas := v_fallas || format('C1: la promo quedó con %s reglas', v_n);
  END IF;

  -- C2 · productos vacíos
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 6, false, C, 6);
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{"producto_ids": []}');
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'error', '') NOT LIKE '%al menos un producto%' THEN
    v_fallas := v_fallas || format('C2: productos vacíos tenían que rechazarse (%s)', j);
  END IF;
  SELECT count(*) INTO v_n FROM public.promocion_productos WHERE promocion_id = p;
  IF v_n <> 1 THEN
    v_fallas := v_fallas || format('C2: la promo quedó con %s productos', v_n);
  END IF;

  -- C3 · ajuste automático sin contenedor
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 6, false, C, 6);
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{"ajuste_producto_id": null}');
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'error', '') NOT LIKE '%el contenedor%' THEN
    v_fallas := v_fallas || format('C3: ajuste automático sin contenedor tenía que rechazarse (%s)', j);
  END IF;
  IF (SELECT ajuste_producto_id IS DISTINCT FROM C FROM public.promociones WHERE id = p) THEN
    v_fallas := v_fallas || 'C3: la promo quedó sin contenedor'::text;
  END IF;

  -- C4 · ajuste automático sin unidades por bloque
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 6, false, C, 6);
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{"unidades_por_bloque": null}');
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'error', '') NOT LIKE '%subunidades%' THEN
    v_fallas := v_fallas || format('C4: ajuste automático sin unidades por bloque tenía que rechazarse (%s)', j);
  END IF;
  IF (SELECT unidades_por_bloque IS DISTINCT FROM 6 FROM public.promociones WHERE id = p) THEN
    v_fallas := v_fallas || 'C4: la promo quedó sin unidades por bloque'::text;
  END IF;

  -- C5 · el guardado completo anda
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 6, false, C, 6);
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{}');
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('C5: el guardado sin cambios tenía que andar (%s)', j);
  END IF;

  -- =====================================================================
  -- D · promos-B2. Promo de unidad entera «5 V dan 2 R», R a $ 100. Pedido V×10 + R×4
  --     (corte 4). Después el admin cambia el regalo de la promo a P ($ 10.000) y R sube a
  --     $ 200. W es del mismo rubro que R y vale $ 50: por valor entran 4 × 100 / 50 = 8 W
  --     (contra el regalo de hoy entraban 800).
  -- =====================================================================
  V := pg_temp.t6b_prod(v_suc, 'D V', 'ZZ t6b venta', 100, 500);
  R := pg_temp.t6b_prod(v_suc, 'D R', 'ZZ t6b rubro D', 100, 500);
  X := pg_temp.t6b_prod(v_suc, 'D P', 'ZZ t6b perfumes', 10000, 500);
  Y := pg_temp.t6b_prod(v_suc, 'D W', 'ZZ t6b rubro D', 50, 500);
  p := pg_temp.t6b_promo(v_suc, V, R, 5, 2, true);
  p1 := pg_temp.t6b_alta(v_cli, v_enc, v_suc, pg_temp.t6b_items(V, 10, R, 4, p));
  it := (SELECT id FROM public.pedido_items WHERE pedido_id = p1 AND es_bonificacion);
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, format('{"producto_regalo_id": %s}', X)::jsonb);
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'D · preparación: no se pudo cambiar el regalo de la promo (%)', j;
  END IF;
  UPDATE public.productos SET precio = 200 WHERE id = R;
  -- D1 · W×9 pasa lo que valía el regalo del pedido
  j := pg_temp.t6b_sust(v_enc, v_suc, it, Y, 9);
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'codigo', '') <> 'regalo_sustituto_sobre_tope' THEN
    v_fallas := v_fallas || format('D1: W×9 pasa lo que valía el regalo del pedido y tenía que rechazarse (%s)', j);
  END IF;
  -- D2 · W×8 vale lo mismo
  j := pg_temp.t6b_sust(v_enc, v_suc, it, Y, 8);
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('D2: W×8 vale lo que el regalo del pedido y tenía que andar (%s)', j);
  END IF;
  -- D3 · la referencia que lee la pantalla
  BEGIN
    PERFORM pg_temp.t6b_claims(v_enc, v_suc);
    SET LOCAL ROLE authenticated;
    EXECUTE 'SELECT public.regalo_referencia_de_linea($1)' INTO j USING it;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    j := jsonb_build_object('excepcion', SQLERRM);
  END;
  IF (j->>'producto_id')::bigint IS DISTINCT FROM R OR (j->>'precio')::numeric IS DISTINCT FROM 100 THEN
    v_fallas := v_fallas || format('D3: la referencia de la pantalla tenía que ser R a $ 100 (%s)', j);
  END IF;

  -- =====================================================================
  -- E · promos-B6. Promo de unidad entera «10 V dan 4 R». Pedido V×10 + R×4; el admin la
  --     apaga.
  -- =====================================================================
  V := pg_temp.t6b_prod(v_suc, 'E V', 'ZZ t6b venta', 100, 500);
  R := pg_temp.t6b_prod(v_suc, 'E R', 'ZZ t6b regalo', 10, 500);
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 4, true);
  p1 := pg_temp.t6b_alta(v_cli, v_enc, v_suc, pg_temp.t6b_items(V, 10, R, 4, p));
  UPDATE public.promociones SET activo = false WHERE id = p;
  -- E1 · a V×20 + R×8: no crece
  j := pg_temp.t6b_editar(v_enc, v_suc, p1, pg_temp.t6b_items(V, 20, R, 8, p));
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'errores', '') NOT LIKE '%ya no rige%' THEN
    v_fallas := v_fallas || format('E1: el regalo de la promo apagada no puede crecer (%s)', j);
  END IF;
  -- E2 · a V×20 + R×4: se conserva
  j := pg_temp.t6b_editar(v_enc, v_suc, p1, pg_temp.t6b_items(V, 20, R, 4, p));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('E2: el regalo de la promo apagada se conserva (%s)', j);
  END IF;
  -- E3 · a V×5 + R×4: bajar la venta lo recorta, como siempre
  j := pg_temp.t6b_editar(v_enc, v_suc, p1, pg_temp.t6b_items(V, 5, R, 4, p));
  IF COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('E3: con V×5 el regalo de 4 no entra (%s)', j);
  END IF;
  SELECT COALESCE(sum(cantidad), 0) INTO v_n FROM public.pedido_items WHERE pedido_id = p1 AND es_bonificacion;
  IF v_n <> 4 THEN
    v_fallas := v_fallas || format('E: el pedido quedó con %s de regalo (esperaba 4)', v_n);
  END IF;

  -- =====================================================================
  -- D4 · promos-B2, H1 de la lente: una edición sin cambios (reinserta las líneas y renueva
  --      la foto) no cambia la referencia. Mismo armado que D; el encargado guarda el pedido
  --      tal cual y después pone W×9 (se rechaza) y W×8 (anda).
  -- =====================================================================
  V := pg_temp.t6b_prod(v_suc, 'D4 V', 'ZZ t6b venta', 100, 500);
  R := pg_temp.t6b_prod(v_suc, 'D4 R', 'ZZ t6b rubro D4', 100, 500);
  X := pg_temp.t6b_prod(v_suc, 'D4 P', 'ZZ t6b perfumes', 10000, 500);
  Y := pg_temp.t6b_prod(v_suc, 'D4 W', 'ZZ t6b rubro D4', 50, 500);
  p := pg_temp.t6b_promo(v_suc, V, R, 5, 2, true);
  p1 := pg_temp.t6b_alta(v_cli, v_enc, v_suc, pg_temp.t6b_items(V, 10, R, 4, p));
  -- Tanda 6 bis (lente t6b2): el pedido nació «ayer» y el cambio de la promo fue «hace 12 h».
  -- En una sola transacción now() es uno solo y la foto renovada por la edición empataba con
  -- la fila de audit_logs: el caso no mordía contra el cuerpo de antes de la 544.
  UPDATE public.pedidos SET created_at = now() - interval '1 day' WHERE id = p1;
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, format('{"producto_regalo_id": %s}', X)::jsonb);
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'D4 · preparación: no se pudo cambiar el regalo de la promo (%)', j;
  END IF;
  UPDATE public.audit_logs SET created_at = now() - interval '12 hours'
   WHERE tabla = 'promociones' AND registro_id = p::text AND accion = 'UPDATE';
  j := pg_temp.t6b_editar(v_enc, v_suc, p1, pg_temp.t6b_items(V, 10, R, 4, p));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'D4 · preparación: la edición sin cambios no anduvo (%)', j;
  END IF;
  it := (SELECT id FROM public.pedido_items WHERE pedido_id = p1 AND es_bonificacion);
  j := pg_temp.t6b_sust(v_enc, v_suc, it, Y, 9);
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'codigo', '') <> 'regalo_sustituto_sobre_tope' THEN
    v_fallas := v_fallas || format('D4: después de una edición sin cambios, W×9 tenía que rechazarse igual (%s)', j);
  END IF;
  j := pg_temp.t6b_sust(v_enc, v_suc, it, Y, 8);
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('D4: W×8 tenía que andar (%s)', j);
  END IF;

  -- =====================================================================
  -- D5 · promos-B2, H2 de la lente: el admin cambia SÓLO el contenedor (old_data trae sólo
  --      esa columna). Promo de unidad entera con contenedor «10 V dan 4 R», R a $ 100; W del
  --      rubro de R a $ 50. La referencia sigue siendo R: W×40 se rechaza, W×8 anda, y la
  --      RPC de la pantalla da R.
  -- =====================================================================
  V := pg_temp.t6b_prod(v_suc, 'D5 V', 'ZZ t6b venta', 100, 500);
  R := pg_temp.t6b_prod(v_suc, 'D5 R', 'ZZ t6b rubro D5', 100, 500);
  C := pg_temp.t6b_prod(v_suc, 'D5 Cont', 'ZZ t6b rubro D5', 600, 100);
  X := pg_temp.t6b_prod(v_suc, 'D5 Cont2', 'ZZ t6b rubro D5', 600, 100);
  Y := pg_temp.t6b_prod(v_suc, 'D5 W', 'ZZ t6b rubro D5', 50, 500);
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 4, true, C, 6);
  p1 := pg_temp.t6b_alta(v_cli, v_enc, v_suc, pg_temp.t6b_items(V, 10, R, 4, p));
  it := (SELECT id FROM public.pedido_items WHERE pedido_id = p1 AND es_bonificacion);
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, format('{"ajuste_producto_id": %s}', X)::jsonb);
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'D5 · preparación: no se pudo cambiar el contenedor de la promo (%)', j;
  END IF;
  BEGIN
    PERFORM pg_temp.t6b_claims(v_enc, v_suc);
    SET LOCAL ROLE authenticated;
    EXECUTE 'SELECT public.regalo_referencia_de_linea($1)' INTO j USING it;
    RESET ROLE;
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    j := jsonb_build_object('excepcion', SQLERRM);
  END;
  IF (j->>'producto_id')::bigint IS DISTINCT FROM R THEN
    v_fallas := v_fallas || format('D5: con sólo el contenedor cambiado, la referencia tenía que seguir siendo R (%s)', j);
  END IF;
  j := pg_temp.t6b_sust(v_enc, v_suc, it, Y, 40);
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'codigo', '') <> 'regalo_sustituto_sobre_tope' THEN
    v_fallas := v_fallas || format('D5: W×40 vale más que el regalo y tenía que rechazarse (%s)', j);
  END IF;
  j := pg_temp.t6b_sust(v_enc, v_suc, it, Y, 8);
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('D5: W×8 tenía que andar (%s)', j);
  END IF;

  -- =====================================================================
  -- C6 · promos-B3, H6 de la lente: una de unidad entera sin producto de regalo y una de
  --      fracción sin descripción del regalo se rechazan, como en el alta.
  -- =====================================================================
  V := pg_temp.t6b_prod(v_suc, 'C6 V', 'ZZ t6b venta', 100, 500);
  R := pg_temp.t6b_prod(v_suc, 'C6 R', 'ZZ t6b regalo', 10, 500);
  C := pg_temp.t6b_prod(v_suc, 'C6 Cont', 'ZZ t6b cont', 600, 100);
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 2, true);
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{"producto_regalo_id": null}');
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'error', '') NOT LIKE '%producto de regalo%'
     OR (SELECT producto_regalo_id IS DISTINCT FROM R FROM public.promociones WHERE id = p) THEN
    v_fallas := v_fallas || format('C6: unidad entera sin producto de regalo tenía que rechazarse (%s)', j);
  END IF;
  p := pg_temp.t6b_promo(v_suc, V, R, 10, 6, false, C, 6);
  j := pg_temp.t6b_guardar(v_adm, v_suc, p, '{"descripcion_regalo": null}');
  IF COALESCE((j->>'success')::boolean, false) OR COALESCE(j->>'error', '') NOT LIKE '%descripción del regalo%'
     OR (SELECT descripcion_regalo IS NULL FROM public.promociones WHERE id = p) THEN
    v_fallas := v_fallas || format('C6: fracción sin descripción del regalo tenía que rechazarse (%s)', j);
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (%)\n%', cardinality(v_fallas), array_to_string(v_fallas, E'\n');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK: tanda 6, tarjeta B (PRM-1, promos-B1, B2, B3 y B6)';
END
$ensayo$;
