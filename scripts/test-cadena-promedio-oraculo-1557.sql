-- Ensayo: el oráculo del costo promedio. Una cadena de 18 pasos sobre un producto (compras, un envío,
-- salidas, NC, ediciones, un regalo, la anulación de una compra del medio y el cambio de proveedor)
-- comparada después de cada paso contra un recálculo desde cero que no mira ninguna foto.
--
-- Es el escenario C1 de la reauditoría completa del 12/11 (#1557, "salió limpio"), que la tarjeta 3
-- de #1565 deja como ensayo. Dos cosas cambian con su migración, y van adaptadas acá:
--   · el paso 13 era un renglón a costo 0 sin bonificación, que desde #1557 (CMP-5) se rechaza: va
--     como el regalo legal, a costo 0 con bonificación del 100 % (para el promedio es lo mismo: no
--     fija costo y diluye);
--   · la edición manda los renglones vistos (FRG-4).
-- El oráculo es `pg_temp.oraculo`: las compras no canceladas (cada renglón con lo que le queda
-- después de sus NC, en proporción), los envíos aceptados con costo y las salidas simuladas, en el
-- orden de la cadena, con `_cpp_linea`.
--
-- Pide un admin activo de la sucursal 1 y la sucursal 2 (el envío sale de la 2). Un único DO que
-- termina SIEMPRE en una excepción, sin dejar rastro (salvo valores de secuencia).
-- Veredicto: 'ENSAYO OK' con la tabla de los 18 pasos, o 'ENSAYO FALLÓ' con la tabla.
--
--   psql "$DATABASE_URL" -f scripts/test-cadena-promedio-oraculo-1557.sql

DO $aud$
DECLARE v_ua uuid; v_p bigint; v_q bigint; v_a bigint; v_b bigint; v_c bigint; v_d bigint; v_e bigint; v_f bigint;
  v_j jsonb; v_t text := ''; v_n numeric; v_x text; v_u2 uuid; v_r record;
BEGIN
  SET LOCAL lock_timeout = '5s';
  SELECT us.usuario_id INTO v_ua
    FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id AND p.activo AND p.rol = 'admin'
   WHERE us.sucursal_id = 1 ORDER BY us.usuario_id LIMIT 1;
  IF v_ua IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · no hay un admin activo de la sucursal 1';
  END IF;
  PERFORM set_config('aud.ua', v_ua::text, true);
  PERFORM set_config('aud.t', '0', true);
  CREATE TEMP TABLE aud_salidas (producto_id bigint, ts timestamptz, qty int) ON COMMIT DROP;

  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;

  -- reloj: cada evento, un minuto despues del anterior, arrancando hace 2 dias
  CREATE FUNCTION pg_temp.reloj() RETURNS timestamptz LANGUAGE plpgsql AS $f$
  DECLARE n int := current_setting('aud.t')::int + 1;
  BEGIN
    PERFORM set_config('aud.t', n::text, true);
    RETURN date_trunc('minute', now()) - interval '2 days' + n * interval '1 minute';
  END $f$;

  CREATE FUNCTION pg_temp.producto(p_suc bigint, p_nombre text, p_stock int, p_cpp numeric)
  RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real,
                                  costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES (p_nombre, 100, p_stock, p_cpp, p_cpp, p_cpp, p_cpp, p_suc) RETURNING id;
  $f$;

  CREATE FUNCTION pg_temp.ok(p_que text, v jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    IF NOT COALESCE((v->>'success')::boolean, (v->>'ok')::boolean, false) THEN
      RAISE EXCEPTION '% no paso: %', p_que, v;
    END IF;
    RETURN v;
  END $f$;

  -- renglones: defaults ZZ sin impuestos; lo que traiga cada renglon pisa el default
  CREATE FUNCTION pg_temp.lineas(p_items jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(x || jsonb_build_object('subtotal',
             round((x->>'cantidad')::numeric * (x->>'costo_unitario')::numeric
                   * (1 - (x->>'bonificacion')::numeric / 100), 2)) ORDER BY o)
      FROM (SELECT jsonb_build_object('bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0) || e AS x, o
              FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o)) s;
  $f$;

  CREATE FUNCTION pg_temp.hora_compra(p_compra bigint, p_ts timestamptz) RETURNS void LANGUAGE sql AS $f$
    UPDATE public.compra_items SET created_at = p_ts WHERE compra_id = p_compra;
    UPDATE public.compras SET created_at = p_ts WHERE id = p_compra;
  $f$;

  CREATE FUNCTION pg_temp.comprar(p_ref text, p_items jsonb, p_tipo text DEFAULT 'ZZ', p_letra text DEFAULT NULL,
                                  p_fecha date DEFAULT NULL)
  RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_lin jsonb := pg_temp.lineas(p_items);
    v_sub numeric := (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(v_lin) e);
    v_r   jsonb;
    v_id  bigint;
  BEGIN
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 1);
    v_r := public.registrar_compra_completa(
      NULL, 'AUD CMP', 'AUD-CMP-' || p_ref, COALESCE(p_fecha, public._tablero_hoy()),
      v_sub, 0, 0, v_sub, 'efectivo', 'aud', current_setting('aud.ua')::uuid, v_lin, p_tipo,
      p_letra_comprobante => p_letra);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la compra % no se registro: %', p_ref, v_r;
    END IF;
    v_id := (v_r->>'compra_id')::bigint;
    PERFORM pg_temp.hora_compra(v_id, pg_temp.reloj());
    RETURN v_id;
  END $f$;

  CREATE FUNCTION pg_temp.editar(p_compra bigint, p_items jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_lin jsonb := pg_temp.lineas(p_items);
    v_sub numeric := (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(v_lin) e);
  BEGIN
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 1);
    RETURN pg_temp.ok('editar', public.actualizar_compra_items(
      p_compra, v_lin, v_sub, 0, v_sub, current_setting('aud.ua')::uuid,
      p_cargos => '[]'::jsonb, p_ii_declarado => '{}'::jsonb,
      p_renglones_vistos => (SELECT array_agg(id) FROM public.compra_items WHERE compra_id = p_compra)));
  END $f$;

  CREATE FUNCTION pg_temp.nc(p_compra bigint, p_prod bigint, p_cant int) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_costo numeric := (SELECT sum(cantidad * costo_unitario * (1 - COALESCE(bonificacion,0)/100)) / sum(cantidad)
                          FROM public.compra_items WHERE compra_id = p_compra AND producto_id = p_prod);
    v_sub   numeric := round(p_cant * v_costo, 2);
  BEGIN
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 1);
    RETURN pg_temp.ok('la NC', public.registrar_nota_credito(
      p_compra, 'NC-AUD-' || p_compra || '-' || p_cant, 'aud', v_sub, 0, v_sub,
      current_setting('aud.ua')::uuid,
      jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'subtotal', v_sub)), 0));
  END $f$;

  CREATE FUNCTION pg_temp.anular(p_compra bigint) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 1);
    RETURN pg_temp.ok('anular', public.anular_compra_atomica(p_compra, current_setting('aud.ua')::uuid));
  END $f$;

  CREATE FUNCTION pg_temp.cambiar_prov(p_compra bigint) RETURNS bigint LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 1);
    RETURN (pg_temp.ok('cambiar proveedor', public.cambiar_proveedor_compra(
      p_compra, current_setting('aud.ua')::uuid, NULL, 'OTRO PROV AUD', 'aud'))->>'nueva_compra_id')::bigint;
  END $f$;

  -- una venta simulada: baja stock sin tocar el promedio
  CREATE FUNCTION pg_temp.salida(p_prod bigint, p_cant int) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('app.stock_origen', 'ajuste_manual', true);
    PERFORM set_config('app.stock_ref_tipo', '', true);
    PERFORM set_config('app.stock_ref_id', '', true);
    UPDATE public.productos SET stock = stock - p_cant WHERE id = p_prod;
    INSERT INTO aud_salidas VALUES (p_prod, pg_temp.reloj(), p_cant);
  END $f$;

  -- un envio aceptado en la sucursal 1 sobre p_dest, desde un producto nuevo de la 2 a costo p_cpp
  CREATE FUNCTION pg_temp.ingreso(p_dest bigint, p_cant int, p_cpp numeric) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE
    v_o    bigint := pg_temp.producto(2, 'AUD origen ' || p_dest || ' ' || gen_random_uuid(), p_cant, p_cpp);
    v_mov  bigint;
    v_item bigint;
    v      jsonb;
  BEGIN
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 2);
    v := public.crear_movimiento_sucursal(1, 'aud',
           jsonb_build_array(jsonb_build_object('producto_id', v_o, 'cantidad', p_cant)));
    IF NOT COALESCE((v->>'success')::boolean, false) THEN RAISE EXCEPTION 'envio: %', v; END IF;
    v_mov := (v->>'movimiento_id')::bigint;
    SELECT id INTO v_item FROM public.movimiento_sucursal_items WHERE movimiento_id = v_mov;
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 1);
    PERFORM pg_temp.ok('aceptar', public.aceptar_movimiento_sucursal(v_mov, jsonb_build_array(jsonb_build_object(
      'item_id', v_item, 'accion', 'match_existente', 'producto_destino_id', p_dest))));
    UPDATE public.movimientos_sucursal SET resuelto_at = pg_temp.reloj() WHERE id = v_mov;
    RETURN v_item;
  END $f$;

  CREATE FUNCTION pg_temp.cpp(p_prod bigint) RETURNS numeric LANGUAGE sql AS $f$
    SELECT round(costo_promedio, 4) FROM public.productos WHERE id = p_prod;
  $f$;

  -- EL ORACULO: el promedio recalculado desde cero con lo que quedo, sin mirar ninguna foto.
  -- Compras no canceladas (cada renglon con lo que le queda despues de sus NC, en proporcion),
  -- envios aceptados con costo, y las salidas simuladas, en el orden de la cadena.
  CREATE FUNCTION pg_temp.oraculo(p_prod bigint, p_s0 numeric, p_c0 numeric) RETURNS numeric LANGUAGE plpgsql AS $f$
  DECLARE r record; s numeric := p_s0; c numeric := p_c0;
  BEGIN
    FOR r IN
      SELECT * FROM (
        SELECT 'compra'::text AS tipo, ci.created_at AS ts, ci.compra_id AS orden, ci.id,
               ci.cantidad::numeric * GREATEST(t.total - n.dev, 0) / t.total AS q,
               COALESCE(ci.costo_real_unitario, ci.costo_neto_unitario) AS costo,
               (COALESCE(ci.bonificacion,0) < 100 AND COALESCE(ci.costo_neto_unitario,0) > 0) AS fija
          FROM public.compra_items ci JOIN public.compras co ON co.id = ci.compra_id
          CROSS JOIN LATERAL (SELECT sum(o.cantidad)::numeric AS total FROM public.compra_items o
                               WHERE o.compra_id = ci.compra_id AND o.producto_id = ci.producto_id) t
          CROSS JOIN LATERAL (SELECT COALESCE(sum(nci.cantidad),0)::numeric AS dev
                                FROM public.nota_credito_items nci JOIN public.notas_credito nc ON nc.id = nci.nota_credito_id
                               WHERE nc.compra_id = ci.compra_id AND nci.producto_id = ci.producto_id) n
         WHERE ci.producto_id = p_prod AND co.estado <> 'cancelada'
        UNION ALL
        SELECT 'envio', m.resuelto_at, m.id, mi.id, mi.cantidad::numeric, mi.origen_costo_promedio, true
          FROM public.movimiento_sucursal_items mi JOIN public.movimientos_sucursal m ON m.id = mi.movimiento_id
         WHERE mi.producto_destino_id = p_prod AND m.estado = 'aceptada' AND mi.origen_costo_promedio > 0
        UNION ALL
        SELECT 'salida', s.ts, 0, 0, -s.qty::numeric, NULL, NULL FROM aud_salidas s WHERE s.producto_id = p_prod
      ) x ORDER BY ts, tipo, orden, id
    LOOP
      IF r.tipo = 'salida' THEN s := s + r.q; CONTINUE; END IF;
      IF r.q > 0 THEN
        c := public._cpp_linea(s, c, r.q, r.costo, r.fija);
        s := s + r.q;
      END IF;
    END LOOP;
    RETURN round(c, 4);
  END $f$;

  -- una linea del informe: el promedio vivo contra el oraculo
  CREATE FUNCTION pg_temp.mira(p_paso text, p_prod bigint, p_s0 numeric, p_c0 numeric) RETURNS text LANGUAGE plpgsql AS $f$
  DECLARE v numeric := pg_temp.cpp(p_prod); o numeric := pg_temp.oraculo(p_prod, p_s0, p_c0);
  BEGIN
    RETURN format(E'\n  %s: vivo=%s oraculo=%s stock=%s %s', p_paso, COALESCE(v::text,'NULL'), COALESCE(o::text,'NULL'),
                  (SELECT stock FROM public.productos WHERE id = p_prod),
                  CASE WHEN v IS NOT DISTINCT FROM o OR abs(v - o) <= 0.0005 THEN 'ok' ELSE '<<< DIFIERE' END);
  END $f$;
  -- C1 · una cadena larga y mezclada sobre un producto, contra el oraculo despues de cada paso.
  v_p := pg_temp.producto(1, 'AUD C1 ' || gen_random_uuid(), 40, 5);
  v_q := pg_temp.producto(1, 'AUD C1q ' || gen_random_uuid(), 0, NULL);
  v_t := '';
  v_a := pg_temp.comprar('C1A', jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 100, 'costo_unitario', 10)));
  v_t := v_t || pg_temp.mira('1 A 100@10', v_p, 40, 5);
  v_b := pg_temp.comprar('C1B', jsonb_build_array(
           jsonb_build_object('producto_id', v_p, 'cantidad', 50, 'costo_unitario', 12),
           jsonb_build_object('producto_id', v_q, 'cantidad', 10, 'costo_unitario', 7),
           jsonb_build_object('producto_id', v_p, 'cantidad', 30, 'costo_unitario', 20)));
  v_t := v_t || pg_temp.mira('2 B 50@12+30@20', v_p, 40, 5);
  PERFORM pg_temp.ingreso(v_p, 60, 15);
  v_t := v_t || pg_temp.mira('3 envio 60@15', v_p, 40, 5);
  PERFORM pg_temp.salida(v_p, 150);
  v_t := v_t || pg_temp.mira('4 salida 150', v_p, 40, 5);
  v_c := pg_temp.comprar('C1C', jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 80, 'costo_unitario', 25)));
  v_t := v_t || pg_temp.mira('5 C 80@25', v_p, 40, 5);
  PERFORM pg_temp.nc(v_b, v_p, 40);
  v_t := v_t || pg_temp.mira('6 NC B 40', v_p, 40, 5);
  PERFORM pg_temp.editar(v_a, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 70, 'costo_unitario', 11)));
  v_t := v_t || pg_temp.mira('7 edita A 70@11', v_p, 40, 5);
  v_d := pg_temp.comprar('C1D', jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 50, 'costo_unitario', 9, 'bonificacion', 100)));
  v_t := v_t || pg_temp.mira('8 D 50 bonif100', v_p, 40, 5);
  PERFORM pg_temp.anular(v_c);
  v_t := v_t || pg_temp.mira('9 anula C', v_p, 40, 5);
  v_a := pg_temp.cambiar_prov(v_a);
  v_t := v_t || pg_temp.mira('10 cambia prov A', v_p, 40, 5);
  PERFORM pg_temp.nc(v_b, v_p, 20);
  v_t := v_t || pg_temp.mira('11 NC B 20 mas', v_p, 40, 5);
  PERFORM pg_temp.editar(v_a, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 90, 'costo_unitario', 9)));
  v_t := v_t || pg_temp.mira('12 edita A'' 90@9', v_p, 40, 5);
  v_e := pg_temp.comprar('C1E', jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 30, 'costo_unitario', 0, 'bonificacion', 100)));
  v_t := v_t || pg_temp.mira('13 E 30 regalo a costo 0', v_p, 40, 5);
  PERFORM pg_temp.nc(v_d, v_p, 10);
  v_t := v_t || pg_temp.mira('14 NC D (regalo) 10', v_p, 40, 5);
  PERFORM pg_temp.editar(v_e, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 30, 'costo_unitario', 12)));
  v_t := v_t || pg_temp.mira('15 edita E 30@12', v_p, 40, 5);
  PERFORM pg_temp.salida(v_p, (SELECT stock FROM productos WHERE id = v_p) - 5);
  v_f := pg_temp.comprar('C1F', jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 200, 'costo_unitario', 30)));
  v_t := v_t || pg_temp.mira('16 salida a 5 y F 200@30', v_p, 40, 5);
  PERFORM pg_temp.editar(v_a, jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 40, 'costo_unitario', 9)));
  v_t := v_t || pg_temp.mira('17 edita A'' a 40 (fotos negativas)', v_p, 40, 5);
  PERFORM pg_temp.anular(v_a);
  v_t := v_t || pg_temp.mira('18 anula A''', v_p, 40, 5);
  IF position('DIFIERE' in v_t) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · el promedio vivo difiere del oráculo:%', v_t;
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · la cadena de 18 pasos da lo mismo que el oráculo:%', v_t;
END $aud$;
