-- Ensayo de #1090 y #1091: el reparto de un regalo se mide en la raiz de cada
-- parte, y el reparto que se elige al cargar el pedido queda registrado.
--
-- #1090: un reparto se conservaba al editar solo si la suma de sus LINEAS era
-- lo que da la promo. Con una parte cambiada por valor (X2 + Y2, Y -> Z 2 -> 4,
-- Z -> Y 4 -> 3: suman 5 y la promo da 4) cualquier guardado lo disolvia en X4
-- sin cadena. Desde la migracion XXX_el_reparto_se_mide_en_su_raiz se suman
-- las cantidades de corte (regalo_cantidad_base), y dividir_regalo_pedido no
-- reparte una linea convertida por valor ni una parte cuya cantidad ya no es
-- su corte.
-- #1091: crear_pedido_completo aceptaba varias lineas de regalo de una promo
-- sin dejar filas de reparto: la promo que se caia y volvia heredaba la clave
-- de UNA parte. Ahora cada parte nace con su clave y su fila de reparto.
--
--   E1 · #1090 modo A: X2 + Y3 (Y -> Z -> Y) se conserva al editar con [X4] y
--        con [X2, Y2], sin mover stock ni lotes; con [X5] se disuelve.
--   E2 · las guardas de dividir: a/g rechazan (convertida por valor), d/e
--        rechazan (parte que cambio de cantidad), b/c/f pasan.
--   E3 · #1091: alta Y2 + W2 -> dos filas de reparto, claves propias, el
--        stock del alta de siempre; Y -> Z, la promo se cae y vuelve con Y4
--        sin heredar la clave.
--   E4 · E1 en modo B, con barras por sabor: ni stock ni barras se mueven.
--   E5 · PROMO-B: el predicado viejo cuenta los repartos disueltos y las
--        cadenas sin linea; el de auditoria_integridad() queda en 0.
--   E6 · el backfill de la migracion (solo corre adentro de ella).
--
-- Bolsa distinta de 0 en todos los productos (nota de la 316).
-- Corre contra prod SIN dejar rastro (salvo los valores de secuencia que
-- consume): cada caso en un subbloque revertido, y todo termina en un RAISE.
-- Veredicto en el mensaje: 'ENSAYO OK' o 'ENSAYO FALLO'.
--
--   psql "$DATABASE_URL" -f scripts/test-repartos-regalo-1090-1091.sql

CREATE OR REPLACE FUNCTION pg_temp.rr_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- set_config es por transaccion (CLAUDE.md): entre llamada y llamada se
-- limpian los GUCs de stock, asi una RPC no hereda la etiqueta de otra.
CREATE OR REPLACE FUNCTION pg_temp.rr_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

-- Stock, lotes y bolsa de unos productos.
CREATE OR REPLACE FUNCTION pg_temp.rr_fotos(p_prods bigint[])
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_object_agg(pr.id::text, jsonb_build_object(
           'stock', pr.stock,
           'lotes', COALESCE((SELECT jsonb_agg(l.cantidad_restante ORDER BY l.fecha_vencimiento, l.id)
                                FROM public.producto_lotes l WHERE l.producto_id = pr.id), '[]'::jsonb),
           'bolsa', pr.stock - COALESCE((SELECT SUM(l.cantidad_restante)
                                           FROM public.producto_lotes l WHERE l.producto_id = pr.id), 0)::int))
    FROM public.productos pr WHERE pr.id = ANY(p_prods);
$fn$;

-- Un producto sintetico con un lote (90 dias, 100, p_restante vivas) y
-- p_bolsa sin lote. Bolsa distinta de 0 a proposito (nota de la 316).
CREATE OR REPLACE FUNCTION pg_temp.rr_prod(p_suc bigint, p_admin uuid, p_cat text, p_bolsa int,
                                           p_restante int, p_bulto int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id, categoria, unidades_por_bulto)
  VALUES ('ZZ ensayo 1090 ' || p_cat, 100, p_bolsa + p_restante, 60, p_suc, 'ZZ ensayo 1090 ' || p_cat, p_bulto)
  RETURNING id INTO v_prod;
  IF p_restante > 0 THEN
    INSERT INTO public.compras (sucursal_id, estado, usuario_id)
    VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
    INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                       cantidad_restante, usuario_id, compra_id)
    VALUES (v_prod, p_suc, pg_temp.rr_hoy() + 90, 100, p_restante, p_admin, v_compra);
  END IF;
  RETURN v_prod;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_promo(p_suc bigint, p_regalo bigint, p_mueve boolean,
                                            p_auto boolean, p_upb int, p_ajuste bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock,
                                  producto_regalo_id, ajuste_automatico, unidades_por_bloque,
                                  stock_por_bloque, ajuste_producto_id)
  VALUES ('ZZ ensayo 1090', 'bonificacion', CURRENT_DATE, p_suc, p_mueve, p_regalo, p_auto, p_upb,
          CASE WHEN p_upb IS NOT NULL THEN 1 END, p_ajuste)
  RETURNING id INTO v;
  RETURN v;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_v(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 100);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_r(p_prod bigint, p_cant int, p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', 0,
                            'es_bonificacion', true, 'promocion_id', p_promo);
$fn$;

-- El alta: V x10 a $100 mas los regalos que vengan.
CREATE OR REPLACE FUNCTION pg_temp.rr_alta(p_cli bigint, p_admin uuid, p_venta bigint, p_regalos jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli, 1000, p_admin, jsonb_build_array(pg_temp.rr_v(p_venta, 10)) || p_regalos, 'ensayo 1090');
  PERFORM pg_temp.rr_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', v_res;
  END IF;
  RETURN (v_res->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_editar(p_ped bigint, p_adm uuid, p_items jsonb)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.actualizar_pedido_items(p_ped, p_items, p_adm);
  PERFORM pg_temp.rr_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo editar el pedido: %', v_res;
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_linea(p_ped bigint, p_prod bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND COALESCE(es_bonificacion, false)
   ORDER BY id LIMIT 1;
$fn$;

-- Las lineas de regalo de un pedido: [{p, c, k}] por producto.
CREATE OR REPLACE FUNCTION pg_temp.rr_lineas(p_ped bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT COALESCE(jsonb_agg(jsonb_build_object('p', producto_id, 'c', cantidad, 'k', regalo_cadena_id)
                            ORDER BY producto_id, id), '[]'::jsonb)
    FROM public.pedido_items
   WHERE pedido_id = p_ped AND COALESCE(es_bonificacion, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_dividir(p_item bigint, p_partes jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.dividir_regalo_pedido(p_item, p_partes, 'ensayo 1090');
  PERFORM pg_temp.rr_reset();
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_sustituir(p_item bigint, p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.sustituir_regalo_pedido(p_item, p_prod, p_cant, 'ensayo 1090');
  PERFORM pg_temp.rr_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo sustituir el regalo: %', v_res;
  END IF;
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_parte(p_prod bigint, p_cant int)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant);
$fn$;

-- El estado de los acumuladores de una promo (modo B).
CREATE OR REPLACE FUNCTION pg_temp.rr_barras(p_promo bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object(
    'default', (SELECT usos_pendientes FROM public.promociones WHERE id = p_promo),
    'sabores', COALESCE((SELECT jsonb_object_agg(producto_regalo_id::text, usos_pendientes)
                           FROM public.promo_acumuladores WHERE promocion_id = p_promo), '{}'::jsonb));
$fn$;

-- El predicado de PROMO-B ANTES de esta migracion, sobre un pedido.
CREATE OR REPLACE FUNCTION pg_temp.rr_promo_b_viejo(p_ped bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT count(*) FROM public.pedido_item_sustituciones s
   WHERE s.pedido_id = p_ped
     AND COALESCE(s.regalo_mueve_stock_snapshot, false)
     AND s.producto_original_id <> s.producto_sustituto_id
     AND EXISTS (SELECT 1 FROM public.stock_historico h
                  WHERE h.referencia_tipo='pedido' AND h.referencia_id=s.pedido_id
                    AND h.sucursal_id=s.sucursal_id AND h.producto_id=s.producto_original_id
                    AND h.origen='pedido_creado' AND h.created_at > s.created_at
                    AND h.diferencia < 0)
     AND NOT EXISTS (SELECT 1 FROM public.stock_historico h
                  WHERE h.referencia_tipo='pedido' AND h.referencia_id=s.pedido_id
                    AND h.sucursal_id=s.sucursal_id AND h.producto_id=s.producto_sustituto_id
                    AND h.origen='pedido_creado' AND h.created_at > s.created_at
                    AND h.diferencia < 0);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_promo_b_auditoria()
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT COALESCE((x->>'violaciones')::numeric, -1)
    FROM jsonb_array_elements(public.auditoria_integridad()->'checks') x
   WHERE x->>'id' = 'PROMO-B';
$fn$;

-- ---------------------------------------------------------------------------
-- E1/E4 · #1090: alta X4 -> dividir X2+Y2 -> Y->Z (2->4, otra categoria) ->
-- Z->Y (4->3). Quedan X2 + Y3 (suman 5, la promo da 4). Editar con [X4] (un
-- bundle viejo) y con [X2, Y2] (el front nuevo, los cortes) conserva X2 + Y3
-- con sus claves y sin mover stock ni lotes (ni las barras por sabor, en modo
-- B); con [X5] la promo cambio
-- y se disuelve en X5 sin cadena. Modo A (E1) y modo B con barras por sabor (E4).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_e1_modo(p_cli bigint, p_adm uuid, p_suc bigint, p_mueve boolean)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; z bigint; c bigint; v_promo bigint; v_ped bigint;
  v_res jsonb; v_l0 jsonb; v_l1 jsonb; v_f0 jsonb; v_f1 jsonb; v_b0 jsonb; v_b1 jsonb;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50, NULL);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  -- En modo B, Y y Z tienen que decir cuantas sueltas trae su contenedor para
  -- cambiar de categoria (mig 295); con 6, la barra de cada sabor cuenta igual.
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, CASE WHEN p_mueve THEN NULL ELSE 6 END);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50, CASE WHEN p_mueve THEN NULL ELSE 6 END);
  IF p_mueve THEN
    v_promo := pg_temp.rr_promo(p_suc, x, true, false, NULL, NULL);
  ELSE
    c := pg_temp.rr_prod(p_suc, p_adm, 'contenedor', 20, 50, NULL);
    v_promo := pg_temp.rr_promo(p_suc, x, false, true, 6, c);
  END IF;

  v_ped := pg_temp.rr_alta(p_cli, p_adm, v, jsonb_build_array(pg_temp.rr_r(x, 4, v_promo)));
  v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, x),
                              jsonb_build_array(pg_temp.rr_parte(x, 2), pg_temp.rr_parte(y, 2)));
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo repartir: %', v_res;
  END IF;
  PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, y), z, 4);
  PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, z), y, 3);

  v_l0 := pg_temp.rr_lineas(v_ped);
  IF jsonb_array_length(v_l0) <> 2 OR (v_l0->0->>'c')::int <> 2 OR (v_l0->1->>'c')::int <> 3
     OR v_l0->0->>'k' IS NULL OR v_l0->1->>'k' IS NULL OR v_l0->0->>'k' = v_l0->1->>'k' THEN
    RETURN jsonb_build_object('fallas', jsonb_build_array(format('punto de partida: %s', v_l0)));
  END IF;
  v_f0 := pg_temp.rr_fotos(ARRAY[v, x, y, z, c]);
  v_b0 := pg_temp.rr_barras(v_promo);

  -- Un bundle viejo: la promo en una linea.
  PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 4, v_promo)));
  v_l1 := pg_temp.rr_lineas(v_ped); v_f1 := pg_temp.rr_fotos(ARRAY[v, x, y, z, c]); v_b1 := pg_temp.rr_barras(v_promo);
  f := pg_temp.rr_si(f, v_l1 = v_l0, format('editar con [X4] dejo %s, antes %s', v_l1, v_l0));
  f := pg_temp.rr_si(f, v_f1 = v_f0, format('editar con [X4] movio stock: %s, antes %s', v_f1, v_f0));
  -- Las barras por sabor son del modo B. En modo A usos_pendientes es un
  -- contador de usos que sustituir y dividir no tocan y la edicion recuenta
  -- por lineas (4 del alta -> 5 de X2 + Y3): no es stock ni es de este issue.
  f := pg_temp.rr_si(f, p_mueve OR v_b1 = v_b0, format('editar con [X4] movio las barras: %s, antes %s', v_b1, v_b0));

  -- El front nuevo: el corte de cada parte.
  PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 2, v_promo),
                                                            pg_temp.rr_r(y, 2, v_promo)));
  v_l1 := pg_temp.rr_lineas(v_ped); v_f1 := pg_temp.rr_fotos(ARRAY[v, x, y, z, c]); v_b1 := pg_temp.rr_barras(v_promo);
  f := pg_temp.rr_si(f, v_l1 = v_l0, format('editar con [X2, Y2] dejo %s, antes %s', v_l1, v_l0));
  f := pg_temp.rr_si(f, v_f1 = v_f0, format('editar con [X2, Y2] movio stock: %s, antes %s', v_f1, v_f0));
  f := pg_temp.rr_si(f, p_mueve OR v_b1 = v_b0, format('editar con [X2, Y2] movio las barras: %s, antes %s', v_b1, v_b0));

  -- La promo cambio: se disuelve.
  PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 5, v_promo)));
  v_l1 := pg_temp.rr_lineas(v_ped);
  f := pg_temp.rr_si(f, v_l1 = jsonb_build_array(jsonb_build_object('p', x, 'c', 5, 'k', NULL)),
                     format('con la promo en 5 quedo %s, esperado X5 sin cadena', v_l1));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.rr_e1_modo(p_cli, p_adm, p_suc, true);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e4(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT pg_temp.rr_e1_modo(p_cli, p_adm, p_suc, false);
$fn$;

-- ---------------------------------------------------------------------------
-- E2 · las guardas de dividir_regalo_pedido (#1090). Cada subcaso en su pedido.
--   a · A4 -> Z8 por valor (otra categoria): repartir Z8 se rechaza.
--   b · A4 -> B4 misma categoria, la promo pasa a 5 (B5): repartir B5 pasa.
--   c · A4 -> Z8 -> A4: repartir A4 pasa.
--   d · parte Y2 -> Y3 (mismo producto): repartirla se rechaza.
--   e · parte Y2 -> W3 (misma categoria): repartirla se rechaza.
--   f · parte Y2 sin cambios: repartirla pasa.
--   g · parte Y2 -> Z4 (otra categoria): repartirla se rechaza.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; a bigint; b bigint; w bigint; z bigint; v_promo bigint; v_ped bigint;
  v_res jsonb; s text;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50, NULL);
  a := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  b := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50, NULL);
  v_promo := pg_temp.rr_promo(p_suc, a, true, false, NULL, NULL);

  FOREACH s IN ARRAY ARRAY['a', 'b', 'c', 'd', 'e', 'f', 'g'] LOOP
    v_ped := pg_temp.rr_alta(p_cli, p_adm, v, jsonb_build_array(pg_temp.rr_r(a, 4, v_promo)));
    IF s = 'a' THEN
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, a), z, 8);
      v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, z), jsonb_build_array(pg_temp.rr_parte(z, 4), pg_temp.rr_parte(w, 4)));
      f := pg_temp.rr_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'error' LIKE '%se cambió por valor%',
                         format('a · repartir Z8 que salio de A4 por valor dio %s, esperado el rechazo', v_res));
    ELSIF s = 'b' THEN
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, a), b, 4);
      PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(a, 5, v_promo)));
      IF pg_temp.rr_lineas(v_ped)->0->>'p' <> b::text OR (pg_temp.rr_lineas(v_ped)->0->>'c')::int <> 5 THEN
        f := f || format('b · punto de partida: %s, esperado B5', pg_temp.rr_lineas(v_ped));
      ELSE
        v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, b), jsonb_build_array(pg_temp.rr_parte(b, 3), pg_temp.rr_parte(a, 2)));
        f := pg_temp.rr_si(f, COALESCE((v_res->>'success')::boolean, false),
                           format('b · repartir B5 (A4->B4, misma categoria, promo en 5) dio %s, esperado que pase', v_res));
      END IF;
    ELSIF s = 'c' THEN
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, a), z, 8);
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, z), a, 4);
      v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, a), jsonb_build_array(pg_temp.rr_parte(a, 2), pg_temp.rr_parte(w, 2)));
      f := pg_temp.rr_si(f, COALESCE((v_res->>'success')::boolean, false),
                         format('c · repartir A4 (A4->Z8->A4) dio %s, esperado que pase', v_res));
    ELSE
      v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, a), jsonb_build_array(pg_temp.rr_parte(a, 2), pg_temp.rr_parte(b, 2)));
      IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
        RAISE EXCEPTION '% · no se pudo repartir: %', s, v_res;
      END IF;
      IF s = 'd' THEN
        PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, b), b, 3);
        v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, b), jsonb_build_array(pg_temp.rr_parte(b, 2), pg_temp.rr_parte(w, 1)));
        f := pg_temp.rr_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'error' LIKE '%ya cambió de cantidad%',
                           format('d · repartir la parte Y2->Y3 dio %s, esperado el rechazo', v_res));
      ELSIF s = 'e' THEN
        PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, b), w, 3);
        v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, w), jsonb_build_array(pg_temp.rr_parte(w, 2), pg_temp.rr_parte(b, 1)));
        f := pg_temp.rr_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'error' LIKE '%ya cambió de cantidad%',
                           format('e · repartir la parte Y2->W3 (misma categoria) dio %s, esperado el rechazo', v_res));
      ELSIF s = 'f' THEN
        v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, b), jsonb_build_array(pg_temp.rr_parte(b, 1), pg_temp.rr_parte(w, 1)));
        f := pg_temp.rr_si(f, COALESCE((v_res->>'success')::boolean, false),
                           format('f · repartir la parte Y2 sin cambios dio %s, esperado que pase', v_res));
      ELSE
        PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, b), z, 4);
        v_res := pg_temp.rr_dividir(pg_temp.rr_linea(v_ped, z), jsonb_build_array(pg_temp.rr_parte(z, 2), pg_temp.rr_parte(w, 2)));
        f := pg_temp.rr_si(f, NOT COALESCE((v_res->>'success')::boolean, false) AND v_res->>'error' LIKE '%se cambió por valor%',
                           format('g · repartir la parte Y2->Z4 (otra categoria) dio %s, esperado el rechazo', v_res));
      END IF;
    END IF;
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- E3 · #1091: alta Y2 + W2 de una promo (default X): dos filas de reparto con
-- el mismo reparto_id, claves distintas, original X por 4 y cada parte
-- describiendose a si misma; el stock del alta es el de siempre (V -10, Y -2,
-- W -2, 'pedido_creado'). Despues Y -> Z, la promo se cae y vuelve con Y4: no
-- hereda la clave de la parte (quedaria Z8).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; w bigint; z bigint; v_promo bigint; v_ped bigint;
  v_l jsonb; v_filas jsonb; v_hist jsonb; v_esperado jsonb;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50, NULL);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50, NULL);
  v_promo := pg_temp.rr_promo(p_suc, x, true, false, NULL, NULL);

  v_ped := pg_temp.rr_alta(p_cli, p_adm, v, jsonb_build_array(pg_temp.rr_r(y, 2, v_promo), pg_temp.rr_r(w, 2, v_promo)));

  v_l := pg_temp.rr_lineas(v_ped);
  f := pg_temp.rr_si(f, jsonb_array_length(v_l) = 2 AND v_l->0->>'k' IS NOT NULL AND v_l->1->>'k' IS NOT NULL
                        AND v_l->0->>'k' <> v_l->1->>'k',
                     format('las partes del alta quedaron %s, esperado una clave propia cada una', v_l));
  SELECT jsonb_agg(jsonb_build_object('item', s.pedido_item_id, 'orig', s.producto_original_id,
                                      'sust', s.producto_sustituto_id, 'co', s.cantidad_original,
                                      'cs', s.cantidad_sustituta, 'raiz', s.producto_raiz_id,
                                      'cadena', s.cadena_id, 'reparto', s.reparto_id, 'motivo', s.motivo,
                                      'snap', s.regalo_mueve_stock_snapshot)
                   ORDER BY s.producto_sustituto_id)
    INTO v_filas
    FROM public.pedido_item_sustituciones s WHERE s.pedido_id = v_ped;
  f := pg_temp.rr_si(f,
         jsonb_array_length(COALESCE(v_filas, '[]')) = 2
         AND v_filas->0->>'reparto' IS NOT NULL AND v_filas->0->>'reparto' = v_filas->1->>'reparto'
         AND NOT EXISTS (
           SELECT 1 FROM jsonb_array_elements(v_filas) e
            WHERE (e->>'orig')::bigint <> x OR (e->>'co')::numeric <> 4 OR (e->>'cs')::numeric <> 2
               OR (e->>'raiz')::bigint <> (e->>'sust')::bigint OR e->>'motivo' <> 'Reparto al cargar el pedido'
               OR NOT (e->>'snap')::boolean
               OR NOT EXISTS (SELECT 1 FROM public.pedido_items pi
                               WHERE pi.id = (e->>'item')::bigint AND pi.producto_id = (e->>'sust')::bigint
                                 AND pi.regalo_cadena_id = (e->>'cadena')::uuid)),
         format('las filas de reparto del alta quedaron %s', v_filas));
  f := pg_temp.rr_si(f, NOT EXISTS (SELECT 1 FROM public.pedido_items
                                     WHERE pedido_id = v_ped AND descripcion_regalo LIKE '%[Sustituido por:%'),
                     'una parte del alta quedo marcada como sustituida');
  -- El stock del alta, el de un alta Y2 + W2 sin el parche.
  SELECT jsonb_agg(jsonb_build_array(h.producto_id, h.diferencia, h.origen) ORDER BY h.producto_id, h.id)
    INTO v_hist
    FROM public.stock_historico h WHERE h.referencia_tipo = 'pedido' AND h.referencia_id = v_ped;
  SELECT jsonb_agg(e ORDER BY (e->>0)::bigint)
    INTO v_esperado
    FROM jsonb_array_elements(jsonb_build_array(jsonb_build_array(v, -10, 'pedido_creado'),
                                                jsonb_build_array(y, -2, 'pedido_creado'),
                                                jsonb_build_array(w, -2, 'pedido_creado'))) e;
  f := pg_temp.rr_si(f, v_hist = v_esperado, format('el stock del alta fue %s, esperado %s', v_hist, v_esperado));

  -- Y -> Z, la promo se cae y vuelve.
  PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, y), z, 4);
  PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10)));
  PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(y, 4, v_promo)));
  v_l := pg_temp.rr_lineas(v_ped);
  f := pg_temp.rr_si(f, v_l = jsonb_build_array(jsonb_build_object('p', y, 'c', 4, 'k', NULL)),
                     format('la promo que volvio quedo %s, esperado Y4 sin cadena', v_l));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- E5 · PROMO-B. now() es el mismo en toda la transaccion, asi que las filas
-- de sustitucion y el stock del alta se corren un dia para atras antes de la
-- edicion: si no, el "posterior a la fila" del predicado no separa el alta de
-- la edicion y el ensayo no muerde.
--   a · alta Y2 + W2 (default X), la promo pasa a 5: X5. El predicado viejo
--       cuenta las filas de reparto; PROMO-B queda en 0.
--   b · alta Y2 + W2, Y -> Z, la promo se cae y vuelve con Y4: el predicado
--       viejo cuenta el eslabon Y -> Z de una clave sin linea; PROMO-B en 0.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; w bigint; z bigint; v_promo bigint; v_ped bigint;
  v_viejo bigint; v_nuevo numeric; s text;
BEGIN
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50, NULL);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50, NULL);
  v_promo := pg_temp.rr_promo(p_suc, x, true, false, NULL, NULL);

  FOREACH s IN ARRAY ARRAY['a', 'b'] LOOP
    v_ped := pg_temp.rr_alta(p_cli, p_adm, v, jsonb_build_array(pg_temp.rr_r(y, 2, v_promo), pg_temp.rr_r(w, 2, v_promo)));
    IF s = 'b' THEN
      PERFORM pg_temp.rr_sustituir(pg_temp.rr_linea(v_ped, y), z, 4);
    END IF;
    -- El alta (y el cambio de b) pasaron ayer: sus filas y su stock.
    UPDATE public.pedido_item_sustituciones SET created_at = now() - interval '1 day' WHERE pedido_id = v_ped;
    UPDATE public.stock_historico SET created_at = now() - interval '1 day'
     WHERE referencia_tipo = 'pedido' AND referencia_id = v_ped;
    IF s = 'a' THEN
      PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(x, 5, v_promo)));
    ELSE
      PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10)));
      PERFORM pg_temp.rr_editar(v_ped, p_adm, jsonb_build_array(pg_temp.rr_v(v, 10), pg_temp.rr_r(y, 4, v_promo)));
    END IF;
    v_viejo := pg_temp.rr_promo_b_viejo(v_ped);
    v_nuevo := pg_temp.rr_promo_b_auditoria();
    f := pg_temp.rr_si(f, v_viejo > 0, format('%s · el predicado viejo de PROMO-B dio %s: el ensayo no muerde', s, v_viejo));
    f := pg_temp.rr_si(f, v_nuevo = 0, format('%s · PROMO-B de auditoria_integridad dio %s, esperado 0', s, v_nuevo));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- E6 · el backfill de la migracion (pg_temp.rr_backfill, solo existe adentro
-- de ella): a · dos lineas de regalo de una promo sin claves -> dos claves y
-- dos filas de reparto; b · si una ya tiene un eslabon comun, aborta.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_linea_regalo_suelta(p_ped bigint, p_prod bigint, p_suc bigint,
                                                          p_cant int, p_promo bigint)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_item bigint;
BEGIN
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (p_ped, p_prod, p_cant, 0, 0, p_suc, true, p_promo)
  RETURNING id INTO v_item;
  RETURN v_item;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.rr_caso_e6(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v bigint; x bigint; y bigint; w bigint; z bigint; v_promo bigint; v_ped bigint;
  v_n int; v_l jsonb; v_filas int; v_item bigint; v_err text;
BEGIN
  IF to_regprocedure('pg_temp.rr_backfill(bigint)') IS NULL THEN
    RETURN jsonb_build_object('fallas', '[]'::jsonb, 'reporte', 'sin rr_backfill: E6 solo corre adentro de la migracion');
  END IF;
  v := pg_temp.rr_prod(p_suc, p_adm, 'venta', 20, 50, NULL);
  x := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  y := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  w := pg_temp.rr_prod(p_suc, p_adm, 'cat A', 20, 50, NULL);
  z := pg_temp.rr_prod(p_suc, p_adm, 'cat B', 20, 50, NULL);
  v_promo := pg_temp.rr_promo(p_suc, x, true, false, NULL, NULL);

  -- a
  v_ped := pg_temp.rr_alta(p_cli, p_adm, v, '[]'::jsonb);
  PERFORM pg_temp.rr_linea_regalo_suelta(v_ped, y, p_suc, 2, v_promo);
  PERFORM pg_temp.rr_linea_regalo_suelta(v_ped, w, p_suc, 2, v_promo);
  v_n := pg_temp.rr_backfill(v_ped);
  v_l := pg_temp.rr_lineas(v_ped);
  SELECT count(*) INTO v_filas FROM public.pedido_item_sustituciones s
   WHERE s.pedido_id = v_ped AND s.reparto_id IS NOT NULL AND s.cantidad_original = 4
     AND s.producto_original_id = x AND s.motivo = 'Reparto al cargar el pedido (backfill)'
     AND EXISTS (SELECT 1 FROM public.pedido_items pi WHERE pi.id = s.pedido_item_id
                    AND pi.regalo_cadena_id = s.cadena_id AND pi.producto_id = s.producto_sustituto_id
                    AND pi.cantidad = s.cantidad_sustituta);
  f := pg_temp.rr_si(f, v_n = 1 AND v_filas = 2 AND v_l->0->>'k' IS NOT NULL AND v_l->1->>'k' IS NOT NULL
                        AND v_l->0->>'k' <> v_l->1->>'k',
                     format('a · el backfill dio %s grupos, %s filas y lineas %s', v_n, v_filas, v_l));

  -- b
  v_ped := pg_temp.rr_alta(p_cli, p_adm, v, '[]'::jsonb);
  v_item := pg_temp.rr_linea_regalo_suelta(v_ped, y, p_suc, 2, v_promo);
  PERFORM pg_temp.rr_linea_regalo_suelta(v_ped, w, p_suc, 2, v_promo);
  UPDATE public.pedido_items SET regalo_cadena_id = gen_random_uuid() WHERE id = v_item;
  INSERT INTO public.pedido_item_sustituciones (pedido_id, pedido_item_id, promocion_id, producto_original_id,
                                                producto_sustituto_id, cantidad_original, cantidad_sustituta,
                                                regalo_mueve_stock_snapshot, motivo, autorizado_por, sucursal_id,
                                                cadena_id)
  SELECT v_ped, v_item, v_promo, z, y, 4, 2, true, 'ensayo 1090', p_adm, p_suc, regalo_cadena_id
    FROM public.pedido_items WHERE id = v_item;
  BEGIN
    PERFORM pg_temp.rr_backfill(v_ped);
    v_err := NULL;
  EXCEPTION WHEN OTHERS THEN
    v_err := SQLERRM;
  END;
  f := pg_temp.rr_si(f, v_err LIKE '%resolverlo a mano%',
                     format('b · el backfill con un eslabon comun dio %s, esperado que aborte', COALESCE(v_err, 'OK')));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo1090$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_caso    text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
  v_notas   text[] := '{}';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  SELECT id INTO v_cliente FROM clientes
   WHERE sucursal_id = v_suc AND activo AND tipo_factura_default IS DISTINCT FROM 'VB'
   ORDER BY id LIMIT 1;
  IF v_admin IS NULL OR v_cliente IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLO · hace falta un admin activo con una sucursal activa y un cliente activo en ella';
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  FOREACH v_caso IN ARRAY ARRAY['e1', 'e2', 'e3', 'e4', 'e5', 'e6'] LOOP
    v_out := NULL;
    BEGIN
      PERFORM pg_temp.rr_reset();
      EXECUTE format('SELECT pg_temp.rr_caso_%s($1, $2, $3)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
      IF v_out->>'reporte' IS NOT NULL THEN
        v_notas := v_notas || (upper(v_caso) || ' · ' || (v_out->>'reporte'));
      END IF;
    END IF;
  END LOOP;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas):\n- %\nnotas: %',
      cardinality(v_fallas), array_to_string(v_fallas, E'\n- '), array_to_string(v_notas, ' | ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · notas: %', array_to_string(v_notas, ' | ');
END
$ensayo1090$;
