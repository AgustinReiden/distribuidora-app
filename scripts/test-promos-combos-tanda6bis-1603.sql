-- Ensayo de la tarjeta I de la tanda 6 bis del plan #1603:
-- migrations/NNN_promos_combos_tanda6bis.sql.
--
--   A · promos-B1 en el alta y la edición. Promo de fracción «5 V dan 2 R», R es su propio
--       contenedor (6 R = 1 R). X es del rubro de R sin «unidades por bulto»; X1, del
--       mismo rubro con bulto 1.
--       A1 · el encargado da de alta V×10 + X×4: se rechaza con «unidades por bulto».
--       A2 · el admin, lo mismo (decisión de la coordinadora: el molde de la 544).
--       A3 · V×10 + X1×4 y V×10 + R×4 andan (controles).
--       A4 · la edición de V×10 + R×4 a V×10 + X×4 se rechaza, para el encargado y para el
--            admin; a V×20 + R×8 anda (control).
--       A5 · el admin le cambia el cliente a un pedido con X1 cuyo bulto ya no está: anda
--            (el pedido nuevo recrea lo que el original tenía).
--   B · promos-B4. Combo acumulable 1 A + 1 B a $ 1.000 (A lista $ 800, B lista $ 400).
--       B1 · el alta guarda en la foto el sin escala de cada línea.
--       B2 · B queda sin lista ($ 0): una edición que le declara a B un sin escala de $ 600
--            (descuento de escala de $ 200 que no tenía) se rechaza; con el de la foto anda.
--   C · promos-B5 (decisión del dueño del 25/11): a un pedido que ya tiene un combo cuyo
--       precio cambió, quien no es admin no le puede sumar más. Combo excluyente 1 A + 1 B a
--       $ 1.000 (A lista $ 800, B lista $ 400).
--       C1 · (a) el precio no cambió: sumar de 1 a 2 anda.
--       C2 · (b) el precio sube a $ 1.200: sumar se rechaza con el motivo (el combo y los dos
--            precios); conservar 2 y bajar a 1 andan, a la plata de la foto.
--       C3 · (c) el precio baja a $ 800: igual.
--       C4 · (d) el admin suma con el precio cambiado (a la plata de la foto, como hoy).
--       C5 · (e) un pedido de 2 combos que pasa a 3 con el precio sin cambio anda (F1 de la lente).
--       C6 · (f) después de una salvedad que rompió un combo, la edición del combo que quedó
--            vale lo de la foto, como en main (F2 de la lente).
--       C7 · (g) el cambio de cliente (admin) con el precio cambiado anda y hereda la foto; un
--            combo acumulable se edita sin cambios como en main.
--   D · N1 y N2 de la segunda lente. Promo de unidad entera «5 V dan 2 R», R a $ 100 (rubro
--       D); S es del rubro D; P es un perfume. El pedido nació «ayer»; el admin cambió el
--       regalo de la promo a P «hace 12 h» (las fechas se corren para atrás: no depende del
--       reloj).
--       D1 · N1: el pedido tiene el reparto R×2 + S×2; el encargado sube la venta y manda R×6
--            (el regalo del pedido): anda. Con P×6 (el de hoy) también (control).
--       D2 · N2: el admin le cambia el cliente a V×10 + R×4; la referencia del pedido nuevo
--            es R (el del original), no P.
--       D3 · F5: el admin armó el pedido con un regalo de otro rubro (X×4) y lo repartió en X y
--            Y; el encargado baja la venta y la pantalla vuelve a X (la raíz de sus líneas): X×2
--            anda. Subirla a X×6 se rechaza: lo que entra sólo por F5 no crece (G1).
--       D4 · G1 de la segunda lente: el admin armó V×10 con R×3 + X×1 (X de otro rubro, a
--            $ 5.000); el encargado edita a V×20: X×8 se rechaza, X×1 anda (se conserva) y R×8
--            (X×0) anda.
--
-- Arma sus propios usuarios, clientes, productos, promos y combos en la primera sucursal
-- activa. Todo se deshace: el veredicto es el RAISE final, 'ENSAYO OK …' o 'ENSAYO FALLÓ
-- (n)' con la lista. Se corre en una base local armada con
-- scripts/concurrencia/docker-local.mjs, nunca contra prod (escribe en auth.users):
--
--   tr -d '\r' < scripts/test-promos-combos-tanda6bis-1603.sql | docker exec -i <contenedor> psql -U postgres -d postgres -q
--
-- Sin la migración falla en A1, A2, A4, B1, B2, C2, C3, D1, D2, D3 y D4; con la entrega anterior de
-- esta tarjeta (sin G1), en D3 (subir) y D4 (X×8). A3, A5, C1, C4, C5, C6 y C7
-- son controles (lo que tiene que seguir andando como en main).

SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION pg_temp.t6i_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_u(p_rol text, p_suc bigint)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE
  v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6i-' || v || '@ensayo.invalid',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 't6i ' || p_rol), now(), now());
  RETURN v;
END
$f$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_claims(p_user uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_cli(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo tanda 6 bis', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_prod(p_suc bigint, p_nombre text, p_cat text, p_precio numeric, p_stock int,
                                           p_bulto int DEFAULT NULL)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria, unidades_por_bulto)
  VALUES ('ZZ t6i ' || p_nombre, p_precio, p_stock, 10, p_suc, p_cat, p_bulto)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_promo(p_suc bigint, p_venta bigint, p_regalo bigint, p_compra int, p_bonif int,
                                            p_mueve boolean, p_cont bigint DEFAULT NULL, p_upb int DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, ajuste_producto_id,
                                  unidades_por_bloque, stock_por_bloque, descripcion_regalo)
  VALUES ('ZZ t6i promo', 'bonificacion', public._tablero_hoy() - 1, p_suc, p_mueve, p_regalo,
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

-- V×cv + los regalos [[producto, cantidad], …] de la promo.
CREATE OR REPLACE FUNCTION pg_temp.t6i_items(p_venta bigint, p_cv int, p_promo bigint, p_regalos jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_venta, 'cantidad', p_cv, 'precio_unitario', 100))
         || COALESCE((SELECT jsonb_agg(jsonb_build_object('producto_id', (g->>0)::bigint, 'cantidad', (g->>1)::int,
                                                          'precio_unitario', 0, 'es_bonificacion', true,
                                                          'promocion_id', p_promo))
                        FROM jsonb_array_elements(p_regalos) g), '[]'::jsonb);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_alta_j(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_tot numeric;
BEGIN
  PERFORM pg_temp.t6i_claims(p_user, p_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
    FROM jsonb_array_elements(p_items) e;
  v_res := public.crear_pedido_completo(p_cli, v_tot, p_user, p_items, 'ensayo tanda 6 bis');
  PERFORM pg_temp.t6i_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_alta(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb := pg_temp.t6i_alta_j(p_cli, p_user, p_suc, p_items);
BEGIN
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'alta falló: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_editar(p_user uuid, p_suc bigint, p_ped bigint, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.t6i_claims(p_user, p_suc);
  j := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.t6i_reset();
  RETURN j;
END $fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_cambio_cli(p_user uuid, p_suc bigint, p_ped bigint, p_cli bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE j jsonb;
BEGIN
  PERFORM pg_temp.t6i_claims(p_user, p_suc);
  j := public.cambiar_cliente_pedido(p_ped, p_cli, p_user,
         (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object('producto_id', producto_id, 'cantidad', cantidad,
                                              'precio_unitario', precio_unitario,
                                              'es_bonificacion', es_bonificacion, 'promocion_id', promocion_id,
                                              'combo_id', combo_id, 'precio_sin_combo_unitario', precio_sin_combo_unitario)) ORDER BY id)
            FROM public.pedido_items WHERE pedido_id = p_ped),
         (SELECT sum(subtotal) FROM public.pedido_items WHERE pedido_id = p_ped));
  PERFORM pg_temp.t6i_reset();
  RETURN j;
END $fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_guardar_promo(p_user uuid, p_suc bigint, p_promo bigint, p_regalo bigint)
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
    'reglas', (SELECT jsonb_agg(jsonb_build_object('clave', clave, 'valor', valor)) FROM public.promocion_reglas WHERE promocion_id = p_promo));
  PERFORM pg_temp.t6i_claims(p_user, p_suc);
  SET LOCAL ROLE authenticated;
  j := public.cambiar_regalo_promocion(p_promo, p_regalo, p.ajuste_producto_id, p.ajuste_automatico, v_datos);
  RESET ROLE;
  PERFORM pg_temp.t6i_reset();
  RETURN j;
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RETURN jsonb_build_object('success', false, 'excepcion', SQLERRM);
END $fn$;

-- Un combo de 1 A + 1 B (guardar_combo, como el admin).
CREATE OR REPLACE FUNCTION pg_temp.t6i_combo(p_adm uuid, p_suc bigint, p_a bigint, p_b bigint, p_precio numeric,
                                            p_escalas boolean)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE v_res jsonb;
BEGIN
  PERFORM pg_temp.t6i_claims(p_adm, p_suc);
  v_res := public.guardar_combo(jsonb_build_object('nombre', 'ZZ t6i combo', 'precio', p_precio,
             'fecha_inicio', public._tablero_hoy() - 1, 'combina_escalas', p_escalas,
             'componentes', jsonb_build_array(
               jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p_a)),
               jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(p_b)))));
  PERFORM pg_temp.t6i_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el combo: %', v_res;
  END IF;
  RETURN (v_res->>'id')::bigint;
END
$fn$;

-- k combos de 1 A + 1 B que cobran p_total, repartido como el server (_combo_prorrateo con
-- las referencias). Con p_sin_a / p_sin_b, el sin escala de cada línea (acumulable).
CREATE OR REPLACE FUNCTION pg_temp.t6i_combo_items(p_combo bigint, p_k int, p_total numeric,
                                                  p_a bigint, p_ref_a numeric, p_b bigint, p_ref_b numeric,
                                                  p_sin_a numeric DEFAULT NULL, p_sin_b numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE v_pr jsonb;
BEGIN
  v_pr := public._combo_prorrateo(p_total, jsonb_build_array(
            jsonb_build_object('producto_id', p_a, 'cantidad', p_k, 'ref', p_ref_a),
            jsonb_build_object('producto_id', p_b, 'cantidad', p_k, 'ref', p_ref_b)));
  IF v_pr IS NULL THEN
    RAISE EXCEPTION 'el total % no se reparte', p_total;
  END IF;
  RETURN jsonb_build_array(
    jsonb_strip_nulls(jsonb_build_object('producto_id', p_a, 'cantidad', p_k, 'precio_unitario', (v_pr->>p_a::text)::numeric,
                       'combo_id', p_combo, 'precio_sin_combo_unitario', p_ref_a, 'precio_sin_escala_unitario', p_sin_a)),
    jsonb_strip_nulls(jsonb_build_object('producto_id', p_b, 'cantidad', p_k, 'precio_unitario', (v_pr->>p_b::text)::numeric,
                       'combo_id', p_combo, 'precio_sin_combo_unitario', p_ref_b, 'precio_sin_escala_unitario', p_sin_b)));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t6i_estado(p_ped bigint, p_estado text)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_claims text := current_setting('request.jwt.claims', true);
BEGIN
  PERFORM set_config('request.jwt.claims', '', true);
  UPDATE public.pedidos SET estado = p_estado WHERE id = p_ped;
  PERFORM set_config('request.jwt.claims', COALESCE(v_claims, ''), true);
END
$fn$;

DO $ensayo$
DECLARE
  v_suc bigint;
  v_adm uuid; v_enc uuid; v_cli bigint; v_cli2 bigint;
  V bigint; R bigint; X bigint; X1 bigint; S bigint; Pf bigint; A bigint; B bigint;
  p bigint; p1 bigint; p2 bigint; cb bigint; it bigint;
  j jsonb; v_txt text; v_items jsonb;
  v_fallas text[] := '{}';
BEGIN
  SET LOCAL lock_timeout = '5s';
  SELECT id INTO v_suc FROM public.sucursales WHERE COALESCE(activa, true) ORDER BY id LIMIT 1;
  v_adm := pg_temp.t6i_u('admin', v_suc);
  v_enc := pg_temp.t6i_u('encargado', v_suc);
  v_cli := pg_temp.t6i_cli(v_suc, 'ZZ t6i cliente');
  v_cli2 := pg_temp.t6i_cli(v_suc, 'ZZ t6i cliente 2');

  -- =====================================================================
  -- A · promos-B1 en el alta y la edición
  -- =====================================================================
  V := pg_temp.t6i_prod(v_suc, 'A V', 'ZZ t6i venta', 100, 500);
  R := pg_temp.t6i_prod(v_suc, 'A R', 'ZZ t6i rubro A', 600, 500);
  X := pg_temp.t6i_prod(v_suc, 'A X', 'ZZ t6i rubro A', 5, 500);
  X1 := pg_temp.t6i_prod(v_suc, 'A X1', 'ZZ t6i rubro A', 100, 500, 1);
  p := pg_temp.t6i_promo(v_suc, V, R, 5, 2, false, R, 6);

  -- A1 · el encargado, V×10 + X×4
  j := pg_temp.t6i_alta_j(v_cli, v_enc, v_suc, pg_temp.t6i_items(V, 10, p, jsonb_build_array(jsonb_build_array(X, 4))));
  IF COALESCE((j->>'success')::boolean, false) OR j::text NOT ILIKE '%unidades por bulto%' THEN
    v_fallas := v_fallas || format('A1: el alta del encargado con X (sin bulto) tenía que rechazarse por el bulto (%s)', left(j::text, 300));
  END IF;
  -- A2 · el admin, lo mismo
  j := pg_temp.t6i_alta_j(v_cli, v_adm, v_suc, pg_temp.t6i_items(V, 10, p, jsonb_build_array(jsonb_build_array(X, 4))));
  IF COALESCE((j->>'success')::boolean, false) OR j::text NOT ILIKE '%unidades por bulto%' THEN
    v_fallas := v_fallas || format('A2: el alta del admin con X (sin bulto) tenía que rechazarse por el bulto (%s)', left(j::text, 300));
  END IF;
  -- A3 · controles
  j := pg_temp.t6i_alta_j(v_cli, v_enc, v_suc, pg_temp.t6i_items(V, 10, p, jsonb_build_array(jsonb_build_array(X1, 4))));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('A3: V×10 + X1×4 (X1 con bulto) tenía que andar (%s)', left(j::text, 300));
  END IF;
  p2 := (j->>'pedido_id')::bigint;
  p1 := pg_temp.t6i_alta(v_cli, v_enc, v_suc, pg_temp.t6i_items(V, 10, p, jsonb_build_array(jsonb_build_array(R, 4))));
  -- A4 · la edición
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_items(V, 10, p, jsonb_build_array(jsonb_build_array(X, 4))));
  IF COALESCE((j->>'success')::boolean, false) OR j::text NOT ILIKE '%unidades por bulto%' THEN
    v_fallas := v_fallas || format('A4: la edición del encargado a X tenía que rechazarse por el bulto (%s)', left(j::text, 300));
  END IF;
  j := pg_temp.t6i_editar(v_adm, v_suc, p1, pg_temp.t6i_items(V, 10, p, jsonb_build_array(jsonb_build_array(X, 4))));
  IF COALESCE((j->>'success')::boolean, false) OR j::text NOT ILIKE '%unidades por bulto%' THEN
    v_fallas := v_fallas || format('A4: la edición del admin a X tenía que rechazarse por el bulto (%s)', left(j::text, 300));
  END IF;
  IF (SELECT string_agg(producto_id || 'x' || cantidad, ',' ORDER BY producto_id) FROM public.pedido_items
       WHERE pedido_id = p1 AND es_bonificacion) IS DISTINCT FROM R || 'x4' THEN
    v_fallas := v_fallas || 'A4: el pedido tenía que seguir con R×4'::text;
  END IF;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_items(V, 20, p, jsonb_build_array(jsonb_build_array(R, 8))));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('A4: a V×20 + R×8 tenía que andar (%s)', left(j::text, 300));
  END IF;
  -- A5 · el cambio de cliente recrea lo que el original tenía, aunque X1 ya no tenga bulto
  IF p2 IS NOT NULL THEN
    -- El dato se borra a mano, sin su trigger (validar_cambio_unidades_por_bulto no lo deja
    -- con un pedido abierto): es el caso de un pedido anterior a la regla.
    ALTER TABLE public.productos DISABLE TRIGGER trg_validar_cambio_unidades_por_bulto;
    UPDATE public.productos SET unidades_por_bulto = NULL WHERE id = X1;
    ALTER TABLE public.productos ENABLE TRIGGER trg_validar_cambio_unidades_por_bulto;
    j := pg_temp.t6i_cambio_cli(v_adm, v_suc, p2, v_cli2);
    IF NOT COALESCE((j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('A5: el cambio de cliente de V×10 + X1×4 tenía que andar (%s)', left(j::text, 300));
    END IF;
  END IF;

  -- =====================================================================
  -- B · promos-B4: combo acumulable con un componente que queda sin lista
  -- =====================================================================
  A := pg_temp.t6i_prod(v_suc, 'B A', 'ZZ t6i combos', 800, 500);
  B := pg_temp.t6i_prod(v_suc, 'B B', 'ZZ t6i combos', 400, 500);
  cb := pg_temp.t6i_combo(v_adm, v_suc, A, B, 1000, true);
  v_items := pg_temp.t6i_combo_items(cb, 1, 1000, A, 800, B, 400, 800, 400);
  p1 := pg_temp.t6i_alta(v_cli, v_enc, v_suc, v_items);
  -- B1 · la foto guarda el sin escala de cada línea
  IF (SELECT (f.precios->A::text->>'sin_escala')::numeric FROM public.pedido_combos f
       WHERE f.pedido_id = p1 AND f.combo_id = cb) IS DISTINCT FROM 800 THEN
    v_fallas := v_fallas || format('B1: la foto tenía que guardar el sin escala de A (%s)',
      (SELECT f.precios FROM public.pedido_combos f WHERE f.pedido_id = p1 AND f.combo_id = cb));
  END IF;
  -- B2 · B queda sin lista; la validación de la edición con B a sin escala 600
  UPDATE public.productos SET precio = 0 WHERE id = B;
  v_txt := public.combo_fuera_de_regla(pg_temp.t6i_combo_items(cb, 1, 800, A, 800, B, 400, 800, 600),
                                       v_suc, public._tablero_hoy(), p1, true);
  IF v_txt IS NULL OR v_txt NOT ILIKE '%sin precio de lista%' THEN
    v_fallas := v_fallas || format('B2: B sin lista con un descuento de escala que no tenía tenía que rechazarse (%s)', COALESCE(v_txt, 'aceptado'));
  END IF;
  v_txt := public.combo_fuera_de_regla(pg_temp.t6i_combo_items(cb, 1, 1000, A, 800, B, 400, 800, 400),
                                       v_suc, public._tablero_hoy(), p1, true);
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('B2: con el sin escala de la foto tenía que andar (%s)', v_txt);
  END IF;

  -- =====================================================================
  -- C · promos-B5: el combo que cambió de precio no crece
  -- =====================================================================
  A := pg_temp.t6i_prod(v_suc, 'C A', 'ZZ t6i combos', 800, 500);
  B := pg_temp.t6i_prod(v_suc, 'C B', 'ZZ t6i combos', 400, 500);
  cb := pg_temp.t6i_combo(v_adm, v_suc, A, B, 1000, false);
  -- C1 · (a) sin cambio de precio, sumar anda
  p1 := pg_temp.t6i_alta(v_cli, v_enc, v_suc, pg_temp.t6i_combo_items(cb, 1, 1000, A, 800, B, 400));
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_combo_items(cb, 2, 2000, A, 800, B, 400));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('C1: sin cambio de precio, sumar un combo tenía que andar (%s)', left(j::text, 300));
  END IF;
  -- C2 · (b) el precio sube: sumar se rechaza; conservar y bajar andan
  UPDATE public.combos SET precio = 1200 WHERE id = cb;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_combo_items(cb, 3, 3000, A, 800, B, 400));
  IF COALESCE((j->>'success')::boolean, false) OR j::text NOT ILIKE '%cambió de precio%'
     OR j::text NOT LIKE '%1.000,00%' OR j::text NOT LIKE '%1.200,00%' THEN
    v_fallas := v_fallas || format('C2: con el precio subido, sumar a la foto tenía que rechazarse con los dos precios (%s)', left(j::text, 400));
  END IF;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_combo_items(cb, 4, 4400, A, 800, B, 400));
  IF COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || 'C2: con el precio subido, sumar al promedio (2 a $ 1.000 y 2 a $ 1.200) también tenía que rechazarse'::text;
  END IF;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_combo_items(cb, 2, 2000, A, 800, B, 400));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('C2: conservar los 2 combos a la foto tenía que andar (%s)', left(j::text, 300));
  END IF;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_combo_items(cb, 1, 1000, A, 800, B, 400));
  IF NOT COALESCE((j->>'success')::boolean, false) OR (SELECT total FROM public.pedidos WHERE id = p1) <> 1000 THEN
    v_fallas := v_fallas || format('C2: bajar a 1 combo a la foto tenía que andar (%s)', left(j::text, 300));
  END IF;
  -- C3 · (c) el precio baja: igual
  UPDATE public.combos SET precio = 800 WHERE id = cb;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_combo_items(cb, 2, 2000, A, 800, B, 400));
  IF COALESCE((j->>'success')::boolean, false) OR j::text NOT ILIKE '%cambió de precio%' THEN
    v_fallas := v_fallas || format('C3: con el precio bajado, sumar tenía que rechazarse (%s)', left(j::text, 300));
  END IF;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_combo_items(cb, 1, 1000, A, 800, B, 400));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('C3: con el precio bajado, conservar tenía que andar (%s)', left(j::text, 300));
  END IF;
  -- C4 · (d) el admin suma, a la plata de la foto
  j := pg_temp.t6i_editar(v_adm, v_suc, p1, pg_temp.t6i_combo_items(cb, 2, 2000, A, 800, B, 400));
  IF NOT COALESCE((j->>'success')::boolean, false)
     OR (SELECT cantidad_combos FROM public.pedido_combos WHERE pedido_id = p1 AND combo_id = cb) <> 2 THEN
    v_fallas := v_fallas || format('C4: el admin tenía que poder sumar con el precio cambiado (%s)', left(j::text, 300));
  END IF;

  -- C5 · (e) 2 combos que pasan a 3 con el precio sin cambio (F1 de la lente)
  A := pg_temp.t6i_prod(v_suc, 'C5 A', 'ZZ t6i combos', 800, 500);
  B := pg_temp.t6i_prod(v_suc, 'C5 B', 'ZZ t6i combos', 400, 500);
  cb := pg_temp.t6i_combo(v_adm, v_suc, A, B, 1000, false);
  p1 := pg_temp.t6i_alta(v_cli, v_enc, v_suc, pg_temp.t6i_combo_items(cb, 2, 2000, A, 800, B, 400));
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_combo_items(cb, 3, 3000, A, 800, B, 400));
  IF NOT COALESCE((j->>'success')::boolean, false) OR (SELECT total FROM public.pedidos WHERE id = p1) <> 3000 THEN
    v_fallas := v_fallas || format('C5: de 2 a 3 combos con el precio sin cambio tenía que andar a $ 3.000 (%s)', left(j::text, 300));
  END IF;

  -- C6 · (f) la rotura: el combo que quedó vale lo de la foto (F2 de la lente)
  A := pg_temp.t6i_prod(v_suc, 'C6 A', 'ZZ t6i combos', 800, 500);
  B := pg_temp.t6i_prod(v_suc, 'C6 B', 'ZZ t6i combos', 400, 500);
  cb := pg_temp.t6i_combo(v_adm, v_suc, A, B, 1000, false);
  p1 := pg_temp.t6i_alta(v_cli, v_enc, v_suc, pg_temp.t6i_combo_items(cb, 2, 2000, A, 800, B, 400));
  PERFORM pg_temp.t6i_estado(p1, 'asignado');
  PERFORM pg_temp.t6i_claims(v_enc, v_suc);
  it := (SELECT id FROM public.pedido_items WHERE pedido_id = p1 AND producto_id = B);
  j := public.registrar_salvedad(p1, it, 1, 'cliente_rechaza', 'ensayo tanda 6 bis', NULL, true, NULL);
  PERFORM pg_temp.t6i_reset();
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'C6 · preparación: la salvedad no anduvo (%)', j;
  END IF;
  IF (SELECT cantidad_combos FROM public.pedido_combos WHERE pedido_id = p1 AND combo_id = cb) <> 1 THEN
    v_fallas := v_fallas || 'C6: la salvedad tenía que dejar 1 combo'::text;
  END IF;
  v_txt := public.combo_fuera_de_regla(pg_temp.t6i_combo_items(cb, 1, 1000, A, 800, B, 400),
                                       v_suc, public._tablero_hoy(), p1, true);
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('C6: después de la rotura, el combo que quedó vale $ 1.000, como en main (%s)', v_txt);
  END IF;
  v_txt := public.combo_fuera_de_regla(pg_temp.t6i_combo_items(cb, 2, 2000, A, 800, B, 400),
                                       v_suc, public._tablero_hoy(), p1, true);
  IF v_txt IS NOT NULL THEN
    v_fallas := v_fallas || format('C6: después de la rotura, volver a 2 combos a la foto anda, como en main (%s)', v_txt);
  END IF;
  PERFORM pg_temp.t6i_estado(p1, 'pendiente');

  -- C7 · (g) el cambio de cliente con el precio cambiado, y un acumulable sin cambios
  A := pg_temp.t6i_prod(v_suc, 'C7 A', 'ZZ t6i combos', 800, 500);
  B := pg_temp.t6i_prod(v_suc, 'C7 B', 'ZZ t6i combos', 400, 500);
  cb := pg_temp.t6i_combo(v_adm, v_suc, A, B, 1000, false);
  p1 := pg_temp.t6i_alta(v_cli, v_enc, v_suc, pg_temp.t6i_combo_items(cb, 2, 2000, A, 800, B, 400));
  UPDATE public.combos SET precio = 1200 WHERE id = cb;
  j := pg_temp.t6i_cambio_cli(v_adm, v_suc, p1, v_cli2);
  IF NOT COALESCE((j->>'success')::boolean, false)
     OR (SELECT f.precio FROM public.pedido_combos f
          WHERE f.pedido_id = (j->>'nuevo_pedido_id')::bigint AND f.combo_id = cb) IS DISTINCT FROM 1000 THEN
    v_fallas := v_fallas || format('C7: el cambio de cliente tenía que andar y heredar la foto a $ 1.000 (%s)', left(j::text, 300));
  END IF;
  A := pg_temp.t6i_prod(v_suc, 'C7 Aa', 'ZZ t6i combos', 800, 500);
  B := pg_temp.t6i_prod(v_suc, 'C7 Ba', 'ZZ t6i combos', 400, 500);
  cb := pg_temp.t6i_combo(v_adm, v_suc, A, B, 1000, true);
  p1 := pg_temp.t6i_alta(v_cli, v_enc, v_suc, pg_temp.t6i_combo_items(cb, 1, 1000, A, 800, B, 400, 800, 400));
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_combo_items(cb, 2, 2000, A, 800, B, 400, 800, 400));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('C7: el acumulable sin cambio de precio tenía que sumar como en main (%s)', left(j::text, 300));
  END IF;

  -- =====================================================================
  -- D · N1 y N2: el regalo del pedido
  -- =====================================================================
  V := pg_temp.t6i_prod(v_suc, 'D V', 'ZZ t6i venta', 100, 500);
  R := pg_temp.t6i_prod(v_suc, 'D R', 'ZZ t6i rubro D', 100, 500);
  S := pg_temp.t6i_prod(v_suc, 'D S', 'ZZ t6i rubro D', 100, 500);
  Pf := pg_temp.t6i_prod(v_suc, 'D P', 'ZZ t6i perfumes', 10000, 500);
  p := pg_temp.t6i_promo(v_suc, V, R, 5, 2, true);
  -- D1 · el reparto R×2 + S×2 (lo arma el admin en el alta)
  p1 := pg_temp.t6i_alta(v_cli, v_adm, v_suc,
          pg_temp.t6i_items(V, 10, p, jsonb_build_array(jsonb_build_array(R, 2), jsonb_build_array(S, 2))));
  p2 := pg_temp.t6i_alta(v_cli, v_enc, v_suc, pg_temp.t6i_items(V, 10, p, jsonb_build_array(jsonb_build_array(R, 4))));
  UPDATE public.pedidos SET created_at = now() - interval '1 day' WHERE id IN (p1, p2);
  j := pg_temp.t6i_guardar_promo(v_adm, v_suc, p, Pf);
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'D · preparación: no se pudo cambiar el regalo de la promo (%)', j;
  END IF;
  UPDATE public.audit_logs SET created_at = now() - interval '12 hours'
   WHERE tabla = 'promociones' AND registro_id = p::text AND accion = 'UPDATE';
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_items(V, 15, p, jsonb_build_array(jsonb_build_array(R, 6))));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('D1: el reparto que no cierra vuelve al regalo del pedido (R×6) y tenía que andar (%s)', left(j::text, 300));
  END IF;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_items(V, 20, p, jsonb_build_array(jsonb_build_array(Pf, 8))));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('D1: el regalo de hoy (P×8) tenía que seguir andando (%s)', left(j::text, 300));
  END IF;
  -- D2 · el cambio de cliente conserva la referencia
  j := pg_temp.t6i_cambio_cli(v_adm, v_suc, p2, v_cli2);
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'D2 · preparación: el cambio de cliente no anduvo (%)', j;
  END IF;
  p1 := (j->>'nuevo_pedido_id')::bigint;
  IF (SELECT x.producto_id FROM public._regalo_de_la_promo(p1, p, v_suc, NULL, R, 4) x) IS DISTINCT FROM R THEN
    v_fallas := v_fallas || format('D2: la referencia del pedido rehecho tenía que ser R (la del original) y es %s (R=%s, P=%s)',
      (SELECT x.producto_id FROM public._regalo_de_la_promo(p1, p, v_suc, NULL, R, 4) x), R, Pf);
  END IF;

  -- D3 · F5: el regalo de otro rubro que eligió el admin, repartido, y la venta que sube
  V := pg_temp.t6i_prod(v_suc, 'D3 V', 'ZZ t6i venta', 100, 500);
  R := pg_temp.t6i_prod(v_suc, 'D3 R', 'ZZ t6i rubro D3', 100, 500);
  X := pg_temp.t6i_prod(v_suc, 'D3 X', 'ZZ t6i rubro otro D3', 100, 500);
  S := pg_temp.t6i_prod(v_suc, 'D3 Y', 'ZZ t6i rubro otro D3', 100, 500);
  p := pg_temp.t6i_promo(v_suc, V, R, 5, 2, true);
  p1 := pg_temp.t6i_alta(v_cli, v_adm, v_suc, pg_temp.t6i_items(V, 10, p, jsonb_build_array(jsonb_build_array(X, 4))));
  it := (SELECT id FROM public.pedido_items WHERE pedido_id = p1 AND es_bonificacion);
  PERFORM pg_temp.t6i_claims(v_adm, v_suc);
  j := public.dividir_regalo_pedido(it, jsonb_build_array(jsonb_build_object('producto_id', X, 'cantidad', 2),
                                                         jsonb_build_object('producto_id', S, 'cantidad', 2)), 'ensayo', NULL);
  PERFORM pg_temp.t6i_reset();
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'D3 · preparación: el reparto no anduvo (%)', j;
  END IF;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_items(V, 15, p, jsonb_build_array(jsonb_build_array(X, 6))));
  IF COALESCE((j->>'success')::boolean, false) OR j::text NOT LIKE '%no puede crecer%' THEN
    v_fallas := v_fallas || format('D3: subir lo que entra sólo por F5 (X×6 sobre 4) tenía que rechazarse con «no puede crecer» (G1) (%s)', left(j::text, 300));
  END IF;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_items(V, 5, p, jsonb_build_array(jsonb_build_array(X, 2))));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('D3: bajar la venta y volver al regalo que el pedido ya tenía (X×2) tenía que andar (%s)', left(j::text, 300));
  END IF;

  -- D4 · G1 de la segunda lente: R×3 + X×1 que armó el admin, y la venta que sube
  V := pg_temp.t6i_prod(v_suc, 'D4 V', 'ZZ t6i venta', 100, 500);
  R := pg_temp.t6i_prod(v_suc, 'D4 R', 'ZZ t6i rubro D4', 100, 500);
  X := pg_temp.t6i_prod(v_suc, 'D4 X', 'ZZ t6i rubro caro D4', 5000, 500);
  p := pg_temp.t6i_promo(v_suc, V, R, 5, 2, true);
  p1 := pg_temp.t6i_alta(v_cli, v_adm, v_suc,
          pg_temp.t6i_items(V, 10, p, jsonb_build_array(jsonb_build_array(R, 3), jsonb_build_array(X, 1))));
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_items(V, 20, p, jsonb_build_array(jsonb_build_array(X, 8))));
  IF COALESCE((j->>'success')::boolean, false) OR j::text NOT LIKE '%no puede crecer%' THEN
    v_fallas := v_fallas || format('D4: X×8 ($ 40.000 donde el admin aprobó X×1) tenía que rechazarse con «no puede crecer» (G1) (%s)', left(j::text, 300));
  END IF;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_items(V, 20, p, jsonb_build_array(jsonb_build_array(X, 1))));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('D4: X×1 (X se conserva) tenía que andar (%s)', left(j::text, 300));
  END IF;
  j := pg_temp.t6i_editar(v_enc, v_suc, p1, pg_temp.t6i_items(V, 20, p, jsonb_build_array(jsonb_build_array(R, 8))));
  IF NOT COALESCE((j->>'success')::boolean, false) THEN
    v_fallas := v_fallas || format('D4: R×8 (sin X) tenía que andar (%s)', left(j::text, 300));
  END IF;

  IF array_length(v_fallas, 1) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (%)\n%', array_length(v_fallas, 1), array_to_string(v_fallas, E'\n');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · tanda 6 bis, tarjeta I: promos-B1 (alta y edición, también el admin), promos-B4, promos-B5 (el combo que cambió de precio no crece), N1, N2, F5 y G1';
END
$ensayo$;
