-- ============================================================================
-- 114 · registrar_compra_completa y actualizar_compra_items con desglose
--       fiscal completo (percepciones, no gravado, II propio, snapshots)
-- ============================================================================
-- · Se consolida registrar_compra_completa en UNA sola función: se dropea el
--   overload de 13 args (el de 12 ya cayó en mig 111). Los 4 params nuevos
--   tienen DEFAULT ⇒ un cliente PWA viejo que llama con los 13 args con nombre
--   sigue resolviendo sin ambigüedad (PGRST203 imposible con función única).
-- · actualizar_compra_items: se dropea la firma de 6 args y se recrea con 5
--   params opcionales DEFAULT NULL (NULL = conservar el valor actual de la
--   cabecera, así un cliente viejo no pisa datos).
-- · Control blando de cuadre: si |total calculado − p_total| > 1 se devuelve
--   warning_descuadre en el JSONB (no bloquea: redondeos de factura reales).
-- · ZZ fuerza iva / II / percepciones / no_gravado = 0 en cabecera y no aplica
--   II por línea (lo pagado ya es todo).
-- ============================================================================

DROP FUNCTION IF EXISTS public.registrar_compra_completa(
  bigint, character varying, character varying, date,
  numeric, numeric, numeric, numeric,
  character varying, text, uuid, jsonb, character varying
);

CREATE FUNCTION public.registrar_compra_completa(
  p_proveedor_id bigint, p_proveedor_nombre character varying,
  p_numero_factura character varying, p_fecha_compra date,
  p_subtotal numeric, p_iva numeric, p_otros_impuestos numeric, p_total numeric,
  p_forma_pago character varying, p_notas text, p_usuario_id uuid,
  p_items jsonb, p_tipo_factura character varying DEFAULT 'FC',
  p_impuestos_internos numeric DEFAULT 0,
  p_percepcion_iva numeric DEFAULT 0,
  p_percepcion_iibb numeric DEFAULT 0,
  p_no_gravado numeric DEFAULT 0
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal            BIGINT := current_sucursal_id();
  v_compra_id           BIGINT;
  v_item                JSONB;
  v_producto            RECORD;
  v_stock_anterior      INTEGER;
  v_stock_nuevo         INTEGER;
  v_cantidad            INTEGER;
  v_bonificacion        NUMERIC;
  v_porcentaje_iva      NUMERIC;
  v_impuestos_internos  NUMERIC;
  v_costo_unitario      NUMERIC;
  v_costo_neto          NUMERIC;
  v_costo_con_iva       NUMERIC;
  v_costo_real          NUMERIC;
  v_actualiza_costo     BOOLEAN;
  v_tipo_factura        TEXT;
  v_es_zz               BOOLEAN;
  v_iva_hdr             NUMERIC;
  v_ii_hdr              NUMERIC;
  v_perc_iva_hdr        NUMERIC;
  v_perc_iibb_hdr       NUMERIC;
  v_no_gravado_hdr      NUMERIC;
  v_total_calc          NUMERIC;
  v_warning             TEXT := NULL;
  v_items_procesados    JSONB := '[]'::JSONB;
  v_user_role           TEXT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden registrar compras');
  END IF;

  v_tipo_factura   := COALESCE(p_tipo_factura, 'FC');
  v_es_zz          := (v_tipo_factura = 'ZZ');
  v_iva_hdr        := CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_iva, 0) END;
  v_ii_hdr         := CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_impuestos_internos, 0) END;
  v_perc_iva_hdr   := CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_percepcion_iva, 0) END;
  v_perc_iibb_hdr  := CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_percepcion_iibb, 0) END;
  v_no_gravado_hdr := CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_no_gravado, 0) END;

  INSERT INTO compras (
    proveedor_id, proveedor_nombre, numero_factura, fecha_compra,
    subtotal, iva, impuestos_internos, percepcion_iva, percepcion_iibb,
    no_gravado, otros_impuestos, total, forma_pago, notas,
    usuario_id, estado, tipo_factura, sucursal_id
  ) VALUES (
    p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra,
    p_subtotal, v_iva_hdr, v_ii_hdr, v_perc_iva_hdr, v_perc_iibb_hdr,
    v_no_gravado_hdr, COALESCE(p_otros_impuestos, 0), p_total, p_forma_pago, p_notas,
    p_usuario_id, 'recibida', v_tipo_factura, v_sucursal
  )
  RETURNING id INTO v_compra_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT id, stock INTO v_producto
      FROM productos
     WHERE id = (v_item->>'producto_id')::BIGINT
       AND sucursal_id = v_sucursal
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Producto no encontrado: %', v_item->>'producto_id';
    END IF;

    v_cantidad           := (v_item->>'cantidad')::INTEGER;
    v_stock_anterior     := COALESCE(v_producto.stock, 0);
    v_stock_nuevo        := v_stock_anterior + v_cantidad;
    v_costo_unitario     := COALESCE((v_item->>'costo_unitario')::NUMERIC, 0);
    v_bonificacion       := COALESCE((v_item->>'bonificacion')::NUMERIC, 0);
    v_porcentaje_iva     := CASE WHEN v_es_zz THEN 0 ELSE COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21) END;
    v_impuestos_internos := CASE WHEN v_es_zz THEN 0 ELSE COALESCE((v_item->>'impuestos_internos')::NUMERIC, 0) END;

    v_costo_neto    := v_costo_unitario * (1 - v_bonificacion / 100);
    v_costo_con_iva := costo_financiero_unitario(v_costo_neto, v_porcentaje_iva, v_impuestos_internos, v_tipo_factura);
    v_costo_real    := costo_real_unitario(v_costo_neto, v_impuestos_internos, v_tipo_factura);

    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      stock_anterior, stock_nuevo, bonificacion, sucursal_id,
      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario
    ) VALUES (
      v_compra_id,
      (v_item->>'producto_id')::BIGINT,
      v_cantidad,
      v_costo_unitario,
      COALESCE((v_item->>'subtotal')::NUMERIC, 0),
      v_stock_anterior,
      v_stock_nuevo,
      v_bonificacion,
      v_sucursal,
      v_porcentaje_iva,
      v_impuestos_internos,
      round(v_costo_neto, 4),
      v_costo_real
    );

    -- Regalos / promos (bonif 100% o costo 0) suman stock pero no fijan costo.
    v_actualiza_costo := (v_bonificacion < 100 AND v_costo_neto > 0);

    IF v_actualiza_costo THEN
      UPDATE productos
         SET stock              = stock + v_cantidad,
             costo_sin_iva      = v_costo_neto,
             costo_con_iva      = v_costo_con_iva,
             costo_real         = v_costo_real,
             ultimo_tipo_compra = v_tipo_factura,
             updated_at         = NOW()
       WHERE id = (v_item->>'producto_id')::BIGINT
         AND sucursal_id = v_sucursal;
    ELSE
      UPDATE productos
         SET stock      = stock + v_cantidad,
             updated_at = NOW()
       WHERE id = (v_item->>'producto_id')::BIGINT
         AND sucursal_id = v_sucursal;
    END IF;

    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id',       (v_item->>'producto_id')::BIGINT,
      'cantidad',          v_cantidad,
      'stock_anterior',    v_stock_anterior,
      'stock_nuevo',       v_stock_nuevo,
      'costo_sin_iva',     v_costo_neto,
      'costo_con_iva',     v_costo_con_iva,
      'costo_real',        v_costo_real,
      'costo_actualizado', v_actualiza_costo
    );
  END LOOP;

  -- Control blando de cuadre contra el total informado
  v_total_calc := CASE
    WHEN v_es_zz THEN COALESCE(p_subtotal, 0)
    ELSE COALESCE(p_subtotal, 0) + v_iva_hdr + v_ii_hdr + v_perc_iva_hdr
         + v_perc_iibb_hdr + v_no_gravado_hdr + COALESCE(p_otros_impuestos, 0)
  END;
  IF abs(v_total_calc - COALESCE(p_total, 0)) > 1 THEN
    v_warning := format('Descuadre: total calculado %s vs total informado %s',
                        round(v_total_calc, 2), round(COALESCE(p_total, 0), 2));
  END IF;

  RETURN jsonb_build_object(
    'success',           true,
    'compra_id',         v_compra_id,
    'items_procesados',  v_items_procesados,
    'warning_descuadre', v_warning
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.registrar_compra_completa(
  bigint, character varying, character varying, date, numeric, numeric, numeric,
  numeric, character varying, text, uuid, jsonb, character varying,
  numeric, numeric, numeric, numeric
) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.registrar_compra_completa(
  bigint, character varying, character varying, date, numeric, numeric, numeric,
  numeric, character varying, text, uuid, jsonb, character varying,
  numeric, numeric, numeric, numeric
) FROM anon, public;

-- ────────────────────────────────────────────────────────────────────────────
-- actualizar_compra_items con cabecera fiscal opcional (NULL = conservar)
-- ────────────────────────────────────────────────────────────────────────────

DROP FUNCTION IF EXISTS public.actualizar_compra_items(bigint, jsonb, numeric, numeric, numeric, uuid);

CREATE FUNCTION public.actualizar_compra_items(
  p_compra_id bigint, p_items_nuevos jsonb,
  p_subtotal numeric, p_iva numeric, p_total numeric, p_usuario_id uuid,
  p_impuestos_internos numeric DEFAULT NULL,
  p_percepcion_iva numeric DEFAULT NULL,
  p_percepcion_iibb numeric DEFAULT NULL,
  p_no_gravado numeric DEFAULT NULL,
  p_otros_impuestos numeric DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_user_role TEXT;
  v_compra RECORD;
  v_dias NUMERIC;
  v_item JSONB;
  v_producto_id BIGINT;
  v_cantidad INTEGER;
  v_costo_unitario NUMERIC;
  v_bonificacion NUMERIC;
  v_porcentaje_iva NUMERIC;
  v_impuestos_internos NUMERIC;
  v_subtotal_item NUMERIC;
  v_costo_neto NUMERIC;
  v_costo_con_iva NUMERIC;
  v_costo_real NUMERIC;
  v_actualiza_costo BOOLEAN;
  v_es_zz BOOLEAN;
  v_stock_anterior INTEGER;
  v_stock_nuevo INTEGER;
  v_max_fecha DATE;
  v_es_mas_reciente BOOLEAN;
  v_iva_efectivo NUMERIC;
  v_items_procesados JSONB := '[]'::JSONB;
  v_costo_actualizado JSONB := '[]'::JSONB;
  v_snapshot_stock JSONB := '{}'::JSONB;
  v_warnings_stock_negativo JSONB;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede editar compras');
  END IF;

  SELECT id, estado, tipo_factura, created_at, fecha_compra
    INTO v_compra
    FROM compras
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada');
  END IF;

  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede editar una compra cancelada');
  END IF;

  v_dias := EXTRACT(EPOCH FROM (now() - v_compra.created_at)) / 86400;
  IF v_dias > 7 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'No se puede editar una compra creada hace mas de 7 dias');
  END IF;

  v_es_zz := (v_compra.tipo_factura = 'ZZ');
  v_iva_efectivo := CASE WHEN v_es_zz THEN 0 ELSE p_iva END;

  PERFORM set_config('app.stock_origen', 'compra_editada', true);
  PERFORM set_config('app.stock_ref_tipo', 'compra', true);
  PERFORM set_config('app.stock_ref_id', p_compra_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (
       SELECT producto_id FROM compra_items
        WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       UNION
       SELECT (item->>'producto_id')::BIGINT
         FROM jsonb_array_elements(p_items_nuevos) AS item
     )
   ORDER BY id
   FOR UPDATE;

  SELECT jsonb_object_agg(id::text, stock) INTO v_snapshot_stock
    FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (
       SELECT producto_id FROM compra_items
        WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       UNION
       SELECT (item->>'producto_id')::BIGINT
         FROM jsonb_array_elements(p_items_nuevos) AS item
     );

  WITH viejos AS (
    SELECT producto_id, SUM(cantidad)::INT AS qty_old
      FROM compra_items
     WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     GROUP BY producto_id
  ),
  nuevos AS (
    SELECT (item->>'producto_id')::BIGINT AS producto_id,
           SUM((item->>'cantidad')::INT)::INT AS qty_new
      FROM jsonb_array_elements(p_items_nuevos) AS item
     GROUP BY (item->>'producto_id')::BIGINT
  ),
  deltas AS (
    SELECT COALESCE(v.producto_id, n.producto_id) AS producto_id,
           COALESCE(n.qty_new, 0) - COALESCE(v.qty_old, 0) AS delta
      FROM viejos v FULL OUTER JOIN nuevos n USING (producto_id)
  )
  UPDATE productos p
     SET stock = p.stock + d.delta,
         updated_at = NOW()
    FROM deltas d
   WHERE p.id = d.producto_id
     AND p.sucursal_id = v_sucursal
     AND d.delta <> 0;

  SELECT jsonb_agg(jsonb_build_object('producto_id', id, 'nombre', nombre, 'stock', stock))
    INTO v_warnings_stock_negativo
    FROM productos
   WHERE sucursal_id = v_sucursal
     AND stock < 0
     AND id IN (
       SELECT producto_id FROM compra_items
        WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       UNION
       SELECT (item->>'producto_id')::BIGINT
         FROM jsonb_array_elements(p_items_nuevos) AS item
     );

  IF v_warnings_stock_negativo IS NOT NULL AND jsonb_array_length(v_warnings_stock_negativo) > 0 THEN
    RAISE EXCEPTION 'La edición dejaría stock negativo en: %. Ajustá las cantidades o reconciliá el stock primero.',
      (SELECT string_agg((w->>'nombre') || ' (' || (w->>'stock') || ')', ', ')
         FROM jsonb_array_elements(v_warnings_stock_negativo) w);
  END IF;

  DELETE FROM compra_items WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id        := (v_item->>'producto_id')::BIGINT;
    v_cantidad           := (v_item->>'cantidad')::INTEGER;
    v_costo_unitario     := COALESCE((v_item->>'costo_unitario')::NUMERIC, 0);
    v_bonificacion       := COALESCE((v_item->>'bonificacion')::NUMERIC, 0);
    v_porcentaje_iva     := CASE WHEN v_es_zz THEN 0 ELSE COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21) END;
    v_impuestos_internos := CASE WHEN v_es_zz THEN 0 ELSE COALESCE((v_item->>'impuestos_internos')::NUMERIC, 0) END;
    v_subtotal_item      := COALESCE((v_item->>'subtotal')::NUMERIC, 0);

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      RAISE EXCEPTION 'Cantidad invalida para producto %', v_producto_id;
    END IF;

    v_stock_anterior := COALESCE((v_snapshot_stock->>v_producto_id::TEXT)::INTEGER, 0);
    v_stock_nuevo := v_stock_anterior + v_cantidad;

    v_costo_neto    := v_costo_unitario * (1 - v_bonificacion / 100);
    v_costo_con_iva := costo_financiero_unitario(v_costo_neto, v_porcentaje_iva, v_impuestos_internos, v_compra.tipo_factura);
    v_costo_real    := costo_real_unitario(v_costo_neto, v_impuestos_internos, v_compra.tipo_factura);
    v_actualiza_costo := (v_bonificacion < 100 AND v_costo_neto > 0);

    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      stock_anterior, stock_nuevo, bonificacion, sucursal_id,
      porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario
    ) VALUES (
      p_compra_id, v_producto_id, v_cantidad, v_costo_unitario,
      v_subtotal_item, v_stock_anterior, v_stock_nuevo, v_bonificacion, v_sucursal,
      v_porcentaje_iva, v_impuestos_internos, round(v_costo_neto, 4), v_costo_real
    );

    SELECT MAX(c.fecha_compra) INTO v_max_fecha
      FROM compras c
      JOIN compra_items ci ON ci.compra_id = c.id AND ci.sucursal_id = c.sucursal_id
     WHERE ci.producto_id = v_producto_id
       AND ci.sucursal_id = v_sucursal
       AND c.estado <> 'cancelada'
       AND c.id <> p_compra_id;

    v_es_mas_reciente := (v_max_fecha IS NULL) OR (v_compra.fecha_compra >= v_max_fecha);

    IF v_es_mas_reciente AND v_actualiza_costo THEN
      UPDATE productos
         SET costo_sin_iva      = v_costo_neto,
             costo_con_iva      = v_costo_con_iva,
             costo_real         = v_costo_real,
             ultimo_tipo_compra = v_compra.tipo_factura,
             updated_at         = NOW()
       WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      v_costo_actualizado := v_costo_actualizado || jsonb_build_object(
        'producto_id', v_producto_id,
        'costo_sin_iva', v_costo_neto,
        'costo_con_iva', v_costo_con_iva,
        'costo_real', v_costo_real
      );
    END IF;

    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id', v_producto_id,
      'cantidad', v_cantidad,
      'stock_anterior', v_stock_anterior,
      'stock_nuevo', v_stock_nuevo,
      'costo_actualizado', (v_es_mas_reciente AND v_actualiza_costo)
    );
  END LOOP;

  UPDATE compras
     SET subtotal = p_subtotal,
         iva = v_iva_efectivo,
         impuestos_internos = CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_impuestos_internos, impuestos_internos) END,
         percepcion_iva     = CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_percepcion_iva, percepcion_iva) END,
         percepcion_iibb    = CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_percepcion_iibb, percepcion_iibb) END,
         no_gravado         = CASE WHEN v_es_zz THEN 0 ELSE COALESCE(p_no_gravado, no_gravado) END,
         otros_impuestos    = COALESCE(p_otros_impuestos, otros_impuestos),
         total = p_total,
         updated_at = NOW()
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'success', true,
    'compra_id', p_compra_id,
    'items_procesados', v_items_procesados,
    'costo_actualizado', v_costo_actualizado,
    'warnings', NULL
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.actualizar_compra_items(
  bigint, jsonb, numeric, numeric, numeric, uuid, numeric, numeric, numeric, numeric, numeric
) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.actualizar_compra_items(
  bigint, jsonb, numeric, numeric, numeric, uuid, numeric, numeric, numeric, numeric, numeric
) FROM anon, public;
