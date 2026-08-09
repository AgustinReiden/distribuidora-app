-- =========================================================================
-- 174_salvedad_regalos_y_minimo_de_venta.sql
--
-- Dos cosas que trababan la entrega con salvedad en la calle:
--
-- 1) El mínimo de venta (mig 147) bloqueaba la salvedad.
--    `trg_validar_minimo_venta_item` dispara en UPDATE OF cantidad, así que
--    bajar una línea de 3 a 1 porque faltó stock reventaba con
--    "La compra mínima de X es 3 unidades". El mínimo es una regla de CARGA
--    del pedido, no de lo que efectivamente bajó del camión: pedido #4503
--    quedó entregado por $21.190 con 2 unidades de ALIC COMINO que nunca se
--    entregaron. 36 productos (condimentos + fideos) tienen mínimo hoy.
--    Fix: escape hatch por GUC de transacción que sólo prenden los RPCs de
--    salvedad. La guarda sigue intacta para alta y edición de pedidos.
--
-- 2) Los regalos de promoción no se podían tocar y encima nadie avisaba.
--    - `registrar_salvedad` ya resincroniza las bonificaciones (mig 010),
--      pero el modal de entrega mostraba los regalos como "entregados
--      correctamente" en el resumen. Pedido #4609: se cayeron los 12
--      PERONACHO, el sistema borró solo el regalo de 4 y la usuaria nunca
--      se enteró.
--    - Si el regalo NO se entregó pero los disparadores sí (no se cargó en
--      el camión), no había forma de registrarlo: el modal no dejaba
--      seleccionarlo. En la vista del chofer sí se podía, pero devolvía
--      stock de un regalo que nunca lo había descontado
--      (`regalo_mueve_stock = false`) y no descontaba `usos_pendientes`.
--    Fix: la salvedad sobre una línea de bonificación es legal y contabiliza
--    bien; + RPC de simulación multi-item para que el modal muestre en qué
--    queda cada regalo ANTES de confirmar.
--
-- De paso se convergen las dos sobrecargas de `registrar_salvedad`, que
-- estaban divergidas en prod: la de 7 args tenía `revertir_bloques_auto_ajuste`
-- pero no la trazabilidad de stock, la de 8 args al revés. La de 7 args pasa a
-- ser un wrapper; la lógica vive en la de 8.
--
-- Idempotente (CREATE OR REPLACE).
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. El mínimo de venta no aplica a lo que se entrega
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validar_minimo_venta_item()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $fn$
DECLARE
  v_nombre text;
  v_minimo integer;
BEGIN
  -- Los RPCs de salvedad prenden este flag (local a la transacción): lo que
  -- se entrega de menos no puede quedar trabado por el mínimo de compra.
  IF COALESCE(current_setting('app.omitir_minimo_venta', true), '') = '1' THEN
    RETURN NEW;
  END IF;

  IF COALESCE(NEW.es_bonificacion, false) THEN
    RETURN NEW;
  END IF;

  SELECT nombre, cantidad_minima_venta INTO v_nombre, v_minimo
  FROM productos WHERE id = NEW.producto_id;

  IF v_minimo IS NOT NULL AND NEW.cantidad < v_minimo THEN
    RAISE EXCEPTION 'La compra mínima de "%" es % unidades (se cargaron %)',
      COALESCE(v_nombre, NEW.producto_id::text), v_minimo, NEW.cantidad
      USING ERRCODE = 'check_violation';
  END IF;

  RETURN NEW;
END;
$fn$;

ALTER FUNCTION public.validar_minimo_venta_item() OWNER TO postgres;

COMMENT ON FUNCTION public.validar_minimo_venta_item() IS
  'Mínimo de compra por producto (mig 147). Se saltea con app.omitir_minimo_venta=1, que prenden los RPCs de salvedad: el mínimo rige el pedido, no la entrega. Mig 174.';

-- -------------------------------------------------------------------------
-- 2. registrar_salvedad: implementación única (8 args)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_salvedad(
  p_pedido_id         bigint,
  p_pedido_item_id    bigint,
  p_cantidad_afectada integer,
  p_motivo            character varying,
  p_descripcion       text    DEFAULT NULL::text,
  p_foto_url          text    DEFAULT NULL::text,
  p_devolver_stock    boolean DEFAULT true,
  p_client_request_id uuid    DEFAULT NULL::uuid
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal              BIGINT := current_sucursal_id();
  v_salvedad_id           BIGINT;
  v_item                  RECORD;
  v_existing              RECORD;
  v_cantidad_entregada    INTEGER;
  v_monto_afectado        DECIMAL;
  v_usuario_id            UUID;
  v_es_admin_o_encargado  BOOLEAN;
  v_subtotal_nuevo        DECIMAL;
  v_stock_devuelto        BOOLEAN := FALSE;
  v_merma_registrada      BOOLEAN := FALSE;
  v_stock_actual          INTEGER;
  v_es_bonif              BOOLEAN;
  v_mueve_stock           BOOLEAN;
  v_bonif                 RECORD;
  v_cant_compra           INT;
  v_cant_bonif            INT;
  v_total_qty             INT;
  v_bloques               INT;
  v_expected_bonif        INT;
  v_diff                  INT;
  v_regalo_mueve_stock    BOOLEAN;
  v_tipo_factura          TEXT;
BEGIN
  IF p_client_request_id IS NOT NULL THEN
    SELECT id, motivo, monto_afectado, cantidad_entregada, stock_devuelto, pedido_id
      INTO v_existing
      FROM salvedades_items
     WHERE client_request_id = p_client_request_id;

    IF FOUND THEN
      RETURN jsonb_build_object(
        'success', true,
        'salvedad_id', v_existing.id,
        'monto_afectado', v_existing.monto_afectado,
        'cantidad_entregada', v_existing.cantidad_entregada,
        'stock_devuelto', v_existing.stock_devuelto,
        'merma_registrada', v_existing.motivo IN ('producto_danado', 'producto_vencido'),
        'nuevo_total_pedido', (
          SELECT total FROM pedidos
           WHERE id = v_existing.pedido_id AND sucursal_id = v_sucursal
        ),
        'idempotent_replay', true
      );
    END IF;
  END IF;

  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  v_usuario_id := auth.uid();
  IF v_usuario_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Usuario no autenticado');
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM perfiles
     WHERE id = v_usuario_id AND rol IN ('admin', 'encargado')
  ) INTO v_es_admin_o_encargado;
  IF NOT v_es_admin_o_encargado THEN
    IF NOT EXISTS (
      SELECT 1 FROM pedidos
       WHERE id = p_pedido_id AND transportista_id = v_usuario_id AND sucursal_id = v_sucursal
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'No autorizado para este pedido');
    END IF;
  END IF;

  SELECT pi.id, pi.producto_id, pi.cantidad, pi.precio_unitario, pi.subtotal,
         COALESCE(pi.es_bonificacion, FALSE) AS es_bonificacion, pi.promocion_id
    INTO v_item
    FROM pedido_items pi
   WHERE pi.id = p_pedido_item_id
     AND pi.pedido_id = p_pedido_id
     AND pi.sucursal_id = v_sucursal;

  IF NOT FOUND THEN
    -- Puede pasar legítimamente con un regalo que la resincronización de
    -- promos ya sacó del pedido; el `codigo` deja que el llamador lo
    -- distinga de un error real.
    RETURN jsonb_build_object(
      'success', false,
      'error', 'Item de pedido no encontrado',
      'codigo', 'item_no_encontrado'
    );
  END IF;

  IF p_cantidad_afectada > v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad afectada mayor a cantidad del item');
  END IF;
  IF p_cantidad_afectada <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad debe ser mayor a 0');
  END IF;

  v_es_bonif := v_item.es_bonificacion;

  -- ¿Esta línea descontó stock cuando se cargó el pedido? Un regalo de una
  -- promo con `regalo_mueve_stock = false` nunca lo tocó, así que tampoco lo
  -- devuelve ni genera merma.
  IF v_es_bonif THEN
    SELECT COALESCE(pr.regalo_mueve_stock, FALSE) INTO v_mueve_stock
      FROM promociones pr
     WHERE pr.id = v_item.promocion_id AND pr.sucursal_id = v_sucursal;
    v_mueve_stock := COALESCE(v_mueve_stock, FALSE);
  ELSE
    v_mueve_stock := TRUE;
  END IF;

  v_cantidad_entregada := v_item.cantidad - p_cantidad_afectada;
  v_monto_afectado     := p_cantidad_afectada * v_item.precio_unitario;
  v_subtotal_nuevo     := v_cantidad_entregada * v_item.precio_unitario;

  IF p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio') THEN
    v_stock_devuelto := TRUE;
  END IF;
  v_stock_devuelto := v_stock_devuelto AND v_mueve_stock;

  PERFORM set_config('app.stock_origen', 'salvedad', true);
  PERFORM set_config('app.stock_ref_tipo', 'pedido', true);
  PERFORM set_config('app.stock_ref_id', p_pedido_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', v_usuario_id::TEXT, true);
  -- Lo que se entregó de menos no lo trapa el mínimo de compra (mig 147).
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  INSERT INTO salvedades_items (
    pedido_id, pedido_item_id, producto_id, cantidad_original, cantidad_afectada,
    cantidad_entregada, motivo, descripcion, foto_url, monto_afectado, precio_unitario,
    reportado_por, stock_devuelto, stock_devuelto_at, estado_resolucion, sucursal_id,
    client_request_id
  ) VALUES (
    p_pedido_id, p_pedido_item_id, v_item.producto_id, v_item.cantidad, p_cantidad_afectada,
    v_cantidad_entregada, p_motivo, p_descripcion, p_foto_url, v_monto_afectado, v_item.precio_unitario,
    v_usuario_id, v_stock_devuelto, CASE WHEN v_stock_devuelto THEN NOW() ELSE NULL END, 'pendiente', v_sucursal,
    p_client_request_id
  ) RETURNING id INTO v_salvedad_id;

  IF v_salvedad_id IS NULL THEN
    RAISE EXCEPTION 'No se pudo crear la salvedad';
  END IF;

  IF v_cantidad_entregada > 0 THEN
    UPDATE pedido_items
       SET cantidad = v_cantidad_entregada,
           subtotal = v_subtotal_nuevo
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    DELETE FROM pedido_items
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  END IF;

  -- Salvedad sobre el regalo mismo: las unidades que no se entregaron dejan
  -- de estar comprometidas por la promo.
  IF v_es_bonif AND v_item.promocion_id IS NOT NULL THEN
    PERFORM public.revertir_bloques_auto_ajuste(
      v_item.promocion_id, p_cantidad_afectada, v_sucursal,
      v_usuario_id, 'Salvedad sobre regalo, pedido #' || p_pedido_id
    );
  END IF;

  -- Resincronizar bonificaciones: si cayó el disparador, cae el regalo.
  -- Sólo reduce, nunca aumenta, así que no pisa una salvedad manual sobre el
  -- propio regalo hecha en el mismo lote.
  FOR v_bonif IN
    SELECT pi.id, pi.producto_id, pi.cantidad, pi.promocion_id
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
       AND pi.promocion_id IS NOT NULL
  LOOP
    SELECT
      MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT,
      MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT,
      MAX(p.regalo_mueve_stock::INT)::BOOLEAN
    INTO v_cant_compra, v_cant_bonif, v_regalo_mueve_stock
    FROM promociones p
    LEFT JOIN promocion_reglas pr
      ON pr.promocion_id = p.id
    WHERE p.id = v_bonif.promocion_id
      AND p.sucursal_id = v_sucursal
    GROUP BY p.id;

    IF v_cant_compra IS NULL OR v_cant_compra <= 0
       OR v_cant_bonif IS NULL OR v_cant_bonif <= 0 THEN
      CONTINUE;
    END IF;

    SELECT COALESCE(SUM(pi.cantidad), 0)::INT
      INTO v_total_qty
      FROM pedido_items pi
      JOIN promocion_productos pp
        ON pp.producto_id = pi.producto_id
       AND pp.promocion_id = v_bonif.promocion_id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = FALSE;

    v_bloques        := v_total_qty / v_cant_compra;
    v_expected_bonif := v_bloques * v_cant_bonif;

    IF v_expected_bonif < v_bonif.cantidad THEN
      v_diff := v_bonif.cantidad - v_expected_bonif;

      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos
           SET stock = stock + v_diff
         WHERE id = v_bonif.producto_id
           AND sucursal_id = v_sucursal;
      END IF;

      PERFORM public.revertir_bloques_auto_ajuste(
        v_bonif.promocion_id, v_diff, v_sucursal,
        v_usuario_id, 'Salvedad pedido #' || p_pedido_id
      );

      IF v_expected_bonif = 0 THEN
        DELETE FROM pedido_items WHERE id = v_bonif.id;
      ELSE
        UPDATE pedido_items
           SET cantidad = v_expected_bonif,
               subtotal = v_expected_bonif * COALESCE(precio_unitario, 0)
         WHERE id = v_bonif.id;
      END IF;
    END IF;
  END LOOP;

  SELECT COALESCE(tipo_factura, 'ZZ') INTO v_tipo_factura
    FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  UPDATE pedidos
     SET total = sub.total_recalc,
         total_neto = sub.neto_recalc,
         total_iva = sub.iva_recalc,
         total_real = sub.real_recalc,
         updated_at = NOW()
    FROM (
      SELECT
        COALESCE(SUM(subtotal), 0) AS total_recalc,
        COALESCE(SUM(CASE WHEN COALESCE(es_bonificacion, FALSE) = FALSE
                          THEN cantidad * COALESCE(neto_unitario, precio_unitario)
                          ELSE 0 END), 0) AS neto_recalc,
        COALESCE(SUM(CASE WHEN COALESCE(es_bonificacion, FALSE) = FALSE
                          THEN cantidad * COALESCE(iva_unitario, 0)
                          ELSE 0 END), 0) AS iva_recalc,
        COALESCE(SUM(CASE WHEN COALESCE(es_bonificacion, FALSE) = FALSE
                          THEN cantidad * COALESCE(ingreso_real_unitario,
                               CASE WHEN v_tipo_factura = 'FC'
                                    THEN COALESCE(neto_unitario, precio_unitario)
                                    ELSE precio_unitario END)
                          ELSE 0 END), 0) AS real_recalc
        FROM pedido_items
       WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal
    ) sub
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  IF v_stock_devuelto THEN
    UPDATE productos
       SET stock = stock + p_cantidad_afectada
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
  END IF;

  IF p_motivo IN ('producto_danado', 'producto_vencido') AND v_mueve_stock THEN
    SELECT stock INTO v_stock_actual
      FROM productos
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal
     FOR UPDATE;

    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      v_item.producto_id, p_cantidad_afectada,
      CASE p_motivo WHEN 'producto_danado' THEN 'rotura' WHEN 'producto_vencido' THEN 'vencimiento' END,
      COALESCE(p_descripcion, 'Salvedad pedido #' || p_pedido_id || ': ' || p_motivo),
      v_stock_actual, GREATEST(v_stock_actual - p_cantidad_afectada, 0), v_usuario_id, v_sucursal
    );

    UPDATE productos
       SET stock = GREATEST(stock - p_cantidad_afectada, 0)
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;

    v_merma_registrada := TRUE;
  END IF;

  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);

  RETURN jsonb_build_object(
    'success', true,
    'salvedad_id', v_salvedad_id,
    'monto_afectado', v_monto_afectado,
    'cantidad_entregada', v_cantidad_entregada,
    'stock_devuelto', v_stock_devuelto,
    'merma_registrada', v_merma_registrada,
    'es_bonificacion', v_es_bonif,
    'nuevo_total_pedido', (
      SELECT total FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal
    )
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$fn$;

ALTER FUNCTION public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean, uuid) TO authenticated;

COMMENT ON FUNCTION public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean, uuid) IS
  'Registra una salvedad de entrega. Acepta líneas de bonificación (regalo no entregado): devuelve stock sólo si la promo mueve stock y libera usos_pendientes. Mig 174.';

-- -------------------------------------------------------------------------
-- 3. La sobrecarga de 7 args pasa a ser un wrapper (la usa useSalvedades)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.registrar_salvedad(
  p_pedido_id         bigint,
  p_pedido_item_id    bigint,
  p_cantidad_afectada integer,
  p_motivo            character varying,
  p_descripcion       text    DEFAULT NULL::text,
  p_foto_url          text    DEFAULT NULL::text,
  p_devolver_stock    boolean DEFAULT true
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
BEGIN
  RETURN public.registrar_salvedad(
    p_pedido_id, p_pedido_item_id, p_cantidad_afectada, p_motivo,
    p_descripcion, p_foto_url, p_devolver_stock, NULL::uuid
  );
END;
$fn$;

ALTER FUNCTION public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean) TO authenticated;

COMMENT ON FUNCTION public.registrar_salvedad(bigint, bigint, integer, character varying, text, text, boolean) IS
  'Wrapper sin client_request_id. La lógica vive en la sobrecarga de 8 args. Mig 174.';

-- -------------------------------------------------------------------------
-- 4. anular_salvedad tampoco se traba con el mínimo
--    (restaurar una línea histórica cargada por debajo del mínimo actual)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.anular_salvedad(
  p_salvedad_id bigint,
  p_notas       text DEFAULT NULL::text
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad RECORD;
  v_usuario_id UUID := auth.uid();
  v_tipo_factura TEXT;
  v_pct_iva NUMERIC; v_pct_ii NUMERIC; v_costo_real NUMERIC; v_costo_sin NUMERIC;
  v_costo_prom NUMERIC;
  v_neto NUMERIC; v_iva NUMERIC; v_real NUMERIC;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;
  SELECT * INTO v_salvedad FROM salvedades_items WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'No encontrada'); END IF;
  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya anulada');
  END IF;

  -- Devolver la línea a su cantidad original no es cargar un pedido nuevo:
  -- el mínimo de venta no debe trabarlo (mig 174).
  PERFORM set_config('app.omitir_minimo_venta', '1', true);

  SELECT COALESCE(tipo_factura, 'ZZ') INTO v_tipo_factura
    FROM pedidos WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;
  IF EXISTS (SELECT 1 FROM pedido_items WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal) THEN
    UPDATE pedido_items SET
      cantidad = v_salvedad.cantidad_original,
      subtotal = v_salvedad.cantidad_original * v_salvedad.precio_unitario
    WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    -- Reinsertar con la terna de ingresos y costo snapshot (CPP primero, mig 129)
    SELECT COALESCE(porcentaje_iva, 21), COALESCE(impuestos_internos, 0), costo_promedio, costo_real, costo_sin_iva
      INTO v_pct_iva, v_pct_ii, v_costo_prom, v_costo_real, v_costo_sin
      FROM productos WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
    SELECT d.neto, d.iva, d.ingreso_real INTO v_neto, v_iva, v_real
      FROM calcular_desglose_venta(v_salvedad.precio_unitario, v_pct_iva, v_pct_ii, v_tipo_factura) d;

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      ingreso_real_unitario, costo_unitario_al_crear
    )
    VALUES (
      v_salvedad.pedido_id, v_salvedad.producto_id, v_salvedad.cantidad_original,
      v_salvedad.precio_unitario, v_salvedad.cantidad_original * v_salvedad.precio_unitario, v_sucursal,
      v_neto, v_iva, 0, v_pct_iva,
      v_real,
      COALESCE(v_costo_prom, v_costo_real,
        CASE WHEN v_costo_sin IS NULL THEN NULL ELSE round(v_costo_sin * (1 + v_pct_ii / 100), 4) END)
    );
  END IF;
  UPDATE pedidos SET
    total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    total_neto = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false) THEN cantidad * COALESCE(neto_unitario, precio_unitario) ELSE 0 END), 0)
                    FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    total_iva = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false) THEN cantidad * COALESCE(iva_unitario, 0) ELSE 0 END), 0)
                   FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    total_real = (SELECT COALESCE(SUM(CASE WHEN NOT COALESCE(es_bonificacion, false)
                          THEN cantidad * COALESCE(ingreso_real_unitario,
                               CASE WHEN v_tipo_factura = 'FC' THEN COALESCE(neto_unitario, precio_unitario) ELSE precio_unitario END)
                          ELSE 0 END), 0)
                    FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    updated_at = NOW()
  WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;
  IF v_salvedad.stock_devuelto THEN
    UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
     WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
  END IF;
  UPDATE salvedades_items SET
    estado_resolucion = 'anulada',
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (p_salvedad_id, 'anulacion', v_salvedad.estado_resolucion, 'anulada', p_notas, v_usuario_id, v_sucursal);
  RETURN jsonb_build_object('success', true);
END;
$fn$;

ALTER FUNCTION public.anular_salvedad(bigint, text) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.anular_salvedad(bigint, text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.anular_salvedad(bigint, text) TO authenticated;

-- -------------------------------------------------------------------------
-- 5. Simulación multi-item: en qué queda CADA regalo del pedido si se
--    confirma este lote de salvedades. Espeja exactamente la resincronización
--    de arriba (sólo reduce; promo sin reglas => no se toca) para que el
--    resumen del modal no mienta.
--
--    p_salvedades: [{"pedido_item_id": 123, "cantidad_afectada": 12}, ...]
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.simular_salvedades_promo_impacto(
  p_pedido_id  bigint,
  p_salvedades jsonb
)
RETURNS TABLE(
  pedido_item_id     bigint,
  promocion_id       bigint,
  promo_nombre       text,
  producto_id        bigint,
  producto_nombre    text,
  descripcion_regalo text,
  cantidad_actual    integer,
  cantidad_final     integer,
  delta              integer,
  sera_eliminada     boolean
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  WITH afectadas AS (
    SELECT (e->>'pedido_item_id')::BIGINT AS item_id,
           GREATEST(COALESCE((e->>'cantidad_afectada')::INT, 0), 0) AS cant
      FROM jsonb_array_elements(COALESCE(p_salvedades, '[]'::jsonb)) e
     WHERE (e->>'pedido_item_id') IS NOT NULL
  ),
  items AS (
    SELECT pi.id, pi.producto_id, pi.cantidad, pi.promocion_id,
           pi.descripcion_regalo,
           COALESCE(pi.es_bonificacion, FALSE) AS es_bonif,
           GREATEST(pi.cantidad - COALESCE(a.cant, 0), 0)::INT AS cantidad_post
      FROM pedido_items pi
      LEFT JOIN afectadas a ON a.item_id = pi.id
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = current_sucursal_id()
  ),
  reglas AS (
    SELECT p.id AS promocion_id, p.nombre, p.descripcion_regalo,
           MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT AS cant_compra,
           MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT AS cant_bonif
      FROM promociones p
      LEFT JOIN promocion_reglas pr ON pr.promocion_id = p.id
     WHERE p.sucursal_id = current_sucursal_id()
     GROUP BY p.id, p.nombre, p.descripcion_regalo
  ),
  totales AS (
    SELECT pp.promocion_id, SUM(i.cantidad_post)::INT AS qty_post
      FROM items i
      JOIN promocion_productos pp ON pp.producto_id = i.producto_id
     WHERE NOT i.es_bonif
     GROUP BY pp.promocion_id
  ),
  calculo AS (
    SELECT
      b.id,
      b.promocion_id,
      r.nombre,
      b.producto_id,
      prod.nombre AS producto_nombre,
      COALESCE(b.descripcion_regalo, r.descripcion_regalo) AS desc_regalo,
      b.cantidad,
      LEAST(
        b.cantidad_post,
        CASE
          WHEN r.promocion_id IS NULL
            OR COALESCE(r.cant_compra, 0) <= 0
            OR COALESCE(r.cant_bonif, 0)  <= 0
          THEN b.cantidad_post            -- promo sin reglas: la resync la saltea
          ELSE (COALESCE(t.qty_post, 0) / r.cant_compra) * r.cant_bonif
        END
      )::INT AS cantidad_final
      FROM items b
      LEFT JOIN reglas   r    ON r.promocion_id = b.promocion_id
      LEFT JOIN totales  t    ON t.promocion_id = b.promocion_id
      LEFT JOIN productos prod ON prod.id = b.producto_id
     WHERE b.es_bonif
  )
  SELECT
    c.id                             AS pedido_item_id,
    c.promocion_id,
    c.nombre::TEXT                   AS promo_nombre,
    c.producto_id,
    c.producto_nombre::TEXT,
    c.desc_regalo::TEXT              AS descripcion_regalo,
    c.cantidad                       AS cantidad_actual,
    c.cantidad_final,
    (c.cantidad - c.cantidad_final)  AS delta,
    (c.cantidad_final = 0)           AS sera_eliminada
  FROM calculo c
  ORDER BY c.id;
$fn$;

ALTER FUNCTION public.simular_salvedades_promo_impacto(bigint, jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.simular_salvedades_promo_impacto(bigint, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.simular_salvedades_promo_impacto(bigint, jsonb) TO authenticated;

COMMENT ON FUNCTION public.simular_salvedades_promo_impacto(bigint, jsonb) IS
  'Dry-run multi-item: devuelve una fila por línea de regalo del pedido con la cantidad en la que queda si se confirma el lote de salvedades. Mig 174.';
