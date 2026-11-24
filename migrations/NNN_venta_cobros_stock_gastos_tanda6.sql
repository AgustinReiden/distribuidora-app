-- =========================================================================
-- NNN · VENTA, COBROS, STOCK Y GASTOS/PERSONAL: LOS BAJOS DE LA REAUDITORÍA
--       (plan #1603, tanda 6, tarjeta D; reauditoría del núcleo del 24/11)
--
-- Ensayo: scripts/test-venta-cobros-gastos-tanda6-1603.sql (falla sin esta
-- migración en V1 V3 V4 C1 C2 C4 C5 C6 S3 G1 G2 G3 G4, ENSAYO OK con ella).
-- Se aplica en LF. Cambia cuerpos de funciones y el CHECK de las operaciones
-- de altas_por_clave (la única DDL de tabla: su LOCK va al principio, NOWAIT).
-- Ninguna firma cambia: un bundle viejo del PWA sigue llamando igual.
--
-- 1 · venta-B1: la edición conserva el precio guardado de una escala sólo si
--     ningún grupo achica su total ni sus distintos (las reglas «son
--     monótonas»). Con un mínimo por producto (grupo_precio_escala_minimos)
--     no lo son: A×10 + B×10 a $80 (escala de 20 u., 2 distintos y 10 de cada
--     uno) se editaba a A×19 + B×1 a $80, que en un alta se rechaza. Ahora
--     tampoco se conserva si baja la cantidad de un producto que tiene mínimo
--     en alguna escala del grupo. precio_fuera_de_politica va por ancla, sin
--     md5 (la tarjeta B puede tocarla en otro tramo, promos-B4).
-- 2 · venta-B3: anular una salvedad que borró la línea entera de un producto
--     que hoy no tiene precio de lista fallaba en validar_precio_item_pedido
--     («pendiente de carga de precio»). La reinserción vuelve con el mismo
--     producto, precio y cantidad: no es una venta nueva. Usa la misma marca
--     que la edición (app.edicion_precio_conservado, D20 de 1559-b3), sólo
--     para esa línea, y la deja como estaba. anular_salvedad va por ancla.
-- 3 · venta-B4 (la mitad de la edición): un renglón sin producto contestaba
--     «path element at position 1 is null». Ahora, success=false con el
--     motivo, antes de escribir nada. La mitad del alta (crear_pedido_completo)
--     no es de esta tarjeta. actualizar_pedido_items va por ancla, sólo en su
--     pre-chequeo de stock.
-- 4 · cobros-B1: imputar_credito_a_pedido abría la solicitud sin contenido:
--     la clave reusada para otro crédito, otra boleta u otro monto devolvía el
--     replay del primero. Ahora pasa (pago, pedido, monto), como los otros seis
--     wrappers (1559-b14).
-- 5 · cobros-B6: el contenido del FIFO simple guardaba el monto como texto
--     (5.00 contra 5 era «otro cobro»). Ahora va como número de jsonb (5.00 =
--     5); un NaN entra como el texto "NaN" (to_jsonb) y lo rechaza el _impl.
-- 6 · cobros-B4: el FIFO de la ficha con un cliente de otra sucursal terminaba
--     en el 23503 de la FK; ahora «Cliente no encontrado» (P0002), antes de
--     tomar nada.
-- 7 · cobros-B2: marcar_entrega_y_pago_masivo_impl le pisaba pedidos.forma_pago
--     a las boletas del lote que ya estaban cobradas (gemelo de 1559-b11, que
--     se arregló en marcar_pagos_masivo_impl). Ahora la forma va sólo en las
--     que este lote cobró; la entrega sigue alcanzando a todas.
-- 8 · cobros-B5: «El pago (#########.##) supera lo que falta»: to_char con
--     'FM999999990.00' desborda desde mil millones. Ahora el número redondeado
--     al centavo, con el mismo formato que antes para lo de siempre (100.00).
-- 9 · stock-STK-3: crear_lote_manual pasa unidades de la bolsa a un lote sin
--     mover el stock y no dejaba fila en el ledger (D5 de #1558 se aplicó sólo
--     a ajustar_lote). Ahora deja la suya: anterior = nuevo (STK-A cierra), con
--     el lote como referencia y quien lo hizo (origen 'lote_manual').
-- 10 · reportes-R1: un gasto de más de 999.999.999.999,99 decía «El monto tiene
--     que ser mayor a cero»; ahora dice el tope.
-- 11 · reportes-R2: guardar_empleado (edición) escribía NULL en cuil, teléfono,
--     fecha de ingreso, usuario, cliente y vehículo si el JSON no traía la
--     clave. Ahora lo omitido se conserva y un null explícito lo borra, como
--     guardar_rubro_gasto y los litros de _guardar_gasto (GAS-1).
-- 12 · reportes-R3: el alta de un gasto y la de un empleado no tenían clave de
--     idempotencia: un reintento tras perder la respuesta duplicaba el gasto (y
--     su reintegro al empleado) o el empleado. Ahora, con el patrón de C4b
--     (altas_por_clave): el JSON trae `clave` (opcional: sin ella, como antes);
--     la misma clave con el mismo contenido devuelve el id del primero; con
--     otro contenido, otra operación u otro usuario, 22023. En el empleado la
--     clave se mira antes de las validaciones: el reintento chocaría con la
--     unicidad del usuario o del cliente que el primer intento ya vinculó.
--
-- Lo que NO hace (y por qué, en el informe de la tarjeta): stock-STK-2 (la
-- barra devuelve el fardo recién al final de la edición, después de la bajada
-- de las líneas: contarlo en el pre-chequeo no alcanza, la bajada de la línea
-- choca con productos_stock_no_negativo; arreglarlo es reordenar el motor de
-- B19). venta-B4 en el alta (crear_pedido_completo no es de esta tarjeta).
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- La única DDL de tabla (el CHECK de altas_por_clave): su lock primero, sin
-- esperar. Si un alta de cliente o de promo la tiene tomada, falla al instante
-- y se reintenta.
LOCK TABLE public.altas_por_clave IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 540.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.imputar_credito_a_pedido(bigint,bigint,numeric,uuid)', '4c4e542cdc21d064aecaab6e41a14e0b'),
    ('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)', '728ea65bf5a8363c6a9b3f254f299323'),
    ('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', '2bc25566a28abf747779a026d1ac5a0b'),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', '23c0298ccce785a11810184312597739'),
    ('public.crear_lote_manual(bigint,date,integer)', '2f676e17bf10f7fe25fbc5183b30cbc8'),
    ('public._guardar_gasto(jsonb,boolean)', '1a44be977a061e1d9f74ef52f191d89f'),
    ('public.guardar_gasto(jsonb)', 'bcadf934b163d3a7702759b76fa4401a'),
    ('public.guardar_empleado(jsonb)', '6bfe66b1e7dfc805722f024c33ccab16'),
    -- Por ancla, sin md5: otra tarjeta de la tanda puede tocar otro tramo.
    ('public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)', NULL),
    ('public.anular_salvedad(bigint,text)', NULL),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', NULL),
    ('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)', NULL)
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    IF r.h IS NULL THEN CONTINUE; END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  -- El CHECK de las operaciones de altas_por_clave, como lo dejó la 534.
  SELECT pg_get_constraintdef(oid) INTO v FROM pg_constraint
   WHERE conrelid = 'public.altas_por_clave'::regclass AND conname = 'altas_por_clave_operacion_check';
  IF v IS DISTINCT FROM $c$CHECK ((operacion = ANY (ARRAY['condicion_mayorista'::text, 'promocion'::text, 'cliente'::text])))$c$ THEN
    RAISE EXCEPTION 'mig NNN · el CHECK de altas_por_clave no es el de la 534 (%): rehacer sobre lo vigente', v;
  END IF;
END
$premisas$;

-- Reemplaza un ancla que tiene que aparecer exactamente p_n veces.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_n int, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> p_n THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba %', p_que, v_n, p_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- 12 · reportes-R3: las altas de gasto y de empleado entran en altas_por_clave
-- =========================================================================
ALTER TABLE public.altas_por_clave DROP CONSTRAINT altas_por_clave_operacion_check;
ALTER TABLE public.altas_por_clave ADD CONSTRAINT altas_por_clave_operacion_check
  CHECK (operacion = ANY (ARRAY['condicion_mayorista'::text, 'promocion'::text, 'cliente'::text,
                                'gasto'::text, 'empleado'::text]));

-- =========================================================================
-- 1 · venta-B1: precio_fuera_de_politica
-- =========================================================================
DO $b1$
DECLARE
  v_def text := pg_get_functiondef('public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$              AND (nv.total_nuevo < gv.total_guardado OR nv.distintos_nuevo < gv.distintos_guardado)) THEN$a$,
$a$              AND (nv.total_nuevo < gv.total_guardado OR nv.distintos_nuevo < gv.distintos_guardado
                   -- venta-B1 (tanda 6 de #1603): con un mínimo por producto la regla no es
                   -- monótona (A×10 + B×10 → A×19 + B×1 no achica el total ni los distintos, y
                   -- B ya no cumple su mínimo). Tampoco se conserva si baja la cantidad de un
                   -- producto que tiene mínimo en alguna escala del grupo, esté activa o no (la
                   -- que justificó el precio guardado puede ser una que hoy no aplica).
                   OR EXISTS (
                     SELECT 1
                       FROM grupo_precio_escalas es
                       JOIN grupo_precio_escala_minimos m ON m.escala_id = es.id
                      WHERE es.grupo_precio_id = g.id AND es.sucursal_id = p_sucursal
                        AND m.cantidad_minima_por_item > 0
                        AND (SELECT COALESCE(SUM(COALESCE(NULLIF(e->>'cantidad', '')::numeric, 0)), 0)
                               FROM jsonb_array_elements(v_items_escala) e
                              WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)
                                AND NULLIF(e->>'producto_id', '')::bigint = m.producto_id)
                          < (SELECT COALESCE(SUM(pi.cantidad), 0)
                               FROM pedido_items pi
                              WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal
                                AND pi.producto_id = m.producto_id
                                AND NOT COALESCE(pi.es_bonificacion, false)
                                AND NOT EXISTS (SELECT 1 FROM pedido_combos f
                                                 WHERE f.pedido_id = pi.pedido_id AND f.combo_id = pi.combo_id
                                                   AND f.sucursal_id = pi.sucursal_id AND NOT f.combina_escalas))))) THEN$a$,
    1, 'precio_fuera_de_politica (venta-B1)');
  EXECUTE v_def;
END
$b1$;

-- =========================================================================
-- 2 · venta-B3: anular_salvedad (sólo el tramo del precio de lista)
-- =========================================================================
DO $b3$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
  v_que text := 'anular_salvedad (venta-B3)';
BEGIN
  v_def := pg_temp.parche(v_def,
$a$AS $function$
DECLARE
$a$,
$a$AS $function$
DECLARE
  -- venta-B3 (tanda 6 de #1603): la marca de precio conservado de quien llama.
  v_conservado_previo TEXT;
$a$, 1, v_que || ' (declare)');
  v_def := pg_temp.parche(v_def,
$a$    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id,$a$,
$a$    -- venta-B3 (tanda 6 de #1603): la línea vuelve con el mismo producto, el mismo
    -- precio y la cantidad que esta salvedad sacó: no es una venta nueva. Si hoy el
    -- producto no tiene lista, validar_precio_item_pedido la deja entrar por la misma
    -- marca que la edición (D20 de 1559-b3), sólo para esta línea; la de quien llama
    -- vuelve a como estaba después del INSERT.
    v_conservado_previo := current_setting('app.edicion_precio_conservado', true);
    PERFORM set_config('app.edicion_precio_conservado',
      (COALESCE(NULLIF(v_conservado_previo, '')::jsonb, '{}'::jsonb)
       || jsonb_build_object(v_salvedad.pedido_id || ':' || v_salvedad.producto_id || ':'
                               || v_salvedad.precio_unitario::numeric(10,2)::text,
                             v_salvedad.cantidad_afectada))::text, true);
    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id,$a$,
    1, v_que || ' (insert)');
  v_def := pg_temp.parche(v_def,
$a$    ) RETURNING id INTO v_item_id;
  END IF;$a$,
$a$    ) RETURNING id INTO v_item_id;
    PERFORM set_config('app.edicion_precio_conservado', COALESCE(v_conservado_previo, ''), true);
  END IF;$a$,
    1, v_que || ' (restaurar)');
  EXECUTE v_def;
END
$b3$;

-- =========================================================================
-- 3 · venta-B4: actualizar_pedido_items (sólo el pre-chequeo de stock)
-- =========================================================================
DO $b4$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;

    IF v_es_bonificacion THEN
      IF v_promocion_id IS NULL THEN CONTINUE; END IF;
      -- #1324: el modo de la foto del pedido.$a$,
$a$    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;

    -- venta-B4 (tanda 6 de #1603): un renglón sin producto contestaba con el error
    -- crudo del jsonb_set de abajo. Todavía no se escribió nada.
    IF v_producto_id IS NULL THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
        'Hay un renglón sin producto: elegí el producto o sacá el renglón. El pedido no se modificó.'));
    END IF;

    IF v_es_bonificacion THEN
      IF v_promocion_id IS NULL THEN CONTINUE; END IF;
      -- #1324: el modo de la foto del pedido.$a$,
    1, 'actualizar_pedido_items (venta-B4)');
  EXECUTE v_def;
END
$b4$;

-- =========================================================================
-- 4 y 5 · cobros-B1 y cobros-B6: el contenido de la solicitud
-- =========================================================================
DO $cob16$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.imputar_credito_a_pedido(bigint,bigint,numeric,uuid)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'imputar_credito_a_pedido');$a$,
$a$  v_previo := public.pago_solicitud_abrir(p_client_request_id, 'imputar_credito_a_pedido',
    -- cobros-B1 (tanda 6 de #1603): lo que define la imputación, como los otros
    -- wrappers (1559-b14). Con otro crédito, otra boleta u otro monto la clave no es
    -- un reintento. El monto como número de jsonb (10.00 = 10); NULL es «todo».
    jsonb_build_object('pago_id', p_pago_id, 'pedido_id', p_pedido_id, 'monto', p_monto));$a$,
    1, 'imputar_credito_a_pedido (cobros-B1)');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$    -- El monto como texto: un 'NaN' no entra en un jsonb y lo rechaza el _impl.
    jsonb_build_object('cliente_id', p_cliente_id, 'monto', p_monto::text, 'forma_pago', p_forma_pago));$a$,
$a$    -- cobros-B6 (tanda 6 de #1603): el monto como número de jsonb, como el combinado
    -- (5.00 = 5). Un NaN queda como el texto "NaN" (to_jsonb) y lo rechaza el _impl.
    jsonb_build_object('cliente_id', p_cliente_id, 'monto', p_monto, 'forma_pago', p_forma_pago));$a$,
    1, 'registrar_pago_cliente_fifo (cobros-B6)');
  EXECUTE v_def;
END
$cob16$;

-- =========================================================================
-- 6 · cobros-B4: registrar_pago_cliente_fifo_impl
-- =========================================================================
DO $cob4$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden registrar pagos desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;
$a$,
$a$    RAISE EXCEPTION 'No autorizado: solo admin o encargado pueden registrar pagos desde ficha de cliente'
      USING ERRCODE = '42501';
  END IF;

  -- cobros-B4 (tanda 6 de #1603): un cliente de otra sucursal (o que no existe)
  -- terminaba en el 23503 de la FK del saldo a favor. Antes de tomar nada.
  IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = v_sucursal_id) THEN
    RAISE EXCEPTION 'Cliente no encontrado' USING ERRCODE = 'P0002';
  END IF;
$a$,
    1, 'registrar_pago_cliente_fifo_impl (cobros-B4)');
  EXECUTE v_def;
END
$cob4$;

-- =========================================================================
-- 7 · cobros-B2: marcar_entrega_y_pago_masivo_impl
-- =========================================================================
DO $cob2$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure);
  v_que text := 'marcar_entrega_y_pago_masivo_impl (cobros-B2)';
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_par RECORD;
BEGIN$a$,
$a$  v_par RECORD;
  -- cobros-B2 (tanda 6 de #1603): las boletas que este lote cobró.
  v_cobrados BIGINT[] := '{}';
BEGIN$a$, 1, v_que || ' (declare)');
  v_def := pg_temp.parche(v_def,
$a$      p_fecha,
      auth.uid(),
      v_sucursal_id
    );
  END LOOP;$a$,
$a$      p_fecha,
      auth.uid(),
      v_sucursal_id
    );
    v_cobrados := v_cobrados || v_pedido.id;
  END LOOP;$a$, 1, v_que || ' (bucle)');
  v_def := pg_temp.parche(v_def,
$a$         forma_pago = p_forma_pago,
         updated_at = now()$a$,
$a$         -- cobros-B2 (tanda 6 de #1603), gemelo de 1559-b11: la forma de pago va sólo en
         -- las boletas que este lote cobró. A una que ya estaba cobrada le pisaba la
         -- forma con la del lote.
         forma_pago = CASE WHEN id = ANY(v_cobrados) THEN p_forma_pago ELSE forma_pago END,
         updated_at = now()$a$, 1, v_que || ' (update)');
  EXECUTE v_def;
END
$cob2$;

-- =========================================================================
-- 8 · cobros-B5: registrar_pagos_pedido_impl (sólo el formato del aviso)
-- =========================================================================
DO $cob5$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$      trim(to_char(v_total, 'FM999999990.00')), p_pedido_id,
      trim(to_char(GREATEST(v_falta, 0), 'FM999999990.00'))$a$,
$a$      -- cobros-B5 (tanda 6 de #1603): el to_char de nueve cifras desbordaba desde mil
      -- millones («#########.##»). El mismo formato (100.00), sin tope.
      round(v_total, 2)::text, p_pedido_id,
      round(GREATEST(v_falta, 0), 2)::text$a$,
    1, 'registrar_pagos_pedido_impl (cobros-B5)');
  EXECUTE v_def;
END
$cob5$;

-- =========================================================================
-- 9 · stock-STK-3: crear_lote_manual
-- =========================================================================
DO $stk3$
DECLARE
  v_def text := pg_get_functiondef('public.crear_lote_manual(bigint,date,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    RETURNING id INTO v_lote_id;
  END IF;

  RETURN jsonb_build_object($a$,
$a$    RETURNING id INTO v_lote_id;
  END IF;

  -- stock-STK-3 (tanda 6 de #1603; D5 de #1558, como ajustar_lote): etiquetar pasa
  -- unidades de la bolsa al lote sin mover productos.stock, así que el trigger del
  -- ledger no escribía nada. Deja su fila: el stock no cambia (anterior = nuevo, y
  -- STK-A sigue cerrando), con el lote como referencia y quien lo hizo.
  INSERT INTO public.stock_historico (
    producto_id, stock_anterior, stock_nuevo, origen,
    referencia_tipo, referencia_id, usuario_id, sucursal_id
  ) VALUES (
    p_producto_id, v_stock, v_stock, 'lote_manual',
    'producto_lotes', v_lote_id, auth.uid(), v_sucursal
  );

  RETURN jsonb_build_object($a$,
    1, 'crear_lote_manual (stock-STK-3)');
  EXECUTE v_def;
END
$stk3$;

-- =========================================================================
-- 10 · reportes-R1: _guardar_gasto
-- =========================================================================
DO $r1$
DECLARE
  v_def text := pg_get_functiondef('public._guardar_gasto(jsonb,boolean)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF v_total IS NULL OR v_total <= 0 OR v_total > 999999999999.99 THEN
    RAISE EXCEPTION 'El monto tiene que ser mayor a cero';
  END IF;$a$,
$a$  IF v_total IS NULL OR v_total <= 0 THEN
    RAISE EXCEPTION 'El monto tiene que ser mayor a cero';
  END IF;
  -- reportes-R1 (tanda 6 de #1603): el techo de la columna, con su motivo (decía
  -- «mayor a cero»).
  IF v_total > 999999999999.99 THEN
    RAISE EXCEPTION 'El monto no puede pasar de $ 999.999.999.999,99';
  END IF;$a$,
    1, '_guardar_gasto (reportes-R1)');
  EXECUTE v_def;
END
$r1$;

-- =========================================================================
-- 12 · reportes-R3: guardar_gasto (el wrapper, entero)
-- =========================================================================
CREATE OR REPLACE FUNCTION public.guardar_gasto(p_gasto jsonb)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path = public, pg_temp
AS $function$
DECLARE
  v_clave     uuid;
  v_suc       bigint;
  v_contenido text;
  v_previa    public.altas_por_clave%ROWTYPE;
  v_id        bigint;
BEGIN
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o el encargado pueden cargar gastos';
  END IF;

  -- reportes-R3 (tanda 6 de #1603): el alta con la clave del formulario (el patrón de
  -- C4b, altas_por_clave). La misma clave con lo mismo es un reintento: devuelve el
  -- gasto del primer intento, sin cargarlo otra vez (ni su reintegro al empleado). Sin
  -- clave (un PWA de antes) o en una edición, como siempre.
  IF jsonb_typeof(p_gasto) = 'object' AND NULLIF(p_gasto->>'id', '') IS NULL
     AND NULLIF(p_gasto->>'clave', '') IS NOT NULL THEN
    BEGIN
      v_clave := (p_gasto->>'clave')::uuid;
      v_suc   := COALESCE(NULLIF(p_gasto->>'sucursal_id', '')::bigint, public.current_sucursal_id());
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Hay un dato del gasto con un formato inválido';
    END;
    -- Sin sucursal, _guardar_gasto lo rechaza con su motivo.
    IF v_suc IS NOT NULL THEN
      v_contenido := md5((p_gasto - 'clave')::text);
      INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
      VALUES (v_clave, 'gasto', auth.uid(), v_suc, v_contenido)
      ON CONFLICT (clave) DO NOTHING;
      IF NOT FOUND THEN
        SELECT * INTO v_previa FROM altas_por_clave WHERE clave = v_clave;
        IF v_previa.operacion <> 'gasto' OR v_previa.usuario_id IS DISTINCT FROM auth.uid()
           OR v_previa.sucursal_id <> v_suc THEN
          RAISE EXCEPTION 'Esta clave de alta ya se usó para otra operación: recargá la página e intentá de nuevo.'
            USING ERRCODE = '22023';
        END IF;
        IF v_previa.contenido <> v_contenido THEN
          RAISE EXCEPTION 'Este gasto ya se cargó con el intento anterior y lo que mandaste ahora es distinto: cerrá esta ventana y corregilo desde la lista.'
            USING ERRCODE = '22023';
        END IF;
        IF v_previa.entidad_id IS NULL OR NOT EXISTS (SELECT 1 FROM gastos WHERE id = v_previa.entidad_id) THEN
          RAISE EXCEPTION 'Este gasto ya se había cargado con el intento anterior y después se eliminó: cerrá esta ventana y cargalo de nuevo.'
            USING ERRCODE = '22023';
        END IF;
        RETURN v_previa.entidad_id;
      END IF;
      v_id := public._guardar_gasto(p_gasto, false);
      UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = v_clave;
      RETURN v_id;
    END IF;
  END IF;

  RETURN public._guardar_gasto(p_gasto, false);
END
$function$;

-- =========================================================================
-- 11 y 12 · reportes-R2 y reportes-R3: guardar_empleado
-- =========================================================================
DO $r23$
DECLARE
  v_def text := pg_get_functiondef('public.guardar_empleado(jsonb)'::regprocedure);
  v_que text := 'guardar_empleado';
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_mueve   boolean;
BEGIN$a$,
$a$  v_mueve   boolean;
  -- reportes-R3 (tanda 6 de #1603): la clave del alta.
  v_clave     uuid;
  v_suc_clave bigint;
  v_contenido text;
  v_previa    public.altas_por_clave%ROWTYPE;
BEGIN$a$, 1, v_que || ' (declare)');

  -- R3: la clave se mira antes de las validaciones. El reintento de un alta que entró
  -- chocaría con la unicidad del usuario o del cliente que el primer intento vinculó.
  v_def := pg_temp.parche(v_def,
$a$  -- 2 · en una edicion, la fila bloqueada y visible
$a$,
$a$  -- 1b · reportes-R3 (tanda 6 de #1603): el alta con la clave del formulario (el
  --      patrón de C4b, altas_por_clave). La misma clave con lo mismo es un reintento:
  --      devuelve el empleado del primer intento. Sin clave (un PWA de antes), como
  --      siempre. Va antes de las validaciones: el reintento de un alta que entró
  --      chocaría con la unicidad del usuario o del cliente que el primero vinculó.
  IF v_id IS NULL AND NULLIF(p_empleado->>'clave', '') IS NOT NULL THEN
    BEGIN
      v_clave := (p_empleado->>'clave')::uuid;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
    END;
    v_suc_clave := COALESCE(v_suc, public.current_sucursal_id());
    -- Sin sucursal, el paso 3 lo rechaza con su motivo.
    IF v_suc_clave IS NOT NULL THEN
      v_contenido := md5((p_empleado - 'clave')::text);
      INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
      VALUES (v_clave, 'empleado', v_uid, v_suc_clave, v_contenido)
      ON CONFLICT (clave) DO NOTHING;
      IF NOT FOUND THEN
        SELECT * INTO v_previa FROM altas_por_clave WHERE clave = v_clave;
        IF v_previa.operacion <> 'empleado' OR v_previa.usuario_id IS DISTINCT FROM v_uid
           OR v_previa.sucursal_id <> v_suc_clave THEN
          RAISE EXCEPTION 'Esta clave de alta ya se usó para otra operación: recargá la página e intentá de nuevo.'
            USING ERRCODE = '22023';
        END IF;
        IF v_previa.contenido <> v_contenido THEN
          RAISE EXCEPTION 'Este empleado ya se cargó con el intento anterior y lo que mandaste ahora es distinto: cerrá esta ventana y corregilo desde la lista.'
            USING ERRCODE = '22023';
        END IF;
        IF v_previa.entidad_id IS NULL OR NOT EXISTS (SELECT 1 FROM empleados WHERE id = v_previa.entidad_id) THEN
          RAISE EXCEPTION 'Este empleado ya se había cargado con el intento anterior y después se eliminó: cerrá esta ventana y cargalo de nuevo.'
            USING ERRCODE = '22023';
        END IF;
        RETURN v_previa.entidad_id;
      END IF;
    ELSE
      v_clave := NULL;
    END IF;
  END IF;

  -- 2 · en una edicion, la fila bloqueada y visible
$a$, 1, v_que || ' (clave)');

  -- R2: en la edición, lo que el JSON no trae se conserva.
  v_def := pg_temp.parche(v_def,
$a$  v_dos := COALESCE(v_dos, v_viejo.de_las_dos, false);
$a$,
$a$  v_dos := COALESCE(v_dos, v_viejo.de_las_dos, false);

  -- reportes-R2 (tanda 6 de #1603): en una edición, la clave que el JSON no trae queda
  -- como estaba; un null explícito la borra (como guardar_rubro_gasto y los litros de
  -- _guardar_gasto). Antes, lo omitido se escribía NULL.
  IF v_id IS NOT NULL THEN
    IF NOT p_empleado ? 'cuil'          THEN v_cuil    := v_viejo.cuil;          END IF;
    IF NOT p_empleado ? 'fecha_ingreso' THEN v_ingreso := v_viejo.fecha_ingreso; END IF;
    IF NOT p_empleado ? 'telefono'      THEN v_tel     := v_viejo.telefono;      END IF;
    IF NOT p_empleado ? 'usuario_id'    THEN v_usr     := v_viejo.usuario_id;    END IF;
    IF NOT p_empleado ? 'cliente_id'    THEN v_cli     := v_viejo.cliente_id;    END IF;
    IF NOT p_empleado ? 'vehiculo_id'   THEN v_veh     := v_viejo.vehiculo_id;   END IF;
  END IF;
$a$, 1, v_que || ' (R2)');

  -- R3: el alta anota el empleado en su clave.
  v_def := pg_temp.parche(v_def,
$a$    VALUES (v_id, LEAST(v_desde, public._tablero_hoy()), 'ajuste', v_saldo, 'Saldo al empezar', v_uid);
  END IF;
  RETURN v_id;$a$,
$a$    VALUES (v_id, LEAST(v_desde, public._tablero_hoy()), 'ajuste', v_saldo, 'Saldo al empezar', v_uid);
  END IF;
  IF v_clave IS NOT NULL THEN
    UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = v_clave;
  END IF;
  RETURN v_id;$a$, 1, v_que || ' (cierre de la clave)');
  EXECUTE v_def;
END
$r23$;

-- =========================================================================
-- La lista blanca de SEG-A (auditoria_definer_sin_rol): los dos wrappers que
-- cambiaron (cobros-B1 y cobros-B6) siguen sin guard de rol propio (lo mira el
-- _impl); su md5 pasa al del cuerpo nuevo. Por ancla y sin premisa de md5: otras
-- tarjetas de la tanda le cambian otras líneas.
-- =========================================================================
DO $sega$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_definer_sin_rol()'::regprocedure);
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)', '728ea65bf5a8363c6a9b3f254f299323',
     'public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)'),
    ('imputar_credito_a_pedido(bigint,bigint,numeric,uuid)', '4c4e542cdc21d064aecaab6e41a14e0b',
     'public.imputar_credito_a_pedido(bigint,bigint,numeric,uuid)')
  ) AS t(firma, viejo, f) LOOP
    v_def := pg_temp.parche(v_def,
      format('(%L,', r.firma),
      format('(%L,', r.firma), 1, 'auditoria_definer_sin_rol (' || r.firma || ', firma)');
    v_def := pg_temp.parche(v_def,
      quote_literal(r.viejo) || ')',
      quote_literal((SELECT md5(prosrc) FROM pg_proc WHERE oid = r.f::regprocedure)) || ')',
      1, 'auditoria_definer_sin_rol (' || r.firma || ', md5)');
  END LOOP;
  EXECUTE v_def;
END
$sega$;

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)', 'JOIN grupo_precio_escala_minimos m ON m.escala_id = es.id', 1, false),
    ('public.anular_salvedad(bigint,text)', 'v_conservado_previo := current_setting(''app.edicion_precio_conservado'', true);', 1, true),
    ('public.anular_salvedad(bigint,text)', 'PERFORM set_config(''app.edicion_precio_conservado'', COALESCE(v_conservado_previo, ''''), true);', 1, true),
    ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', 'Hay un renglón sin producto', 1, true),
    ('public.imputar_credito_a_pedido(bigint,bigint,numeric,uuid)', 'jsonb_build_object(''pago_id'', p_pago_id, ''pedido_id'', p_pedido_id, ''monto'', p_monto)', 1, true),
    ('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)', '''monto'', p_monto, ''forma_pago''', 1, true),
    ('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)', 'p_monto::text', 0, true),
    ('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', 'RAISE EXCEPTION ''Cliente no encontrado''', 1, true),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', 'forma_pago = CASE WHEN id = ANY(v_cobrados) THEN p_forma_pago ELSE forma_pago END', 1, true),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', 'v_cobrados := v_cobrados || v_pedido.id;', 1, true),
    ('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)', 'FM999999990.00', 0, true),
    ('public.crear_lote_manual(bigint,date,integer)', '''lote_manual''', 1, true),
    ('public._guardar_gasto(jsonb,boolean)', 'El monto no puede pasar de $ 999.999.999.999,99', 1, true),
    ('public.guardar_gasto(jsonb)', 'VALUES (v_clave, ''gasto'', auth.uid(), v_suc, v_contenido)', 1, true),
    ('public.guardar_empleado(jsonb)', 'VALUES (v_clave, ''empleado'', v_uid, v_suc_clave, v_contenido)', 1, true),
    ('public.guardar_empleado(jsonb)', 'IF NOT p_empleado ? ''vehiculo_id''   THEN v_veh     := v_viejo.vehiculo_id;   END IF;', 1, true),
    ('public.guardar_empleado(jsonb)', 'UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = v_clave;', 1, true)
  ) AS t(f, marca, n, definer) LOOP
    IF (SELECT (length(prosrc) - length(replace(prosrc, r.marca, ''))) / length(r.marca)
          FROM pg_proc WHERE oid = r.f::regprocedure) <> r.n
       OR (SELECT prosecdef FROM pg_proc WHERE oid = r.f::regprocedure) <> r.definer THEN
      RAISE EXCEPTION 'mig NNN · el parche de % no entró (% debía aparecer % veces)', r.f, r.marca, r.n;
    END IF;
  END LOOP;
  -- Todas siguen con su search_path terminado en pg_temp (B15).
  FOR r IN SELECT unnest(ARRAY[
      'public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)',
      'public.anular_salvedad(bigint,text)',
      'public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)',
      'public.imputar_credito_a_pedido(bigint,bigint,numeric,uuid)',
      'public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)',
      'public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)',
      'public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)',
      'public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)',
      'public.crear_lote_manual(bigint,date,integer)',
      'public._guardar_gasto(jsonb,boolean)',
      'public.guardar_gasto(jsonb)',
      'public.guardar_empleado(jsonb)']) AS f LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = r.f::regprocedure
                    AND proconfig @> ARRAY['search_path=public, pg_temp']) THEN
      RAISE EXCEPTION 'mig NNN · % quedó sin pg_temp en su search_path', r.f;
    END IF;
  END LOOP;
  -- Los permisos no cambiaron: las RPCs, para authenticated; los _impl y el helper, sólo server.
  FOR r IN SELECT * FROM (VALUES
      ('public.anular_salvedad(bigint,text)', true),
      ('public.actualizar_pedido_items(bigint,jsonb,uuid,text,timestamp with time zone)', true),
      ('public.imputar_credito_a_pedido(bigint,bigint,numeric,uuid)', true),
      ('public.registrar_pago_cliente_fifo(bigint,numeric,text,date,text,text,uuid)', true),
      ('public.crear_lote_manual(bigint,date,integer)', true),
      ('public.guardar_gasto(jsonb)', true),
      ('public.guardar_empleado(jsonb)', true),
      ('public.registrar_pago_cliente_fifo_impl(bigint,numeric,text,date,text,text)', false),
      ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', false),
      ('public.registrar_pagos_pedido_impl(bigint,jsonb,date,text,text)', false),
      ('public._guardar_gasto(jsonb,boolean)', false)
    ) AS t(f, api) LOOP
    IF has_function_privilege('anon', r.f, 'EXECUTE')
       OR has_function_privilege('authenticated', r.f, 'EXECUTE') IS DISTINCT FROM r.api THEN
      RAISE EXCEPTION 'mig NNN · los permisos de % no son los esperados', r.f;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint
                  WHERE conrelid = 'public.altas_por_clave'::regclass AND conname = 'altas_por_clave_operacion_check'
                    AND pg_get_constraintdef(oid) LIKE '%''gasto''::text, ''empleado''::text%') THEN
    RAISE EXCEPTION 'mig NNN · el CHECK de altas_por_clave no quedó con gasto y empleado';
  END IF;
  -- SEG-A no ve ninguna de las funciones de esta migración (lee sólo el catálogo).
  IF EXISTS (SELECT 1 FROM public.auditoria_definer_sin_rol() x
              WHERE row_to_json(x)::text ~ '(imputar_credito_a_pedido|registrar_pago_cliente_fifo|marcar_entrega_y_pago_masivo_impl|registrar_pagos_pedido_impl|crear_lote_manual|guardar_gasto|guardar_empleado|anular_salvedad|actualizar_pedido_items)\(') THEN
    RAISE EXCEPTION 'mig NNN · SEG-A ve una función de esta migración';
  END IF;
END
$post$;

COMMIT;
