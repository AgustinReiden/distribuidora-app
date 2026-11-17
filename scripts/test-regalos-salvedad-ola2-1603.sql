-- Ensayo de la tarjeta B1 de la ola 2 del plan #1603 (regalos, barra y salvedad):
-- migrations/NNN_regalos_salvedad_y_bloques_con_su_config.sql.
--
--   H · #1592 PRM-2 residual (H6 de la revisión de la 512) · cada bloque de la
--       barra se deshace con la configuración con la que se cerró. Promo de
--       fracción "10 V dan 4 R", contenedor con stock 50 y la bolsa en 0 (un lote
--       de 50), dos pedidos R×4 entregados.
--       H1 · el factor pasa de 6 a 4 y llegan dos salvedades del regalo entero: el
--            contenedor vuelve a 49 y a 50 (antes 50 y 51), la barra queda en 0
--            (antes 2), el lote en 50 y la bolsa en 0 (antes la bolsa en 1), y
--            PROMO-A de la promo en verde.
--       H2 · el contenedor pasa de K1 a K2: el fardo vuelve a K1 (antes K1 49 y
--            K2 51).
--       H3 · el factor sube de 4 a 6 con dos bloques cerrados: las salvedades
--            dejan el contenedor en 50 y la barra en 0 (antes la barra en 4).
--       H4 · el bloque que cierra la renormalización anota su barra y su
--            configuración, y deshacerlo devuelve su fardo.
--       H5 · un bloque sin anotar (anterior a la migración) usa la cuenta de hoy
--            con tope: nunca devuelve más fardos de los que la promo sacó (antes
--            51 y PROMO-A en rojo).
--       H6 · el factor baja de 6 a 4 y el contenedor pasa de K1 a K2, con K2 en
--            0: la salvedad del regalo entra igual (el recierre no tiene stock y
--            lo que sobra queda en la barra, en 4), el fardo vuelve a K1 y K2 no
--            se toca. La segunda salvedad deja la barra en 0. (Antes de la
--            revisión, la salvedad se rechazaba por «stock insuficiente».)
--       H7 · el factor baja de 6 a 4 y el stock por bloque sube de 1 a 2, con el
--            contenedor en 0: lo mismo, el fardo vuelve y la barra queda en 4.
--   C · 1583-a (#1583) · la salvedad sobre la venta baja el corte guardado.
--       Promo "1 V da 1 R" que mueve stock: V×10 + R×10, R×10 → W×1 por valor,
--       edición a V×14 (W×1 con corte 14).
--       C1 · salvedad de 4 V: el corte queda en 10 (antes 14) y la línea W×1;
--            el stock de W no cambia.
--       C2 · otra de 6 V: el corte queda en 4 (antes 14).
--       C3 · con un límite de 14 usos, después de la salvedad de 4 V entra otro
--            pedido de R×4 (antes lo rechazaba el cupo).
--       C4 · _regalo_recorte devuelve la línea que sólo pierde corte.
--       C5 · anular la salvedad de 4 V, que sólo bajó el corte, se rechaza como
--            cualquier recorte (1592-b5), y el corte queda en 10. Con un límite de
--            14, otro pedido de R×4 entra (14 + 4 cuentan 14). Si la anulación
--            pasara, la venta volvía a V×14 con el corte en 10 y el cupo dejaba
--            pasar de más.
--   B · 1595-b5 (#1595, D23) · la salvedad sólo va sobre un pedido en camino o
--       entregado: pendiente y en preparación se rechazan (`pedido_sin_salir`),
--       en camino entra.
--   S · 1564-b2 (#1564) · un admin parado en la sucursal 1 no lee la NC vigente
--       de un pedido de la 2: contesta "Pedido no encontrado".
--
-- Arma sus propios usuarios, clientes, productos y promos. Cada caso se deshace
-- con su propio RAISE, y todo con el RAISE final: 'ENSAYO OK …' o 'ENSAYO FALLÓ
-- (n)' con la lista. Se corre en una base local armada con
-- scripts/concurrencia/docker-local.mjs, nunca contra prod (escribe en auth.users):
--
--   tr -d '\r' < scripts/test-regalos-salvedad-ola2-1603.sql | docker exec -i <contenedor> psql -U postgres -d postgres -q
--
-- Sin la migración fallan H1, H2, H3, H4, H5, H6, H7, C1, C2, C3, C4, C5, B y S.

SET client_min_messages = warning;

CREATE OR REPLACE FUNCTION pg_temp.b1_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.b1_u(p_rol text, p_suc bigint)
RETURNS uuid LANGUAGE plpgsql AS $f$
DECLARE
  v uuid := gen_random_uuid();
BEGIN
  INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
  VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 'eb1-' || v || '@ensayo.invalid',
          jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'eb1 ' || p_rol), now(), now());
  RETURN v;
END
$f$;

CREATE OR REPLACE FUNCTION pg_temp.b1_claims(p_user uuid, p_suc bigint)
RETURNS void LANGUAGE sql AS $f$
  SELECT set_config('request.jwt.claims', json_build_object('sub', p_user, 'role', 'authenticated')::text, true);
  SELECT set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
$f$;

CREATE OR REPLACE FUNCTION pg_temp.b1_cli(p_suc bigint, p_nombre text)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
  VALUES (p_nombre, p_nombre, 'Ensayo B1', p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.b1_prod(p_suc bigint, p_nombre text, p_precio numeric DEFAULT 100,
                                           p_stock int DEFAULT 500)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria)
  VALUES ('ZZ ensayo b1 ' || p_nombre, p_precio, p_stock, 10, p_suc, 'ZZ ensayo b1 cat')
  RETURNING id;
$fn$;

-- Promo "p_compra V dan p_bonif R".
CREATE OR REPLACE FUNCTION pg_temp.b1_promo(p_suc bigint, p_venta bigint, p_regalo bigint, p_compra int, p_bonif int,
                                            p_mueve boolean, p_auto boolean DEFAULT false, p_contenedor bigint DEFAULT NULL,
                                            p_upb int DEFAULT NULL, p_spb int DEFAULT NULL, p_limite int DEFAULT NULL)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, ajuste_producto_id,
                                  unidades_por_bloque, stock_por_bloque, limite_usos)
  VALUES ('ZZ ensayo b1 promo', 'bonificacion', public._tablero_hoy() - 1, p_suc, p_mueve, p_regalo,
          p_auto, p_contenedor, p_upb, p_spb, p_limite)
  RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', p_compra, p_suc), (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, p_venta, p_suc);
  RETURN v_promo;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.b1_items(p_venta bigint, p_cv int, p_regalo bigint, p_cr int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_array(jsonb_build_object('producto_id', p_venta, 'cantidad', p_cv, 'precio_unitario', 100))
         || CASE WHEN p_cr > 0 THEN jsonb_build_array(
              jsonb_build_object('producto_id', p_regalo, 'cantidad', p_cr, 'precio_unitario', 0,
                                 'es_bonificacion', true, 'promocion_id', p_promo)) ELSE '[]'::jsonb END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.b1_alta(p_cli bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_tot numeric;
BEGIN
  PERFORM pg_temp.b1_claims(p_user, p_suc);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  SELECT COALESCE(sum((e->>'cantidad')::numeric * (e->>'precio_unitario')::numeric), 0) INTO v_tot
    FROM jsonb_array_elements(p_items) e;
  v_res := public.crear_pedido_completo(p_cli, v_tot, p_user, p_items, 'ensayo b1');
  PERFORM pg_temp.b1_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'alta fallo: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.b1_editar(p_ped bigint, p_user uuid, p_suc bigint, p_items jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  PERFORM pg_temp.b1_claims(p_user, p_suc);
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_user);
  PERFORM pg_temp.b1_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.b1_sust(p_user uuid, p_suc bigint, p_item bigint, p_prod bigint, p_cant numeric)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  j jsonb;
BEGIN
  PERFORM pg_temp.b1_claims(p_user, p_suc);
  j := public.sustituir_regalo_pedido(p_item, p_prod, p_cant, 'ensayo b1', NULL, NULL);
  PERFORM pg_temp.b1_reset();
  RETURN j;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.b1_salv(p_user uuid, p_suc bigint, p_ped bigint, p_item bigint, p_cant int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  j jsonb;
BEGIN
  PERFORM pg_temp.b1_claims(p_user, p_suc);
  j := public.registrar_salvedad(p_ped, p_item, p_cant, 'cliente_rechaza', 'ensayo b1', NULL, true, NULL);
  PERFORM pg_temp.b1_reset();
  RETURN j;
END
$fn$;

-- Entregado (retiro en depósito, hoy): ninguna guarda de la barra lo cuenta como abierto.
CREATE OR REPLACE FUNCTION pg_temp.b1_anular(p_user uuid, p_suc bigint, p_salv bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  j jsonb;
BEGIN
  PERFORM pg_temp.b1_claims(p_user, p_suc);
  j := public.anular_salvedad(p_salv, 'ensayo b1');
  PERFORM pg_temp.b1_reset();
  RETURN j;
END
$fn$;

-- Cada RPC es su transacción en la vida real: lo escrito en audit_logs hasta acá
-- pasa a «un minuto antes», para que la anulación (1592-b5) separe las salvedades.
CREATE OR REPLACE FUNCTION pg_temp.b1_audit_atras()
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.audit_logs SET created_at = created_at - interval '1 minute' WHERE created_at = now();
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.b1_entregar(p_ped bigint)
RETURNS void LANGUAGE sql AS $fn$
  UPDATE public.pedidos SET estado = 'entregado', retiro_deposito = true, fecha_entrega = now() WHERE id = p_ped;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.b1_item_regalo(p_ped bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items WHERE pedido_id = p_ped AND es_bonificacion ORDER BY id LIMIT 1;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.b1_item_venta(p_ped bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items WHERE pedido_id = p_ped AND NOT COALESCE(es_bonificacion, false) ORDER BY id LIMIT 1;
$fn$;

-- "stock=50 lote=50 bolsa=0"
CREATE OR REPLACE FUNCTION pg_temp.b1_lotes(p_prod bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT format('stock=%s lote=%s bolsa=%s', p.stock, COALESCE(sum(l.cantidad_restante), 0),
                p.stock - COALESCE(sum(l.cantidad_restante), 0))
    FROM public.productos p LEFT JOIN public.producto_lotes l ON l.producto_id = p.id
   WHERE p.id = p_prod
   GROUP BY p.stock;
$fn$;

-- La barra de la promo (la del regalo de la promo).
CREATE OR REPLACE FUNCTION pg_temp.b1_up(p_promo bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT usos_pendientes FROM public.promociones WHERE id = p_promo;
$fn$;

-- PROMO-A de una promo: los (promo, contenedor) que devolvieron más fardos de los que se les sacaron.
CREATE OR REPLACE FUNCTION pg_temp.b1_promo_a(p_promo bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT count(*) FROM (SELECT producto_id FROM public.promo_ajustes
                         WHERE promocion_id = p_promo AND producto_id IS NOT NULL
                         GROUP BY producto_id HAVING SUM(COALESCE(unidades_ajustadas, 0)) < 0) x;
$fn$;

DO $ensayo$
DECLARE
  v_suc  bigint := 1;
  v_suc2 bigint := 2;
  v_adm uuid; v_adm2 uuid;
  c1 bigint; c2 bigint;
  V bigint; R bigint; W bigint; K1 bigint; K2 bigint;
  p bigint; ped1 bigint; ped2 bigint; ped3 bigint; v_lote bigint; v_nc bigint;
  j jsonb; v_txt text; v_n bigint;
  v_f text[] := '{}';
  v_caso text;
  v_tiene_pila boolean := EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.promo_ajustes'::regclass
                                   AND attname = 'bloques_vivos' AND NOT attisdropped);
BEGIN
  SET LOCAL lock_timeout = '5s';
  SET CONSTRAINTS ALL IMMEDIATE;
  IF NOT EXISTS (SELECT 1 FROM public.sucursales WHERE id = v_suc AND activa)
     OR NOT EXISTS (SELECT 1 FROM public.sucursales WHERE id = v_suc2 AND activa) THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · hacen falta las sucursales 1 y 2 activas';
  END IF;
  v_adm  := pg_temp.b1_u('admin', v_suc);
  v_adm2 := pg_temp.b1_u('admin', v_suc2);
  c1 := pg_temp.b1_cli(v_suc, 'ZZ ensayo b1 C1');
  c2 := pg_temp.b1_cli(v_suc2, 'ZZ ensayo b1 C2');

  -- =======================================================================
  -- H1 · factor 6 → 4 con dos pedidos entregados, y dos salvedades del regalo
  -- =======================================================================
  BEGIN
    V := pg_temp.b1_prod(v_suc, 'V');
    R := pg_temp.b1_prod(v_suc, 'R', 600, 50);
    INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
    VALUES (R, v_suc, public._tablero_hoy() + 30, 50, 50, 'manual')
    RETURNING id INTO v_lote;
    p := pg_temp.b1_promo(v_suc, V, R, 10, 4, false, true, R, 6, 1);
    ped1 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    ped2 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    IF pg_temp.b1_lotes(R) <> 'stock=49 lote=49 bolsa=0' OR pg_temp.b1_up(p) <> 2 THEN
      v_f := v_f || format('H1 las dos altas no cerraron el bloque: %s up=%s', pg_temp.b1_lotes(R), pg_temp.b1_up(p));
    END IF;
    PERFORM pg_temp.b1_entregar(ped1);
    PERFORM pg_temp.b1_entregar(ped2);
    UPDATE promociones SET unidades_por_bloque = 4 WHERE id = p;

    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_regalo(ped1), 4);
    v_txt := format('%s up=%s', pg_temp.b1_lotes(R), pg_temp.b1_up(p));
    IF NOT COALESCE((j->>'success')::boolean, false) OR v_txt <> 'stock=49 lote=49 bolsa=0 up=0' THEN
      v_f := v_f || format('H1 la primera salvedad dejó %s (se esperaba stock=49 lote=49 bolsa=0 up=0; %s)', v_txt, j->>'error');
    END IF;
    j := pg_temp.b1_salv(v_adm, v_suc, ped2, pg_temp.b1_item_regalo(ped2), 4);
    v_txt := format('%s up=%s', pg_temp.b1_lotes(R), pg_temp.b1_up(p));
    IF NOT COALESCE((j->>'success')::boolean, false) OR v_txt <> 'stock=50 lote=50 bolsa=0 up=0' THEN
      v_f := v_f || format('H1 la segunda salvedad dejó %s (se esperaba stock=50 lote=50 bolsa=0 up=0; %s)', v_txt, j->>'error');
    END IF;
    IF pg_temp.b1_promo_a(p) > 0 THEN
      v_f := v_f || 'H1 PROMO-A en rojo para la promo'::text;
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_f := v_f || format('H1 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- H2 · el contenedor pasa de K1 a K2 con los pedidos entregados
  -- =======================================================================
  BEGIN
    V := pg_temp.b1_prod(v_suc, 'V');
    R := pg_temp.b1_prod(v_suc, 'R', 100, 50);
    K1 := pg_temp.b1_prod(v_suc, 'K1', 600, 50);
    K2 := pg_temp.b1_prod(v_suc, 'K2', 600, 50);
    p := pg_temp.b1_promo(v_suc, V, R, 10, 4, false, true, K1, 6, 1);
    ped1 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    ped2 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    PERFORM pg_temp.b1_entregar(ped1);
    PERFORM pg_temp.b1_entregar(ped2);
    UPDATE promociones SET ajuste_producto_id = K2 WHERE id = p;
    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_regalo(ped1), 4);
    j := pg_temp.b1_salv(v_adm, v_suc, ped2, pg_temp.b1_item_regalo(ped2), 4);
    v_txt := format('K1=%s K2=%s up=%s', (SELECT stock FROM productos WHERE id = K1),
                    (SELECT stock FROM productos WHERE id = K2), pg_temp.b1_up(p));
    IF v_txt <> 'K1=50 K2=50 up=0' OR pg_temp.b1_promo_a(p) > 0 THEN
      v_f := v_f || format('H2 el fardo no volvió al contenedor del que salió: %s (se esperaba K1=50 K2=50 up=0)', v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_f := v_f || format('H2 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- H3 · el factor sube de 4 a 6 con dos bloques cerrados
  -- =======================================================================
  BEGIN
    V := pg_temp.b1_prod(v_suc, 'V');
    R := pg_temp.b1_prod(v_suc, 'R', 600, 50);
    p := pg_temp.b1_promo(v_suc, V, R, 10, 4, false, true, R, 4, 1);
    ped1 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    ped2 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    PERFORM pg_temp.b1_entregar(ped1);
    PERFORM pg_temp.b1_entregar(ped2);
    UPDATE promociones SET unidades_por_bloque = 6 WHERE id = p;
    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_regalo(ped1), 4);
    v_txt := format('R=%s up=%s', (SELECT stock FROM productos WHERE id = R), pg_temp.b1_up(p));
    IF v_txt <> 'R=49 up=0' THEN
      v_f := v_f || format('H3 la primera salvedad dejó %s (se esperaba R=49 up=0)', v_txt);
    END IF;
    j := pg_temp.b1_salv(v_adm, v_suc, ped2, pg_temp.b1_item_regalo(ped2), 4);
    v_txt := format('R=%s up=%s', (SELECT stock FROM productos WHERE id = R), pg_temp.b1_up(p));
    IF v_txt <> 'R=50 up=0' OR pg_temp.b1_promo_a(p) > 0 THEN
      v_f := v_f || format('H3 la segunda salvedad dejó %s (se esperaba R=50 up=0)', v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_f := v_f || format('H3 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- H4 · el bloque de la renormalización anota su barra y su configuración
  -- =======================================================================
  BEGIN
    V := pg_temp.b1_prod(v_suc, 'V');
    R := pg_temp.b1_prod(v_suc, 'R', 600, 50);
    p := pg_temp.b1_promo(v_suc, V, R, 10, 2, false, true, R, 6, 1);
    ped1 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 2, p));
    ped2 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 2, p));
    PERFORM pg_temp.b1_entregar(ped1);
    PERFORM pg_temp.b1_entregar(ped2);
    -- La barra en 4: el factor 6 → 4 cierra un bloque de 4.
    UPDATE promociones SET unidades_por_bloque = 4 WHERE id = p;
    IF NOT v_tiene_pila THEN
      v_f := v_f || 'H4 promo_ajustes no anota los bloques (falta bloques_vivos)'::text;
    ELSE
      EXECUTE 'SELECT format(''%s/%s/%s/%s'', barra_regalo_id = $2, usos_por_bloque, stock_por_bloque, bloques_vivos)
                 FROM promo_ajustes WHERE promocion_id = $1 AND unidades_ajustadas = 1'
         INTO v_txt USING p, R;
      IF v_txt IS DISTINCT FROM 't/4/1/1' THEN
        v_f := v_f || format('H4 el bloque de la renormalización anotó %s (se esperaba t/4/1/1)', v_txt);
      END IF;
    END IF;
    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_regalo(ped1), 2);
    j := pg_temp.b1_salv(v_adm, v_suc, ped2, pg_temp.b1_item_regalo(ped2), 2);
    v_txt := format('R=%s up=%s', (SELECT stock FROM productos WHERE id = R), pg_temp.b1_up(p));
    IF v_txt <> 'R=50 up=0' OR pg_temp.b1_promo_a(p) > 0 THEN
      v_f := v_f || format('H4 deshacer el bloque de la renormalización dejó %s (se esperaba R=50 up=0)', v_txt);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_f := v_f || format('H4 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- H5 · un bloque sin anotar: la cuenta de hoy, con tope
  -- =======================================================================
  BEGIN
    V := pg_temp.b1_prod(v_suc, 'V');
    R := pg_temp.b1_prod(v_suc, 'R', 600, 50);
    p := pg_temp.b1_promo(v_suc, V, R, 10, 4, false, true, R, 6, 1);
    ped1 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    ped2 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    -- Como un bloque cerrado antes de la migración: sin la pila.
    IF v_tiene_pila THEN
      EXECUTE 'UPDATE promo_ajustes SET barra_regalo_id = NULL, usos_por_bloque = NULL, stock_por_bloque = NULL,
                      bloques_vivos = NULL WHERE promocion_id = $1' USING p;
    END IF;
    PERFORM pg_temp.b1_entregar(ped1);
    PERFORM pg_temp.b1_entregar(ped2);
    UPDATE promociones SET unidades_por_bloque = 4 WHERE id = p;
    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_regalo(ped1), 4);
    j := pg_temp.b1_salv(v_adm, v_suc, ped2, pg_temp.b1_item_regalo(ped2), 4);
    v_txt := format('R=%s up=%s', (SELECT stock FROM productos WHERE id = R), pg_temp.b1_up(p));
    IF v_txt <> 'R=50 up=0' OR pg_temp.b1_promo_a(p) > 0 THEN
      v_f := v_f || format('H5 sin la pila, las salvedades dejaron %s y PROMO-A=%s (se esperaba R=50 up=0 y 0)',
                           v_txt, pg_temp.b1_promo_a(p));
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_f := v_f || format('H5 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- H6 · factor 6 → 4 y contenedor K1 → K2, con K2 en 0
  -- =======================================================================
  BEGIN
    V := pg_temp.b1_prod(v_suc, 'V');
    R := pg_temp.b1_prod(v_suc, 'R', 100, 50);
    K1 := pg_temp.b1_prod(v_suc, 'K1', 600, 50);
    K2 := pg_temp.b1_prod(v_suc, 'K2', 600, 0);
    p := pg_temp.b1_promo(v_suc, V, R, 10, 4, false, true, K1, 6, 1);
    ped1 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    ped2 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    PERFORM pg_temp.b1_entregar(ped1);
    PERFORM pg_temp.b1_entregar(ped2);
    UPDATE promociones SET unidades_por_bloque = 4, ajuste_producto_id = K2 WHERE id = p;
    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_regalo(ped1), 4);
    v_txt := format('%s K1=%s K2=%s up=%s', COALESCE(j->>'success', '?'), (SELECT stock FROM productos WHERE id = K1),
                    (SELECT stock FROM productos WHERE id = K2), pg_temp.b1_up(p));
    IF v_txt <> 'true K1=50 K2=0 up=4' THEN
      v_f := v_f || format('H6 la primera salvedad dio %s (se esperaba true K1=50 K2=0 up=4; %s)', v_txt, j->>'error');
    END IF;
    j := pg_temp.b1_salv(v_adm, v_suc, ped2, pg_temp.b1_item_regalo(ped2), 4);
    v_txt := format('%s K1=%s K2=%s up=%s', COALESCE(j->>'success', '?'), (SELECT stock FROM productos WHERE id = K1),
                    (SELECT stock FROM productos WHERE id = K2), pg_temp.b1_up(p));
    IF v_txt <> 'true K1=50 K2=0 up=0' OR pg_temp.b1_promo_a(p) > 0 THEN
      v_f := v_f || format('H6 la segunda salvedad dio %s, PROMO-A=%s (se esperaba true K1=50 K2=0 up=0 y 0; %s)',
                           v_txt, pg_temp.b1_promo_a(p), j->>'error');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_f := v_f || format('H6 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- H7 · factor 6 → 4 y stock por bloque 1 → 2, con el contenedor en 0
  -- =======================================================================
  BEGIN
    V := pg_temp.b1_prod(v_suc, 'V');
    R := pg_temp.b1_prod(v_suc, 'R', 600, 1);
    p := pg_temp.b1_promo(v_suc, V, R, 10, 4, false, true, R, 6, 1);
    ped1 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    ped2 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 4, p));
    PERFORM pg_temp.b1_entregar(ped1);
    PERFORM pg_temp.b1_entregar(ped2);
    UPDATE promociones SET unidades_por_bloque = 4, stock_por_bloque = 2 WHERE id = p;
    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_regalo(ped1), 4);
    v_txt := format('%s R=%s up=%s', COALESCE(j->>'success', '?'), (SELECT stock FROM productos WHERE id = R), pg_temp.b1_up(p));
    IF v_txt <> 'true R=1 up=4' THEN
      v_f := v_f || format('H7 la primera salvedad dio %s (se esperaba true R=1 up=4; %s)', v_txt, j->>'error');
    END IF;
    j := pg_temp.b1_salv(v_adm, v_suc, ped2, pg_temp.b1_item_regalo(ped2), 4);
    v_txt := format('%s R=%s up=%s', COALESCE(j->>'success', '?'), (SELECT stock FROM productos WHERE id = R), pg_temp.b1_up(p));
    IF v_txt <> 'true R=1 up=0' OR pg_temp.b1_promo_a(p) > 0 THEN
      v_f := v_f || format('H7 la segunda salvedad dio %s (se esperaba true R=1 up=0; %s)', v_txt, j->>'error');
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_f := v_f || format('H7 · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- C · 1583-a · la salvedad sobre la venta baja el corte guardado
  -- =======================================================================
  FOREACH v_caso IN ARRAY ARRAY['C1', 'C3', 'C4', 'C5'] LOOP
    BEGIN
      V := pg_temp.b1_prod(v_suc, 'V', 100, 500);
      R := pg_temp.b1_prod(v_suc, 'R', 100, 500);
      W := pg_temp.b1_prod(v_suc, 'W', 1000, 50);
      p := pg_temp.b1_promo(v_suc, V, R, 1, 1, true, false, NULL, NULL, NULL,
                            CASE WHEN v_caso IN ('C3', 'C5') THEN 14 END);
      ped1 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, R, 10, p));
      j := pg_temp.b1_sust(v_adm, v_suc, pg_temp.b1_item_regalo(ped1), W, 1);
      IF NOT COALESCE((j->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'sustituir R×10 → W×1: %', j;
      END IF;
      j := pg_temp.b1_editar(ped1, v_adm, v_suc, pg_temp.b1_items(V, 14, R, 14, p));
      IF NOT COALESCE((j->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'editar a V×14: %', j;
      END IF;
      v_txt := (SELECT format('%s×%s corte %s', replace(pr.nombre, 'ZZ ensayo b1 ', ''), pi.cantidad, pi.regalo_corte)
                  FROM pedido_items pi JOIN productos pr ON pr.id = pi.producto_id
                 WHERE pi.pedido_id = ped1 AND pi.es_bonificacion);
      IF v_txt <> 'W×1 corte 14' THEN
        RAISE EXCEPTION 'la edición dejó %, y el ensayo pide W×1 corte 14', v_txt;
      END IF;
      PERFORM pg_temp.b1_entregar(ped1);

      IF v_caso = 'C4' THEN
        -- C4 · lo que le pasa _regalo_recorte con un exceso de 4.
        SELECT string_agg(format('%s→%s', x.cantidad, x.cantidad_final), ',') INTO v_txt
          FROM public._regalo_recorte(ped1, p, v_suc, 4) x;
        IF v_txt IS DISTINCT FROM '1→1' THEN
          v_f := v_f || format('C4 _regalo_recorte no devuelve la línea que sólo pierde corte: %s', COALESCE(v_txt, '(nada)'));
        ELSE
          EXECUTE 'SELECT string_agg(corte_final::text, '','') FROM public._regalo_recorte($1, $2, $3, 4)'
             INTO v_txt USING ped1, p, v_suc;
          IF v_txt IS DISTINCT FROM '10' THEN
            v_f := v_f || format('C4 _regalo_recorte dio corte_final %s (se esperaba 10)', v_txt);
          END IF;
        END IF;
        RAISE EXCEPTION USING ERRCODE = 'ZZ001';
      END IF;

      v_n := (SELECT stock FROM productos WHERE id = W);
      PERFORM pg_temp.b1_audit_atras();
      j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_venta(ped1), 4);
      v_nc := (j->>'salvedad_id')::bigint;
      v_txt := (SELECT format('W×%s corte %s', pi.cantidad, pi.regalo_corte)
                  FROM pedido_items pi WHERE pi.pedido_id = ped1 AND pi.es_bonificacion);
      IF NOT COALESCE((j->>'success')::boolean, false) OR v_txt IS DISTINCT FROM 'W×1 corte 10'
         OR (SELECT stock FROM productos WHERE id = W) <> v_n THEN
        v_f := v_f || format('%s la salvedad de 4 V dejó %s y W=%s (se esperaba W×1 corte 10 y W=%s; %s)', v_caso,
                             v_txt, (SELECT stock FROM productos WHERE id = W), v_n, j->>'error');
      END IF;

      IF v_caso = 'C1' THEN
        -- C2 · otra salvedad, de 6 V: la promo da 4.
        j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_venta(ped1), 6);
        v_txt := (SELECT format('W×%s corte %s', pi.cantidad, pi.regalo_corte)
                    FROM pedido_items pi WHERE pi.pedido_id = ped1 AND pi.es_bonificacion);
        IF NOT COALESCE((j->>'success')::boolean, false) OR v_txt IS DISTINCT FROM 'W×1 corte 4' THEN
          v_f := v_f || format('C2 la salvedad de 6 V dejó %s (se esperaba W×1 corte 4; %s)', v_txt, j->>'error');
        END IF;
      ELSIF v_caso = 'C5' THEN
        -- C5 · anular la salvedad que sólo bajó el corte se rechaza como un recorte.
        j := pg_temp.b1_anular(v_adm, v_suc, v_nc);
        v_txt := (SELECT format('V×%s W×%s corte %s',
                                (SELECT cantidad FROM pedido_items WHERE id = pg_temp.b1_item_venta(ped1)),
                                pi.cantidad, pi.regalo_corte)
                    FROM pedido_items pi WHERE pi.pedido_id = ped1 AND pi.es_bonificacion);
        IF COALESCE(j->>'codigo', '') <> 'anulacion_toca_promociones' OR v_txt IS DISTINCT FROM 'V×10 W×1 corte 10' THEN
          v_f := v_f || format('C5 anular la salvedad que bajó el corte dio %s y dejó %s (se esperaba el rechazo anulacion_toca_promociones y V×10 W×1 corte 10)',
                               j, v_txt);
        END IF;
        BEGIN
          ped2 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 4, R, 4, p));
          SET CONSTRAINTS ALL IMMEDIATE;
        EXCEPTION WHEN OTHERS THEN
          v_f := v_f || format('C5 con la anulación rechazada, otro pedido de R×4 no entra en el cupo de 14: %s', left(SQLERRM, 200));
        END;
      ELSE
        -- C3 · el cupo de 14 ya no cuenta los 4 que se rechazaron: entra otro R×4.
        BEGIN
          ped2 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 4, R, 4, p));
          SET CONSTRAINTS ALL IMMEDIATE;
        EXCEPTION WHEN OTHERS THEN
          v_f := v_f || format('C3 tras la salvedad de 4 V, otro pedido de R×4 no entra en el cupo de 14: %s', left(SQLERRM, 200));
        END;
      END IF;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
              WHEN OTHERS THEN v_f := v_f || format('%s · error: %s', v_caso, SQLERRM);
    END;
  END LOOP;

  -- =======================================================================
  -- B · 1595-b5 · en camino o entregado
  -- =======================================================================
  BEGIN
    V := pg_temp.b1_prod(v_suc, 'V');
    ped1 := pg_temp.b1_alta(c1, v_adm, v_suc, pg_temp.b1_items(V, 10, NULL, 0, NULL));
    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_venta(ped1), 1);
    IF COALESCE(j->>'codigo', '') <> 'pedido_sin_salir' THEN
      v_f := v_f || format('B sobre un pedido pendiente: %s', j);
    END IF;
    UPDATE pedidos SET estado = 'en_preparacion' WHERE id = ped1;
    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_venta(ped1), 1);
    IF COALESCE(j->>'codigo', '') <> 'pedido_sin_salir' THEN
      v_f := v_f || format('B sobre un pedido en preparación: %s', j);
    END IF;
    IF (SELECT cantidad FROM pedido_items WHERE id = pg_temp.b1_item_venta(ped1)) <> 10 THEN
      v_f := v_f || 'B la salvedad rechazada tocó la línea'::text;
    END IF;
    UPDATE pedidos SET estado = 'asignado' WHERE id = ped1;
    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_venta(ped1), 1);
    IF NOT COALESCE((j->>'success')::boolean, false) THEN
      v_f := v_f || format('B sobre un pedido en camino: %s', j);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_f := v_f || format('B · error: %s', SQLERRM);
  END;

  -- =======================================================================
  -- S · 1564-b2 · la NC de un pedido de otra sucursal
  -- =======================================================================
  BEGIN
    V := pg_temp.b1_prod(v_suc2, 'V');
    ped1 := pg_temp.b1_alta(c2, v_adm2, v_suc2, pg_temp.b1_items(V, 10, NULL, 0, NULL));
    PERFORM pg_temp.b1_entregar(ped1);
    INSERT INTO notas_credito_venta (sucursal_id, cliente_id, pedido_id, total, neto, iva)
    VALUES (v_suc2, c2, ped1, 100, 100, 0)
    RETURNING id INTO v_nc;
    -- El admin de la 1 (sin la 2) pregunta por el pedido de la 2.
    j := pg_temp.b1_salv(v_adm, v_suc, ped1, pg_temp.b1_item_venta(ped1), 1);
    IF COALESCE((j->>'success')::boolean, true) OR position('#' || v_nc IN COALESCE(j->>'error', '')) > 0
       OR COALESCE(j->>'codigo', '') <> 'pedido_no_encontrado' THEN
      v_f := v_f || format('S un admin de la 1 lee el pedido de la 2: %s', j);
    END IF;
    RAISE EXCEPTION USING ERRCODE = 'ZZ001';
  EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
            WHEN OTHERS THEN v_f := v_f || format('S · error: %s', SQLERRM);
  END;

  IF array_length(v_f, 1) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (%):\n%', array_length(v_f, 1), array_to_string(v_f, E'\n');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · regalos y salvedad de la ola 2 (#1603 B1): bloques con su configuración y recierre sin stock (H1-H7), corte guardado en la salvedad y su anulación (C1-C5), salvedad en camino o entregado (B) y la sucursal antes que la NC (S)';
END
$ensayo$;
