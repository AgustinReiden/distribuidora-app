-- Ensayo de la tarjeta de promos y regalos de #1592 (y los bajos de #1556 y #1558
-- de las mismas funciones): migrations/NNN_promos_tope_del_sustituto_y_config_de_la_barra.sql.
--
--   S · PRM-1 · el sustituto de un regalo no vale más que el regalo original para
--       quien no es admin (decisión del dueño del 15/11, en #1592). Promo "10 V
--       dan 4 R", R a $100.
--       S1 · el encargado cambia R×4 por R×40: se rechaza, nada cambia.
--       S2 · R×4 por S×41 (S a $10) se rechaza; por S×40 anda.
--       S3 · y editar el pedido a V×20 (el modal manda R×8) lo deja en S×80: la
--            cadena estaba dentro del tope y escala proporcional.
--       S4 · el admin cambia R×4 por R×40 (sin tope). Después el encargado edita a
--            V×20 (R×8): R×80 se rechaza; editar otra línea con el regalo como
--            estaba (R×4) anda y conserva R×40.
--       S5 · sustituir dos veces no sube el techo: R×4 → S2×6 (S2 a $72, ≈ $432)
--            anda; S2×6 → T×11 (T a $41) se rechaza contra la raíz ($400 ≈ T×10),
--            aunque contra S2×6 ($432) daría 11; T×10 anda.
--       S6 · una unidad de algo que vale más que todo el regalo (X a $1000) se
--            rechaza.
--       S7 · en una promo de fracción el valor es por suelta: R (fardo de 6) a $100
--            y S12 (bulto de 12) a $10. R×4 vale como S12×80: S12×81 se rechaza y
--            S12×80 anda.
--   B · 1556-b2 · sustituir R×4 por R×4 con el stock de R en 0 anda (el stock que
--       se compara es neto de lo que la línea ya tiene).
--   F · PRM-2 · con dos pedidos abiertos que entraron en la barra (R×4 cada uno,
--       6 R = 1 contenedor K1), el admin no puede cambiar el factor, el stock por
--       bloque, el contenedor ni el ajuste automático: se rechaza diciendo que son
--       2 pedidos y no cambia nada. Cambiar el nombre o el tipo de la promo sí.
--       El UPDATE REST del admin también se rechaza. Cancelados los dos, el factor
--       cambia.
--   R · PRM-3 · renormalizar_bloques_por_cambio_factor anota de qué lote salió el
--       fardo y deja los GUC como estaban. Contenedor con un lote de 50 y la bolsa
--       en 0 (R1) o en 5 (R2), barra en 4, sin pedidos: el factor 6 → 4 cierra un
--       bloque. Deshacerlo (la barra baja 4) le devuelve el fardo a su lote (R1)
--       o a la bolsa (R2).
--   D · 1592-b2 · una promo que mueve stock con ajuste automático y factor no
--       cierra bloques del contenedor: el regalo ya bajó por línea.
--   U · 1592-b3 · en una promo que mueve stock, el contador (usos_pendientes) no se
--       corre con un cambio por valor: R×10 → W×1 y cancelar lo deja en 0.
--   L · 1556-c2 · sustituir y repartir toman la promo FOR UPDATE después de los
--       productos y recién ahí leen el modo y la marca de la barra (estructura).
--
-- Arma sus propios usuarios, clientes, productos y promos en la primera sucursal
-- activa. Todo se deshace: el veredicto es el RAISE final, 'ENSAYO OK …' o
-- 'ENSAYO FALLÓ (n)' con la lista. Se corre en una base local armada con
-- scripts/concurrencia/docker-local.mjs, nunca contra prod (escribe en auth.users):
--
--   tr -d '\r' < scripts/test-promos-regalos-1592.sql | docker exec -i <contenedor> psql -U postgres -d postgres -q
--
-- Sin la migración fallan S1, S2, S3 (no llega), S4, S5, S6, S7, B, F, R1, R2, D, U y L.

SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION pg_temp.m1_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.m1_u(p_rol text, p_suc bigint)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE
  v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'e1592-' || v || '@ensayo.invalid',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'e1592 ' || p_rol), now(), now());
  RETURN v;
END
$f$;

CREATE OR REPLACE FUNCTION pg_temp.m1_claims(p_user uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.m1_cli(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo 1592', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.m1_prod(p_suc bigint, p_nombre text, p_precio numeric DEFAULT 100,
                                           p_stock int DEFAULT 500, p_cat text DEFAULT 'ZZ ensayo 1592 cat')
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo 1592 ' || p_nombre, p_precio, p_stock, 10, p_suc, p_cat)
  RETURNING id;
$fn$;

-- Promo "p_compra V dan p_bonif R".
CREATE OR REPLACE FUNCTION pg_temp.m1_promo(p_suc bigint, p_venta bigint, p_regalo bigint, p_compra int, p_bonif int,
                                            p_mueve boolean, p_auto boolean DEFAULT false, p_contenedor bigint DEFAULT NULL,
                                            p_upb int DEFAULT NULL, p_spb int DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, ajuste_producto_id,
                                  unidades_por_bloque, stock_por_bloque)
  VALUES ('ZZ ensayo 1592 promo', 'bonificacion', public._tablero_hoy() - 1, p_suc, p_mueve, p_regalo,
          p_auto, p_contenedor, p_upb, p_spb)
  RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', p_compra, p_suc), (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, p_venta, p_suc);
  RETURN v_promo;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.m1_items(p_venta bigint, p_cv int, p_regalo bigint, p_cr int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_venta, 'cantidad', p_cv, 'precio_unitario', 100))
         || CASE WHEN p_cr > 0 THEN jsonb_build_array(
              jsonb_build_object('producto_id', p_regalo, 'cantidad', p_cr, 'precio_unitario', 0,
                                 'es_bonificacion', true, 'promocion_id', p_promo)) ELSE '[]'::jsonb END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.m1_alta(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_tot numeric;
BEGIN
  PERFORM pg_temp.m1_claims(p_user, p_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
    FROM jsonb_array_elements(p_items) e;
  v_res := public.crear_pedido_completo(p_cli, v_tot, p_user, p_items, 'ensayo 1592');
  PERFORM pg_temp.m1_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'alta fallo: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.m1_editar(p_ped bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.m1_claims(p_user, p_suc);
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.m1_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.m1_sust(p_user uuid, p_suc bigint, p_item bigint, p_prod bigint, p_cant numeric)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  j jsonb;
BEGIN
  PERFORM pg_temp.m1_claims(p_user, p_suc);
  j := public.sustituir_regalo_pedido(p_item, p_prod, p_cant, 'ensayo 1592', NULL, NULL);
  PERFORM pg_temp.m1_reset();
  RETURN j;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.m1_cancelar(p_user uuid, p_suc bigint, p_ped bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  j jsonb;
BEGIN
  PERFORM pg_temp.m1_claims(p_user, p_suc);
  j := public.cancelar_pedido_con_stock(p_ped, 'ensayo 1592', p_user, NULL);
  PERFORM pg_temp.m1_reset();
  RETURN j;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.m1_guardar(p_user uuid, p_suc bigint, p_promo bigint, p_regalo bigint, p_cont bigint,
                                              p_auto boolean, p_datos jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  j jsonb;
BEGIN
  PERFORM pg_temp.m1_claims(p_user, p_suc);
  j := public.cambiar_regalo_promocion(p_promo, p_regalo, p_cont, p_auto, p_datos);
  PERFORM pg_temp.m1_reset();
  RETURN j;
END
$fn$;

-- Las líneas de regalo del pedido: "R×4" (sin el prefijo de los nombres).
CREATE OR REPLACE FUNCTION pg_temp.m1_regalos(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(string_agg(format('%s×%s', replace(pr.nombre, 'ZZ ensayo 1592 ', ''), pi.cantidad), ', ' ORDER BY pi.id), '-')
    FROM public.pedido_items pi JOIN public.productos pr ON pr.id = pi.producto_id
   WHERE pi.pedido_id = p_ped AND pi.es_bonificacion;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.m1_stock(p_ids bigint[])
RETURNS text LANGUAGE sql AS $fn$
  SELECT string_agg(format('%s=%s', replace(nombre, 'ZZ ensayo 1592 ', ''), stock), ' ' ORDER BY array_position(p_ids, id))
    FROM public.productos WHERE id = ANY(p_ids);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.m1_promo_txt(p_promo bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('upb=%s spb=%s cont=%s auto=%s up=%s', unidades_por_bloque, stock_por_bloque,
                COALESCE(ajuste_producto_id::text, '-'), ajuste_automatico, usos_pendientes)
    FROM public.promociones WHERE id = p_promo;
$fn$;

-- El lote del contenedor y la bolsa: "lote=50 bolsa=0".
CREATE OR REPLACE FUNCTION pg_temp.m1_lotes(p_prod bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('stock=%s lote=%s bolsa=%s', p.stock, COALESCE(sum(l.cantidad_restante), 0),
                p.stock - COALESCE(sum(l.cantidad_restante), 0))
    FROM public.productos p LEFT JOIN public.producto_lotes l ON l.producto_id = p.id
   WHERE p.id = p_prod
   GROUP BY p.stock;
$fn$;

DO $ensayo$
DECLARE
  v_suc bigint := (SELECT min(id) FROM public.sucursales WHERE activa);
  v_adm uuid; v_enc uuid;
  c1 bigint;
  V bigint; R bigint; S bigint; S2 bigint; T bigint; X bigint; W bigint; S12 bigint; K1 bigint; K2 bigint; C bigint;
  p bigint; ped bigint; ped2 bigint; v_it bigint; v_lote bigint;
  j jsonb; v_antes text;
  v_f text[] := '{}';
  v_caso text;
  v_src text;
  v_esperado text;
  v_registro jsonb;
  M constant text := 'regalo_sustituto_sobre_tope';
BEGIN
  SET LOCAL lock_timeout = '5s';
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay una sucursal activa';
  END IF;
  v_adm := pg_temp.m1_u('admin', v_suc);
  v_enc := pg_temp.m1_u('encargado', v_suc);
  c1 := pg_temp.m1_cli(v_suc, 'ZZ ensayo 1592 C1');

  -- =======================================================================
  -- S · PRM-1 · el tope del sustituto
  -- =======================================================================
  FOREACH v_caso IN ARRAY ARRAY['S1', 'S2', 'S4', 'S5', 'S6', 'S7', 'B'] LOOP
    BEGIN
      V := pg_temp.m1_prod(v_suc, 'V');
      R := pg_temp.m1_prod(v_suc, 'R', 100, CASE WHEN v_caso = 'B' THEN 4 ELSE 500 END);
      S := pg_temp.m1_prod(v_suc, 'S', 10);
      S2 := pg_temp.m1_prod(v_suc, 'S2', 72);
      T := pg_temp.m1_prod(v_suc, 'T', 41);
      X := pg_temp.m1_prod(v_suc, 'X', 1000);
      S12 := pg_temp.m1_prod(v_suc, 'S12', 10);
      UPDATE productos SET unidades_por_bulto = 12 WHERE id = S12;
      IF v_caso = 'S7' THEN
        -- fracción: el regalo es el fardo (6 sueltas) y es su propio contenedor
        p := pg_temp.m1_promo(v_suc, V, R, 10, 4, false, true, R, 6, 1);
      ELSE
        p := pg_temp.m1_promo(v_suc, V, R, 10, 4, true);
      END IF;
      ped := pg_temp.m1_alta(c1, v_adm, v_suc, pg_temp.m1_items(V, 10, R, 4, p));
      v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped AND es_bonificacion);
      v_antes := pg_temp.m1_regalos(ped) || ' # ' || pg_temp.m1_stock(ARRAY[R, S, S2, T, X, S12]);

      IF v_caso = 'S1' THEN
        j := pg_temp.m1_sust(v_enc, v_suc, v_it, R, 40);
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR j->>'error' NOT LIKE '%hasta 4 de ZZ ensayo 1592 R%'
           OR pg_temp.m1_regalos(ped) || ' # ' || pg_temp.m1_stock(ARRAY[R, S, S2, T, X, S12]) <> v_antes THEN
          v_f := v_f || format('S1 el encargado cambió R×4 por R×40: %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;

      ELSIF v_caso = 'S2' THEN
        j := pg_temp.m1_sust(v_enc, v_suc, v_it, S, 41);
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR j->>'error' NOT LIKE '%hasta 40 de ZZ ensayo 1592 S%' THEN
          v_f := v_f || format('S2 el encargado cambió R×4 ($400) por S×41 ($410): %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;
        j := pg_temp.m1_sust(v_enc, v_suc, v_it, S, 40);
        IF NOT COALESCE((j->>'success')::boolean, false) OR pg_temp.m1_regalos(ped) <> 'S×40' THEN
          v_f := v_f || format('S2 el encargado no pudo cambiar R×4 por S×40 (mismo valor): %s | %s', j, pg_temp.m1_regalos(ped));
        ELSE
          -- S3: la edición escala una cadena que estaba dentro del tope
          j := pg_temp.m1_editar(ped, v_enc, v_suc, pg_temp.m1_items(V, 20, R, 8, p));
          IF NOT COALESCE((j->>'success')::boolean, false) OR pg_temp.m1_regalos(ped) <> 'S×80' THEN
            v_f := v_f || format('S3 editar a V×20 con S×40 por R×4 no dejó S×80: %s | %s', j, pg_temp.m1_regalos(ped));
          END IF;
        END IF;

      ELSIF v_caso = 'S4' THEN
        j := pg_temp.m1_sust(v_adm, v_suc, v_it, R, 40);
        IF NOT COALESCE((j->>'success')::boolean, false) OR pg_temp.m1_regalos(ped) <> 'R×40' THEN
          v_f := v_f || format('S4 el admin no pudo cambiar R×4 por R×40: %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;
        v_antes := pg_temp.m1_regalos(ped) || ' # ' || pg_temp.m1_stock(ARRAY[V, R]);
        j := pg_temp.m1_editar(ped, v_enc, v_suc, pg_temp.m1_items(V, 20, R, 8, p));
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR pg_temp.m1_regalos(ped) || ' # ' || pg_temp.m1_stock(ARRAY[V, R]) <> v_antes THEN
          v_f := v_f || format('S4 el encargado escaló R×40 a R×80 editando: %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;
        j := pg_temp.m1_editar(ped, v_enc, v_suc, pg_temp.m1_items(V, 12, R, 4, p));
        IF NOT COALESCE((j->>'success')::boolean, false) OR pg_temp.m1_regalos(ped) <> 'R×40' THEN
          v_f := v_f || format('S4 el encargado no pudo editar otra línea con el regalo como estaba: %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;

      ELSIF v_caso = 'S5' THEN
        j := pg_temp.m1_sust(v_enc, v_suc, v_it, S2, 6);
        IF NOT COALESCE((j->>'success')::boolean, false) OR pg_temp.m1_regalos(ped) <> 'S2×6' THEN
          v_f := v_f || format('S5 el encargado no pudo cambiar R×4 por S2×6 (lo que sugiere la pantalla): %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;
        j := pg_temp.m1_sust(v_enc, v_suc, v_it, T, 11);
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR j->>'error' NOT LIKE '%hasta 10 de ZZ ensayo 1592 T%' THEN
          v_f := v_f || format('S5 la segunda sustitución subió el techo (S2×6 → T×11): %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;
        j := pg_temp.m1_sust(v_enc, v_suc, v_it, T, 10);
        IF NOT COALESCE((j->>'success')::boolean, false) OR pg_temp.m1_regalos(ped) <> 'T×10' THEN
          v_f := v_f || format('S5 el encargado no pudo cambiar S2×6 por T×10: %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;

      ELSIF v_caso = 'S6' THEN
        j := pg_temp.m1_sust(v_enc, v_suc, v_it, X, 1);
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR pg_temp.m1_regalos(ped) <> 'R×4' THEN
          v_f := v_f || format('S6 el encargado cambió R×4 ($400) por X×1 ($1000): %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;

      ELSIF v_caso = 'S7' THEN
        j := pg_temp.m1_sust(v_enc, v_suc, v_it, S12, 81);
        IF COALESCE((j->>'success')::boolean, true) OR j->>'codigo' IS DISTINCT FROM M
           OR j->>'error' NOT LIKE '%hasta 80 de ZZ ensayo 1592 S12%' THEN
          v_f := v_f || format('S7 en fracción el encargado cambió R×4 por S12×81: %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;
        j := pg_temp.m1_sust(v_enc, v_suc, v_it, S12, 80);
        IF NOT COALESCE((j->>'success')::boolean, false) OR pg_temp.m1_regalos(ped) <> 'S12×80' THEN
          v_f := v_f || format('S7 en fracción el encargado no pudo cambiar R×4 por S12×80: %s | %s', j, pg_temp.m1_regalos(ped));
        END IF;

      ELSIF v_caso = 'B' THEN
        -- 1556-b2: R tenía 4 y el alta se los llevó
        IF (SELECT stock FROM productos WHERE id = R) <> 0 THEN
          RAISE EXCEPTION 'la premisa no se armó: %', pg_temp.m1_stock(ARRAY[R]);
        END IF;
        j := pg_temp.m1_sust(v_enc, v_suc, v_it, R, 4);
        IF NOT COALESCE((j->>'success')::boolean, false) OR pg_temp.m1_regalos(ped) <> 'R×4'
           OR (SELECT stock FROM productos WHERE id = R) <> 0 THEN
          v_f := v_f || format('B sustituir R×4 por R×4 con el stock en 0: %s | %s # %s', j, pg_temp.m1_regalos(ped),
                               pg_temp.m1_stock(ARRAY[R]));
        END IF;
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_f := v_f || format('%s · error: %s', v_caso, SQLERRM);
    END;
  END LOOP;

  -- =======================================================================
  -- F · PRM-2 · la configuración de la barra no cambia con pedidos abiertos
  -- =======================================================================
  BEGIN
    V := pg_temp.m1_prod(v_suc, 'V', 100, 200);
    R := pg_temp.m1_prod(v_suc, 'R', 10, 200);
    K1 := pg_temp.m1_prod(v_suc, 'K1', 600, 50, 'ZZ ensayo 1592 otra');
    K2 := pg_temp.m1_prod(v_suc, 'K2', 600, 50, 'ZZ ensayo 1592 otra');
    -- 2 V dan 1 R; 6 R = 1 K1
    p := pg_temp.m1_promo(v_suc, V, R, 2, 1, false, true, K1, 6, 1);
    ped := pg_temp.m1_alta(c1, v_adm, v_suc, pg_temp.m1_items(V, 8, R, 4, p));
    ped2 := pg_temp.m1_alta(c1, v_adm, v_suc, pg_temp.m1_items(V, 8, R, 4, p));
    v_antes := pg_temp.m1_promo_txt(p) || ' # ' || pg_temp.m1_stock(ARRAY[K1, K2]);
    IF v_antes <> format('upb=6 spb=1 cont=%s auto=t up=2 # K1=49 K2=50', K1) THEN
      RAISE EXCEPTION 'la premisa no se armó: %', v_antes;
    END IF;
    FOREACH v_caso IN ARRAY ARRAY['factor', 'spb', 'contenedor', 'ajuste'] LOOP
      j := CASE v_caso
             WHEN 'factor' THEN pg_temp.m1_guardar(v_adm, v_suc, p, R, K1, true, '{"unidades_por_bloque": 4}')
             WHEN 'spb' THEN pg_temp.m1_guardar(v_adm, v_suc, p, R, K1, true, '{"stock_por_bloque": 2}')
             WHEN 'contenedor' THEN pg_temp.m1_guardar(v_adm, v_suc, p, R, K2, true, '{"nombre": "ZZ ensayo 1592 promo"}')
             ELSE pg_temp.m1_guardar(v_adm, v_suc, p, R, K1, false, '{"nombre": "ZZ ensayo 1592 promo"}') END;
      IF COALESCE((j->>'success')::boolean, true)
         OR j->>'error' NOT LIKE '%hay 2 pedido(s) sin entregar%'
         OR pg_temp.m1_promo_txt(p) || ' # ' || pg_temp.m1_stock(ARRAY[K1, K2]) <> v_antes THEN
        v_f := v_f || format('F %s cambió con 2 pedidos abiertos en la barra: %s | %s # %s', v_caso, j,
                             pg_temp.m1_promo_txt(p), pg_temp.m1_stock(ARRAY[K1, K2]));
      END IF;
    END LOOP;
    -- El UPDATE REST del admin (la policy lo deja) tampoco.
    BEGIN
      PERFORM pg_temp.m1_claims(v_adm, v_suc);
      SET LOCAL ROLE authenticated;
      UPDATE promociones SET unidades_por_bloque = 4 WHERE id = p;
      RESET ROLE;
      v_f := v_f || format('F rest el UPDATE REST del factor entró: %s', pg_temp.m1_promo_txt(p));
    EXCEPTION WHEN OTHERS THEN
      RESET ROLE;
      IF SQLERRM NOT LIKE '%hay 2 pedido(s) sin entregar%' THEN
        v_f := v_f || format('F rest se rechazó por otra cosa: %s', SQLERRM);
      END IF;
    END;
    PERFORM pg_temp.m1_reset();
    -- Lo demás de la promo sí cambia.
    j := pg_temp.m1_guardar(v_adm, v_suc, p, R, K1, true, '{"nombre": "ZZ ensayo 1592 promo bis", "limite_usos": 50}');
    IF NOT COALESCE((j->>'success')::boolean, false) THEN
      v_f := v_f || format('F otro campo no se pudo cambiar con pedidos abiertos: %s', j);
    END IF;
    -- Cancelados los dos, el factor cambia.
    j := pg_temp.m1_cancelar(v_adm, v_suc, ped);
    j := pg_temp.m1_cancelar(v_adm, v_suc, ped2);
    j := pg_temp.m1_guardar(v_adm, v_suc, p, R, K1, true, '{"unidades_por_bloque": 4}');
    IF NOT COALESCE((j->>'success')::boolean, false)
       OR pg_temp.m1_promo_txt(p) || ' # ' || pg_temp.m1_stock(ARRAY[K1, K2]) <> format('upb=4 spb=1 cont=%s auto=t up=0 # K1=50 K2=50', K1) THEN
      v_f := v_f || format('F sin pedidos abiertos el factor no cambió o el contenedor no cerró: %s | %s # %s', j,
                           pg_temp.m1_promo_txt(p), pg_temp.m1_stock(ARRAY[K1, K2]));
    END IF;
    -- El tipo se puede cambiar con pedidos abiertos (#1324, decisión del dueño).
    ped := pg_temp.m1_alta(c1, v_adm, v_suc, pg_temp.m1_items(V, 8, R, 4, p));
    j := pg_temp.m1_guardar(v_adm, v_suc, p, R, NULL, false, '{"regalo_mueve_stock": true}');
    IF NOT COALESCE((j->>'success')::boolean, false) THEN
      v_f := v_f || format('F el cambio de tipo con un pedido abierto se rechazó: %s', j);
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_f := v_f || format('F · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- R · PRM-3 · el bloque de la renormalización anota su lote
  -- =======================================================================
  FOREACH v_caso IN ARRAY ARRAY['R1', 'R2'] LOOP
    BEGIN
      V := pg_temp.m1_prod(v_suc, 'V', 100, 200);
      R := pg_temp.m1_prod(v_suc, 'R', 10, 200);
      C := pg_temp.m1_prod(v_suc, 'Cont', 600, CASE WHEN v_caso = 'R1' THEN 50 ELSE 55 END, 'ZZ ensayo 1592 otra');
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
      VALUES (C, v_suc, public._tablero_hoy() + 30, 50, 50, 'manual')
      RETURNING id INTO v_lote;
      p := pg_temp.m1_promo(v_suc, V, R, 2, 1, false, true, C, 6, 1);
      -- La barra en 4, de pedidos ya entregados: ningún pedido abierto la traba.
      UPDATE promociones SET usos_pendientes = 4 WHERE id = p;
      PERFORM set_config('app.stock_origen', 'ensayo_1592_previo', true);
      PERFORM set_config('app.stock_ref_tipo', 'ensayo', true);
      PERFORM pg_temp.m1_claims(v_adm, v_suc);
      j := public.cambiar_regalo_promocion(p, R, C, true, '{"unidades_por_bloque": 4}'::jsonb);
      IF NOT COALESCE((j->>'success')::boolean, false)
         OR current_setting('app.stock_origen', true) IS DISTINCT FROM 'ensayo_1592_previo'
         OR current_setting('app.stock_ref_tipo', true) IS DISTINCT FROM 'ensayo' THEN
        v_f := v_f || format('%s el cambio de factor no anduvo o dejó los GUC puestos: %s | origen=%s ref_tipo=%s', v_caso, j,
                             current_setting('app.stock_origen', true), current_setting('app.stock_ref_tipo', true));
      END IF;
      PERFORM pg_temp.m1_reset();
      v_esperado := CASE WHEN v_caso = 'R1' THEN 'stock=49 lote=49 bolsa=0' ELSE 'stock=54 lote=50 bolsa=4' END;
      v_registro := jsonb_build_array(jsonb_build_object('lote_id', CASE WHEN v_caso = 'R1' THEN v_lote END, 'cantidad', 1));
      IF pg_temp.m1_lotes(C) <> v_esperado
         OR (SELECT lotes_pendientes FROM promo_ajustes WHERE promocion_id = p AND unidades_ajustadas = 1)
            IS DISTINCT FROM v_registro THEN
        v_f := v_f || format('%s el bloque no anotó de dónde salió el fardo: %s | %s', v_caso, pg_temp.m1_lotes(C),
                             (SELECT jsonb_agg(lotes_pendientes) FROM promo_ajustes WHERE promocion_id = p));
      END IF;
      -- Deshacerlo: la barra baja 4 (una salvedad, una cancelación).
      PERFORM public.aplicar_uso_promo_acumulador(p, R, -4, R, v_suc, v_adm, 'ensayo 1592: deshacer');
      PERFORM pg_temp.m1_reset();
      v_esperado := CASE WHEN v_caso = 'R1' THEN 'stock=50 lote=50 bolsa=0' ELSE 'stock=55 lote=50 bolsa=5' END;
      IF pg_temp.m1_lotes(C) <> v_esperado THEN
        v_f := v_f || format('%s deshacer el bloque no le devolvió el fardo a donde salió: %s', v_caso, pg_temp.m1_lotes(C));
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_f := v_f || format('%s · error: %s', v_caso, SQLERRM);
    END;
  END LOOP;

  -- =======================================================================
  -- D · 1592-b2 · mueve stock + ajuste automático: el contenedor no baja
  -- =======================================================================
  BEGIN
    V := pg_temp.m1_prod(v_suc, 'V', 100, 200);
    R := pg_temp.m1_prod(v_suc, 'R', 10, 200);
    C := pg_temp.m1_prod(v_suc, 'Cont', 600, 50, 'ZZ ensayo 1592 otra');
    p := pg_temp.m1_promo(v_suc, V, R, 2, 1, true, true, C, 6, 1);
    ped := pg_temp.m1_alta(c1, v_adm, v_suc, pg_temp.m1_items(V, 12, R, 6, p));
    IF pg_temp.m1_stock(ARRAY[R, C]) <> 'R=194 Cont=50' THEN
      v_f := v_f || format('D el regalo de una promo que mueve stock bajó dos veces: %s', pg_temp.m1_stock(ARRAY[R, C]));
    END IF;
    j := pg_temp.m1_cancelar(v_adm, v_suc, ped);
    IF pg_temp.m1_stock(ARRAY[R, C]) <> 'R=200 Cont=50' THEN
      v_f := v_f || format('D cancelar no dejó el stock como al principio: %s', pg_temp.m1_stock(ARRAY[R, C]));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_f := v_f || format('D · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- U · 1592-b3 · el contador de una promo que mueve stock y un cambio por valor
  -- =======================================================================
  BEGIN
    V := pg_temp.m1_prod(v_suc, 'V', 100, 200);
    R := pg_temp.m1_prod(v_suc, 'R', 100, 200);
    W := pg_temp.m1_prod(v_suc, 'W', 1000, 200);
    p := pg_temp.m1_promo(v_suc, V, R, 2, 1, true);
    ped := pg_temp.m1_alta(c1, v_adm, v_suc, pg_temp.m1_items(V, 20, R, 10, p));
    v_it := (SELECT id FROM pedido_items WHERE pedido_id = ped AND es_bonificacion);
    j := pg_temp.m1_sust(v_enc, v_suc, v_it, W, 1);
    IF NOT COALESCE((j->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la sustitución R×10 → W×1 no anduvo: %', j;
    END IF;
    j := pg_temp.m1_cancelar(v_adm, v_suc, ped);
    IF (SELECT usos_pendientes FROM promociones WHERE id = p) <> 0 THEN
      v_f := v_f || format('U el contador quedó corrido tras R×10 → W×1 y cancelar: up=%s',
                           (SELECT usos_pendientes FROM promociones WHERE id = p));
    END IF;
  EXCEPTION WHEN OTHERS THEN
    v_f := v_f || format('U · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- L · 1556-c2 · la promo se toma antes de leer el modo (estructura)
  -- =======================================================================
  FOREACH v_caso IN ARRAY ARRAY['public.sustituir_regalo_pedido(bigint,bigint,numeric,text,bigint,uuid)',
                                'public.dividir_regalo_pedido(bigint,jsonb,text,uuid)'] LOOP
    v_src := (SELECT prosrc FROM pg_proc WHERE oid = v_caso::regprocedure);
    IF position(E'AND sucursal_id = v_sucursal\n     FOR UPDATE;\n  -- #1324: el modo de la foto del pedido.' IN v_src) = 0
       OR position(E'AND sucursal_id = v_sucursal\n     FOR UPDATE;\n  -- #1324: el modo de la foto del pedido.' IN v_src)
          < position('public._contenedores_de_promos(ARRAY[v_item.promocion_id], v_sucursal) c)' IN v_src)
       OR position('_regalo_modo_del_pedido' IN v_src)
          < position('public._contenedores_de_promos(ARRAY[v_item.promocion_id], v_sucursal) c)' IN v_src) THEN
      v_f := v_f || format('L %s lee el modo de la promo sin tomarla, o antes de los productos', v_caso);
    END IF;
  END LOOP;

  IF array_length(v_f, 1) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (%):\n%', array_length(v_f, 1), array_to_string(v_f, E'\n');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · promos y regalos de #1592: tope del sustituto (S1-S7), stock neto (B), configuración de la barra (F), lote del bloque (R1, R2), contador (D, U) y lock de la promo (L)';
END
$ensayo$;
