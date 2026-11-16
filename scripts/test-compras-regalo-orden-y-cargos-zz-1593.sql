-- Ensayo de la tarjeta M2 del plan #1603 (compras y costo promedio): los dos medios CMP-A y CMP-B
-- de #1593 y los bajos 1593-b2, 1593-b4, 1557-c3 y 1557-c4.
--
--   A · CMP-A · el promedio de una factura con un regalo no depende del orden de sus renglones.
--       10 u. pagadas a 100 más 10 u. de regalo, sobre un producto agotado con un promedio viejo
--       de 80 o sobre uno nuevo, dan 50 (el prorrateo de la factura entera) vaya primero el
--       pagado o el regalo; en el alta, en la edición, con una NC de devolución y arrastrado por
--       una compra posterior. El oráculo es independiente: una cuenta por factura (el stock y el
--       promedio de antes, lo pagado y las unidades), sin `_cpp_linea` ni las fotos.
--       Y 1593-b4: una bonificación que deja el costo neto en 0 sin ser del 100 % se rechaza
--       (el umbral de regalo es uno: bonificación del 100 %).
--   B · CMP-B · el total de una ZZ incluye sus cargos en factura (decisión del dueño, 15/11):
--       10 × 100 más un flete de 300 dan 1.300, sin aviso de descuadre y sin COMPRA-A1. Y
--       1557-c3: el aviso con un descuento en factura se reproducía sólo en ZZ (es CMP-B); en una
--       FC con la cabecera que manda el front no hay aviso.
--   C · 1593-b2 / 1557-c4 · un flete o un descuento prorrateado se reparte sólo entre los
--       renglones pagados: la parte del regalo ya no se pierde.
--
-- Pide un admin activo de la sucursal 1. Un único DO que termina SIEMPRE en una excepción, sin
-- dejar rastro (salvo valores de secuencia). Veredicto: 'ENSAYO OK' o 'ENSAYO FALLÓ' con la lista.
--
--   psql "$DATABASE_URL" -f scripts/test-compras-regalo-orden-y-cargos-zz-1593.sql

DO $aud$
DECLARE v_ua uuid; v_a bigint; v_b bigint; v_c bigint; v_d bigint; v_e bigint; v_k bigint;
  v_j jsonb; v_t text := ''; v_f text := ''; v_n numeric; v_a1 int; v_i int;
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

  CREATE FUNCTION pg_temp.como(p_uid uuid, p_suc bigint) RETURNS void LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', p_suc::text)::text, true);
  END $f$;

  -- reloj: cada compra, un minuto despues de la anterior, arrancando hace 2 dias
  CREATE FUNCTION pg_temp.reloj() RETURNS timestamptz LANGUAGE plpgsql AS $f$
  DECLARE n int := current_setting('aud.t')::int + 1;
  BEGIN
    PERFORM set_config('aud.t', n::text, true);
    RETURN date_trunc('minute', now()) - interval '2 days' + n * interval '1 minute';
  END $f$;

  CREATE FUNCTION pg_temp.producto(p_nombre text, p_stock int, p_cpp numeric) RETURNS bigint LANGUAGE sql AS $f$
    INSERT INTO public.productos (nombre, precio, stock, costo_promedio, costo_real, costo_sin_iva, costo_con_iva, sucursal_id)
    VALUES (p_nombre || ' ' || gen_random_uuid(), 100, p_stock, p_cpp, p_cpp, p_cpp, p_cpp, 1) RETURNING id;
  $f$;

  -- renglones: defaults sin impuestos, el costo al centavo y el subtotal que cierra
  CREATE FUNCTION pg_temp.lineas(p_items jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_agg(x || jsonb_build_object('costo_unitario', round((x->>'costo_unitario')::numeric, 2),
             'subtotal', round((x->>'cantidad')::numeric * round((x->>'costo_unitario')::numeric, 2)
                   * (1 - (x->>'bonificacion')::numeric / 100), 2)) ORDER BY o)
      FROM (SELECT jsonb_build_object('bonificacion', 0, 'porcentaje_iva', 0, 'impuestos_internos', 0) || e AS x, o
              FROM jsonb_array_elements(p_items) WITH ORDINALITY AS t(e, o)) s;
  $f$;

  -- el alta tal cual: el total lo pone quien llama (es lo que se ensaya en B)
  CREATE FUNCTION pg_temp.alta(p_ref text, p_items jsonb, p_total numeric, p_tipo text DEFAULT 'ZZ',
                               p_cargos jsonb DEFAULT '[]', p_iva numeric DEFAULT 0, p_bonif numeric DEFAULT 0,
                               p_letra text DEFAULT NULL)
  RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_lin jsonb := pg_temp.lineas(p_items);
    v_sub numeric := (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(v_lin) e);
    v_r   jsonb;
  BEGIN
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 1);
    v_r := public.registrar_compra_completa(
      NULL, 'AUD M2', 'AUD-M2-' || p_ref || '-' || left(gen_random_uuid()::text, 8), public._tablero_hoy(),
      v_sub, p_iva, 0, p_total, 'efectivo', 'aud', current_setting('aud.ua')::uuid, v_lin, p_tipo,
      p_cargos => p_cargos, p_bonificaciones => p_bonif, p_letra_comprobante => p_letra);
    IF COALESCE((v_r->>'success')::boolean, false) THEN
      UPDATE public.compra_items SET created_at = pg_temp.reloj() WHERE compra_id = (v_r->>'compra_id')::bigint;
      UPDATE public.compras c SET created_at = (SELECT min(ci.created_at) FROM public.compra_items ci WHERE ci.compra_id = c.id)
       WHERE c.id = (v_r->>'compra_id')::bigint;
    END IF;
    RETURN v_r;
  END $f$;

  -- una ZZ sin cargos con el total que cierra; devuelve la compra
  CREATE FUNCTION pg_temp.comprar(p_ref text, p_items jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  DECLARE v_r jsonb;
  BEGIN
    v_r := pg_temp.alta(p_ref, p_items,
             (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(pg_temp.lineas(p_items)) e));
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la compra % no se registro: %', p_ref, v_r;
    END IF;
    RETURN (v_r->>'compra_id')::bigint;
  END $f$;

  CREATE FUNCTION pg_temp.ok_id(v jsonb) RETURNS bigint LANGUAGE plpgsql AS $f$
  BEGIN
    IF NOT COALESCE((v->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la compra no se registro: %', v;
    END IF;
    RETURN (v->>'compra_id')::bigint;
  END $f$;

  CREATE FUNCTION pg_temp.editar(p_compra bigint, p_items jsonb, p_total numeric DEFAULT NULL,
                                 p_cargos jsonb DEFAULT '[]') RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_lin jsonb := pg_temp.lineas(p_items);
    v_sub numeric := (SELECT sum((e->>'subtotal')::numeric) FROM jsonb_array_elements(v_lin) e);
    v_r   jsonb;
  BEGIN
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 1);
    v_r := public.actualizar_compra_items(
      p_compra, v_lin, v_sub, 0, COALESCE(p_total, v_sub), current_setting('aud.ua')::uuid,
      p_cargos => p_cargos, p_ii_declarado => '{}'::jsonb,
      p_renglones_vistos => (SELECT array_agg(id) FROM public.compra_items WHERE compra_id = p_compra));
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la edicion de % no paso: %', p_compra, v_r;
    END IF;
    RETURN v_r;
  END $f$;

  CREATE FUNCTION pg_temp.nc(p_compra bigint, p_prod bigint, p_cant int) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE
    v_costo numeric := (SELECT sum(cantidad * costo_unitario * (1 - COALESCE(bonificacion,0)/100)) / sum(cantidad)
                          FROM public.compra_items WHERE compra_id = p_compra AND producto_id = p_prod);
    v_sub   numeric := round(p_cant * v_costo, 2);
    v_r     jsonb;
  BEGIN
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 1);
    v_r := public.registrar_nota_credito(
      p_compra, 'NC-M2-' || p_compra || '-' || left(gen_random_uuid()::text, 8), 'aud', v_sub, 0, v_sub,
      current_setting('aud.ua')::uuid,
      jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'subtotal', v_sub)), 0);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la NC sobre % no paso: %', p_compra, v_r;
    END IF;
    RETURN v_r;
  END $f$;

  CREATE FUNCTION pg_temp.anular(p_compra bigint) RETURNS jsonb LANGUAGE plpgsql AS $f$
  DECLARE v_r jsonb;
  BEGIN
    PERFORM pg_temp.como(current_setting('aud.ua')::uuid, 1);
    v_r := public.anular_compra_atomica(p_compra, current_setting('aud.ua')::uuid);
    IF NOT COALESCE((v_r->>'success')::boolean, false) THEN
      RAISE EXCEPTION 'la anulacion de % no paso: %', p_compra, v_r;
    END IF;
    RETURN v_r;
  END $f$;

  CREATE FUNCTION pg_temp.cpp(p_prod bigint) RETURNS numeric LANGUAGE sql AS $f$
    SELECT round(costo_promedio, 4) FROM public.productos WHERE id = p_prod;
  $f$;

  -- EL ORACULO INDEPENDIENTE: el promedio desde cero, una cuenta por factura. Para cada compra no
  -- cancelada del producto, en el orden de la cadena: Q = las unidades que le quedan (lo devuelto
  -- por NC sale de cada renglon en proporcion), V = lo pagado por las que quedan de los renglones
  -- que pagan (bonificacion < 100 y costo neto > 0). Si habia stock con promedio, se pondera; si
  -- no, la factura entra con su prorrateo (V / Q); una factura de puros regalos sobre nada no fija
  -- promedio. No mira ninguna foto ni `_cpp_linea`.
  CREATE FUNCTION pg_temp.oraculo(p_prod bigint, p_s0 numeric, p_c0 numeric) RETURNS numeric LANGUAGE plpgsql AS $f$
  DECLARE r record; s numeric := p_s0; c numeric := p_c0;
  BEGIN
    FOR r IN
      SELECT ci.compra_id, min(ci.created_at) AS ts,
             sum(ci.cantidad::numeric * (t.total - n.dev) / t.total) AS q,
             sum(ci.cantidad::numeric * (t.total - n.dev) / t.total * COALESCE(ci.costo_real_unitario, ci.costo_neto_unitario))
               FILTER (WHERE COALESCE(ci.bonificacion, 0) < 100 AND ci.costo_neto_unitario > 0) AS v,
             bool_or(COALESCE(ci.bonificacion, 0) < 100 AND ci.costo_neto_unitario > 0) AS paga
        FROM public.compra_items ci JOIN public.compras co ON co.id = ci.compra_id
        CROSS JOIN LATERAL (SELECT sum(o.cantidad)::numeric AS total FROM public.compra_items o
                             WHERE o.compra_id = ci.compra_id AND o.producto_id = ci.producto_id) t
        CROSS JOIN LATERAL (SELECT COALESCE(sum(nci.cantidad), 0)::numeric AS dev
                              FROM public.nota_credito_items nci JOIN public.notas_credito nc ON nc.id = nci.nota_credito_id
                             WHERE nc.compra_id = ci.compra_id AND nci.producto_id = ci.producto_id) n
       WHERE ci.producto_id = p_prod AND co.estado <> 'cancelada'
       GROUP BY ci.compra_id
       ORDER BY 2, 1
    LOOP
      CONTINUE WHEN r.q <= 0;
      IF s > 0 AND COALESCE(c, 0) > 0 THEN
        c := (s * c + COALESCE(r.v, 0)) / (s + r.q);
      ELSIF r.paga THEN
        c := r.v / r.q;
      END IF;
      s := s + r.q;
    END LOOP;
    RETURN round(c, 4);
  END $f$;

  -- una linea del informe
  CREATE FUNCTION pg_temp.igual(p_que text, p_vale numeric, p_espera numeric) RETURNS text LANGUAGE sql AS $f$
    SELECT format(E'\n  %s: %s (se espera %s) %s', p_que, COALESCE(round(p_vale, 4)::text, 'NULL'),
                  COALESCE(round(p_espera, 4)::text, 'NULL'),
                  CASE WHEN p_vale IS NOT DISTINCT FROM p_espera OR abs(p_vale - p_espera) <= 0.0005 THEN 'ok' ELSE '<<< FALLA' END);
  $f$;
  CREATE FUNCTION pg_temp.igual_t(p_que text, p_vale text, p_espera text) RETURNS text LANGUAGE sql AS $f$
    SELECT format(E'\n  %s: %s (se espera %s) %s', p_que, COALESCE(p_vale, 'NULL'), COALESCE(p_espera, 'NULL'),
                  CASE WHEN p_vale IS NOT DISTINCT FROM p_espera THEN 'ok' ELSE '<<< FALLA' END);
  $f$;

  CREATE FUNCTION pg_temp.a1() RETURNS int LANGUAGE sql AS $f$
    SELECT (c->>'violaciones')::int FROM jsonb_array_elements(public.auditoria_integridad()->'checks') c
     WHERE c->>'id' = 'COMPRA-A1';
  $f$;

  -- el costo real y los cargos guardados de un renglon (por su posicion en la compra: el pagado o el regalo)
  CREATE FUNCTION pg_temp.renglon(p_compra bigint, p_regalo boolean, p_que text) RETURNS numeric LANGUAGE sql AS $f$
    SELECT CASE p_que WHEN 'real' THEN round(costo_real_unitario, 4) ELSE round(cargos_unitarios, 4) END
      FROM public.compra_items WHERE compra_id = p_compra AND (bonificacion >= 100) = p_regalo;
  $f$;

  -- ===================================================================================
  -- A · CMP-A · la misma factura en los dos ordenes
  -- ===================================================================================
  v_a := pg_temp.producto('AUD M2 A1 agotado', 0, 80);
  v_b := pg_temp.producto('AUD M2 A2 agotado', 0, 80);
  v_c := pg_temp.producto('AUD M2 A3 nuevo', 0, NULL);
  v_d := pg_temp.producto('AUD M2 A4 nuevo', 0, NULL);
  UPDATE productos SET costo_real = NULL, costo_sin_iva = NULL, costo_con_iva = NULL WHERE id IN (v_c, v_d);

  PERFORM set_config('aud.ca', pg_temp.comprar('A1', jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'costo_unitario', 100, 'bonificacion', 100),
    jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'costo_unitario', 100)))::text, true);
  PERFORM set_config('aud.cb', pg_temp.comprar('A2', jsonb_build_array(
    jsonb_build_object('producto_id', v_b, 'cantidad', 10, 'costo_unitario', 100),
    jsonb_build_object('producto_id', v_b, 'cantidad', 10, 'costo_unitario', 100, 'bonificacion', 100)))::text, true);
  PERFORM set_config('aud.cc', pg_temp.comprar('A3', jsonb_build_array(
    jsonb_build_object('producto_id', v_c, 'cantidad', 10, 'costo_unitario', 100, 'bonificacion', 100),
    jsonb_build_object('producto_id', v_c, 'cantidad', 10, 'costo_unitario', 100)))::text, true);
  PERFORM set_config('aud.cd', pg_temp.comprar('A4', jsonb_build_array(
    jsonb_build_object('producto_id', v_d, 'cantidad', 10, 'costo_unitario', 100),
    jsonb_build_object('producto_id', v_d, 'cantidad', 10, 'costo_unitario', 100, 'bonificacion', 100)))::text, true);
  v_t := v_t || pg_temp.igual('A1 agotado (cpp 80), [regalo, pagado]', pg_temp.cpp(v_a), 50)
             || pg_temp.igual('A2 agotado (cpp 80), [pagado, regalo]', pg_temp.cpp(v_b), 50)
             || pg_temp.igual('A3 nuevo, [regalo, pagado]', pg_temp.cpp(v_c), 50)
             || pg_temp.igual('A4 nuevo, [pagado, regalo]', pg_temp.cpp(v_d), 50)
             || pg_temp.igual('A1 contra el oraculo', pg_temp.cpp(v_a), pg_temp.oraculo(v_a, 0, 80))
             || pg_temp.igual('A3 contra el oraculo', pg_temp.cpp(v_c), pg_temp.oraculo(v_c, 0, NULL));

  -- la edicion sin cambios, con el regalo primero en el payload: sigue en 50
  PERFORM pg_temp.editar(current_setting('aud.ca')::bigint, jsonb_build_array(
    jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'costo_unitario', 100, 'bonificacion', 100),
    jsonb_build_object('producto_id', v_a, 'cantidad', 10, 'costo_unitario', 100)));
  v_t := v_t || pg_temp.igual('A1 editada sin cambios, [regalo, pagado]', pg_temp.cpp(v_a), 50);

  -- una compra posterior y la edicion de la primera: el arrastre, contra el oraculo
  PERFORM pg_temp.comprar('A2b', jsonb_build_array(jsonb_build_object('producto_id', v_b, 'cantidad', 20, 'costo_unitario', 80)));
  v_t := v_t || pg_temp.igual('A2 + 20 a 80 despues', pg_temp.cpp(v_b), 65);
  PERFORM pg_temp.editar(current_setting('aud.cb')::bigint, jsonb_build_array(
    jsonb_build_object('producto_id', v_b, 'cantidad', 10, 'costo_unitario', 100, 'bonificacion', 100),
    jsonb_build_object('producto_id', v_b, 'cantidad', 10, 'costo_unitario', 200)));
  v_t := v_t || pg_temp.igual('A2 editada a 200, [regalo, pagado], arrastrada', pg_temp.cpp(v_b), 90)
             || pg_temp.igual('A2 contra el oraculo', pg_temp.cpp(v_b), pg_temp.oraculo(v_b, 0, 80));

  -- una NC de devolucion de 10 u. sobre la factura con el regalo primero: quedan 5 y 5
  PERFORM pg_temp.nc(current_setting('aud.cc')::bigint, v_c, 10);
  v_t := v_t || pg_temp.igual('A3 tras una NC de 10 u.', pg_temp.cpp(v_c), 50)
             || pg_temp.igual('A3 tras la NC, contra el oraculo', pg_temp.cpp(v_c), pg_temp.oraculo(v_c, 0, NULL));

  -- la anulacion vuelve a la foto del alta: producto nuevo, sin promedio
  PERFORM pg_temp.anular(current_setting('aud.cd')::bigint);
  v_t := v_t || pg_temp.igual('A4 anulada: sin promedio', pg_temp.cpp(v_d), NULL)
             || pg_temp.igual('A4 anulada: stock', (SELECT stock FROM productos WHERE id = v_d), 0);

  -- 1593-b4 · una bonificacion que deja el costo neto en 0 sin ser del 100 % no entra
  v_e := pg_temp.producto('AUD M2 B4', 0, NULL);
  v_j := pg_temp.alta('B4a', jsonb_build_array(jsonb_build_object('producto_id', v_e, 'cantidad', 10, 'costo_unitario', 1, 'bonificacion', 99.999)), 0);
  v_t := v_t || pg_temp.igual_t('b4 · 99,999 % sobre costo 1: se rechaza',
               CASE WHEN COALESCE((v_j->>'success')::boolean, false) THEN 'entró'
                    WHEN v_j->>'error' ILIKE '%cargalo con bonificación del 100 %%' THEN 'rechazada' ELSE v_j->>'error' END,
               'rechazada')
             || pg_temp.igual('b4 · el producto no se movio', pg_temp.cpp(v_e), NULL);
  -- y una que deja centavos sigue siendo un renglon pagado, en el alta y en la cadena
  v_j := pg_temp.alta('B4b', jsonb_build_array(jsonb_build_object('producto_id', v_e, 'cantidad', 10, 'costo_unitario', 10000, 'bonificacion', 99.99)), 10);
  v_t := v_t || pg_temp.igual('b4 · 99,99 % sobre 10.000 (neto 1): promedio', pg_temp.cpp(v_e), 1)
             || pg_temp.igual_t('b4 · ese renglon fija costo en la cadena',
               (SELECT _cpp_fija_costo(bonificacion, costo_neto_unitario, costo_unitario)::text FROM compra_items
                 WHERE compra_id = (v_j->>'compra_id')::bigint), 'true');

  -- ===================================================================================
  -- B · CMP-B · el total de una ZZ incluye sus cargos en factura · 1557-c3
  -- ===================================================================================
  v_a1 := pg_temp.a1();
  v_k := pg_temp.producto('AUD M2 B', 0, NULL);
  v_j := pg_temp.alta('B1', jsonb_build_array(jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100)), 1300, 'ZZ',
           jsonb_build_array(jsonb_build_object('concepto', 'Flete', 'monto', 300, 'condicion_iva', 'gravado', 'en_factura', true,
             'prorratea_al_costo', true, 'base_prorrateo', 'cantidad', 'pesos', jsonb_build_object('0', 10))));
  v_t := v_t || pg_temp.igual_t('B1 ZZ 10x100 + flete 300 en factura, total 1300: aviso', v_j->>'warning_descuadre', NULL)
             || pg_temp.igual('B1 total guardado', (SELECT total FROM compras WHERE id = (v_j->>'compra_id')::bigint), 1300)
             || pg_temp.igual('B1 costo del producto', pg_temp.cpp(v_k), 130);
  v_j := pg_temp.alta('B2', jsonb_build_array(jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100)), 1000, 'ZZ',
           jsonb_build_array(jsonb_build_object('concepto', 'Flete', 'monto', 300, 'condicion_iva', 'gravado', 'en_factura', true,
             'prorratea_al_costo', true, 'base_prorrateo', 'cantidad', 'pesos', jsonb_build_object('0', 10))));
  v_t := v_t || pg_temp.igual_t('B2 la misma con total 1000 (un cliente viejo): aviso', v_j->>'warning_descuadre',
                                'Descuadre: total calculado 1300.00 vs total informado 1000.00');
  v_j := pg_temp.alta('B3', jsonb_build_array(jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100)), 850, 'ZZ',
           jsonb_build_array(jsonb_build_object('concepto', 'Descuento', 'monto', -150, 'condicion_iva', 'gravado', 'en_factura', true,
             'prorratea_al_costo', true, 'base_prorrateo', 'cantidad', 'pesos', jsonb_build_object('0', 10))));
  v_t := v_t || pg_temp.igual_t('B3 (1557-c3) ZZ con descuento -150 en factura, total 850: aviso', v_j->>'warning_descuadre', NULL);
  v_j := pg_temp.alta('B4', jsonb_build_array(jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100, 'porcentaje_iva', 21)),
           1028.50, 'FC',
           jsonb_build_array(jsonb_build_object('concepto', 'Descuento', 'monto', -150, 'condicion_iva', 'gravado', 'en_factura', true,
             'prorratea_al_costo', true, 'base_prorrateo', 'cantidad', 'pesos', jsonb_build_object('0', 10))),
           178.50, -150, 'A');
  v_t := v_t || pg_temp.igual_t('B4 (1557-c3) FC A con descuento -150 y la cabecera del front: aviso', v_j->>'warning_descuadre', NULL);
  v_j := pg_temp.alta('B5', jsonb_build_array(jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100)), 1000, 'ZZ',
           jsonb_build_array(jsonb_build_object('concepto', 'Flete aparte', 'monto', 300, 'condicion_iva', 'no_gravado', 'en_factura', false,
             'prorratea_al_costo', true, 'base_prorrateo', 'cantidad', 'pesos', jsonb_build_object('0', 10))));
  v_t := v_t || pg_temp.igual_t('B5 ZZ con un flete que no viene en la factura, total 1000: aviso', v_j->>'warning_descuadre', NULL)
             || pg_temp.igual('B COMPRA-A1 cuenta sólo la B2', pg_temp.a1() - v_a1, 1);

  -- ===================================================================================
  -- C · 1593-b2 / 1557-c4 · el cargo se reparte entre los renglones pagados
  -- ===================================================================================
  v_k := pg_temp.producto('AUD M2 C1', 0, NULL);
  v_j := pg_temp.alta('C1', jsonb_build_array(
           jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100, 'bonificacion', 100),
           jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100)), 1300, 'ZZ',
           jsonb_build_array(jsonb_build_object('concepto', 'Flete', 'monto', 300, 'condicion_iva', 'gravado', 'en_factura', true,
             'prorratea_al_costo', true, 'base_prorrateo', 'cantidad', 'pesos', jsonb_build_object('0', 10, '1', 10))));
  v_a := pg_temp.ok_id(v_j);
  v_t := v_t || pg_temp.igual('C1 (b2) flete 300 sobre [regalo, pagado]: costo real del pagado', pg_temp.renglon(v_a, false, 'real'), 130)
             || pg_temp.igual('C1 costo real del regalo', pg_temp.renglon(v_a, true, 'real'), 0)
             || pg_temp.igual('C1 promedio (130 por 10, diluido en 20)', pg_temp.cpp(v_k), 65)
             || pg_temp.igual('C1 repartos guardados (sólo el pagado)',
                  (SELECT count(*) FROM compra_cargo_repartos WHERE compra_id = v_a), 1);
  PERFORM pg_temp.editar(v_a, jsonb_build_array(
    jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100, 'bonificacion', 100),
    jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100)), 1300,
    jsonb_build_array(jsonb_build_object('concepto', 'Flete', 'monto', 300, 'condicion_iva', 'gravado', 'en_factura', true,
      'prorratea_al_costo', true, 'base_prorrateo', 'cantidad', 'pesos', jsonb_build_object('0', 10, '1', 10))));
  v_t := v_t || pg_temp.igual('C1 editada igual: costo real del pagado', pg_temp.renglon(v_a, false, 'real'), 130)
             || pg_temp.igual('C1 editada igual: promedio', pg_temp.cpp(v_k), 65);

  v_k := pg_temp.producto('AUD M2 C2', 0, NULL);
  v_j := pg_temp.alta('C2', jsonb_build_array(
           jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100),
           jsonb_build_object('producto_id', v_k, 'cantidad', 5, 'costo_unitario', 100, 'bonificacion', 100)), 850, 'ZZ',
           jsonb_build_array(jsonb_build_object('concepto', 'Descuento', 'monto', -150, 'condicion_iva', 'gravado', 'en_factura', true,
             'prorratea_al_costo', true, 'base_prorrateo', 'cantidad', 'pesos', jsonb_build_object('0', 10, '1', 5))));
  v_a := pg_temp.ok_id(v_j);
  v_t := v_t || pg_temp.igual('C2 (1557-c4) descuento -150 sobre [pagado, regalo]: costo real del pagado', pg_temp.renglon(v_a, false, 'real'), 85);

  v_k := pg_temp.producto('AUD M2 C3', 0, NULL);
  v_j := pg_temp.alta('C3', jsonb_build_array(
           jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100, 'bonificacion', 100),
           jsonb_build_object('producto_id', v_k, 'cantidad', 10, 'costo_unitario', 100)), 1200, 'ZZ',
           jsonb_build_array(jsonb_build_object('concepto', 'Pallets', 'monto', 200, 'condicion_iva', 'no_gravado', 'en_factura', true,
             'prorratea_al_costo', true, 'base_prorrateo', 'cantidad', 'pesos', jsonb_build_object('0', 10, '1', 10))));
  v_a := pg_temp.ok_id(v_j);
  v_t := v_t || pg_temp.igual('C3 no gravado 200: cargos del pagado', pg_temp.renglon(v_a, false, 'cargos'), 20)
             || pg_temp.igual('C3 cargos del regalo', pg_temp.renglon(v_a, true, 'cargos'), 0)
             || pg_temp.igual('C3 COMPRA-A3 sobre esta compra (repartos contra cargos guardados)',
                  (SELECT count(*) FROM compra_items ci
                     LEFT JOIN (SELECT r.item_id, sum(r.monto) AS monto
                                  FROM compra_cargos cc
                                  CROSS JOIN LATERAL prorratear_cargo(cc.monto,
                                    (SELECT jsonb_object_agg(x.compra_item_id::text, x.peso) FROM compra_cargo_repartos x WHERE x.cargo_id = cc.id)) r
                                 WHERE cc.compra_id = v_a AND cc.condicion_iva <> 'gravado' AND cc.prorratea_al_costo
                                 GROUP BY r.item_id) rep ON rep.item_id = ci.id
                    WHERE ci.compra_id = v_a
                      AND abs(COALESCE(rep.monto, 0) - COALESCE(ci.cargos_unitarios, 0) * ci.cantidad) > 0.01 + 0.0001 * ci.cantidad), 0);

  -- el motor directo: un cargo que sólo pesa sobre regalos queda como estaba (no hay a quien darselo)
  v_j := calcular_costos_compra(
    '[{"id":0,"cantidad":10,"costo_unitario":100,"bonificacion":100,"impuestos_internos":0,"porcentaje_iva":0,"condicion_iva":"gravado"},
      {"id":1,"cantidad":10,"costo_unitario":100,"bonificacion":0,"impuestos_internos":0,"porcentaje_iva":0,"condicion_iva":"gravado"}]'::jsonb,
    '[{"monto":300,"condicion_iva":"gravado","en_factura":true,"prorratea_al_costo":true,"afecta_base_ii":false,"pesos":{"0":10}}]'::jsonb,
    '{}'::jsonb);
  v_t := v_t || pg_temp.igual('C4 motor: un cargo sólo sobre el regalo queda en el regalo',
                  (SELECT round((l->>'costo_real')::numeric, 4) FROM jsonb_array_elements(v_j->'lineas') l WHERE l->>'id' = '0'), 30);
  v_j := calcular_costos_compra(
    '[{"id":0,"cantidad":10,"costo_unitario":100,"bonificacion":100,"impuestos_internos":0,"porcentaje_iva":21,"condicion_iva":"gravado"},
      {"id":1,"cantidad":10,"costo_unitario":100,"bonificacion":0,"impuestos_internos":0,"porcentaje_iva":21,"condicion_iva":"gravado"}]'::jsonb,
    '[{"monto":300,"condicion_iva":"gravado","en_factura":true,"prorratea_al_costo":true,"afecta_base_ii":false,"pesos":{"0":10,"1":10}}]'::jsonb,
    '{}'::jsonb);
  v_t := v_t || pg_temp.igual('C5 motor FC: costo real del pagado', (SELECT round((l->>'costo_real')::numeric, 4)
                  FROM jsonb_array_elements(v_j->'lineas') l WHERE l->>'id' = '1'), 130)
             || pg_temp.igual('C5 motor FC: el IVA no cambia (21 % de 1.300)', round((v_j->'totales'->>'iva')::numeric, 2), 273);

  -- el umbral del regalo del reparto es el de la cadena
  IF to_regprocedure('public._pesos_entre_pagados(jsonb,jsonb)') IS NULL THEN
    v_t := v_t || E'\n  C6 _pesos_entre_pagados no existe <<< FALLA';
  ELSE
  SELECT count(*) INTO v_i
    FROM (VALUES (0::numeric, 100::numeric), (100, 100), (99.999, 1), (99.99, 10000), (50, 0), (0, 0.004), (99.995, 1)) AS t(b, c)
   WHERE (public._pesos_entre_pagados('{"0":1,"1":1}'::jsonb,
            jsonb_build_array(jsonb_build_object('id', 0, 'costo_unitario', t.c, 'bonificacion', t.b),
                              jsonb_build_object('id', 1, 'costo_unitario', 100, 'bonificacion', 0))) ? '0')
         IS DISTINCT FROM _cpp_fija_costo(t.b, round(t.c * (1 - t.b / 100), 4), t.c);
  v_t := v_t || pg_temp.igual('C6 _pesos_entre_pagados usa el umbral de _cpp_fija_costo', v_i, 0);
  END IF;

  IF position('FALLA' in v_t) > 0 THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ:%', v_t;
  END IF;
  RAISE EXCEPTION 'ENSAYO OK:%', v_t;
END $aud$;
