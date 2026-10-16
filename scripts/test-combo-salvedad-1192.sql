-- Ensayo de #1192: la salvedad decide por el motivo si el combo se rompe.
--
-- Fixture: Fernet (lista 10.000) y Coca (lista 2.500), combo 1 + 1 a $9.800:
-- Fernet 7.840 y Coca 1.960 (el ejemplo del issue). Cada producto con un lote
-- de 100 y bolsa 0, asi que las lineas nacen con huella entera.
--
--   M1 · cliente_rechaza la Coca de 1 combo: el Fernet vuelve a 10.000 (la
--        linea entera, sin partir), recargo 2.160, total 10.000, foto 0 combos
--        vivos y recargo 2.160 (el ejemplo del issue).
--   M2 · los otros siete motivos (faltante_stock, producto_danado,
--        producto_vencido, error_pedido, entregado_otro_cliente,
--        diferencia_precio, otro): el Fernet sigue a 7.840, recargo 0, total
--        7.840, foto 1 combo.
--   D2 · 2 combos, el cliente rechaza 1 Coca: queda 1 combo, la linea del
--        Fernet se parte (1 a 7.840 y 1 a 10.000), la huella se reparte 1 y 1
--        sin mover stock ni lotes, recargo 2.160, total 19.800. La simulacion
--        predijo el mismo recargo.
--   A1 · anular D2: una linea de Fernet de 2 (la vieja) con su huella de 2,
--        Coca 2, total 19.600, foto 2 combos y recargo 0, stock como antes.
--   C1 · boleta cobrada (9.800 en efectivo), el cliente rechaza la Coca: el
--        total sube a 10.000, el pago queda intacto, estado parcial y la
--        cuenta corriente del cliente sube 200 (la deuda).
--   V1 · un vale blanco no lleva combos (crear lo rechaza), y una salvedad
--        sobre un vale blanco lo deja saldado (monto_pagado = total, pagado,
--        sin filas en pagos).
--   L1 · lote: 2 combos, el cliente rechaza 1 Fernet y 1 Coca (las lineas que
--        vio el chofer): queda 1 combo entero a 9.800, sin lineas fuera del
--        combo; los recargos suman 0. En el orden inverso da lo mismo. La
--        simulacion del lote predijo 0 y 1 combo.
--   L2 · el pozo: 2 combos, el cliente rechaza 1 Fernet y despues 2 Cocas
--        sobre la linea de Coca que ya se habia partido (1 + 1): la salvedad
--        toma de las dos. Queda el Fernet solo, a 10.000.
--   N1 · anular en otro orden: L1 y se anula la primera (Fernet): queda como
--        si solo se hubiera rechazado la Coca (19.800); anulada la otra, 19.600.
--   R1 · un motivo nuestro rearma: 2 combos, el cliente rechaza 1 Fernet (la
--        Coca se parte) y despues se rompe la Coca del combo: la que habia
--        salido vuelve al combo. Total 9.800, recargo -540.
--   Q1 · combo 2 Coca + 1 Fernet a 14.000, 3 combos: el cliente rechaza 1 Coca
--        (quedan 2: sale 1 Coca y 1 Fernet, 40.500) y despues otra (siguen 2:
--        la Coca que habia salido vuelve, 38.000). La cuenta es la acumulada
--        del issue, floor((6 - 2) / 2).
--   G1 · los gates: PRECIO-A, COSTO-D, STK-F y SEG-A en 0.
--
-- Cada caso controla tambien COMBO-A, COMBO-B y LOTE-D de su pedido.
--
-- Corre contra prod SIN dejar rastro: cada caso se revierte en su subbloque y
-- el script termina con RAISE EXCEPTION 'ENSAYO_ROLLBACK', que revierte toda
-- la transaccion. Veredicto: 'ENSAYO FALLO (...)' con la lista de fallas, o,
-- si todo pasa, el unico error es 'ENSAYO_ROLLBACK' (el NOTICE dice ENSAYO OK).
-- Para el ensayo en seco de la migracion: el SQL de la migracion y este script
-- en una sola llamada (una transaccion implicita); el RAISE final la revierte.
--
--   psql "$DATABASE_URL" -1 -f migrations/383b_la_salvedad_rompe_el_combo.sql \
--                           -f scripts/test-combo-salvedad-1192.sql

CREATE OR REPLACE FUNCTION pg_temp.t_hoy()
RETURNS date LANGUAGE sql AS $fn$
  SELECT (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

-- Un producto con lista p_lista, costo 60% y un lote de 100 (bolsa 0).
CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_admin uuid, p_nombre text, p_lista numeric)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_prod   bigint;
  v_compra bigint;
  v_lote   bigint;
BEGIN
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1192 ' || p_nombre, p_lista, 100, round(p_lista * 0.6, 2), p_suc)
  RETURNING id INTO v_prod;
  INSERT INTO public.compras (sucursal_id, estado, usuario_id)
  VALUES (p_suc, 'recibida', p_admin) RETURNING id INTO v_compra;
  INSERT INTO public.producto_lotes (producto_id, sucursal_id, fecha_vencimiento, cantidad,
                                     cantidad_restante, usuario_id, compra_id)
  VALUES (v_prod, p_suc, pg_temp.t_hoy() + 90, 100, 100, p_admin, v_compra)
  RETURNING id INTO v_lote;
  RETURN jsonb_build_object('prod', v_prod, 'lote', v_lote);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_combo(p_suc bigint, p_precio numeric, p_comp jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.guardar_combo(jsonb_build_object('nombre', 'ZZ ensayo 1192', 'precio', p_precio,
                                                   'fecha_inicio', pg_temp.t_hoy(), 'componentes', p_comp));
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el combo: %', v_res;
  END IF;
  RETURN (v_res->>'id')::bigint;
END
$fn$;

-- Un pedido con lineas [{prod, cant, precio, combo?, sin_combo?}].
CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_admin uuid, p_lineas jsonb, p_tipo text DEFAULT 'ZZ')
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
  v_ped bigint;
BEGIN
  v_res := public.crear_pedido_completo(
    p_cli,
    (SELECT SUM((x->>'cant')::int * (x->>'precio')::numeric) FROM jsonb_array_elements(p_lineas) x),
    p_admin,
    (SELECT jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
              'producto_id', (x->>'prod')::bigint, 'cantidad', (x->>'cant')::int,
              'precio_unitario', (x->>'precio')::numeric,
              'combo_id', NULLIF(x->>'combo', '')::bigint,
              'precio_sin_combo_unitario', NULLIF(x->>'sin_combo', '')::numeric)))
       FROM jsonb_array_elements(p_lineas) x),
    'ensayo 1192', 'efectivo', 'pendiente', NULL, p_tipo);
  PERFORM pg_temp.t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RETURN jsonb_build_object('error', v_res);
  END IF;
  v_ped := (v_res->>'pedido_id')::bigint;
  RETURN jsonb_build_object('pedido', v_ped,
    'items', (SELECT jsonb_object_agg(producto_id::text, id) FROM public.pedido_items WHERE pedido_id = v_ped));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_reset()
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  PERFORM set_config('app.stock_user_id', '', true);
  PERFORM set_config('app.stock_pedido_item_id', '', true);
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_salvedad(p_ped bigint, p_item bigint, p_cant int, p_motivo text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.registrar_salvedad(p_ped, p_item, p_cant, p_motivo,
                                     'ensayo 1192: descripcion del caso', NULL, true, NULL);
  PERFORM pg_temp.t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'registrar % (item %, %): %', p_motivo, p_item, p_cant, v_res;
  END IF;
  RETURN v_res;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_anular(p_salv bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  v_res jsonb;
BEGIN
  v_res := public.anular_salvedad(p_salv, 'ensayo 1192');
  PERFORM pg_temp.t_reset();
  IF NOT COALESCE((v_res->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'anular %: %', p_salv, v_res;
  END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_total(p_ped bigint)
RETURNS numeric LANGUAGE sql AS $fn$
  SELECT total FROM public.pedidos WHERE id = p_ped;
$fn$;

-- Las lineas de venta de un producto: "cantidad@precio[c|r]" por id (c = en el
-- combo, r = salio de un combo roto).
CREATE OR REPLACE FUNCTION pg_temp.t_lineas(p_ped bigint, p_prod bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(string_agg(cantidad || '@' || trim(to_char(precio_unitario, 'FM999999990.00'))
                             || CASE WHEN combo_id IS NOT NULL THEN 'c'
                                     WHEN combo_roto_id IS NOT NULL THEN 'r' ELSE '' END,
                             ' ' ORDER BY id), '-')
    FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND NOT COALESCE(es_bonificacion, false);
$fn$;

-- La huella de cada linea de un producto, por id.
CREATE OR REPLACE FUNCTION pg_temp.t_huellas(p_ped bigint, p_prod bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE(string_agg(COALESCE((SELECT SUM(pil.cantidad)::int FROM public.pedido_item_lotes pil
                                        WHERE pil.pedido_item_id = pi.id), 0)::text, ' ' ORDER BY pi.id), '-')
    FROM public.pedido_items pi
   WHERE pi.pedido_id = p_ped AND pi.producto_id = p_prod AND NOT COALESCE(pi.es_bonificacion, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_stock(p_prod bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT pr.stock || '/' || COALESCE((SELECT SUM(l.cantidad_restante) FROM public.producto_lotes l
                                       WHERE l.producto_id = pr.id), 0)
    FROM public.productos pr WHERE pr.id = p_prod;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_foto(p_ped bigint, p_combo bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT COALESCE((SELECT cantidad_combos || '/' || cantidad_combos_armados || ' r'
                          || trim(to_char(recargo, 'FM999999990.00'))
                     FROM public.pedido_combos WHERE pedido_id = p_ped AND combo_id = p_combo), '-');
$fn$;

-- COMBO-A, COMBO-B y LOTE-D de un pedido (0 = bien).
CREATE OR REPLACE FUNCTION pg_temp.t_gates(p_ped bigint)
RETURNS text LANGUAGE sql AS $fn$
  SELECT 'A' || (SELECT count(*) FROM public.pedido_items pi
                   LEFT JOIN public.pedido_combos f
                     ON f.pedido_id = pi.pedido_id AND f.combo_id = pi.combo_id AND f.sucursal_id = pi.sucursal_id
                   LEFT JOIN LATERAL (SELECT c FROM jsonb_array_elements(f.componentes) c
                                       WHERE c->'productos' @> to_jsonb(pi.producto_id) LIMIT 1) lug ON true
                  WHERE pi.pedido_id = p_ped AND pi.combo_id IS NOT NULL
                    AND (f.pedido_id IS NULL OR lug.c IS NULL
                         OR (SELECT COALESCE(sum(pj.cantidad), 0) FROM public.pedido_items pj
                              WHERE pj.pedido_id = pi.pedido_id AND pj.combo_id = pi.combo_id
                                AND lug.c->'productos' @> to_jsonb(pj.producto_id))
                            > f.cantidad_combos * (lug.c->>'cantidad')::int))
      || ' B' || (SELECT count(*) FROM public.pedido_combos f
                   CROSS JOIN LATERAL (SELECT public._combo_estado(f.pedido_id, f.sucursal_id, f.combo_id, NULL) AS e) x
                   CROSS JOIN LATERAL (SELECT public._combo_plan(x.e->'componentes', (x.e->>'armados')::int,
                                                                 x.e->'lineas', x.e->'rechazos', x.e->'precios') AS pl) y
                  WHERE f.pedido_id = p_ped
                    AND (y.pl IS NULL
                         OR f.cantidad_combos IS DISTINCT FROM (y.pl->>'combos')::int
                         OR f.recargo IS DISTINCT FROM (y.pl->>'recargo')::numeric
                         OR EXISTS (SELECT 1 FROM jsonb_array_elements(x.e->'lineas') l
                                     WHERE (l->>'en_combo')::int
                                           IS DISTINCT FROM (y.pl->'productos'->(l->>'producto_id')->>'en_combo')::int)))
      || ' D' || (SELECT count(*) FROM (SELECT pil.pedido_item_id FROM public.pedido_item_lotes pil
                                          JOIN public.pedido_items pi ON pi.id = pil.pedido_item_id
                                         WHERE pi.pedido_id = p_ped
                                         GROUP BY pil.pedido_item_id, pi.cantidad
                                        HAVING SUM(pil.cantidad) > pi.cantidad) z);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_simular(p_ped bigint, p_salv jsonb)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT public.simular_salvedades_combo_impacto(p_ped, p_salv);
$fn$;

-- El fixture: Fernet, Coca y el combo 1 + 1 a 9.800, y un pedido de p_k combos.
CREATE OR REPLACE FUNCTION pg_temp.t_base(p_cli bigint, p_adm uuid, p_suc bigint, p_k int)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f jsonb; c jsonb; v_combo bigint; p jsonb;
BEGIN
  f := pg_temp.t_prod(p_suc, p_adm, 'Fernet', 10000);
  c := pg_temp.t_prod(p_suc, p_adm, 'Coca', 2500);
  v_combo := pg_temp.t_combo(p_suc, 9800, jsonb_build_array(
    jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array((f->>'prod')::bigint)),
    jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array((c->>'prod')::bigint))));
  p := pg_temp.t_pedido(p_cli, p_adm, jsonb_build_array(
    jsonb_build_object('prod', f->'prod', 'cant', p_k, 'precio', 7840, 'combo', v_combo, 'sin_combo', 10000),
    jsonb_build_object('prod', c->'prod', 'cant', p_k, 'precio', 1960, 'combo', v_combo, 'sin_combo', 2500)));
  IF p ? 'error' THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', p->'error';
  END IF;
  RETURN jsonb_build_object('f', (f->>'prod')::bigint, 'c', (c->>'prod')::bigint, 'combo', v_combo,
                            'pedido', (p->>'pedido')::bigint,
                            'lf', (p->'items'->>(f->>'prod'))::bigint, 'lc', (p->'items'->>(c->>'prod'))::bigint);
END
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION pg_temp.caso_m1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; r jsonb; f text[] := '{}'; v_salv record;
BEGIN
  b := pg_temp.t_base(p_cli, p_adm, p_suc, 1);
  v_ped := b->>'pedido';
  r := pg_temp.t_salvedad(v_ped, (b->>'lc')::bigint, 1, 'cliente_rechaza');
  SELECT * INTO v_salv FROM public.salvedades_items WHERE id = (r->>'salvedad_id')::bigint;
  f := pg_temp.t_si(f, v_salv.monto_afectado = 1960 AND v_salv.recargo_combo = 2160
                       AND (r->>'recargo_combo')::numeric = 2160 AND v_salv.combo_id = (b->>'combo')::bigint,
                    format('monto %s y recargo %s (contesta %s), esperado 1960 y 2160',
                           v_salv.monto_afectado, v_salv.recargo_combo, r->>'recargo_combo'));
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (b->>'f')::bigint) = '1@10000.00r'
                       AND pg_temp.t_lineas(v_ped, (b->>'c')::bigint) = '-',
                    format('Fernet %s, Coca %s; esperado 1@10000.00r y sin Coca',
                           pg_temp.t_lineas(v_ped, (b->>'f')::bigint), pg_temp.t_lineas(v_ped, (b->>'c')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_total(v_ped) = 10000 AND (r->>'nuevo_total_pedido')::numeric = 10000,
                    format('total %s, esperado 10000', pg_temp.t_total(v_ped)));
  f := pg_temp.t_si(f, pg_temp.t_foto(v_ped, (b->>'combo')::bigint) = '0/1 r2160.00',
                    format('foto %s, esperado 0/1 r2160.00', pg_temp.t_foto(v_ped, (b->>'combo')::bigint)));
  f := pg_temp.t_si(f, (v_salv.combo_detalle->>'combos_antes')::int = 1 AND (v_salv.combo_detalle->>'combos_despues')::int = 0,
                    format('combo_detalle %s', v_salv.combo_detalle));
  f := pg_temp.t_si(f, (SELECT origen_precio FROM public.pedido_items WHERE id = (b->>'lf')::bigint) = 'lista',
                    'el Fernet fuera del combo tendria que quedar con origen lista');
  f := pg_temp.t_si(f, pg_temp.t_gates(v_ped) = 'A0 B0 D0', format('gates %s', pg_temp.t_gates(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_m2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; r jsonb; f text[] := '{}'; v_motivo text;
BEGIN
  FOREACH v_motivo IN ARRAY ARRAY['faltante_stock', 'producto_danado', 'producto_vencido', 'error_pedido',
                                  'entregado_otro_cliente', 'diferencia_precio', 'otro'] LOOP
    b := pg_temp.t_base(p_cli, p_adm, p_suc, 1);
    v_ped := b->>'pedido';
    r := pg_temp.t_salvedad(v_ped, (b->>'lc')::bigint, 1, v_motivo);
    f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (b->>'f')::bigint) = '1@7840.00c'
                         AND pg_temp.t_total(v_ped) = 7840
                         AND (r->>'recargo_combo')::numeric = 0
                         AND pg_temp.t_foto(v_ped, (b->>'combo')::bigint) = '1/1 r0.00'
                         AND pg_temp.t_gates(v_ped) = 'A0 B0 D0',
                      format('%s: Fernet %s, total %s, recargo %s, foto %s, gates %s; esperado 1@7840.00c, 7840, 0, 1/1 r0.00',
                             v_motivo, pg_temp.t_lineas(v_ped, (b->>'f')::bigint), pg_temp.t_total(v_ped),
                             r->>'recargo_combo', pg_temp.t_foto(v_ped, (b->>'combo')::bigint), pg_temp.t_gates(v_ped)));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_d2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; r jsonb; s jsonb; f text[] := '{}'; v_stock_f text;
BEGIN
  b := pg_temp.t_base(p_cli, p_adm, p_suc, 2);
  v_ped := b->>'pedido';
  v_stock_f := pg_temp.t_stock((b->>'f')::bigint);
  s := pg_temp.t_simular(v_ped, jsonb_build_array(jsonb_build_object(
         'pedido_item_id', b->'lc', 'cantidad_afectada', 1, 'motivo', 'cliente_rechaza')));
  r := pg_temp.t_salvedad(v_ped, (b->>'lc')::bigint, 1, 'cliente_rechaza');
  f := pg_temp.t_si(f, (s->0->>'recargo')::numeric = 2160 AND (s->0->>'combos_antes')::int = 2
                       AND (s->0->>'combos_despues')::int = 1 AND (r->>'recargo_combo')::numeric = 2160,
                    format('simulado %s, registrado %s; esperado recargo 2160 y 2 -> 1 combos', s, r->>'recargo_combo'));
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (b->>'f')::bigint) = '1@7840.00c 1@10000.00r'
                       AND pg_temp.t_lineas(v_ped, (b->>'c')::bigint) = '1@1960.00c',
                    format('Fernet %s, Coca %s', pg_temp.t_lineas(v_ped, (b->>'f')::bigint),
                           pg_temp.t_lineas(v_ped, (b->>'c')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_huellas(v_ped, (b->>'f')::bigint) = '1 1'
                       AND pg_temp.t_stock((b->>'f')::bigint) = v_stock_f,
                    format('huella del Fernet %s (esperado 1 1), stock %s (antes %s)',
                           pg_temp.t_huellas(v_ped, (b->>'f')::bigint), pg_temp.t_stock((b->>'f')::bigint), v_stock_f));
  f := pg_temp.t_si(f, pg_temp.t_total(v_ped) = 19800 AND pg_temp.t_foto(v_ped, (b->>'combo')::bigint) = '1/2 r2160.00',
                    format('total %s, foto %s', pg_temp.t_total(v_ped), pg_temp.t_foto(v_ped, (b->>'combo')::bigint)));
  f := pg_temp.t_si(f, (SELECT costo_unitario_al_crear FROM public.pedido_items
                         WHERE pedido_id = v_ped AND combo_roto_id IS NOT NULL) = 6000,
                    'la parte que salio del combo tendria que conservar el costo de la venta (6000)');
  f := pg_temp.t_si(f, pg_temp.t_gates(v_ped) = 'A0 B0 D0', format('gates %s', pg_temp.t_gates(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_a1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; r jsonb; f text[] := '{}'; v_sf text; v_sc text; v_det jsonb;
BEGIN
  b := pg_temp.t_base(p_cli, p_adm, p_suc, 2);
  v_ped := b->>'pedido';
  v_sf := pg_temp.t_stock((b->>'f')::bigint); v_sc := pg_temp.t_stock((b->>'c')::bigint);
  r := pg_temp.t_salvedad(v_ped, (b->>'lc')::bigint, 1, 'cliente_rechaza');
  PERFORM pg_temp.t_anular((r->>'salvedad_id')::bigint);
  SELECT combo_detalle INTO v_det FROM public.salvedades_items WHERE id = (r->>'salvedad_id')::bigint;
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (b->>'f')::bigint) = '2@7840.00c'
                       AND (SELECT id FROM public.pedido_items WHERE pedido_id = v_ped AND producto_id = (b->>'f')::bigint)
                           = (b->>'lf')::bigint
                       AND pg_temp.t_lineas(v_ped, (b->>'c')::bigint) = '2@1960.00c',
                    format('Fernet %s, Coca %s; esperado la linea vieja 2@7840.00c y 2@1960.00c',
                           pg_temp.t_lineas(v_ped, (b->>'f')::bigint), pg_temp.t_lineas(v_ped, (b->>'c')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_huellas(v_ped, (b->>'f')::bigint) = '2' AND pg_temp.t_huellas(v_ped, (b->>'c')::bigint) = '2',
                    format('huellas %s / %s, esperado 2 / 2', pg_temp.t_huellas(v_ped, (b->>'f')::bigint),
                           pg_temp.t_huellas(v_ped, (b->>'c')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_total(v_ped) = 19600 AND pg_temp.t_foto(v_ped, (b->>'combo')::bigint) = '2/2 r0.00'
                       AND pg_temp.t_stock((b->>'f')::bigint) = v_sf AND pg_temp.t_stock((b->>'c')::bigint) = v_sc,
                    format('total %s, foto %s, stock F %s (antes %s), C %s (antes %s)', pg_temp.t_total(v_ped),
                           pg_temp.t_foto(v_ped, (b->>'combo')::bigint), pg_temp.t_stock((b->>'f')::bigint), v_sf,
                           pg_temp.t_stock((b->>'c')::bigint), v_sc));
  f := pg_temp.t_si(f, (v_det->'anulacion'->>'combos_despues')::int = 2,
                    format('combo_detalle de la anulacion: %s', v_det));
  f := pg_temp.t_si(f, pg_temp.t_gates(v_ped) = 'A0 B0 D0', format('gates %s', pg_temp.t_gates(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_c1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; f text[] := '{}'; v_saldo numeric; v_pagos text; v_ped_row record;
BEGIN
  b := pg_temp.t_base(p_cli, p_adm, p_suc, 1);
  v_ped := b->>'pedido';
  INSERT INTO public.pagos (cliente_id, pedido_id, monto, forma_pago, fecha, sucursal_id, usuario_id)
  VALUES (p_cli, v_ped, 9800, 'efectivo', pg_temp.t_hoy(), p_suc, p_adm);
  SELECT saldo_cuenta INTO v_saldo FROM public.clientes WHERE id = p_cli;
  SELECT string_agg(id || ':' || monto, ',' ORDER BY id) INTO v_pagos FROM public.pagos WHERE pedido_id = v_ped;
  SELECT * INTO v_ped_row FROM public.pedidos WHERE id = v_ped;
  f := pg_temp.t_si(f, v_ped_row.monto_pagado = 9800 AND v_ped_row.estado_pago = 'pagado',
                    format('antes: pagado %s, estado %s', v_ped_row.monto_pagado, v_ped_row.estado_pago));
  PERFORM pg_temp.t_salvedad(v_ped, (b->>'lc')::bigint, 1, 'cliente_rechaza');
  SELECT * INTO v_ped_row FROM public.pedidos WHERE id = v_ped;
  f := pg_temp.t_si(f, v_ped_row.total = 10000 AND v_ped_row.monto_pagado = 9800 AND v_ped_row.estado_pago = 'parcial',
                    format('total %s, pagado %s, estado %s; esperado 10000, 9800, parcial',
                           v_ped_row.total, v_ped_row.monto_pagado, v_ped_row.estado_pago));
  f := pg_temp.t_si(f, (SELECT string_agg(id || ':' || monto, ',' ORDER BY id) FROM public.pagos WHERE pedido_id = v_ped) = v_pagos,
                    'la salvedad toco los pagos de la boleta');
  f := pg_temp.t_si(f, (SELECT saldo_cuenta FROM public.clientes WHERE id = p_cli) = v_saldo + 200,
                    format('cuenta corriente %s, esperado %s (+200 de deuda)',
                           (SELECT saldo_cuenta FROM public.clientes WHERE id = p_cli), v_saldo + 200));
  f := pg_temp.t_si(f, pg_temp.t_gates(v_ped) = 'A0 B0 D0', format('gates %s', pg_temp.t_gates(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_v1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; p jsonb; v_ped bigint; f text[] := '{}'; v_row record; v_item bigint;
BEGIN
  b := pg_temp.t_base(p_cli, p_adm, p_suc, 1);
  -- El vale blanco es solo para un cliente habilitado, y el front lo manda a
  -- precio 0: lo precia el server, a costo (317).
  UPDATE public.clientes SET tipo_factura_default = 'VB' WHERE id = p_cli;
  -- Un vale blanco no lleva combos.
  p := pg_temp.t_pedido(p_cli, p_adm, jsonb_build_array(
    jsonb_build_object('prod', b->'f', 'cant', 1, 'precio', 0, 'combo', b->'combo', 'sin_combo', 10000),
    jsonb_build_object('prod', b->'c', 'cant', 1, 'precio', 0, 'combo', b->'combo', 'sin_combo', 2500)), 'VB');
  f := pg_temp.t_si(f, p ? 'error' AND (p->'error')::text ILIKE '%combos%',
                    format('un vale blanco con combos se creo, o se rechazo por otra cosa: %s', p));
  -- Una salvedad sobre un vale blanco lo deja saldado (3 a costo 6.000 = 18.000).
  p := pg_temp.t_pedido(p_cli, p_adm, jsonb_build_array(
    jsonb_build_object('prod', b->'f', 'cant', 3, 'precio', 0)), 'VB');
  IF p ? 'error' THEN
    RAISE EXCEPTION 'no se pudo crear el vale blanco: %', p->'error';
  END IF;
  v_ped := p->>'pedido';
  v_item := (p->'items'->>(b->>'f'))::bigint;
  PERFORM pg_temp.t_salvedad(v_ped, v_item, 1, 'cliente_rechaza');
  SELECT * INTO v_row FROM public.pedidos WHERE id = v_ped;
  f := pg_temp.t_si(f, v_row.total = 12000 AND v_row.monto_pagado = v_row.total AND v_row.estado_pago = 'pagado'
                       AND NOT EXISTS (SELECT 1 FROM public.pagos WHERE pedido_id = v_ped),
                    format('vale blanco: total %s, pagado %s, estado %s; esperado 12000 saldado sin pagos',
                           v_row.total, v_row.monto_pagado, v_row.estado_pago));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_l1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; r1 jsonb; r2 jsonb; s jsonb; f text[] := '{}'; v_orden int;
BEGIN
  FOR v_orden IN 1..2 LOOP
    b := pg_temp.t_base(p_cli, p_adm, p_suc, 2);
    v_ped := b->>'pedido';
    s := pg_temp.t_simular(v_ped, jsonb_build_array(
           jsonb_build_object('pedido_item_id', b->'lf', 'cantidad_afectada', 1, 'motivo', 'cliente_rechaza'),
           jsonb_build_object('pedido_item_id', b->'lc', 'cantidad_afectada', 1, 'motivo', 'cliente_rechaza')));
    IF v_orden = 1 THEN
      r1 := pg_temp.t_salvedad(v_ped, (b->>'lf')::bigint, 1, 'cliente_rechaza');
      r2 := pg_temp.t_salvedad(v_ped, (b->>'lc')::bigint, 1, 'cliente_rechaza');
    ELSE
      r1 := pg_temp.t_salvedad(v_ped, (b->>'lc')::bigint, 1, 'cliente_rechaza');
      r2 := pg_temp.t_salvedad(v_ped, (b->>'lf')::bigint, 1, 'cliente_rechaza');
    END IF;
    f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (b->>'f')::bigint) = '1@7840.00c'
                         AND pg_temp.t_lineas(v_ped, (b->>'c')::bigint) = '1@1960.00c'
                         AND pg_temp.t_total(v_ped) = 9800
                         AND (r1->>'recargo_combo')::numeric + (r2->>'recargo_combo')::numeric = 0
                         AND pg_temp.t_foto(v_ped, (b->>'combo')::bigint) = '1/2 r0.00',
                      format('orden %s: Fernet %s, Coca %s, total %s, recargos %s + %s, foto %s', v_orden,
                             pg_temp.t_lineas(v_ped, (b->>'f')::bigint), pg_temp.t_lineas(v_ped, (b->>'c')::bigint),
                             pg_temp.t_total(v_ped), r1->>'recargo_combo', r2->>'recargo_combo',
                             pg_temp.t_foto(v_ped, (b->>'combo')::bigint)));
    f := pg_temp.t_si(f, (s->0->>'recargo')::numeric = 0 AND (s->0->>'combos_despues')::int = 1,
                      format('la simulacion del lote dio %s, esperado recargo 0 y 1 combo', s));
    f := pg_temp.t_si(f, pg_temp.t_gates(v_ped) = 'A0 B0 D0', format('orden %s: gates %s', v_orden, pg_temp.t_gates(v_ped)));
  END LOOP;
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_l2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; f text[] := '{}'; s jsonb;
BEGIN
  b := pg_temp.t_base(p_cli, p_adm, p_suc, 2);
  v_ped := b->>'pedido';
  s := pg_temp.t_simular(v_ped, jsonb_build_array(
         jsonb_build_object('pedido_item_id', b->'lf', 'cantidad_afectada', 1, 'motivo', 'cliente_rechaza'),
         jsonb_build_object('pedido_item_id', b->'lc', 'cantidad_afectada', 2, 'motivo', 'cliente_rechaza')));
  PERFORM pg_temp.t_salvedad(v_ped, (b->>'lf')::bigint, 1, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (b->>'c')::bigint) = '1@1960.00c 1@2500.00r',
                    format('despues del Fernet, Coca %s; esperado 1@1960.00c 1@2500.00r',
                           pg_temp.t_lineas(v_ped, (b->>'c')::bigint)));
  -- El chofer vio 2 Cocas en la linea original: la salvedad toma de las dos.
  PERFORM pg_temp.t_salvedad(v_ped, (b->>'lc')::bigint, 2, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (b->>'f')::bigint) = '1@10000.00r'
                       AND pg_temp.t_lineas(v_ped, (b->>'c')::bigint) = '-'
                       AND pg_temp.t_total(v_ped) = 10000
                       AND pg_temp.t_foto(v_ped, (b->>'combo')::bigint) = '0/2 r2160.00',
                    format('Fernet %s, Coca %s, total %s, foto %s; esperado 1@10000.00r, sin Coca, 10000, 0/2 r2160.00',
                           pg_temp.t_lineas(v_ped, (b->>'f')::bigint), pg_temp.t_lineas(v_ped, (b->>'c')::bigint),
                           pg_temp.t_total(v_ped), pg_temp.t_foto(v_ped, (b->>'combo')::bigint)));
  -- La simulacion del lote: 19.600 - (7.840 + 2 x 1.960) + recargo = 10.000.
  f := pg_temp.t_si(f, 19600 - (7840 + 2 * 1960) + (s->0->>'recargo')::numeric = 10000,
                    format('la simulacion del lote dio %s', s));
  f := pg_temp.t_si(f, pg_temp.t_gates(v_ped) = 'A0 B0 D0', format('gates %s', pg_temp.t_gates(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_n1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; r1 jsonb; r2 jsonb; f text[] := '{}';
BEGIN
  b := pg_temp.t_base(p_cli, p_adm, p_suc, 2);
  v_ped := b->>'pedido';
  r1 := pg_temp.t_salvedad(v_ped, (b->>'lf')::bigint, 1, 'cliente_rechaza');
  r2 := pg_temp.t_salvedad(v_ped, (b->>'lc')::bigint, 1, 'cliente_rechaza');
  PERFORM pg_temp.t_anular((r1->>'salvedad_id')::bigint);
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (b->>'f')::bigint) = '1@7840.00c 1@10000.00r'
                       AND pg_temp.t_lineas(v_ped, (b->>'c')::bigint) = '1@1960.00c'
                       AND pg_temp.t_total(v_ped) = 19800
                       AND pg_temp.t_foto(v_ped, (b->>'combo')::bigint) = '1/2 r2160.00',
                    format('anulada la primera: Fernet %s, Coca %s, total %s, foto %s; esperado como solo la Coca (19800)',
                           pg_temp.t_lineas(v_ped, (b->>'f')::bigint), pg_temp.t_lineas(v_ped, (b->>'c')::bigint),
                           pg_temp.t_total(v_ped), pg_temp.t_foto(v_ped, (b->>'combo')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_gates(v_ped) = 'A0 B0 D0', format('anulada la primera: gates %s', pg_temp.t_gates(v_ped)));
  PERFORM pg_temp.t_anular((r2->>'salvedad_id')::bigint);
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (b->>'f')::bigint) = '2@7840.00c'
                       AND pg_temp.t_lineas(v_ped, (b->>'c')::bigint) = '2@1960.00c'
                       AND pg_temp.t_total(v_ped) = 19600
                       AND pg_temp.t_foto(v_ped, (b->>'combo')::bigint) = '2/2 r0.00'
                       AND pg_temp.t_huellas(v_ped, (b->>'f')::bigint) = '2'
                       AND pg_temp.t_huellas(v_ped, (b->>'c')::bigint) = '2',
                    format('anuladas las dos: Fernet %s, Coca %s, total %s, foto %s, huellas %s / %s',
                           pg_temp.t_lineas(v_ped, (b->>'f')::bigint), pg_temp.t_lineas(v_ped, (b->>'c')::bigint),
                           pg_temp.t_total(v_ped), pg_temp.t_foto(v_ped, (b->>'combo')::bigint),
                           pg_temp.t_huellas(v_ped, (b->>'f')::bigint), pg_temp.t_huellas(v_ped, (b->>'c')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_gates(v_ped) = 'A0 B0 D0', format('anuladas las dos: gates %s', pg_temp.t_gates(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_r1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  b jsonb; v_ped bigint; r jsonb; f text[] := '{}'; v_lc bigint;
BEGIN
  b := pg_temp.t_base(p_cli, p_adm, p_suc, 2);
  v_ped := b->>'pedido';
  PERFORM pg_temp.t_salvedad(v_ped, (b->>'lf')::bigint, 1, 'cliente_rechaza');
  SELECT id INTO v_lc FROM public.pedido_items
   WHERE pedido_id = v_ped AND producto_id = (b->>'c')::bigint AND combo_id IS NOT NULL;
  r := pg_temp.t_salvedad(v_ped, v_lc, 1, 'producto_danado');
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (b->>'c')::bigint) = '1@1960.00c'
                       AND pg_temp.t_total(v_ped) = 9800
                       AND (r->>'recargo_combo')::numeric = -540
                       AND pg_temp.t_foto(v_ped, (b->>'combo')::bigint) = '1/2 r0.00',
                    format('Coca %s, total %s, recargo %s, foto %s; esperado 1@1960.00c, 9800, -540, 1/2 r0.00',
                           pg_temp.t_lineas(v_ped, (b->>'c')::bigint), pg_temp.t_total(v_ped), r->>'recargo_combo',
                           pg_temp.t_foto(v_ped, (b->>'combo')::bigint)));
  f := pg_temp.t_si(f, pg_temp.t_gates(v_ped) = 'A0 B0 D0', format('gates %s', pg_temp.t_gates(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_q1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  vf jsonb; vc jsonb; v_combo bigint; p jsonb; v_ped bigint; v_lc bigint; f text[] := '{}';
BEGIN
  vf := pg_temp.t_prod(p_suc, p_adm, 'Fernet', 10000);
  vc := pg_temp.t_prod(p_suc, p_adm, 'Coca', 2500);
  v_combo := pg_temp.t_combo(p_suc, 14000, jsonb_build_array(
    jsonb_build_object('cantidad', 2, 'productos', jsonb_build_array((vc->>'prod')::bigint)),
    jsonb_build_object('cantidad', 1, 'productos', jsonb_build_array((vf->>'prod')::bigint))));
  p := pg_temp.t_pedido(p_cli, p_adm, jsonb_build_array(
    jsonb_build_object('prod', vc->'prod', 'cant', 6, 'precio', 2333.33, 'combo', v_combo, 'sin_combo', 2500),
    jsonb_build_object('prod', vf->'prod', 'cant', 3, 'precio', 9333.34, 'combo', v_combo, 'sin_combo', 10000)));
  IF p ? 'error' THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', p->'error';
  END IF;
  v_ped := p->>'pedido';
  v_lc := (p->'items'->>(vc->>'prod'))::bigint;
  PERFORM pg_temp.t_salvedad(v_ped, v_lc, 1, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (vc->>'prod')::bigint) = '4@2333.33c 1@2500.00r'
                       AND pg_temp.t_lineas(v_ped, (vf->>'prod')::bigint) = '2@9333.34c 1@10000.00r'
                       AND pg_temp.t_total(v_ped) = 40500,
                    format('primer rechazo: Coca %s, Fernet %s, total %s; esperado 2 combos + 1 Coca + 1 Fernet = 40500',
                           pg_temp.t_lineas(v_ped, (vc->>'prod')::bigint), pg_temp.t_lineas(v_ped, (vf->>'prod')::bigint),
                           pg_temp.t_total(v_ped)));
  PERFORM pg_temp.t_salvedad(v_ped, v_lc, 1, 'cliente_rechaza');
  f := pg_temp.t_si(f, pg_temp.t_lineas(v_ped, (vc->>'prod')::bigint) = '4@2333.33c'
                       AND pg_temp.t_lineas(v_ped, (vf->>'prod')::bigint) = '2@9333.34c 1@10000.00r'
                       AND pg_temp.t_total(v_ped) = 38000
                       AND pg_temp.t_foto(v_ped, v_combo) = '2/3 r666.66',
                    format('segundo rechazo: Coca %s, Fernet %s, total %s, foto %s; esperado 2 combos + 1 Fernet = 38000',
                           pg_temp.t_lineas(v_ped, (vc->>'prod')::bigint), pg_temp.t_lineas(v_ped, (vf->>'prod')::bigint),
                           pg_temp.t_total(v_ped), pg_temp.t_foto(v_ped, v_combo)));
  f := pg_temp.t_si(f, pg_temp.t_gates(v_ped) = 'A0 B0 D0', format('gates %s', pg_temp.t_gates(v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_g1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}';
BEGIN
  f := pg_temp.t_si(f, public.auditoria_funciones_pedido_items_sin_piso() = 0,
                    format('PRECIO-A: %s', public.auditoria_funciones_pedido_items_sin_piso()));
  f := pg_temp.t_si(f, public.auditoria_funciones_costo_sin_valuacion() = 0,
                    format('COSTO-D: %s', public.auditoria_funciones_costo_sin_valuacion()));
  f := pg_temp.t_si(f, public.auditoria_funciones_stock_sin_origen() = 0,
                    format('STK-F: %s', public.auditoria_funciones_stock_sin_origen()));
  f := pg_temp.t_si(f, (SELECT count(*) FROM public.auditoria_definer_sin_rol()) = 0,
                    format('SEG-A: %s', (SELECT string_agg(firma || ' ' || motivo, '; ') FROM public.auditoria_definer_sin_rol())));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- ---------------------------------------------------------------------------
-- Corrida
-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_admin   uuid;
  v_suc     bigint;
  v_cliente bigint;
  v_caso    text;
  v_out     jsonb;
  v_fallas  text[] := '{}';
BEGIN
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un admin activo con una sucursal activa';
  END IF;
  -- Sin saldo a favor: aplicar_credito_cliente se lo imputaria a la boleta de
  -- C1 y el pago ya no seria el del caso.
  SELECT c.id INTO v_cliente FROM clientes c
   WHERE c.sucursal_id = v_suc AND c.activo
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = c.id AND pg.pedido_id IS NULL)
   ORDER BY c.id LIMIT 1;
  IF v_cliente IS NULL THEN
    RAISE EXCEPTION 'el ensayo necesita un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);

  -- Cada caso corre en un subbloque que termina en una excepcion atrapada: no
  -- deja nada.
  FOREACH v_caso IN ARRAY ARRAY['m1', 'm2', 'd2', 'a1', 'c1', 'v1', 'l1', 'l2', 'n1', 'r1', 'q1', 'g1'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3)', v_caso)
        INTO v_out USING v_cliente, v_admin, v_suc;
      RAISE EXCEPTION USING ERRCODE = 'ZZ001';
    EXCEPTION
      WHEN SQLSTATE 'ZZ001' THEN NULL;
      WHEN OTHERS THEN v_fallas := v_fallas || format('%s · error: %s', upper(v_caso), SQLERRM);
    END;
    IF v_out IS NOT NULL THEN
      v_fallas := v_fallas || ARRAY(SELECT upper(v_caso) || ' · ' || x
                                      FROM jsonb_array_elements_text(COALESCE(v_out->'fallas', '[]')) x);
    END IF;
  END LOOP;

  PERFORM set_config('request.jwt.claims', '', true);
  PERFORM set_config('request.headers', '', true);
  PERFORM set_config('app.omitir_minimo_pedido', '', true);

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLO (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE NOTICE 'ENSAYO OK';
END
$ensayo$;

-- Nada de lo de arriba queda escrito: la transaccion se revierte entera.
DO $fin$ BEGIN RAISE EXCEPTION 'ENSAYO_ROLLBACK'; END $fin$;
