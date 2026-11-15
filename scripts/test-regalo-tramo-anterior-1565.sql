-- Ensayo de LV-1 (cierre de la tanda #1565): a un regalo de fracción que no
-- entra en la barra viva no se le suma
-- (migrations/502_regalo_de_tramo_anterior_no_suma.sql).
--
-- Cada caso arma su promo de fracción "10 V dan 4 R" con contenedor Cont
-- (6 R = 1 Cont) y carga un pedido V×10 + R×4 (la barra queda en 4). Después:
--   L · tramo anterior: pasa la promo a unidad entera y la vuelve a fracción.
--       La barra se reinicia (up=0) y la foto queda marcada (barra_anterior,
--       PRM-B de la 500).
--   O · otro modo (#1324): pasa la promo a unidad entera y la deja así. La foto
--       sigue de fracción y la promo de hoy no tiene barra (up=4 queda como
--       contador).
-- Desde ahí, en L y en O:
--   1 · editarlo subiendo el regalo (V×20 + R×8) se rechaza con
--       codigo = 'regalo_de_tramo_anterior' y no cambia nada. En L, también con
--       el encargado (L1e).
--   2 · sacarle el regalo anda y no toca la barra ni el contenedor. Volver a
--       ponérselo en otra edición: en L se rechaza; en O anda y mueve stock por
--       línea (R=96), porque la foto sin regalo vivo arranca con el modo de hoy
--       (#1324): no sale gratis.
--   3 · bajarlo (R×2) anda igual que hoy; volver a subirlo a R×4 se rechaza.
--   4 · editar otra línea sin tocar el regalo (V×12 + R×4) anda.
--   5 · cancelarlo y 6 · eliminarlo andan: contenedor 100, sin merma.
--   7 · sustituir el regalo por otro producto o por más cantidad se rechaza;
--       con el mismo producto y menos cantidad, anda.
--   8 · repartirlo se rechaza.
-- Y además:
--   L9 · una salvedad sobre el regalo anda (baja), y anularla se rechaza
--        (anular_salvedad no repone regalos de promo): no hay camino que sume.
--   L10 · una salvedad sobre la venta le saca el regalo, y anularla también se
--        rechaza.
--   L11 · el cambio de cliente exige el regalo tal cual (con R×8 se rechaza) y
--        el pedido nuevo nace con su foto, sin la marca: entra en la barra viva.
--   O9 · el cambio de cliente del pedido de otro modo se rechaza (480, PRM-1).
--   T  · testigo: un pedido cargado después del reinicio entra en la barra, y
--        editarlo a V×20 + R×8 suma a la barra y consume un contenedor.
--   F  · un pedido de fracción con la promo todavía en fracción y sin marca:
--        lo mismo.
--   I  · el caso inverso: foto de unidad entera con la promo hoy en fracción.
--        Se le suma (V×20 + R×8) y mueve stock por línea (R=92).
--
-- Arma sus propios usuarios, clientes, productos y promos en la primera
-- sucursal activa. Todo se deshace: el veredicto es el RAISE final,
-- 'ENSAYO OK …' o 'ENSAYO FALLÓ (n)' con la lista. Se corre en una base local
-- armada con scripts/concurrencia/docker-local.mjs, nunca contra prod (escribe
-- en auth.users):
--
--   tr -d '\r' < scripts/test-regalo-tramo-anterior-1565.sql | docker exec -i <contenedor> psql -U postgres -d postgres -q
--
-- Sin la migración falla en L1, L1e, L2, L3, L7, L8, O1, O3, O7 y O8.

SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION pg_temp.l1_t_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.l1_u(p_rol text, p_suc bigint)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE
  v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e1565-' || v || '@ensayo.invalid',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'e1565 ' || p_rol), now(), now());
  RETURN v;
END
$f$;

CREATE OR REPLACE FUNCTION pg_temp.l1_claims(p_user uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.l1_cli(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1565', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.l1_prod(p_suc bigint, p_nombre text, p_cat text DEFAULT 'ZZ ensayo 1565 cat',
                                         p_precio numeric DEFAULT 100, p_stock int DEFAULT 100)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1565 ' || p_nombre, p_precio, p_stock, 10, p_suc, p_cat)
  RETURNING id;
$fn$;

-- Promo de fracción "10 V dan 4 R", contenedor p_cont: 6 R = 1 contenedor.
CREATE OR REPLACE FUNCTION pg_temp.l1_promo(p_suc bigint, p_venta bigint, p_regalo bigint, p_cont bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, ajuste_producto_id,
                                  unidades_por_bloque, stock_por_bloque)
  VALUES ('ZZ ensayo 1565 promo', 'bonificacion', public._tablero_hoy() - 1, p_suc, false, p_regalo,
          true, p_cont, 6, 1)
  RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', 10, p_suc), (v_promo, 'cantidad_bonificacion', 4, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, p_venta, p_suc);
  RETURN v_promo;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.l1_items(p_venta bigint, p_cv int, p_regalo bigint, p_cr int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_venta, 'cantidad', p_cv, 'precio_unitario', 100))
         || CASE WHEN p_cr > 0 THEN jsonb_build_array(
              jsonb_build_object('producto_id', p_regalo, 'cantidad', p_cr, 'precio_unitario', 0,
                                 'es_bonificacion', true, 'promocion_id', p_promo)) ELSE '[]'::jsonb END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.l1_alta_ok(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_tot numeric;
BEGIN
  PERFORM pg_temp.l1_claims(p_user, p_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
    FROM jsonb_array_elements(p_items) e;
  v_res := public.crear_pedido_completo(p_cli, v_tot, p_user, p_items, 'ensayo 1565');
  PERFORM pg_temp.l1_t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'alta fallo: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.l1_editar(p_ped bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.l1_claims(p_user, p_suc);
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.l1_t_reset();
  RETURN v_res;
END
$fn$;

-- Las líneas del pedido, en orden de id: "V×10, R:R×4".
CREATE OR REPLACE FUNCTION pg_temp.l1_lineas(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(string_agg(format('%s%s×%s', CASE WHEN pi.es_bonificacion THEN 'R:' ELSE '' END,
                                    replace(pr.nombre, 'ZZ ensayo 1565 ', ''), pi.cantidad),
                             ', ' ORDER BY pi.id), '-')
    FROM public.pedido_items pi JOIN public.productos pr ON pr.id = pi.producto_id
   WHERE pi.pedido_id = p_ped;
$fn$;

-- Stock de V, R, S y Cont, la barra de la promo y las mermas del contenedor:
-- "V=90 R=100 S=100 Cont=100 | up=0 | mermas=0".
CREATE OR REPLACE FUNCTION pg_temp.l1_estado(p_ids bigint[], p_promo bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT (SELECT string_agg(format('%s=%s', replace(nombre, 'ZZ ensayo 1565 ', ''), stock), ' '
                            ORDER BY array_position(p_ids, id))
            FROM public.productos WHERE id = ANY(p_ids))
         || format(' | up=%s', (SELECT usos_pendientes FROM public.promociones WHERE id = p_promo))
         || format(' | mermas=%s', (SELECT count(*) FROM public.mermas_stock WHERE producto_id = p_ids[4]));
$fn$;

DO $ensayo$
DECLARE
  v_suc bigint := (SELECT min(id) FROM public.sucursales WHERE activa);
  v_adm uuid; v_enc uuid;
  c1 bigint; c2 bigint;
  V bigint; R bigint; S bigint; C bigint; ids bigint[];
  p bigint; ped bigint; ped2 bigint; v_it bigint; v_sal bigint;
  j jsonb; v_items jsonb;
  v_f text[] := '{}';
  v_caso text;
  v_k text;
  v_up text;
  v_razon text;
  v_msg text;
  v_intacto text;
  M constant text := 'regalo_de_tramo_anterior';
BEGIN
  SET LOCAL lock_timeout = '5s';
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay una sucursal activa';
  END IF;
  v_adm := pg_temp.l1_u('admin', v_suc);
  v_enc := pg_temp.l1_u('encargado', v_suc);
  c1 := pg_temp.l1_cli(v_suc, 'ZZ ensayo 1565 C1');
  c2 := pg_temp.l1_cli(v_suc, 'ZZ ensayo 1565 C2');

  FOREACH v_caso IN ARRAY ARRAY['L1', 'L1e', 'L2', 'L3', 'L4', 'L5', 'L6', 'L7', 'L8', 'L9', 'L10', 'L11',
                                'O1', 'O2', 'O3', 'O4', 'O5', 'O6', 'O7', 'O8', 'O9'] LOOP
    BEGIN
      -- L: tramo anterior (entera y de vuelta a fracción). O: otro modo (queda en entera).
      v_k := substr(v_caso, 2);
      v_up := CASE WHEN v_caso LIKE 'L%' THEN '0' ELSE '4' END;
      v_razon := CASE WHEN v_caso LIKE 'L%' THEN 'reinició su barra' ELSE 'cambió de tipo' END;
      v_msg := format('El regalo de este pedido es de fracción y no entra en la barra de la promo «ZZ ensayo 1565 promo», que %s después de cargarlo%%pedido nuevo%%', v_razon);
      v_intacto := format('V×10, R:R×4 # V=90 R=100 S=100 Cont=100 | up=%s | mermas=0', v_up);
      V := pg_temp.l1_prod(v_suc, 'V');
      R := pg_temp.l1_prod(v_suc, 'R');
      S := pg_temp.l1_prod(v_suc, 'S');
      C := pg_temp.l1_prod(v_suc, 'Cont', 'ZZ ensayo 1565 otra', 600);
      ids := ARRAY[V, R, S, C];
      p := pg_temp.l1_promo(v_suc, V, R, C);
      ped := pg_temp.l1_alta_ok(c1, v_adm, v_suc, pg_temp.l1_items(V, 10, R, 4, p));
      PERFORM pg_temp.l1_claims(v_adm, v_suc);
      j := public.cambiar_regalo_promocion(p, R, NULL, false, '{"regalo_mueve_stock": true}'::jsonb);
      IF v_caso LIKE 'L%' THEN
        j := public.cambiar_regalo_promocion(p, R, C, true, '{"regalo_mueve_stock": false}'::jsonb);
      END IF;
      PERFORM pg_temp.l1_t_reset();
      IF (SELECT barra_anterior FROM pedido_promo_reglas WHERE pedido_id = ped AND promocion_id = p) <> (v_caso LIKE 'L%')
         OR (SELECT regalo_mueve_stock FROM pedido_promo_reglas WHERE pedido_id = ped AND promocion_id = p)
         OR public._regalo_barra_vale(ped, p, v_suc)
         OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> v_intacto THEN
        RAISE EXCEPTION 'la premisa no se armó: %', pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p);
      END IF;
      v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped AND es_bonificacion);

      IF v_k IN ('1', '1e') THEN
        -- subirle el regalo: V×20 + R×8 (el admin, y el encargado)
        j := pg_temp.l1_editar(ped, CASE WHEN v_k = '1' THEN v_adm ELSE v_enc END, v_suc,
                               pg_temp.l1_items(V, 20, R, 8, p));
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR j->'errores'->>0 NOT LIKE v_msg
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> v_intacto THEN
          v_f := v_f || format('%s subirle el regalo a V×20 + R×8 no se rechazó o movió algo: %s | %s # %s', v_caso, j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;

      ELSIF v_k = '2' THEN
        -- sacarle el regalo anda y no toca la barra; volver a ponerlo: L se rechaza, O mueve stock
        j := pg_temp.l1_editar(ped, v_adm, v_suc, pg_temp.l1_items(V, 5, R, 0, p));
        IF NOT COALESCE((j->>'success')::boolean, false)
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p)
              <> format('V×5 # V=95 R=100 S=100 Cont=100 | up=%s | mermas=0', v_up) THEN
          v_f := v_f || format('%sa sacarle el regalo no anduvo como hoy: %s | %s # %s', v_caso, j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;
        j := pg_temp.l1_editar(ped, v_adm, v_suc, pg_temp.l1_items(V, 10, R, 4, p));
        IF v_caso LIKE 'L%' THEN
          IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
             OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> 'V×5 # V=95 R=100 S=100 Cont=100 | up=0 | mermas=0' THEN
            v_f := v_f || format('L2b volver a ponerle el regalo no se rechazó o movió algo: %s | %s # %s', j,
                                 pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
          END IF;
        ELSIF NOT COALESCE((j->>'success')::boolean, false)
              OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> 'V×10, R:R×4 # V=90 R=96 S=100 Cont=100 | up=8 | mermas=0'
              OR NOT (SELECT regalo_mueve_stock FROM pedido_promo_reglas WHERE pedido_id = ped AND promocion_id = p) THEN
          v_f := v_f || format('O2b volver a ponerle el regalo no anduvo como hoy (con el modo de hoy, moviendo stock): %s | %s # %s', j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;

      ELSIF v_k = '3' THEN
        -- bajarlo anda; volver a subirlo se rechaza
        j := pg_temp.l1_editar(ped, v_adm, v_suc, pg_temp.l1_items(V, 10, R, 2, p));
        IF NOT COALESCE((j->>'success')::boolean, false)
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p)
              <> format('V×10, R:R×2 # V=90 R=100 S=100 Cont=100 | up=%s | mermas=0', v_up) THEN
          v_f := v_f || format('%sa bajarle el regalo a R×2 no anduvo como hoy: %s | %s # %s', v_caso, j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;
        j := pg_temp.l1_editar(ped, v_adm, v_suc, pg_temp.l1_items(V, 10, R, 4, p));
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR pg_temp.l1_lineas(ped) <> 'V×10, R:R×2' THEN
          v_f := v_f || format('%sb volver a subirlo de R×2 a R×4 no se rechazó: %s | %s', v_caso, j, pg_temp.l1_lineas(ped));
        END IF;

      ELSIF v_k = '4' THEN
        -- editar otra línea sin tocar el regalo
        j := pg_temp.l1_editar(ped, v_adm, v_suc, pg_temp.l1_items(V, 12, R, 4, p));
        IF NOT COALESCE((j->>'success')::boolean, false)
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p)
              <> format('V×12, R:R×4 # V=88 R=100 S=100 Cont=100 | up=%s | mermas=0', v_up) THEN
          v_f := v_f || format('%s editar otra línea sin tocar el regalo no anduvo: %s | %s # %s', v_caso, j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;

      ELSIF v_k = '5' THEN
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.cancelar_pedido_con_stock(ped, 'ensayo 1565', v_adm, NULL);
        PERFORM pg_temp.l1_t_reset();
        IF NOT COALESCE((j->>'success')::boolean, false)
           OR pg_temp.l1_estado(ids, p) <> format('V=100 R=100 S=100 Cont=100 | up=%s | mermas=0', v_up) THEN
          v_f := v_f || format('%s cancelarlo no anduvo como hoy: %s | %s', v_caso, j, pg_temp.l1_estado(ids, p));
        END IF;

      ELSIF v_k = '6' THEN
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.eliminar_pedido_completo(ped, v_adm, 'ensayo 1565', true);
        PERFORM pg_temp.l1_t_reset();
        IF NOT COALESCE((j->>'success')::boolean, false)
           OR pg_temp.l1_estado(ids, p) <> format('V=100 R=100 S=100 Cont=100 | up=%s | mermas=0', v_up) THEN
          v_f := v_f || format('%s eliminarlo no anduvo como hoy: %s | %s', v_caso, j, pg_temp.l1_estado(ids, p));
        END IF;

      ELSIF v_k = '7' THEN
        -- sustituir: otro producto o más cantidad se rechaza; mismo producto y menos, anda
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.sustituir_regalo_pedido(v_it, S, 4, 'ensayo 1565', NULL, NULL);
        PERFORM pg_temp.l1_t_reset();
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR j->>'error' NOT LIKE v_msg
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> v_intacto THEN
          v_f := v_f || format('%sa sustituir R×4 por S×4 no se rechazó o movió algo: %s | %s # %s', v_caso, j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.sustituir_regalo_pedido(v_it, R, 8, 'ensayo 1565', NULL, NULL);
        PERFORM pg_temp.l1_t_reset();
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> v_intacto THEN
          v_f := v_f || format('%sb sustituir R×4 por R×8 no se rechazó o movió algo: %s | %s # %s', v_caso, j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.sustituir_regalo_pedido(v_it, R, 2, 'ensayo 1565', NULL, NULL);
        PERFORM pg_temp.l1_t_reset();
        IF NOT COALESCE((j->>'success')::boolean, false)
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p)
              <> format('V×10, R:R×2 # V=90 R=100 S=100 Cont=100 | up=%s | mermas=0', v_up) THEN
          v_f := v_f || format('%sc sustituir R×4 por R×2 (bajar) no anduvo: %s | %s # %s', v_caso, j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;

      ELSIF v_k = '8' THEN
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.dividir_regalo_pedido(v_it, jsonb_build_array(jsonb_build_object('producto_id', R, 'cantidad', 2),
                                                                   jsonb_build_object('producto_id', S, 'cantidad', 2)), 'ensayo 1565');
        PERFORM pg_temp.l1_t_reset();
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR j->>'error' NOT LIKE v_msg
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> v_intacto THEN
          v_f := v_f || format('%s repartir R×4 en R×2 + S×2 no se rechazó o movió algo: %s | %s # %s', v_caso, j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;

      ELSIF v_caso = 'L9' THEN
        -- salvedad sobre el regalo: baja, y anularla no lo repone
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.registrar_salvedad(ped, v_it, 1, 'cliente_rechaza', 'ensayo 1565', NULL, true, NULL);
        PERFORM pg_temp.l1_t_reset();
        v_sal := (j->>'salvedad_id')::bigint;
        IF NOT COALESCE((j->>'success')::boolean, false)
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> 'V×10, R:R×3 # V=90 R=100 S=100 Cont=100 | up=0 | mermas=0' THEN
          v_f := v_f || format('L9a la salvedad sobre el regalo no anduvo como hoy: %s | %s # %s', j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.anular_salvedad(v_sal, 'ensayo 1565');
        PERFORM pg_temp.l1_t_reset();
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM 'anulacion_toca_promociones'
           OR pg_temp.l1_lineas(ped) <> 'V×10, R:R×3' THEN
          v_f := v_f || format('L9b anular la salvedad sobre el regalo lo repuso: %s | %s', j, pg_temp.l1_lineas(ped));
        END IF;

      ELSIF v_caso = 'L10' THEN
        -- salvedad sobre la venta: el regalo cae, y anularla no lo repone
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.registrar_salvedad(ped, (SELECT id FROM pedido_items WHERE pedido_id = ped AND NOT es_bonificacion),
                                       1, 'cliente_rechaza', 'ensayo 1565', NULL, true, NULL);
        PERFORM pg_temp.l1_t_reset();
        v_sal := (j->>'salvedad_id')::bigint;
        IF NOT COALESCE((j->>'success')::boolean, false)
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> 'V×9 # V=91 R=100 S=100 Cont=100 | up=0 | mermas=0' THEN
          v_f := v_f || format('L10a la salvedad sobre la venta no anduvo como hoy: %s | %s # %s', j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.anular_salvedad(v_sal, 'ensayo 1565');
        PERFORM pg_temp.l1_t_reset();
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM 'anulacion_toca_promociones'
           OR pg_temp.l1_lineas(ped) <> 'V×9' THEN
          v_f := v_f || format('L10b anular la salvedad sobre la venta repuso el regalo: %s | %s', j, pg_temp.l1_lineas(ped));
        END IF;

      ELSIF v_caso = 'L11' THEN
        -- cambio de cliente: el regalo tal cual, y el pedido nuevo nace con su foto
        v_items := (SELECT jsonb_agg(jsonb_build_object('producto_id', producto_id, 'cantidad', cantidad,
                                                        'precio_unitario', precio_unitario,
                                                        'es_bonificacion', es_bonificacion, 'promocion_id', promocion_id)
                                     ORDER BY id)
                      FROM pedido_items WHERE pedido_id = ped);
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.cambiar_cliente_pedido(ped, c2, v_adm, pg_temp.l1_items(V, 20, R, 8, p), 2000);
        PERFORM pg_temp.l1_t_reset();
        IF COALESCE((j->>'success')::boolean, true)
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> v_intacto
           OR (SELECT estado FROM pedidos WHERE id = ped) = 'cancelado' THEN
          v_f := v_f || format('L11a el cambio de cliente con R×8 no se rechazó: %s | %s # %s', j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.cambiar_cliente_pedido(ped, c2, v_adm, v_items, 1000);
        PERFORM pg_temp.l1_t_reset();
        ped2 := COALESCE((j->>'nuevo_pedido_id')::bigint, (j->>'pedido_nuevo_id')::bigint);
        IF NOT COALESCE((j->>'success')::boolean, false)
           OR (SELECT estado FROM pedidos WHERE id = ped) <> 'cancelado'
           OR pg_temp.l1_lineas(ped2) <> 'V×10, R:R×4'
           OR (SELECT barra_anterior FROM pedido_promo_reglas WHERE pedido_id = ped2 AND promocion_id = p)
           OR NOT public._regalo_barra_vale(ped2, p, v_suc)
           OR pg_temp.l1_estado(ids, p) <> 'V=90 R=100 S=100 Cont=100 | up=4 | mermas=0' THEN
          v_f := v_f || format('L11b el cambio de cliente no dejó el pedido nuevo en el tramo nuevo: %s | %s # %s | marca %s', j,
                               pg_temp.l1_lineas(ped2), pg_temp.l1_estado(ids, p),
                               (SELECT barra_anterior FROM pedido_promo_reglas WHERE pedido_id = ped2 AND promocion_id = p));
        END IF;

      ELSIF v_caso = 'O9' THEN
        -- cambio de cliente con la promo de otro tipo: lo rechaza PRM-1 (480)
        v_items := (SELECT jsonb_agg(jsonb_build_object('producto_id', producto_id, 'cantidad', cantidad,
                                                        'precio_unitario', precio_unitario,
                                                        'es_bonificacion', es_bonificacion, 'promocion_id', promocion_id)
                                     ORDER BY id)
                      FROM pedido_items WHERE pedido_id = ped);
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.cambiar_cliente_pedido(ped, c2, v_adm, v_items, 1000);
        PERFORM pg_temp.l1_t_reset();
        IF COALESCE((j->>'success')::boolean, true)
           OR j->>'error' NOT LIKE '%cambio de tipo%'
           OR (SELECT estado FROM pedidos WHERE id = ped) = 'cancelado'
           OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> v_intacto THEN
          v_f := v_f || format('O9 el cambio de cliente del pedido de otro modo no se rechazó: %s | %s # %s', j,
                               pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_f := v_f || format('%s · error: %s', v_caso, SQLERRM);
    END;
  END LOOP;

  -- =====================================================================
  -- T, F, I · los que sí se suman: el tramo nuevo, la fracción sin marca y el
  --           caso inverso (foto de unidad entera, promo hoy en fracción)
  -- =====================================================================
  FOREACH v_caso IN ARRAY ARRAY['T', 'F', 'I'] LOOP
    BEGIN
      V := pg_temp.l1_prod(v_suc, 'V');
      R := pg_temp.l1_prod(v_suc, 'R');
      S := pg_temp.l1_prod(v_suc, 'S');
      C := pg_temp.l1_prod(v_suc, 'Cont', 'ZZ ensayo 1565 otra', 600);
      ids := ARRAY[V, R, S, C];
      p := pg_temp.l1_promo(v_suc, V, R, C);
      IF v_caso = 'T' THEN
        -- el reinicio antes del alta
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.cambiar_regalo_promocion(p, R, NULL, false, '{"regalo_mueve_stock": true}'::jsonb);
        j := public.cambiar_regalo_promocion(p, R, C, true, '{"regalo_mueve_stock": false}'::jsonb);
        PERFORM pg_temp.l1_t_reset();
      ELSIF v_caso = 'I' THEN
        -- el alta con la promo en unidad entera: mueve stock por línea
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.cambiar_regalo_promocion(p, R, NULL, false, '{"regalo_mueve_stock": true}'::jsonb);
        PERFORM pg_temp.l1_t_reset();
      END IF;
      ped := pg_temp.l1_alta_ok(c1, v_adm, v_suc, pg_temp.l1_items(V, 10, R, 4, p));
      IF v_caso = 'I' THEN
        -- y la promo vuelve a fracción con el pedido abierto
        PERFORM pg_temp.l1_claims(v_adm, v_suc);
        j := public.cambiar_regalo_promocion(p, R, C, true, '{"regalo_mueve_stock": false}'::jsonb);
        PERFORM pg_temp.l1_t_reset();
        IF (SELECT barra_anterior OR NOT regalo_mueve_stock FROM pedido_promo_reglas WHERE pedido_id = ped AND promocion_id = p)
           OR pg_temp.l1_estado(ids, p) <> 'V=90 R=96 S=100 Cont=100 | up=0 | mermas=0' THEN
          v_f := v_f || format('I1 la premisa del caso inverso no se armó: %s', pg_temp.l1_estado(ids, p));
        END IF;
      ELSIF (SELECT barra_anterior FROM pedido_promo_reglas WHERE pedido_id = ped AND promocion_id = p)
            OR NOT public._regalo_barra_vale(ped, p, v_suc)
            OR pg_temp.l1_estado(ids, p) <> 'V=90 R=100 S=100 Cont=100 | up=4 | mermas=0' THEN
        v_f := v_f || format('%s1 el pedido no entró en la barra: %s', v_caso, pg_temp.l1_estado(ids, p));
      END IF;
      j := pg_temp.l1_editar(ped, v_adm, v_suc, pg_temp.l1_items(V, 20, R, 8, p));
      -- I mueve stock por línea; T y F suman a la barra y consumen un contenedor.
      v_intacto := CASE WHEN v_caso = 'I' THEN 'V×20, R:R×8 # V=80 R=92 S=100 Cont=100 | up=0 | mermas=0'
                        ELSE 'V×20, R:R×8 # V=80 R=100 S=100 Cont=99 | up=2 | mermas=1' END;
      IF NOT COALESCE((j->>'success')::boolean, false)
         OR pg_temp.l1_lineas(ped) || ' # ' || pg_temp.l1_estado(ids, p) <> v_intacto THEN
        v_f := v_f || format('%s2 subirle el regalo no lo asentó como hoy: %s | %s # %s', v_caso, j,
                             pg_temp.l1_lineas(ped), pg_temp.l1_estado(ids, p));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_f := v_f || format('%s · error: %s', v_caso, SQLERRM);
    END;
  END LOOP;

  IF array_length(v_f, 1) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (%):\n%', array_length(v_f, 1), array_to_string(v_f, E'\n');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · LV-1 de #1565: al regalo de fracción que no entra en la barra viva no se le suma (L1-L11, O1-O9, T, F, I)';
END
$ensayo$;
