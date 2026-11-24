-- Ensayo de la tarjeta A de la tanda 6 del plan #1603 (reauditoría del núcleo del 24/11):
-- compras y costos. Migración: 541_compras_promedio_huella_y_avisos.
--
-- Un único DO con datos propios que termina SIEMPRE en una excepción: no deja rastro (salvo
-- valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista. Sin la
-- migración fallan CMP1, B1, B4, B5 y STK1; REG (regresión) pasa igual.
--
--   CMP1 · CMP-1 (medio): producto con 20 u. a 6; A: 100 u. a 10; B: el producto en dos
--          renglones (variante 1: 40 a 12 y 60 a 18; variante 2: 100 a 20 y 20 de regalo).
--          NC de 30 sobre B, NC de 40 sobre A (su arrastre pasa por B con la NC vigente),
--          anular la de B y anular la de A: la historia vuelve a ser la del principio y el
--          promedio vuelve exacto (12,1818 y 13,0000; antes 12,1684 y 12,9869).
--   B1   · compras-CMP-b1: editar una FC A cuya cabecera suma 1.210 con total 910 devuelve
--          warning_descuadre (antes, nada); con 1.210, sin aviso.
--   B4   · compras-CMP-b4: FC A de 3 u. con II de 200 en la cabecera y tres devoluciones de
--          1: el II de las notas suma 200 (antes 200,01). Anular la tercera y volver a
--          devolver 1 sigue en 200.
--   B5   · gestion-B5: el alta con p_items '[]' o NULL se rechaza con su motivo (antes
--          quedaba una compra sin renglones); la edición mandada vacía, también, y la
--          compra conserva sus renglones.
--   STK1 · stock-STK-1: lote manual Lm (vence en 60 días, 100 con 40) y bolsa 20; una ZZ de
--          100 con su lote Lc (vence en 5) y una venta de 50 (20 de la bolsa y 30 de Lc).
--          Anular la compra pasa la huella a Lm (30) y cancelar la venta deja lo de antes de
--          la compra: Lm 40 y bolsa 20 (antes Lm 10 y bolsa 50). Variante con 15 u. más en la
--          bolsa antes de anular: la bajada saca sólo 15 de Lm, la huella pasa 15 y cancelar
--          deja Lm 40 y bolsa 35. Sin checks en rojo en auditoria_integridad().
--   REG  · Regresión: una compra de un renglón por producto con NC y su anulación, y la
--          edición de una ZZ que cuadra, siguen igual (promedio de vuelta y sin aviso).
--
--   docker exec -i <contenedor> psql -U postgres -h localhost -d postgres -f - < scripts/test-compras-tanda6-1603.sql

DO $ensayo$
DECLARE
  v_adm    uuid;
  v_fallas text[] := '{}';
  v_notas  text[] := '{}';
BEGIN
 BEGIN
  SET LOCAL lock_timeout = '5s';

  -- ---------------------------------------------------------------- helpers -
  CREATE FUNCTION pg_temp.u(p_rol text, p_suc bigint) RETURNS uuid LANGUAGE plpgsql AS $f$
  DECLARE v uuid := gen_random_uuid();
  BEGIN
    INSERT INTO auth.users (id, instance_id, aud, role, email, raw_app_meta_data, raw_user_meta_data, created_at, updated_at)
    VALUES (v, '00000000-0000-0000-0000-000000000000', 'authenticated', 'authenticated', 't6a-' || v || '@ensayo.invalid',
            jsonb_build_object('rol', p_rol, 'sucursal_id', p_suc), jsonb_build_object('nombre', 'T6A ' || p_rol), now(), now());
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.jwt.claim.sub', p_uid::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;
  -- cada RPC real es su propia transacción: los GUC de stock no pasan de una a otra
  CREATE FUNCTION pg_temp.limpiar() RETURNS void LANGUAGE sql AS $f$
    SELECT set_config('app.stock_origen', '', true), set_config('app.stock_ref_tipo', '', true),
           set_config('app.stock_ref_id', '', true), set_config('app.stock_user_id', '', true),
           set_config('app.stock_pedido_item_id', '', true), set_config('app.regalo_corte_manual', '', true),
           set_config('app.cambio_cliente_desde', '', true), set_config('app.omitir_minimo_venta', '', true);
  $f$;
  -- reloj: cada compra, un minuto después de la anterior (su lugar en la cadena)
  PERFORM set_config('t6a.t', '0', true);
  CREATE FUNCTION pg_temp.reloj() RETURNS timestamptz LANGUAGE plpgsql AS $f$
  DECLARE n int := current_setting('t6a.t')::int + 1;
  BEGIN
    PERFORM set_config('t6a.t', n::text, true);
    RETURN date_trunc('minute', now()) - interval '2 days' + n * interval '1 minute';
  END $f$;
  CREATE FUNCTION pg_temp.producto(p_nombre text, p_stock int, p_cpp numeric) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES ('T6A ' || p_nombre || ' ' || gen_random_uuid(), 1000, p_stock, p_cpp, p_cpp, p_cpp, p_cpp, 1) RETURNING id;
  $f$;
  -- renglones: ZZ sin impuestos por defecto; lo que traiga cada renglón pisa el default
  CREATE FUNCTION pg_temp.lineas(p_items jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(x || jsonb_build_object('subtotal',
             round((x->>'cantidad')::numeric * (x->>'costo_unitario')::numeric * (1 - (x->>'bonificacion')::numeric / 100), 2))
             ORDER BY o)
      FROM (SELECT jsonb_build_object('bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0) || e AS x, o
              FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o)) s;
  $f$;
  -- el alta: devuelve la respuesta entera
  CREATE FUNCTION pg_temp.alta(p_adm uuid, p_lin jsonb, p_tipo text, p_iva numeric, p_ii numeric, p_total numeric,
                               p_letra text DEFAULT NULL) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    v := public.registrar_compra_completa(
      NULL, 'T6A', 'T6A-' || left(gen_random_uuid()::text, 8), public._tablero_hoy(),
      COALESCE((SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_lin) e), 0), p_iva, 0, p_total,
      'efectivo', 't6a', p_adm, p_lin, p_tipo, p_impuestos_internos => p_ii, p_cargos => '[]'::jsonb,
      p_bonificaciones => 0, p_letra_comprobante => p_letra);
    PERFORM pg_temp.limpiar();
    RETURN v;
  END $f$;
  -- una compra que tiene que entrar, con su lugar en la cadena
  CREATE FUNCTION pg_temp.compra(p_adm uuid, p_items jsonb, p_tipo text DEFAULT 'ZZ', p_iva numeric DEFAULT 0,
                                 p_ii numeric DEFAULT 0, p_letra text DEFAULT NULL) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_lin jsonb := pg_temp.lineas(p_items); v jsonb; v_id bigint; v_ts timestamptz := pg_temp.reloj();
  BEGIN
    v := pg_temp.alta(p_adm, v_lin, p_tipo, p_iva, p_ii,
                      (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(v_lin) e) + p_iva + p_ii, p_letra);
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la compra no se registró: %', v;
    END IF;
    v_id := (v->>'compra_id')::bigint;
    UPDATE public.compra_items SET created_at = v_ts WHERE compra_id = v_id;
    UPDATE public.compras SET created_at = v_ts WHERE id = v_id;
    RETURN v_id;
  END $f$;
  CREATE FUNCTION pg_temp.editar(p_adm uuid, p_c bigint, p_lin jsonb, p_iva numeric, p_total numeric) RETURNS jsonb
  LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    v := public.actualizar_compra_items(
      p_c, p_lin, COALESCE((SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(p_lin) e), 0), p_iva, p_total, p_adm,
      p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb,
      p_renglones_vistos => (SELECT COALESCE(array_agg(id), '{}') FROM public.compra_items WHERE compra_id = p_c));
    PERFORM pg_temp.limpiar();
    RETURN v;
  END $f$;
  -- una devolución de p_cant u. de un producto, con el costo neto promedio de la factura
  CREATE FUNCTION pg_temp.nc(p_adm uuid, p_c bigint, p_prod bigint, p_cant int, p_iva numeric DEFAULT 0) RETURNS jsonb
  LANGUAGE plpgsql AS $f$
  DECLARE
    v_costo numeric := (SELECT sum(cantidad * costo_unitario * (1 - COALESCE(bonificacion, 0) / 100)) / sum(cantidad)
                          FROM public.compra_items WHERE compra_id = p_c AND producto_id = p_prod);
    v_sub   numeric := round(p_cant * v_costo, 2);
    v       jsonb;
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    v := public.registrar_nota_credito(p_c, 'T6A-' || left(gen_random_uuid()::text, 8), 'devolución t6a',
           v_sub, round(v_sub * p_iva / 100, 2), v_sub + round(v_sub * p_iva / 100, 2), p_adm,
           jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'subtotal', v_sub)), NULL);
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la NC no entró: %', v;
    END IF;
    RETURN v;
  END $f$;
  CREATE FUNCTION pg_temp.anular_nc(p_adm uuid, p_nota bigint) RETURNS void LANGUAGE plpgsql AS $f$
  DECLARE v jsonb;
  BEGIN
    PERFORM pg_temp.como(p_adm, 1);
    v := public.anular_nota_credito_compra(p_nota, 'ensayo t6a');
    PERFORM pg_temp.limpiar();
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la anulación de la NC no entró: %', v;
    END IF;
  END $f$;
  CREATE FUNCTION pg_temp.cpp(p bigint) RETURNS numeric LANGUAGE sql AS $f$
    SELECT round(costo_promedio, 4) FROM public.productos WHERE id = p;
  $f$;
  -- stock, lotes (restante por vencimiento), bolsa y huella por lote del producto
  CREATE FUNCTION pg_temp.ff(p bigint) RETURNS text LANGUAGE sql AS $f$
    SELECT format('stock=%s lotes=[%s] bolsa=%s huella=[%s]', pr.stock,
      COALESCE((SELECT string_agg(l.cantidad_restante::text, ',' ORDER BY l.fecha_vencimiento, l.id)
                  FROM public.producto_lotes l WHERE l.producto_id = p), ''),
      pr.stock - COALESCE((SELECT sum(l.cantidad_restante) FROM public.producto_lotes l WHERE l.producto_id = p), 0),
      COALESCE((SELECT string_agg(x.c::text, ',' ORDER BY x.fv, x.lote_id)
                  FROM (SELECT pil.lote_id, l.fecha_vencimiento AS fv, sum(pil.cantidad) AS c
                          FROM public.pedido_item_lotes pil JOIN public.producto_lotes l ON l.id = pil.lote_id
                         WHERE l.producto_id = p GROUP BY 1, 2) x), ''))
      FROM public.productos pr WHERE pr.id = p;
  $f$;
  CREATE FUNCTION pg_temp.lote(p bigint, p_dias int, p_cant int, p_rest int) RETURNS void LANGUAGE sql AS $f$
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, origen)
    VALUES (p, 1, public._tablero_hoy() + p_dias, p_cant, p_rest, 'manual');
  $f$;

  -- ---------------------------------------------------------------- datos ---
  v_adm := pg_temp.u('admin', 1);

  -- ================================================================ CMP1 ====
  DECLARE
    v_i int; v_p bigint; v_a bigint; v_b bigint; v_na bigint; v_nb bigint; v_c1 numeric; v_c5 numeric;
  BEGIN
    FOR v_i IN 1..2 LOOP
      v_p := pg_temp.producto('CMP1-' || v_i, 20, 6);
      v_a := pg_temp.compra(v_adm, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 100, 'costo_unitario', 10)));
      v_b := pg_temp.compra(v_adm, CASE WHEN v_i = 1 THEN jsonb_build_array(
               jsonb_build_object('producto_id', v_p, 'cantidad', 40, 'costo_unitario', 12),
               jsonb_build_object('producto_id', v_p, 'cantidad', 60, 'costo_unitario', 18))
             ELSE jsonb_build_array(
               jsonb_build_object('producto_id', v_p, 'cantidad', 100, 'costo_unitario', 20),
               jsonb_build_object('producto_id', v_p, 'cantidad', 20, 'costo_unitario', 20, 'bonificacion', 100)) END);
      v_c1 := pg_temp.cpp(v_p);
      v_nb := (pg_temp.nc(v_adm, v_b, v_p, 30)->>'nota_credito_id')::bigint;
      v_na := (pg_temp.nc(v_adm, v_a, v_p, 40)->>'nota_credito_id')::bigint;
      PERFORM pg_temp.anular_nc(v_adm, v_nb);
      PERFORM pg_temp.anular_nc(v_adm, v_na);
      v_c5 := pg_temp.cpp(v_p);
      v_notas := v_notas || format('CMP1 variante %s: al principio %s, anuladas las dos notas %s', v_i, v_c1, v_c5);
      IF v_c1 IS DISTINCT FROM (CASE v_i WHEN 1 THEN 12.1818 ELSE 13.0000 END) THEN
        v_fallas := v_fallas || format('CMP1 · variante %s: el promedio del principio tenía que ser %s y dio %s',
                                       v_i, CASE v_i WHEN 1 THEN '12,1818' ELSE '13,0000' END, v_c1);
      END IF;
      IF v_c5 IS DISTINCT FROM v_c1 THEN
        v_fallas := v_fallas || format('CMP1 · variante %s: anuladas las dos notas el promedio tenía que volver a %s y quedó en %s',
                                       v_i, v_c1, v_c5);
      END IF;
    END LOOP;
  END;

  -- ================================================================== B1 ====
  DECLARE
    v_p bigint := pg_temp.producto('B1', 0, NULL);
    v_c bigint; v_j jsonb;
    v_lin jsonb;
  BEGIN
    v_lin := pg_temp.lineas(jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100,
               'porcentaje_iva', 21, 'condicion_iva', 'gravado')));
    v_c := pg_temp.compra(v_adm, v_lin, 'FC', 210, 0, 'A');
    v_j := pg_temp.editar(v_adm, v_c, v_lin, 210, 910);
    IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
      v_fallas := v_fallas || format('B1 · la edición con total 910 tenía que guardarse (el aviso es blando): %s', v_j);
    ELSIF v_j->>'warning_descuadre' IS NULL OR position('1210' IN v_j->>'warning_descuadre') = 0
          OR position('910' IN v_j->>'warning_descuadre') = 0 THEN
      v_fallas := v_fallas || format('B1 · la edición de una FC que suma 1.210 con total 910 tenía que avisar el descuadre: %s',
                                     COALESCE(v_j->>'warning_descuadre', 'sin aviso'));
    ELSE
      v_notas := v_notas || ('B1 · ' || (v_j->>'warning_descuadre'));
    END IF;
    v_j := pg_temp.editar(v_adm, v_c, v_lin, 210, 1210);
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR v_j->>'warning_descuadre' IS NOT NULL THEN
      v_fallas := v_fallas || format('B1 · la edición que cuadra (1.210) no tenía que avisar: %s', v_j);
    END IF;
  END;

  -- ================================================================== B4 ====
  DECLARE
    v_p bigint := pg_temp.producto('B4', 0, NULL);
    v_c bigint; v_j jsonb; v_ii numeric[] := '{}'; v_suma numeric; v_n3 bigint; k int;
  BEGIN
    v_c := pg_temp.compra(v_adm, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 3, 'costo_unitario', 100,
             'porcentaje_iva', 21, 'condicion_iva', 'gravado')), 'FC', 63, 200, 'A');
    FOR k IN 1..3 LOOP
      v_j := pg_temp.nc(v_adm, v_c, v_p, 1, 21);
      v_ii := v_ii || (v_j->>'impuestos_internos')::numeric;
      v_n3 := (v_j->>'nota_credito_id')::bigint;
    END LOOP;
    SELECT sum(impuestos_internos) INTO v_suma FROM public.notas_credito WHERE compra_id = v_c AND NOT anulada;
    v_notas := v_notas || format('B4 · II de las tres notas: %s (suma %s)', v_ii, v_suma);
    IF v_suma IS DISTINCT FROM 200.00 THEN
      v_fallas := v_fallas || format('B4 · tres devoluciones de 1 de una compra con II 200 sobre 3 u. tenían que acreditar 200 de II y acreditaron %s (%s)',
                                     v_suma, v_ii);
    END IF;
    PERFORM pg_temp.anular_nc(v_adm, v_n3);
    v_j := pg_temp.nc(v_adm, v_c, v_p, 1, 21);
    SELECT sum(impuestos_internos) INTO v_suma FROM public.notas_credito WHERE compra_id = v_c AND NOT anulada;
    IF v_suma IS DISTINCT FROM 200.00 THEN
      v_fallas := v_fallas || format('B4 · anulada la tercera y devuelta otra vez, el II de las notas vigentes tenía que seguir en 200 y es %s', v_suma);
    END IF;
  END;

  -- ================================================================== B5 ====
  DECLARE
    v_p bigint := pg_temp.producto('B5', 0, NULL);
    v_c bigint; v_j jsonb; v_n int;
  BEGIN
    v_j := pg_temp.alta(v_adm, '[]'::jsonb, 'ZZ', 0, 0, 0);
    IF COALESCE((v_j->>'success')::boolean, false) OR position('renglones' IN COALESCE(v_j->>'error', '')) = 0 THEN
      v_fallas := v_fallas || format('B5 · el alta sin renglones tenía que rechazarse con su motivo: %s', v_j);
    END IF;
    v_j := pg_temp.alta(v_adm, NULL, 'FC', 0, 0, 0, 'A');
    IF COALESCE((v_j->>'success')::boolean, false) OR position('renglones' IN COALESCE(v_j->>'error', '')) = 0 THEN
      v_fallas := v_fallas || format('B5 · el alta con p_items NULL tenía que rechazarse con su motivo: %s', v_j);
    END IF;
    v_c := pg_temp.compra(v_adm, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'costo_unitario', 100)));
    v_j := pg_temp.editar(v_adm, v_c, '[]'::jsonb, 0, 0);
    SELECT count(*) INTO v_n FROM public.compra_items WHERE compra_id = v_c;
    IF COALESCE((v_j->>'success')::boolean, false) OR v_n <> 1 OR position('renglón' IN COALESCE(v_j->>'error', '')) = 0 THEN
      v_fallas := v_fallas || format('B5 · la edición mandada vacía tenía que rechazarse y la compra quedar con su renglón (%s): %s', v_n, v_j);
    END IF;
  END;

  -- ================================================================ STK1 ====
  DECLARE
    v_cli bigint; v_p bigint; v_c bigint; v_ped bigint; v_j jsonb; k int;
    v_tras_anular text; v_fin text; v_esp_anular text; v_esp_fin text;
  BEGIN
    INSERT INTO public.clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
    VALUES ('T6A cliente', 'T6A cliente', 'calle falsa 1', 1) RETURNING id INTO v_cli;
    FOR k IN 1..2 LOOP
      v_p := pg_temp.producto('STK1-' || k, 60, 60);
      PERFORM pg_temp.lote(v_p, 60, 100, 40);  -- Lm 40 y bolsa 20
      v_c := pg_temp.compra(v_adm, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 100, 'costo_unitario', 10)));
      PERFORM pg_temp.como(v_adm, 1);
      v_j := public.sincronizar_lotes_compra(v_c, jsonb_build_array(jsonb_build_object(
               'producto_id', v_p, 'fecha_vencimiento', public._tablero_hoy() + 5, 'cantidad', 100)));
      PERFORM pg_temp.limpiar();
      v_j := public.crear_pedido_completo(v_cli, 5000, v_adm,
               jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 50, 'precio_unitario', 100)), 'ensayo t6a');
      PERFORM pg_temp.limpiar();
      IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'STK1: el pedido no entró: %', v_j;
      END IF;
      v_ped := (v_j->>'pedido_id')::bigint;
      IF pg_temp.ff(v_p) <> 'stock=110 lotes=[70,40] bolsa=0 huella=[30]' THEN
        RAISE EXCEPTION 'STK1: la venta no salió como se esperaba: %', pg_temp.ff(v_p);
      END IF;
      IF k = 2 THEN
        -- 15 u. más en la bolsa (otra compra, sin vencimientos) antes de anular
        PERFORM pg_temp.compra(v_adm, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 15, 'costo_unitario', 10)));
      END IF;
      PERFORM pg_temp.como(v_adm, 1);
      v_j := public.anular_compra_atomica(v_c, v_adm);
      PERFORM pg_temp.limpiar();
      IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'STK1: la anulación no entró: %', v_j;
      END IF;
      v_tras_anular := pg_temp.ff(v_p);
      PERFORM pg_temp.como(v_adm, 1);
      v_j := public.cancelar_pedido_con_stock(v_ped, 'ensayo t6a', v_adm, NULL);
      PERFORM pg_temp.limpiar();
      IF NOT COALESCE((v_j->>'success')::boolean, false) THEN
        RAISE EXCEPTION 'STK1: la cancelación no entró: %', v_j;
      END IF;
      v_fin := pg_temp.ff(v_p);
      v_esp_anular := CASE k WHEN 1 THEN 'stock=10 lotes=[10] bolsa=0 huella=[30]' ELSE 'stock=25 lotes=[25] bolsa=0 huella=[15]' END;
      v_esp_fin    := CASE k WHEN 1 THEN 'stock=60 lotes=[40] bolsa=20 huella=[]' ELSE 'stock=75 lotes=[40] bolsa=35 huella=[]' END;
      v_notas := v_notas || format('STK1 variante %s: anulada la compra %s; cancelada la venta %s', k, v_tras_anular, v_fin);
      IF v_tras_anular <> v_esp_anular THEN
        v_fallas := v_fallas || format('STK1 · variante %s: anulada la compra tenía que quedar «%s» (la huella pasa al lote manual) y quedó «%s»',
                                       k, v_esp_anular, v_tras_anular);
      END IF;
      IF v_fin <> v_esp_fin THEN
        v_fallas := v_fallas || format('STK1 · variante %s: cancelada la venta tenía que quedar «%s» (lo de antes de la compra) y quedó «%s»',
                                       k, v_esp_fin, v_fin);
      END IF;
    END LOOP;
  END;

  -- ================================================================= REG ====
  DECLARE
    v_p bigint := pg_temp.producto('REG', 20, 6);
    v_a bigint; v_b bigint; v_n bigint; v_c1 numeric; v_j jsonb; v_lin jsonb;
  BEGIN
    v_a := pg_temp.compra(v_adm, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 100, 'costo_unitario', 10)));
    v_lin := pg_temp.lineas(jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 50, 'costo_unitario', 30)));
    v_b := pg_temp.compra(v_adm, v_lin);
    v_c1 := pg_temp.cpp(v_p);
    v_n := (pg_temp.nc(v_adm, v_a, v_p, 40)->>'nota_credito_id')::bigint;
    PERFORM pg_temp.anular_nc(v_adm, v_n);
    IF pg_temp.cpp(v_p) IS DISTINCT FROM v_c1 THEN
      v_fallas := v_fallas || format('REG · una NC anulada sobre una compra de un renglón tenía que dejar el promedio en %s y quedó %s',
                                     v_c1, pg_temp.cpp(v_p));
    END IF;
    v_j := pg_temp.editar(v_adm, v_b, v_lin, 0, 1500);
    IF NOT COALESCE((v_j->>'success')::boolean, false) OR v_j->>'warning_descuadre' IS NOT NULL
       OR pg_temp.cpp(v_p) IS DISTINCT FROM v_c1 THEN
      v_fallas := v_fallas || format('REG · la edición sin cambios de una ZZ que cuadra no tenía que avisar ni mover el promedio (%s → %s): %s',
                                     v_c1, pg_temp.cpp(v_p), v_j);
    END IF;
  END;

  SET CONSTRAINTS ALL IMMEDIATE;
  v_notas := v_notas || ('checks en rojo: ' || COALESCE((SELECT string_agg((c->>'id') || '=' || (c->>'violaciones'), ', ')
       FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE NOT (c->>'ok')::boolean), 'ninguno'));
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c WHERE NOT (c->>'ok')::boolean) THEN
    v_fallas := v_fallas || 'auditoria_integridad() tiene checks en rojo con los datos del ensayo (ver notas)'::text;
  END IF;

  RAISE EXCEPTION USING ERRCODE = 'ZZ001';
 EXCEPTION WHEN SQLSTATE 'ZZ001' THEN NULL;
 END;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION USING ERRCODE = 'ZZ0FA', MESSAGE = format(E'ENSAYO FALLÓ (%s fallas, todo revertido):\n- %s\nnotas:\n  %s',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, E'\n  '));
  END IF;
  RAISE EXCEPTION USING ERRCODE = 'ZZ0OK', MESSAGE = format(E'ENSAYO OK (todo revertido) · CMP1 B1 B4 B5 STK1 REG\nnotas:\n  %s',
    array_to_string(v_notas, E'\n  '));
END
$ensayo$;
