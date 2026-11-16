-- Ensayo de la migración «la línea que vuelve al anular una salvedad trae su foto»
-- (tarjeta M4 del plan #1603: VTA-1 de #1595, 1592-b5 de #1592 y 1559-c2 de #1559).
--
-- VTA-1: con la línea borrada por la salvedad, anular_salvedad la recreaba con el
-- costo de hoy y sin la lista, el origen ni el descuento de la venta. Ahora
-- registrar_salvedad guarda esa foto (salvedad_linea_foto) al borrarla y anular la
-- usa. 1592-b5: anular rechazaba «toca promociones» toda restitución que cruzara un
-- múltiplo, aunque la salvedad no hubiera recortado el regalo. 1559-c2: anular
-- bloqueaba los pagos antes que el producto.
--
--   V1 · [F] venta a 1.234,57 (lista 1.300, costo 600). La salvedad borra la línea,
--        el costo pasa a 700 y la lista a 1.400. Anular la recrea con costo 600,
--        lista 1.300 y el origen y el descuento de la venta. Total, stock y la foto
--        de la tabla, como antes.
--   V2 · [F] dos salvedades sobre la misma línea: S1 recorta 2 de 5 y S2 borra las 3
--        que quedan. Las dos tienen foto. Anular S1 recrea la línea con la foto, y
--        anular S2 le suma: una línea de 5 con el costo de la venta.
--   V3 · [R] sin foto (una salvedad anterior a la migración): el costo de hoy, como
--        hasta ahora, y la lista y el origen que completa el trigger.
--   V4 · [F] la foto es sólo de server: authenticated y anon no la leen ni la
--        escriben, tiene RLS y ninguna policy. anular_salvedad sigue siendo definer,
--        de authenticated y sin anon.
--   B1 · [F] 1592-b5. Promo 10+2, línea 20 y regalo 2 (menos de lo que le toca). Un
--        rechazo de 5 no recorta el regalo (le quedan derecho 2 y tiene 2). Anular
--        pasa: la línea vuelve a 20 y el regalo sigue en 2.
--   B2 · [R] el mismo pedido con regalo 4: el rechazo de 5 lo recorta a 2 y anular
--        rechaza con anulacion_toca_promociones y el mensaje del recorte, sin mover
--        nada.
--   B3 · [F] la salvedad de B1 sin su rastro en audit_logs: no se puede saber si
--        recortó, así que rechaza como antes, con un mensaje que no lo afirma.
--   H1 · [F] la revisión de M4: dos salvedades del mismo pedido sobre la misma
--        promo 10+2 (venta 20, regalo 4), cada una en su transacción. A rechaza 1 y
--        recorta el regalo a 2; B rechaza 9 y no recorta. Anular A y después B:
--        B se rechaza (el regalo que vuelve a dar lo recortó A), y el pedido queda
--        con el regalo que le toca. En el orden inverso, B pasa (no cruza) y A se
--        rechaza. En los dos órdenes el regalo nunca queda por debajo del derecho.
--   H1b · [F] lo mismo con dos productos de la promo (A sobre P, B sobre Q).
--   H5 · [F] una línea mayorista vuelve con su escala (grupo_precio_escala_id) y su
--        origen; si después se fusiona su condición en otra con la misma escala,
--        la foto se repunta y vuelve con la escala del destino.
--   L1 · [F] 1559-c2. En anular_salvedad, el lock del producto va antes que el de
--        los pagos (el orden de registrar_salvedad). La espera cruzada pide dos
--        sesiones: se mira el cuerpo.
--
-- [F] falla sin la migración y pasa con ella; [R] pasa antes y después.
-- Fixtures: un admin activo con una sucursal activa y un cliente activo en ella sin
-- saldo a favor. Todo lo demás nace en el ensayo.
--
-- Un único DO que termina SIEMPRE en una excepción: no deja nada. Cada caso corre
-- en un sub-bloque que se revierte.
--   'ENSAYO OK …'    -> todas las aserciones pasaron.
--   'ENSAYO FALLÓ …' -> lista de lo que no se cumplió.
--
--   psql "$DATABASE_URL" -1 -f scripts/test-salvedad-anulada-foto-1595.sql

CREATE OR REPLACE FUNCTION pg_temp.t_si(p_f text[], p_ok boolean, p_msg text)
RETURNS text[] LANGUAGE sql AS $fn$
  SELECT CASE WHEN COALESCE(p_ok, false) THEN p_f ELSE p_f || p_msg END;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_prod(p_suc bigint, p_precio numeric, p_costo numeric)
RETURNS bigint LANGUAGE sql AS $fn$
  INSERT INTO public.productos (nombre, precio, stock, costo_promedio, sucursal_id)
  VALUES ('ZZ ensayo 1595', p_precio, 1000, p_costo, p_suc)
  RETURNING id;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_pedido(p_cli bigint, p_adm uuid, p_prod bigint, p_cant int, p_precio numeric)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  r jsonb;
BEGIN
  r := public.crear_pedido_completo(p_cli, p_cant * p_precio, p_adm,
         jsonb_build_array(jsonb_build_object('producto_id', p_prod, 'cantidad', p_cant, 'precio_unitario', p_precio)),
         'ensayo 1595');
  IF NOT COALESCE((r->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', r;
  END IF;
  RETURN (r->>'pedido_id')::bigint;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_linea(p_ped bigint, p_prod bigint)
RETURNS bigint LANGUAGE sql AS $fn$
  SELECT id FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND NOT COALESCE(es_bonificacion, false)
   ORDER BY id LIMIT 1;
$fn$;

-- La foto de una línea, para comparar.
CREATE OR REPLACE FUNCTION pg_temp.t_foto_linea(p_item bigint)
RETURNS jsonb LANGUAGE sql AS $fn$
  SELECT jsonb_build_object('cantidad', cantidad, 'costo', costo_unitario_al_crear, 'lista', precio_lista_al_crear,
                            'origen', origen_precio, 'descuento', descuento_pct, 'precio', precio_unitario)
    FROM public.pedido_items WHERE id = p_item;
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_salvedad(p_ped bigint, p_item bigint, p_cant int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  r jsonb;
BEGIN
  r := public.registrar_salvedad(p_ped, p_item, p_cant, 'cliente_rechaza',
                                 'ensayo 1595: descripcion del caso', NULL, true, NULL);
  IF NOT COALESCE((r->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'registrar: %', r;
  END IF;
  RETURN (r->>'salvedad_id')::bigint;
END
$fn$;

-- Las filas de la foto de una salvedad. plpgsql a propósito: sin la migración la
-- tabla no existe y da -1.
CREATE OR REPLACE FUNCTION pg_temp.t_fotos(p_salv bigint)
RETURNS int LANGUAGE plpgsql AS $fn$
DECLARE
  n int;
BEGIN
  IF to_regclass('public.salvedad_linea_foto') IS NULL THEN
    RETURN -1;
  END IF;
  EXECUTE 'SELECT count(*)::int FROM public.salvedad_linea_foto WHERE salvedad_id = $1' INTO n USING p_salv;
  RETURN n;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_promo(p_suc bigint, p_prod bigint, p_compra int, p_bonif int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_promo bigint;
BEGIN
  INSERT INTO public.promociones (nombre, tipo, fecha_inicio, sucursal_id, regalo_mueve_stock, producto_regalo_id)
  VALUES ('ZZ ensayo 1595', 'bonificacion', CURRENT_DATE, p_suc, true, p_prod) RETURNING id INTO v_promo;
  INSERT INTO public.promocion_reglas (promocion_id, clave, valor, sucursal_id)
  VALUES (v_promo, 'cantidad_compra', p_compra, p_suc),
         (v_promo, 'cantidad_bonificacion', p_bonif, p_suc);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id)
  VALUES (v_promo, p_prod, p_suc);
  RETURN v_promo;
END
$fn$;

-- Una línea de regalo, con su bajada de stock (como la venta).
CREATE OR REPLACE FUNCTION pg_temp.t_regalo(p_ped bigint, p_promo bigint, p_prod bigint, p_suc bigint, p_n int)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  v_regalo bigint;
BEGIN
  INSERT INTO public.pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal,
                                   sucursal_id, es_bonificacion, promocion_id)
  VALUES (p_ped, p_prod, p_n, 0, 0, p_suc, true, p_promo) RETURNING id INTO v_regalo;
  PERFORM set_config('app.stock_origen', 'pedido_creado', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_ped::text, true);
  PERFORM set_config('app.stock_pedido_item_id', v_regalo::text, true);
  UPDATE public.productos SET stock = stock - p_n WHERE id = p_prod;
  PERFORM set_config('app.stock_pedido_item_id', '', true);
  PERFORM set_config('app.stock_origen', '', true);
  PERFORM set_config('app.stock_ref_tipo', '', true);
  PERFORM set_config('app.stock_ref_id', '', true);
  RETURN v_regalo;
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_regalos(p_ped bigint, p_promo bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_items
   WHERE pedido_id = p_ped AND promocion_id = p_promo AND COALESCE(es_bonificacion, false);
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.t_vendido(p_ped bigint, p_prod bigint)
RETURNS int LANGUAGE sql AS $fn$
  SELECT COALESCE(SUM(cantidad), 0)::int FROM public.pedido_items
   WHERE pedido_id = p_ped AND producto_id = p_prod AND NOT COALESCE(es_bonificacion, false);
$fn$;

-- ---------------------------------------------------------------------------
-- Casos
-- ---------------------------------------------------------------------------

-- V1 · la línea borrada vuelve con la foto de la venta.
CREATE OR REPLACE FUNCTION pg_temp.caso_v1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_prod bigint; v_ped bigint; v_item bigint; v_s bigint; v_antes jsonb; v_despues jsonb;
  v_res jsonb; v_stock int;
BEGIN
  v_prod := pg_temp.t_prod(p_suc, 1300, 600);
  v_ped  := pg_temp.t_pedido(p_cli, p_adm, v_prod, 1, 1234.57);
  v_item := pg_temp.t_linea(v_ped, v_prod);
  v_antes := pg_temp.t_foto_linea(v_item);
  f := pg_temp.t_si(f, (v_antes->>'costo')::numeric = 600 AND (v_antes->>'lista')::numeric = 1300,
                    format('la venta no quedó con costo 600 y lista 1300: %s', v_antes));
  v_s := pg_temp.t_salvedad(v_ped, v_item, 1);
  f := pg_temp.t_si(f, NOT EXISTS (SELECT 1 FROM public.pedido_items WHERE id = v_item),
                    'la salvedad no borró la línea');
  f := pg_temp.t_si(f, pg_temp.t_fotos(v_s) = 1, format('filas de foto de la salvedad: %s, esperado 1', pg_temp.t_fotos(v_s)));
  UPDATE public.productos SET costo_promedio = 700, precio = 1400 WHERE id = v_prod;
  SELECT stock INTO v_stock FROM public.productos WHERE id = v_prod;
  v_res := public.anular_salvedad(v_s, 'ensayo 1595');
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false), format('anular: %s', v_res));
  v_despues := pg_temp.t_foto_linea(pg_temp.t_linea(v_ped, v_prod));
  f := pg_temp.t_si(f, v_despues = v_antes,
                    format('la línea volvió como %s; la de la venta era %s', v_despues, v_antes));
  f := pg_temp.t_si(f, (SELECT total FROM public.pedidos WHERE id = v_ped) = 1234.57
                       AND (SELECT stock FROM public.productos WHERE id = v_prod) = v_stock - 1,
                    format('total %s y stock %s (antes de anular %s)',
                           (SELECT total FROM public.pedidos WHERE id = v_ped),
                           (SELECT stock FROM public.productos WHERE id = v_prod), v_stock));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- V2 · dos salvedades sobre la misma línea: las dos con foto.
CREATE OR REPLACE FUNCTION pg_temp.caso_v2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_prod bigint; v_ped bigint; v_item bigint; v_s1 bigint; v_s2 bigint; v_antes jsonb;
  v_res jsonb; v_l bigint;
BEGIN
  v_prod := pg_temp.t_prod(p_suc, 100, 60);
  v_ped  := pg_temp.t_pedido(p_cli, p_adm, v_prod, 5, 95);
  v_item := pg_temp.t_linea(v_ped, v_prod);
  v_antes := pg_temp.t_foto_linea(v_item) - 'cantidad';
  v_s1 := pg_temp.t_salvedad(v_ped, v_item, 2);
  v_s2 := pg_temp.t_salvedad(v_ped, v_item, 3);
  f := pg_temp.t_si(f, pg_temp.t_fotos(v_s1) = 1 AND pg_temp.t_fotos(v_s2) = 1,
                    format('filas de foto: S1 %s, S2 %s; esperado 1 y 1', pg_temp.t_fotos(v_s1), pg_temp.t_fotos(v_s2)));
  UPDATE public.productos SET costo_promedio = 80, precio = 120 WHERE id = v_prod;
  v_res := public.anular_salvedad(v_s1, 'ensayo 1595');
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false), format('anular S1: %s', v_res));
  v_l := pg_temp.t_linea(v_ped, v_prod);
  f := pg_temp.t_si(f, pg_temp.t_foto_linea(v_l) = v_antes || '{"cantidad": 2}',
                    format('anulada S1 la línea es %s; esperado %s', pg_temp.t_foto_linea(v_l), v_antes || '{"cantidad": 2}'));
  v_res := public.anular_salvedad(v_s2, 'ensayo 1595');
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false), format('anular S2: %s', v_res));
  f := pg_temp.t_si(f, pg_temp.t_foto_linea(pg_temp.t_linea(v_ped, v_prod)) = v_antes || '{"cantidad": 5}'
                       AND (SELECT count(*) FROM public.pedido_items WHERE pedido_id = v_ped) = 1
                       AND (SELECT total FROM public.pedidos WHERE id = v_ped) = 475,
                    format('anuladas las dos la línea es %s (líneas %s, total %s); esperado %s, 1 y 475',
                           pg_temp.t_foto_linea(pg_temp.t_linea(v_ped, v_prod)),
                           (SELECT count(*) FROM public.pedido_items WHERE pedido_id = v_ped),
                           (SELECT total FROM public.pedidos WHERE id = v_ped), v_antes || '{"cantidad": 5}'));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- V3 · sin foto, lo de antes: el costo de hoy.
CREATE OR REPLACE FUNCTION pg_temp.caso_v3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_prod bigint; v_ped bigint; v_item bigint; v_s bigint; v_res jsonb; v_l jsonb;
BEGIN
  v_prod := pg_temp.t_prod(p_suc, 1300, 600);
  v_ped  := pg_temp.t_pedido(p_cli, p_adm, v_prod, 1, 1300);
  v_item := pg_temp.t_linea(v_ped, v_prod);
  v_s := pg_temp.t_salvedad(v_ped, v_item, 1);
  IF to_regclass('public.salvedad_linea_foto') IS NOT NULL THEN
    EXECUTE 'DELETE FROM public.salvedad_linea_foto WHERE salvedad_id = $1' USING v_s;
  END IF;
  UPDATE public.productos SET costo_promedio = 700, precio = 1400 WHERE id = v_prod;
  v_res := public.anular_salvedad(v_s, 'ensayo 1595');
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false), format('anular: %s', v_res));
  v_l := pg_temp.t_foto_linea(pg_temp.t_linea(v_ped, v_prod));
  f := pg_temp.t_si(f, (v_l->>'costo')::numeric = 700 AND (v_l->>'lista')::numeric = 1400
                       AND v_l->>'origen' = 'desconocido',
                    format('sin foto la línea volvió como %s; esperado costo 700, lista 1400 y origen desconocido', v_l));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- B1 · el rechazo no recortó el regalo: anular pasa.
CREATE OR REPLACE FUNCTION pg_temp.caso_b1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_prod bigint; v_ped bigint; v_item bigint; v_promo bigint; v_s bigint; v_res jsonb;
BEGIN
  v_prod  := pg_temp.t_prod(p_suc, 100, 60);
  v_ped   := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20, 100);
  v_item  := pg_temp.t_linea(v_ped, v_prod);
  v_promo := pg_temp.t_promo(p_suc, v_prod, 10, 2);
  PERFORM pg_temp.t_regalo(v_ped, v_promo, v_prod, p_suc, 2);
  v_s := pg_temp.t_salvedad(v_ped, v_item, 5);
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 2 AND pg_temp.t_vendido(v_ped, v_prod) = 15,
                    format('tras el rechazo: regalo %s y vendido %s; esperado 2 y 15',
                           pg_temp.t_regalos(v_ped, v_promo), pg_temp.t_vendido(v_ped, v_prod)));
  v_res := public.anular_salvedad(v_s, 'ensayo 1592');
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false), format('anular tendría que pasar: %s', v_res));
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 2 AND pg_temp.t_vendido(v_ped, v_prod) = 20
                       AND (SELECT total FROM public.pedidos WHERE id = v_ped) = 2000,
                    format('anulada: regalo %s, vendido %s, total %s; esperado 2, 20 y 2000',
                           pg_temp.t_regalos(v_ped, v_promo), pg_temp.t_vendido(v_ped, v_prod),
                           (SELECT total FROM public.pedidos WHERE id = v_ped)));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- B2 · el rechazo recortó el regalo: anular rechaza sin mover nada.
CREATE OR REPLACE FUNCTION pg_temp.caso_b2(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_prod bigint; v_ped bigint; v_item bigint; v_promo bigint; v_s bigint; v_res jsonb;
BEGIN
  v_prod  := pg_temp.t_prod(p_suc, 100, 60);
  v_ped   := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20, 100);
  v_item  := pg_temp.t_linea(v_ped, v_prod);
  v_promo := pg_temp.t_promo(p_suc, v_prod, 10, 2);
  PERFORM pg_temp.t_regalo(v_ped, v_promo, v_prod, p_suc, 4);
  v_s := pg_temp.t_salvedad(v_ped, v_item, 5);
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 2,
                    format('tras el rechazo el regalo quedó en %s, esperado 2', pg_temp.t_regalos(v_ped, v_promo)));
  v_res := public.anular_salvedad(v_s, 'ensayo 1592');
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'success')::boolean, false)
                       AND v_res->>'codigo' = 'anulacion_toca_promociones'
                       AND v_res->>'error' LIKE '%que una salvedad de este pedido habia recortado%',
                    format('anular tendría que rechazar por el recorte: %s', v_res));
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 2 AND pg_temp.t_vendido(v_ped, v_prod) = 15
                       AND (SELECT estado_resolucion FROM public.salvedades_items WHERE id = v_s) = 'pendiente',
                    'el rechazo movió algo');
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- B3 · sin el rastro de la salvedad en el log no se sabe: rechaza sin afirmar.
CREATE OR REPLACE FUNCTION pg_temp.caso_b3(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_prod bigint; v_ped bigint; v_item bigint; v_promo bigint; v_s bigint; v_res jsonb;
BEGIN
  v_prod  := pg_temp.t_prod(p_suc, 100, 60);
  v_ped   := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20, 100);
  v_item  := pg_temp.t_linea(v_ped, v_prod);
  v_promo := pg_temp.t_promo(p_suc, v_prod, 10, 2);
  PERFORM pg_temp.t_regalo(v_ped, v_promo, v_prod, p_suc, 2);
  v_s := pg_temp.t_salvedad(v_ped, v_item, 5);
  DELETE FROM public.audit_logs
   WHERE tabla = 'pedido_items' AND accion IN ('UPDATE', 'DELETE') AND created_at = now();
  v_res := public.anular_salvedad(v_s, 'ensayo 1592');
  f := pg_temp.t_si(f, NOT COALESCE((v_res->>'success')::boolean, false)
                       AND v_res->>'codigo' = 'anulacion_toca_promociones'
                       AND v_res->>'error' LIKE '%no se puede saber si una salvedad de este pedido lo recorto%',
                    format('anular tendría que rechazar sin afirmar el recorte: %s', v_res));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- Lo escrito en "esta" transacción pasa a otra, p_h horas antes: cada RPC es su
-- transacción, y el ensayo corre entero en una.
CREATE OR REPLACE FUNCTION pg_temp.t_otra_tx(p_h int)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  UPDATE public.audit_logs SET created_at = created_at - make_interval(hours => p_h) WHERE created_at = now();
  UPDATE public.salvedades_items SET created_at = created_at - make_interval(hours => p_h) WHERE created_at = now();
  UPDATE public.pedido_historial SET created_at = created_at - make_interval(hours => p_h) WHERE created_at = now();
END
$fn$;

-- H1 · A recorta, B no; p_orden 'AB' o 'BA'.
CREATE OR REPLACE FUNCTION pg_temp.t_h1(p_cli bigint, p_adm uuid, p_suc bigint, p_orden text)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_prod bigint; v_ped bigint; v_item bigint; v_promo bigint; v_a bigint; v_b bigint;
  r1 jsonb; r2 jsonb; v_v int; v_r int;
BEGIN
  v_prod  := pg_temp.t_prod(p_suc, 100, 60);
  v_ped   := pg_temp.t_pedido(p_cli, p_adm, v_prod, 20, 100);
  v_item  := pg_temp.t_linea(v_ped, v_prod);
  v_promo := pg_temp.t_promo(p_suc, v_prod, 10, 2);
  PERFORM pg_temp.t_regalo(v_ped, v_promo, v_prod, p_suc, 4);
  PERFORM pg_temp.t_otra_tx(3);
  v_a := pg_temp.t_salvedad(v_ped, v_item, 1);
  PERFORM pg_temp.t_otra_tx(2);
  v_b := pg_temp.t_salvedad(v_ped, v_item, 9);
  PERFORM pg_temp.t_otra_tx(1);
  f := pg_temp.t_si(f, pg_temp.t_regalos(v_ped, v_promo) = 2 AND pg_temp.t_vendido(v_ped, v_prod) = 10,
                    format('%s · tras las salvedades: regalo %s y vendido %s; esperado 2 y 10', p_orden,
                           pg_temp.t_regalos(v_ped, v_promo), pg_temp.t_vendido(v_ped, v_prod)));
  IF p_orden = 'AB' THEN
    r1 := public.anular_salvedad(v_a, 'ensayo H1');
    r2 := public.anular_salvedad(v_b, 'ensayo H1');
    f := pg_temp.t_si(f, COALESCE((r1->>'success')::boolean, false), format('AB · anular A tendría que pasar: %s', r1));
    f := pg_temp.t_si(f, r2->>'codigo' = 'anulacion_toca_promociones',
                      format('AB · anular B tendría que rechazar (A recortó el regalo): %s', r2));
  ELSE
    r1 := public.anular_salvedad(v_b, 'ensayo H1');
    r2 := public.anular_salvedad(v_a, 'ensayo H1');
    f := pg_temp.t_si(f, COALESCE((r1->>'success')::boolean, false), format('BA · anular B tendría que pasar: %s', r1));
    f := pg_temp.t_si(f, r2->>'codigo' = 'anulacion_toca_promociones',
                      format('BA · anular A tendría que rechazar (recortó el regalo): %s', r2));
  END IF;
  v_v := pg_temp.t_vendido(v_ped, v_prod);
  v_r := pg_temp.t_regalos(v_ped, v_promo);
  f := pg_temp.t_si(f, v_r >= (v_v / 10) * 2,
                    format('%s · final: vendido %s, regalo %s (derecho %s)', p_orden, v_v, v_r, (v_v / 10) * 2));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_h1(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN pg_temp.t_h1(p_cli, p_adm, p_suc, 'AB');
END
$fn$;

CREATE OR REPLACE FUNCTION pg_temp.caso_h1r(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
BEGIN
  RETURN pg_temp.t_h1(p_cli, p_adm, p_suc, 'BA');
END
$fn$;

-- H1b · dos productos de la promo: A sobre P recorta, B sobre Q no.
CREATE OR REPLACE FUNCTION pg_temp.caso_h1b(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_p bigint; v_q bigint; v_ped bigint; v_promo bigint; v_a bigint; v_b bigint;
  r jsonb; r1 jsonb; r2 jsonb; v_v int; v_r int;
BEGIN
  v_p := pg_temp.t_prod(p_suc, 100, 60);
  v_q := pg_temp.t_prod(p_suc, 100, 60);
  r := public.crear_pedido_completo(p_cli, 2000, p_adm,
         jsonb_build_array(jsonb_build_object('producto_id', v_p, 'cantidad', 10, 'precio_unitario', 100),
                           jsonb_build_object('producto_id', v_q, 'cantidad', 10, 'precio_unitario', 100)),
         'ensayo H1b');
  IF NOT COALESCE((r->>'success')::boolean, false) THEN
    RAISE EXCEPTION 'no se pudo crear el pedido: %', r;
  END IF;
  v_ped := (r->>'pedido_id')::bigint;
  v_promo := pg_temp.t_promo(p_suc, v_p, 10, 1);
  INSERT INTO public.promocion_productos (promocion_id, producto_id, sucursal_id) VALUES (v_promo, v_q, p_suc);
  PERFORM pg_temp.t_regalo(v_ped, v_promo, v_p, p_suc, 2);
  PERFORM pg_temp.t_otra_tx(3);
  v_a := pg_temp.t_salvedad(v_ped, pg_temp.t_linea(v_ped, v_p), 1);   -- 19: derecho 1, regalo 2 -> 1
  PERFORM pg_temp.t_otra_tx(2);
  v_b := pg_temp.t_salvedad(v_ped, pg_temp.t_linea(v_ped, v_q), 9);   -- 10: derecho 1, regalo 1, no recorta
  PERFORM pg_temp.t_otra_tx(1);
  r1 := public.anular_salvedad(v_a, 'ensayo H1b');
  r2 := public.anular_salvedad(v_b, 'ensayo H1b');
  f := pg_temp.t_si(f, COALESCE((r1->>'success')::boolean, false), format('anular A tendría que pasar: %s', r1));
  f := pg_temp.t_si(f, r2->>'codigo' = 'anulacion_toca_promociones',
                    format('anular B tendría que rechazar (A recortó el regalo): %s', r2));
  v_v := pg_temp.t_vendido(v_ped, v_p) + pg_temp.t_vendido(v_ped, v_q);
  v_r := pg_temp.t_regalos(v_ped, v_promo);
  f := pg_temp.t_si(f, v_r >= v_v / 10, format('final: vendido %s, regalo %s (derecho %s)', v_v, v_r, v_v / 10));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

-- H5 · la escala mayorista vuelve con la línea, y se repunta al fusionar.
CREATE OR REPLACE FUNCTION pg_temp.caso_h5(p_cli bigint, p_adm uuid, p_suc bigint)
RETURNS jsonb LANGUAGE plpgsql AS $fn$
DECLARE
  f text[] := '{}'; v_prod bigint; v_ped bigint; v_item bigint; v_s bigint; v_res jsonb; v_l record;
  v_g1 bigint; v_g2 bigint; v_e1 bigint; v_e2 bigint; v_prod2 bigint; v_ped2 bigint; v_item2 bigint; v_s2 bigint;
BEGIN
  INSERT INTO public.grupos_precio (nombre, sucursal_id) VALUES ('ZZ ensayo 1595 G1', p_suc) RETURNING id INTO v_g1;
  INSERT INTO public.grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, sucursal_id)
  VALUES (v_g1, 6, 90, p_suc) RETURNING id INTO v_e1;
  -- La venta mayorista, como la deja el alta: la escala y el origen en la línea.
  v_prod := pg_temp.t_prod(p_suc, 100, 60);
  v_ped  := pg_temp.t_pedido(p_cli, p_adm, v_prod, 6, 90);
  v_item := pg_temp.t_linea(v_ped, v_prod);
  UPDATE public.pedido_items SET grupo_precio_escala_id = v_e1, origen_precio = 'mayorista' WHERE id = v_item;
  v_s := pg_temp.t_salvedad(v_ped, v_item, 6);
  v_res := public.anular_salvedad(v_s, 'ensayo H5');
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false), format('anular: %s', v_res));
  SELECT grupo_precio_escala_id, origen_precio INTO v_l FROM public.pedido_items WHERE id = pg_temp.t_linea(v_ped, v_prod);
  f := pg_temp.t_si(f, v_l.grupo_precio_escala_id = v_e1 AND v_l.origen_precio = 'mayorista',
                    format('la línea volvió con escala %s y origen %s; esperado %s y mayorista',
                           v_l.grupo_precio_escala_id, v_l.origen_precio, v_e1));
  -- La condición se fusiona en otra con la misma escala mientras la salvedad está viva.
  v_prod2 := pg_temp.t_prod(p_suc, 100, 60);
  v_ped2  := pg_temp.t_pedido(p_cli, p_adm, v_prod2, 6, 90);
  v_item2 := pg_temp.t_linea(v_ped2, v_prod2);
  UPDATE public.pedido_items SET grupo_precio_escala_id = v_e1, origen_precio = 'mayorista' WHERE id = v_item2;
  v_s2 := pg_temp.t_salvedad(v_ped2, v_item2, 6);
  INSERT INTO public.grupos_precio (nombre, sucursal_id) VALUES ('ZZ ensayo 1595 G2', p_suc) RETURNING id INTO v_g2;
  INSERT INTO public.grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, sucursal_id)
  VALUES (v_g2, 6, 90, p_suc) RETURNING id INTO v_e2;
  BEGIN
    PERFORM public.consolidar_condiciones(v_g2, ARRAY[v_g1]);
  EXCEPTION WHEN OTHERS THEN
    f := f || format('consolidar: %s', SQLERRM);
  END;
  v_res := public.anular_salvedad(v_s2, 'ensayo H5');
  f := pg_temp.t_si(f, COALESCE((v_res->>'success')::boolean, false), format('anular tras fusionar: %s', v_res));
  SELECT grupo_precio_escala_id, origen_precio INTO v_l FROM public.pedido_items WHERE id = pg_temp.t_linea(v_ped2, v_prod2);
  f := pg_temp.t_si(f, v_l.grupo_precio_escala_id = v_e2 AND v_l.origen_precio = 'mayorista',
                    format('tras fusionar la línea volvió con escala %s; esperado la del destino %s',
                           v_l.grupo_precio_escala_id, v_e2));
  RETURN jsonb_build_object('fallas', to_jsonb(f));
END
$fn$;

DO $ensayo$
DECLARE
  v_admin  uuid;
  v_suc    bigint;
  v_cli    bigint;
  v_caso   text;
  v_out    jsonb;
  v_fallas text[] := '{}';
  v_src    text;
BEGIN
  SET LOCAL lock_timeout = '5s';

  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us
    JOIN perfiles pf  ON pf.id = us.usuario_id AND pf.rol = 'admin' AND pf.activo
    JOIN sucursales s ON s.id = us.sucursal_id AND s.activa
   ORDER BY us.usuario_id, us.sucursal_id
   LIMIT 1;
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un admin activo con una sucursal activa';
  END IF;
  SELECT cl.id INTO v_cli FROM clientes cl
   WHERE cl.sucursal_id = v_suc AND cl.activo
     AND NOT EXISTS (SELECT 1 FROM pagos pg WHERE pg.cliente_id = cl.id AND pg.pedido_id IS NULL)
   ORDER BY cl.id LIMIT 1;
  IF v_cli IS NULL THEN
    RAISE EXCEPTION 'ENSAYO FALLÓ · sin un cliente activo en la sucursal %', v_suc;
  END IF;

  PERFORM set_config('request.jwt.claims', json_build_object('sub', v_admin)::text, true);
  PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);
  PERFORM set_config('app.omitir_minimo_pedido', '1', true);
  PERFORM set_config('app.cargo_envio_forzado', '', true);
  PERFORM set_config('app.cargo_envio_estado_forzado', '', true);

  -- Sin cargo de envío ni compra mínima que muevan los totales.
  INSERT INTO politicas_comerciales (sucursal_id, modo_minimo_pedido, monto_minimo_pedido, monto_envio_gratis, cargo_envio_pedido)
  VALUES (v_suc, 'bloquear', 0, 0, 500)
  ON CONFLICT (sucursal_id) DO UPDATE SET modo_minimo_pedido = EXCLUDED.modo_minimo_pedido,
    monto_minimo_pedido = EXCLUDED.monto_minimo_pedido, monto_envio_gratis = EXCLUDED.monto_envio_gratis,
    cargo_envio_pedido = EXCLUDED.cargo_envio_pedido;

  FOREACH v_caso IN ARRAY ARRAY['v1', 'v2', 'v3', 'b1', 'b2', 'b3', 'h1', 'h1r', 'h1b', 'h5'] LOOP
    v_out := NULL;
    BEGIN
      EXECUTE format('SELECT pg_temp.caso_%s($1, $2, $3)', v_caso) INTO v_out USING v_cli, v_admin, v_suc;
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

  -- V4 · la foto es sólo de server
  IF to_regclass('public.salvedad_linea_foto') IS NULL THEN
    v_fallas := v_fallas || 'V4 · salvedad_linea_foto no existe'::text;
  ELSIF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.salvedad_linea_foto'::regclass)
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.salvedad_linea_foto'::regclass)
     OR has_table_privilege('authenticated', 'public.salvedad_linea_foto', 'SELECT,INSERT,UPDATE,DELETE')
     OR has_table_privilege('anon', 'public.salvedad_linea_foto', 'SELECT,INSERT,UPDATE,DELETE') THEN
    v_fallas := v_fallas || 'V4 · salvedad_linea_foto no es sólo de server'::text;
  END IF;
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure)
     OR has_function_privilege('anon', 'public.anular_salvedad(bigint,text)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.anular_salvedad(bigint,text)', 'EXECUTE') THEN
    v_fallas := v_fallas || 'V4 · cambiaron el definer o los EXECUTE de anular_salvedad'::text;
  END IF;

  -- L1 · el producto antes que los pagos
  SELECT prosrc INTO v_src FROM pg_proc WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure;
  IF position('PERFORM 1 FROM productos' IN v_src) = 0
     OR position('PERFORM 1 FROM productos' IN v_src) > position('PERFORM 1 FROM pagos' IN v_src) THEN
    v_fallas := v_fallas || 'L1 · anular_salvedad bloquea los pagos antes que el producto'::text;
  END IF;

  IF cardinality(v_fallas) > 0 THEN
    RAISE EXCEPTION E'ENSAYO FALLÓ (% fallas)\n- %', cardinality(v_fallas), array_to_string(v_fallas, E'\n- ');
  END IF;
  RAISE EXCEPTION 'ENSAYO OK · VTA-1 de #1595 (V1-V4), 1592-b5 (B1-B3), 1559-c2 (L1) y la revisión (H1, H1r, H1b, H5)';
END
$ensayo$;
