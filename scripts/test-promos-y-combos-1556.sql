-- Ensayo de la tarjeta 5 de #1565: PRM-A, PRM-B, PRM-C y PRM-D de #1556
-- (migrations/500_promos_y_combos_1556.sql).
--
--   A1-A5 · PRM-A: el encargado que reparte el regalo a un producto de otra
--           categoría recibe el mismo rechazo que en la sustitución, y nada se
--           mueve. El encargado sí reparte en la misma categoría, y el admin a
--           otra.
--   B0-B4 · PRM-B: promo de fracción que pasa a unidad entera y vuelve a
--           fracción con un pedido del primer tramo abierto. Cancelarlo (o
--           editarlo sin el regalo) no le resta a la barra reiniciada: el
--           contenedor queda en 100, sin merma. Un pedido del tramo nuevo sí
--           entra en la barra y sale al cancelarlo.
--   C0-C3 · PRM-C: combo con tope 2. Una salvedad cliente_rechaza rompe uno,
--           otro pedido toma el lugar, y anular la salvedad se rechaza con
--           «llegó a su tope»: quedan 2 combos vivos. Sin el otro pedido, la
--           anulación rearma el combo.
--   D1-D4 · PRM-D: límite 14, R×10 -> W×1 por valor. P1 editado a 14 cuenta 14 y
--           no deja entrar otro con 4; editado a 5, cuenta 5.
--   D5-D9 · el corte de cada parte de un reparto, la sustitución que no lo
--           mueve, la salvedad que lo baja y el cambio de cliente que lo lleva.
--   D10-D11 · un corte escrito a mano sin la marca se vuelve a calcular; una
--           línea de venta no tiene corte.
--   E1    · las columnas nuevas y la función del trigger son de server.
--
-- Arma sus propios usuarios, clientes, productos y promos en la primera
-- sucursal activa; los triggers diferidos del cupo se fuerzan con SET
-- CONSTRAINTS (pg_temp.e5_check_cupo). Todo se deshace: el veredicto es el
-- RAISE final, 'ENSAYO OK …' o 'ENSAYO FALLÓ (n)' con la lista. Se corre en
-- una base local armada con scripts/concurrencia/docker-local.mjs, después de
-- aplicar la migración, nunca contra prod (escribe en auth.users):
--
--   tr -d '\r' < scripts/test-promos-y-combos-1556.sql | docker exec -i <contenedor> psql -U postgres -d postgres -q
--
-- Sin la migración falla en A2-A5, B1-B4, C2 y en todo D y E.

SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION pg_temp.e5_t_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.e5_u(p_rol text, p_suc bigint)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE
  v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e1556-' || v || '@ensayo.invalid',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'e1556 ' || p_rol), now(), now());
  RETURN v;
END
$f$;

CREATE OR REPLACE FUNCTION pg_temp.e5_claims(p_user uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$f$;

-- Corre p_sql como el front: rol authenticated, con el JWT de p_user. Devuelve el texto.
CREATE OR REPLACE FUNCTION pg_temp.e5_como(p_user uuid, p_suc bigint, p_sql text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v text;
BEGIN
  PERFORM pg_temp.e5_claims(p_user, p_suc);
  SET LOCAL ROLE authenticated;
  EXECUTE p_sql INTO v;
  RESET ROLE;
  PERFORM pg_temp.e5_t_reset();
  RETURN v;
END
$f$;

-- 'OK: <resultado>' o 'ERR <sqlstate>: <mensaje>'
CREATE OR REPLACE FUNCTION pg_temp.e5_prueba(p_user uuid, p_suc bigint, p_sql text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v text;
BEGIN
  BEGIN
    v := pg_temp.e5_como(p_user, p_suc, p_sql);
    RETURN 'OK: ' || COALESCE(v, 'null');
  EXCEPTION WHEN OTHERS THEN
    RESET ROLE;
    RETURN 'ERR ' || SQLSTATE || ': ' || SQLERRM;
  END;
END
$f$;

-- Dispara el trigger diferido del cupo. NULL si paso; el mensaje si lo rechazo.
CREATE OR REPLACE FUNCTION pg_temp.e5_check_cupo()
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  SET CONSTRAINTS public.trg_limite_usos_promo IMMEDIATE;
  SET CONSTRAINTS public.trg_limite_usos_promo DEFERRED;
  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  RETURN SQLERRM;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.e5_cli(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1556', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.e5_prod(p_suc bigint, p_nombre text, p_cat text DEFAULT 'ZZ ensayo 1556 cat', p_precio numeric DEFAULT 100,
                                        p_stock int DEFAULT 100)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1556 ' || p_nombre, p_precio, p_stock, 10, p_suc, p_cat)
  RETURNING id;
$fn$;

-- Promo "p_compra de p_venta dan p_bonif de p_regalo".
CREATE OR REPLACE FUNCTION pg_temp.e5_promo(p_suc bigint, p_venta bigint, p_regalo bigint, p_compra int, p_bonif int,
                                         p_mueve boolean, p_limite int DEFAULT NULL,
                                         p_auto boolean DEFAULT false, p_contenedor bigint DEFAULT NULL,
                                         p_upb int DEFAULT NULL, p_spb int DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, limite_usos, ajuste_automatico, ajuste_producto_id,
                                  unidades_por_bloque, stock_por_bloque)
  VALUES ('ZZ ensayo 1556 promo', 'bonificacion', public._tablero_hoy() - 1, p_suc, p_mueve, p_regalo, p_limite,
          p_auto, p_contenedor, p_upb, p_spb)
  RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', p_compra, p_suc), (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, p_venta, p_suc);
  RETURN v_promo;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.e5_items(p_venta bigint, p_cv int, p_regalo bigint, p_cr int, p_promo bigint, p_precio numeric DEFAULT 100)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_venta, 'cantidad', p_cv, 'precio_unitario', p_precio))
         || CASE WHEN p_cr > 0 THEN jsonb_build_array(
              jsonb_build_object('producto_id', p_regalo, 'cantidad', p_cr, 'precio_unitario', 0,
                                 'es_bonificacion', true, 'promocion_id', p_promo)) ELSE '[]'::jsonb END;
$fn$;

-- Alta como p_user (claims puestos por el caller o aca).
CREATE OR REPLACE FUNCTION pg_temp.e5_alta(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_tot numeric;
BEGIN
  PERFORM pg_temp.e5_claims(p_user, p_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
    FROM jsonb_array_elements(p_items) e;
  v_res := public.crear_pedido_completo(p_cli, v_tot, p_user, p_items, 'ensayo 1556');
  PERFORM pg_temp.e5_t_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.e5_alta_ok(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb := pg_temp.e5_alta(p_cli, p_user, p_suc, p_items);
BEGIN
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'alta fallo: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.e5_editar(p_ped bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.e5_claims(p_user, p_suc);
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.e5_t_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.e5_regalos(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(string_agg(format('%s:%s×%s', pi.id, pr.nombre, pi.cantidad), ', ' ORDER BY pi.id), '-')
    FROM public.pedido_items pi JOIN public.productos pr ON pr.id = pi.producto_id
   WHERE pi.pedido_id = p_ped AND pi.es_bonificacion;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.e5_lineas(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(string_agg(format('%s%s×%s@%s%s', CASE WHEN pi.es_bonificacion THEN 'R:' ELSE '' END,
                                    replace(pr.nombre, 'ZZ ensayo 1556 ', ''), pi.cantidad, pi.precio_unitario,
                                    CASE WHEN pi.combo_id IS NOT NULL THEN '[c' || pi.combo_id || ']'
                                         WHEN pi.combo_roto_id IS NOT NULL THEN '[roto' || pi.combo_roto_id || ']' ELSE '' END),
                             ', ' ORDER BY pi.id), '-')
    FROM public.pedido_items pi JOIN public.productos pr ON pr.id = pi.producto_id
   WHERE pi.pedido_id = p_ped;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.e5_stock(p_ids bigint[])
RETURNS text LANGUAGE sql AS $fn$
  SELECT string_agg(format('%s=%s', replace(nombre, 'ZZ ensayo 1556 ', ''), stock), ' ' ORDER BY array_position(p_ids, id))
    FROM public.productos WHERE id = ANY(p_ids);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.e5_barra(p_promo bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('up=%s acc=[%s] usos=%s activo=%s', p.usos_pendientes,
                COALESCE((SELECT string_agg(a.producto_regalo_id || ':' || a.usos_pendientes, ',' ORDER BY a.producto_regalo_id)
                            FROM public.promo_acumuladores a WHERE a.promocion_id = p.id), ''),
                (SELECT u.usos FROM public._promo_usos(p.id) u), p.activo)
    FROM public.promociones p WHERE p.id = p_promo;
$fn$;

DO $ensayo$
DECLARE
  v_suc bigint := (SELECT min(id) FROM public.sucursales WHERE activa);
  v_adm uuid; v_enc uuid; v_pre uuid;
  c1 bigint; c2 bigint;
  V bigint; R bigint; S bigint; T bigint; W bigint; C bigint; A bigint; B bigint;
  p bigint; ped bigint; ped2 bigint; ped3 bigint; v_it bigint; v_sal bigint; v_combo bigint;
  j jsonb; e text; res text; v_msg text; v_n numeric; pr jsonb;
  v_f text[] := '{}';
  v_caso text;
  M constant text := 'Solo un admin puede cambiar el regalo por un producto de otra categoría';
BEGIN
  SET LOCAL lock_timeout = '5s';
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay una sucursal activa';
  END IF;
  v_adm := pg_temp.e5_u('admin', v_suc);
  v_enc := pg_temp.e5_u('encargado', v_suc);
  v_pre := pg_temp.e5_u('preventista', v_suc);
  c1 := pg_temp.e5_cli(v_suc, 'ZZ ensayo 1556 C1');
  c2 := pg_temp.e5_cli(v_suc, 'ZZ ensayo 1556 C2');

  -- =====================================================================
  -- A · PRM-A: el encargado no reparte a otra categoría; el admin sí
  -- =====================================================================
  BEGIN
    V := pg_temp.e5_prod(v_suc, 'A V', 'ZZ ensayo 1556 gaseosas');
    R := pg_temp.e5_prod(v_suc, 'A R', 'ZZ ensayo 1556 gaseosas');
    S := pg_temp.e5_prod(v_suc, 'A S', 'ZZ ensayo 1556 gaseosas');
    W := pg_temp.e5_prod(v_suc, 'A W', 'ZZ ensayo 1556 blancas', 25000);
    p := pg_temp.e5_promo(v_suc, V, R, 10, 4, true);
    ped := pg_temp.e5_alta_ok(c1, v_adm, v_suc, pg_temp.e5_items(V, 10, R, 4, p));
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped AND es_bonificacion);

    res := pg_temp.e5_prueba(v_enc, v_suc, format('SELECT public.sustituir_regalo_pedido(%s, %s, 4, %L)::text', v_it, W, 'ensayo 1556'));
    IF (substr(res, 5)::jsonb)->>'error' IS DISTINCT FROM M THEN
      v_f := v_f || ('A1 sustituir del encargado a otra categoría: ' || res);
    END IF;
    res := pg_temp.e5_prueba(v_enc, v_suc, format('SELECT public.dividir_regalo_pedido(%s, %L::jsonb, %L)::text', v_it,
             jsonb_build_array(jsonb_build_object('producto_id', W, 'cantidad', 3), jsonb_build_object('producto_id', R, 'cantidad', 1)),
             'ensayo 1556'));
    IF res NOT LIKE 'OK: %' OR (substr(res, 5)::jsonb)->>'error' IS DISTINCT FROM M THEN
      v_f := v_f || ('A2 dividir del encargado a otra categoría no da el rechazo de sustituir: ' || res);
    END IF;
    IF pg_temp.e5_lineas(ped) <> 'A V×10@100.00, R:A R×4@0.00'
       OR (SELECT stock FROM productos WHERE id = W) <> 100 THEN
      v_f := v_f || ('A3 el reparto rechazado movió algo: ' || pg_temp.e5_lineas(ped) || ' | ' || pg_temp.e5_stock(ARRAY[R, W]));
    END IF;
    -- control: el encargado reparte en la misma categoría, y el admin a otra
    res := pg_temp.e5_prueba(v_enc, v_suc, format('SELECT public.dividir_regalo_pedido(%s, %L::jsonb, %L)::text', v_it,
             jsonb_build_array(jsonb_build_object('producto_id', S, 'cantidad', 3), jsonb_build_object('producto_id', R, 'cantidad', 1)),
             'ensayo 1556'));
    IF res NOT LIKE 'OK: %' OR NOT COALESCE(((substr(res, 5)::jsonb)->>'success')::boolean, false) THEN
      v_f := v_f || ('A4 el encargado no pudo repartir en la misma categoría: ' || res);
    END IF;
    ped2 := pg_temp.e5_alta_ok(c1, v_adm, v_suc, pg_temp.e5_items(V, 10, R, 4, p));
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped2 AND es_bonificacion);
    res := pg_temp.e5_prueba(v_adm, v_suc, format('SELECT public.dividir_regalo_pedido(%s, %L::jsonb, %L)::text', v_it,
             jsonb_build_array(jsonb_build_object('producto_id', W, 'cantidad', 3), jsonb_build_object('producto_id', R, 'cantidad', 1)),
             'ensayo 1556'));
    IF res NOT LIKE 'OK: %' OR NOT COALESCE(((substr(res, 5)::jsonb)->>'success')::boolean, false)
       OR (SELECT stock FROM productos WHERE id = W) <> 97 THEN
      v_f := v_f || ('A5 el admin no pudo repartir a otra categoría: ' || res);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_f := v_f || ('A · error: ' || SQLERRM);
  END;

  -- =====================================================================
  -- B · PRM-B: fracción -> unidad entera -> fracción con un pedido del primer tramo
  -- =====================================================================
  FOREACH v_caso IN ARRAY ARRAY['cancelar', 'editar'] LOOP
    BEGIN
      V := pg_temp.e5_prod(v_suc, 'B V');
      R := pg_temp.e5_prod(v_suc, 'B R');
      C := pg_temp.e5_prod(v_suc, 'B Cont', 'ZZ ensayo 1556 otra', 600);
      p := pg_temp.e5_promo(v_suc, V, R, 10, 4, false, NULL, true, C, 6, 1);
      ped := pg_temp.e5_alta_ok(c1, v_adm, v_suc, pg_temp.e5_items(V, 10, R, 4, p));
      IF NOT public._regalo_barra_vale(ped, p, v_suc) OR (SELECT usos_pendientes FROM promociones WHERE id = p) <> 4 THEN
        v_f := v_f || format('B0 [%s] el alta de fracción no entró en la barra: %s', v_caso, pg_temp.e5_barra(p));
      END IF;
      PERFORM pg_temp.e5_claims(v_adm, v_suc);
      j := public.cambiar_regalo_promocion(p, R, NULL, false, '{"regalo_mueve_stock": true}'::jsonb);
      j := public.cambiar_regalo_promocion(p, R, C, true, '{"regalo_mueve_stock": false}'::jsonb);
      PERFORM pg_temp.e5_t_reset();
      IF public._regalo_barra_vale(ped, p, v_suc) THEN
        v_f := v_f || format('B1 [%s] el pedido del tramo anterior vale para la barra reiniciada', v_caso);
      END IF;
      IF v_caso = 'cancelar' THEN
        PERFORM pg_temp.e5_claims(v_adm, v_suc);
        j := public.cancelar_pedido_con_stock(ped, 'ensayo 1556', v_adm, NULL);
        PERFORM pg_temp.e5_t_reset();
      ELSE
        j := pg_temp.e5_editar(ped, v_adm, v_suc, pg_temp.e5_items(V, 5, R, 0, p));
      END IF;
      IF NOT COALESCE((j->>'success')::boolean, false)
         OR (SELECT stock FROM productos WHERE id = C) <> 100
         OR (SELECT usos_pendientes FROM promociones WHERE id = p) <> 0
         OR EXISTS (SELECT 1 FROM mermas_stock WHERE producto_id = C) THEN
        v_f := v_f || format('B2 [%s] la barra reiniciada se movió: %s | %s | %s', v_caso, j, pg_temp.e5_stock(ARRAY[C]), pg_temp.e5_barra(p));
      END IF;
      -- control: un pedido del tramo nuevo sí entra y sí sale
      ped3 := pg_temp.e5_alta_ok(c1, v_adm, v_suc, pg_temp.e5_items(V, 10, R, 4, p));
      IF NOT public._regalo_barra_vale(ped3, p, v_suc) OR (SELECT usos_pendientes FROM promociones WHERE id = p) <> 4 THEN
        v_f := v_f || format('B3 [%s] el pedido del tramo nuevo no entró en la barra: %s', v_caso, pg_temp.e5_barra(p));
      END IF;
      PERFORM pg_temp.e5_claims(v_adm, v_suc);
      j := public.cancelar_pedido_con_stock(ped3, 'ensayo 1556', v_adm, NULL);
      PERFORM pg_temp.e5_t_reset();
      IF (SELECT usos_pendientes FROM promociones WHERE id = p) <> 0 OR (SELECT stock FROM productos WHERE id = C) <> 100 THEN
        v_f := v_f || format('B4 [%s] cancelar el pedido del tramo nuevo no devolvió su barra: %s | %s', v_caso, pg_temp.e5_barra(p), pg_temp.e5_stock(ARRAY[C]));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_f := v_f || format('B [%s] · error: %s', v_caso, SQLERRM);
    END;
  END LOOP;

  -- =====================================================================
  -- C · PRM-C: anular una salvedad no rearma un combo por encima de su tope
  -- =====================================================================
  FOREACH v_caso IN ARRAY ARRAY['otro pedido tomó el lugar', 'nadie lo tomó'] LOOP
    BEGIN
      A := pg_temp.e5_prod(v_suc, 'C A', 'ZZ ensayo 1556 cat', 100);
      B := pg_temp.e5_prod(v_suc, 'C B', 'ZZ ensayo 1556 cat', 120);
      PERFORM pg_temp.e5_claims(v_adm, v_suc);
      j := public.guardar_combo(jsonb_build_object(
        'nombre', 'ZZ ensayo 1556 combo ' || v_caso, 'precio', 250, 'fecha_inicio', public._tablero_hoy() - 1, 'tope_combos', 2,
        'componentes', jsonb_build_array(
          jsonb_build_object('cantidad', 2, 'productos', jsonb_build_array(A)),
          jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array(B)))));
      PERFORM pg_temp.e5_t_reset();
      v_combo := (j->>'id')::bigint;
      pr := public._combo_prorrateo(250, jsonb_build_array(jsonb_build_object('producto_id', A, 'cantidad', 2, 'ref', 100),
                                                            jsonb_build_object('producto_id', B, 'cantidad', 1, 'ref', 120)));
      ped := pg_temp.e5_alta_ok(c1, v_adm, v_suc, jsonb_build_array(
        jsonb_build_object('producto_id', A, 'cantidad', 4, 'precio_unitario', (pr->>A::text)::numeric, 'precio_sin_combo_unitario', 100, 'combo_id', v_combo),
        jsonb_build_object('producto_id', B, 'cantidad', 2, 'precio_unitario', (pr->>B::text)::numeric, 'precio_sin_combo_unitario', 120, 'combo_id', v_combo)));
      PERFORM pg_temp.e5_claims(v_adm, v_suc);
      v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped AND producto_id = A);
      j := public.registrar_salvedad(ped, v_it, 1, 'cliente_rechaza', 'ensayo 1556 combo', NULL, true, NULL);
      PERFORM pg_temp.e5_t_reset();
      v_sal := (j->>'salvedad_id')::bigint;
      IF (SELECT cantidad_combos FROM pedido_combos WHERE pedido_id = ped) <> 1 THEN
        v_f := v_f || format('C0 [%s] la salvedad no rompió el combo: %s', v_caso, j);
      END IF;
      IF v_caso = 'otro pedido tomó el lugar' THEN
        j := pg_temp.e5_alta(c2, v_pre, v_suc, jsonb_build_array(
          jsonb_build_object('producto_id', A, 'cantidad', 2, 'precio_unitario', (pr->>A::text)::numeric, 'precio_sin_combo_unitario', 100, 'combo_id', v_combo),
          jsonb_build_object('producto_id', B, 'cantidad', 1, 'precio_unitario', (pr->>B::text)::numeric, 'precio_sin_combo_unitario', 120, 'combo_id', v_combo)));
        IF NOT COALESCE((j->>'success')::boolean, false) THEN
          v_f := v_f || format('C1 el otro pedido no pudo tomar el lugar libre: %s', j);
        END IF;
      END IF;
      v_msg := NULL;
      BEGIN
        PERFORM pg_temp.e5_claims(v_adm, v_suc);
        j := public.anular_salvedad(v_sal, 'ensayo 1556');
        PERFORM pg_temp.e5_t_reset();
      EXCEPTION WHEN OTHERS THEN
        v_msg := SQLERRM;
        PERFORM pg_temp.e5_t_reset();
      END;
      v_n := (SELECT sum(f.cantidad_combos) FROM pedido_combos f JOIN pedidos x ON x.id = f.pedido_id
               WHERE f.combo_id = v_combo AND x.estado <> 'cancelado');
      IF v_caso = 'otro pedido tomó el lugar' THEN
        IF v_msg IS NULL OR v_msg NOT LIKE '%llegó a su tope%' OR v_n <> 2
           OR (SELECT cantidad_combos FROM pedido_combos WHERE pedido_id = ped) <> 1 THEN
          v_f := v_f || format('C2 la anulación rearmó por encima del tope o no dio su motivo: %s | %s | vivos %s con tope 2',
                               COALESCE(v_msg, j::text), pg_temp.e5_lineas(ped), v_n);
        END IF;
      ELSE
        IF v_msg IS NOT NULL OR NOT COALESCE((j->>'success')::boolean, false) OR v_n <> 2
           OR (SELECT cantidad_combos FROM pedido_combos WHERE pedido_id = ped) <> 2 THEN
          v_f := v_f || format('C3 con el lugar libre la anulación no rearmó el combo: %s | %s | vivos %s',
                               COALESCE(v_msg, j::text), pg_temp.e5_lineas(ped), v_n);
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_f := v_f || format('C [%s] · error: %s', v_caso, SQLERRM);
    END;
  END LOOP;

  -- =====================================================================
  -- D · PRM-D: el corte se guarda en la línea
  -- =====================================================================
  -- D1: R×10 -> W×1 por valor, límite 14. P1 editado a 14 cuenta 14 y traba a otro; a 5, cuenta 5.
  BEGIN
    V := pg_temp.e5_prod(v_suc, 'D V');
    R := pg_temp.e5_prod(v_suc, 'D R', 'ZZ ensayo 1556 cat', 100);
    W := pg_temp.e5_prod(v_suc, 'D W', 'ZZ ensayo 1556 cat', 1000);
    p := pg_temp.e5_promo(v_suc, V, R, 1, 1, true, 14);
    ped := pg_temp.e5_alta_ok(c1, v_adm, v_suc, pg_temp.e5_items(V, 10, R, 10, p));
    e := pg_temp.e5_check_cupo();
    PERFORM pg_temp.e5_claims(v_adm, v_suc);
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped AND es_bonificacion);
    j := public.sustituir_regalo_pedido(v_it, W, 1, 'ensayo 1556: R x10 vale un W', NULL, NULL);
    PERFORM pg_temp.e5_t_reset();
    e := pg_temp.e5_check_cupo();
    IF NOT COALESCE((j->>'success')::boolean, false)
       OR (SELECT regalo_corte FROM pedido_items WHERE id = v_it) <> 10
       OR (SELECT u.del_pedido FROM public._promo_usos(p, ped) u) <> 10 THEN
      v_f := v_f || format('D1 sustituir por valor movió el corte: %s | corte %s', j,
                           (SELECT regalo_corte FROM pedido_items WHERE id = v_it));
    END IF;
    j := pg_temp.e5_editar(ped, v_adm, v_suc, pg_temp.e5_items(V, 14, R, 14, p));
    e := pg_temp.e5_check_cupo();
    IF NOT COALESCE((j->>'success')::boolean, false) OR e IS NOT NULL
       OR pg_temp.e5_lineas(ped) <> 'D V×14@100.00, R:D W×1@0.00'
       OR (SELECT u.del_pedido FROM public._promo_usos(p, ped) u) <> 14 THEN
      v_f := v_f || format('D2 P1 editado a 14 no cuenta 14: %s | %s | %s | cupo %s', j, pg_temp.e5_lineas(ped),
                           (SELECT u.del_pedido FROM public._promo_usos(p, ped) u), e);
    END IF;
    j := pg_temp.e5_alta(c2, v_pre, v_suc, pg_temp.e5_items(V, 4, R, 4, p));
    e := pg_temp.e5_check_cupo();
    IF COALESCE((j->>'success')::boolean, false) AND e IS NULL THEN
      v_f := v_f || format('D3 entró otro pedido con 4 cortes sobre los 14 de P1 (límite 14): %s', pg_temp.e5_barra(p));
    END IF;
    j := pg_temp.e5_editar(ped, v_adm, v_suc, pg_temp.e5_items(V, 5, R, 5, p));
    e := pg_temp.e5_check_cupo();
    IF NOT COALESCE((j->>'success')::boolean, false)
       OR (SELECT u.del_pedido FROM public._promo_usos(p, ped) u) <> 5 THEN
      v_f := v_f || format('D4 P1 editado a 5 no cuenta 5: %s | %s | %s', j, pg_temp.e5_lineas(ped),
                           (SELECT u.del_pedido FROM public._promo_usos(p, ped) u));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_f := v_f || ('D1-D4 · error: ' || SQLERRM);
  END;

  -- D5: reparto, sustitución de una parte, salvedad sobre el regalo y cambio de cliente.
  BEGIN
    V := pg_temp.e5_prod(v_suc, 'E V');
    R := pg_temp.e5_prod(v_suc, 'E R');
    S := pg_temp.e5_prod(v_suc, 'E S');
    T := pg_temp.e5_prod(v_suc, 'E T');
    p := pg_temp.e5_promo(v_suc, V, R, 10, 4, true);
    ped := pg_temp.e5_alta_ok(c1, v_adm, v_suc, pg_temp.e5_items(V, 10, R, 4, p));
    PERFORM pg_temp.e5_claims(v_adm, v_suc);
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped AND es_bonificacion);
    j := public.dividir_regalo_pedido(v_it, jsonb_build_array(jsonb_build_object('producto_id', R, 'cantidad', 1),
                                                               jsonb_build_object('producto_id', S, 'cantidad', 3)), 'ensayo 1556');
    PERFORM pg_temp.e5_t_reset();
    IF NOT COALESCE((j->>'success')::boolean, false)
       OR (SELECT string_agg(producto_id || ':' || regalo_corte, ',' ORDER BY producto_id) FROM pedido_items
            WHERE pedido_id = ped AND es_bonificacion) <> format('%s:1,%s:3', R, S) THEN
      v_f := v_f || format('D5 las partes del reparto no tienen su corte: %s | %s', j,
        (SELECT string_agg(producto_id || ':' || cantidad || '/' || regalo_corte, ',') FROM pedido_items WHERE pedido_id = ped AND es_bonificacion));
    END IF;
    PERFORM pg_temp.e5_claims(v_adm, v_suc);
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped AND es_bonificacion AND producto_id = S);
    j := public.sustituir_regalo_pedido(v_it, T, 5, 'ensayo 1556', NULL, NULL);
    PERFORM pg_temp.e5_t_reset();
    IF NOT COALESCE((j->>'success')::boolean, false)
       OR (SELECT regalo_corte FROM pedido_items WHERE id = v_it) <> 3
       OR (SELECT u.del_pedido FROM public._promo_usos(p, ped) u) <> 4 THEN
      v_f := v_f || format('D6 sustituir la parte S×3 por T×5 movió el corte: %s | corte %s', j,
                           (SELECT regalo_corte FROM pedido_items WHERE id = v_it));
    END IF;
    -- la salvedad sobre la parte R×1 la saca entera
    PERFORM pg_temp.e5_claims(v_adm, v_suc);
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped AND es_bonificacion AND producto_id = R);
    j := public.registrar_salvedad(ped, v_it, 1, 'cliente_rechaza', 'ensayo 1556', NULL, true, NULL);
    PERFORM pg_temp.e5_t_reset();
    IF NOT COALESCE((j->>'success')::boolean, false)
       OR (SELECT u.del_pedido FROM public._promo_usos(p, ped) u) <> 3 THEN
      v_f := v_f || format('D7 la salvedad de la parte R×1 no liberó su corte: %s | usos %s', j,
                           (SELECT u.del_pedido FROM public._promo_usos(p, ped) u));
    END IF;
    -- otro pedido, sin reparto: la salvedad de 1 sobre R×4 deja el corte en 3
    ped2 := pg_temp.e5_alta_ok(c1, v_adm, v_suc, pg_temp.e5_items(V, 10, R, 4, p));
    PERFORM pg_temp.e5_claims(v_adm, v_suc);
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped2 AND es_bonificacion);
    j := public.registrar_salvedad(ped2, v_it, 1, 'cliente_rechaza', 'ensayo 1556', NULL, true, NULL);
    PERFORM pg_temp.e5_t_reset();
    IF NOT COALESCE((j->>'success')::boolean, false)
       OR (SELECT regalo_corte FROM pedido_items WHERE id = v_it) <> 3 THEN
      v_f := v_f || format('D8 la salvedad de 1 sobre R×4 no dejó el corte en 3: %s | corte %s', j,
                           (SELECT regalo_corte FROM pedido_items WHERE id = v_it));
    END IF;
    -- cambio de cliente de un pedido con R×10 -> W×1: el pedido nuevo cuenta 10
    W := pg_temp.e5_prod(v_suc, 'E W', 'ZZ ensayo 1556 cat', 1000);
    A := pg_temp.e5_prod(v_suc, 'E V2');
    p := pg_temp.e5_promo(v_suc, A, R, 1, 1, true);
    ped3 := pg_temp.e5_alta_ok(c1, v_adm, v_suc, pg_temp.e5_items(A, 10, R, 10, p));
    PERFORM pg_temp.e5_claims(v_adm, v_suc);
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped3 AND es_bonificacion);
    j := public.sustituir_regalo_pedido(v_it, W, 1, 'ensayo 1556', NULL, NULL);
    j := public.cambiar_cliente_pedido(ped3, c2, v_adm,
           (SELECT jsonb_agg(jsonb_build_object('producto_id', producto_id, 'cantidad', cantidad, 'precio_unitario', precio_unitario,
                                                'es_bonificacion', es_bonificacion, 'promocion_id', promocion_id) ORDER BY id)
              FROM pedido_items WHERE pedido_id = ped3),
           (SELECT sum(subtotal) FROM pedido_items WHERE pedido_id = ped3));
    PERFORM pg_temp.e5_t_reset();
    ped := COALESCE((j->>'nuevo_pedido_id')::bigint, (j->>'pedido_nuevo_id')::bigint);
    IF NOT COALESCE((j->>'success')::boolean, false)
       OR (SELECT string_agg(producto_id || ':' || cantidad || '/' || regalo_corte, ',') FROM pedido_items
            WHERE pedido_id = ped AND es_bonificacion) <> format('%s:1/10', W)
       OR (SELECT u.del_pedido FROM public._promo_usos(p, ped) u) <> 10
       OR (SELECT u.del_pedido FROM public._promo_usos(p, ped3) u) <> 0 THEN
      v_f := v_f || format('D9 el cambio de cliente no se llevó el corte: %s | %s', j,
        (SELECT string_agg(producto_id || ':' || cantidad || '/' || regalo_corte, ',') FROM pedido_items WHERE pedido_id = ped AND es_bonificacion));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_f := v_f || ('D5-D9 · error: ' || SQLERRM);
  END;

  -- D10: el corte escrito a mano sin la marca se vuelve a calcular; una venta no tiene corte.
  BEGIN
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped2 AND es_bonificacion);
    UPDATE pedido_items SET regalo_corte = 99 WHERE id = v_it;
    IF (SELECT regalo_corte FROM pedido_items WHERE id = v_it) <> 3 THEN
      v_f := v_f || 'D10 un corte escrito a mano quedó';
    END IF;
    IF EXISTS (SELECT 1 FROM pedido_items WHERE pedido_id = ped2 AND NOT es_bonificacion AND regalo_corte IS NOT NULL) THEN
      v_f := v_f || 'D11 una línea de venta tiene corte';
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_f := v_f || ('D10 · error: ' || SQLERRM);
  END;

  -- E · permisos: las columnas nuevas y la función del trigger son de server.
  BEGIN
  IF has_column_privilege('authenticated', 'public.pedido_items', 'regalo_corte', 'SELECT')
     OR has_column_privilege('anon', 'public.pedido_items', 'regalo_corte', 'SELECT')
     OR has_column_privilege('authenticated', 'public.pedido_promo_reglas', 'barra_anterior', 'SELECT')
     OR has_function_privilege('authenticated', 'public.sellar_corte_regalo_item()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.sellar_corte_regalo_item()', 'EXECUTE') THEN
    v_f := v_f || 'E1 las columnas nuevas o la función del trigger quedaron al alcance de la app';
  END IF;
  EXCEPTION WHEN OTHERS THEN
    v_f := v_f || ('E1 · error: ' || SQLERRM);
  END;

  IF array_length(v_f, 1) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (%):\n%', array_length(v_f, 1), array_to_string(v_f, E'\n');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · PRM-A, PRM-B, PRM-C y PRM-D de #1556 (A1-A5, B0-B4 x2, C0-C3, D1-D11, E1)';
END
$ensayo$;
