-- ============================================================================
-- 115 · anular_compra_atomica v2: multi-tenant, atómica y con restauración
--       de costo desde la última compra restante
-- ============================================================================
-- La versión del baseline era pre-multitenant y el front ni la usaba: anulaba
-- CLIENT-SIDE (loop de updates de stock no atómico, clampeado en 0 que pierde
-- reversa, sin restaurar costo). Esta versión:
--   · admin/encargado, scoping por current_sucursal_id()
--   · rechaza si la reversa dejaría stock negativo (misma invariante que 104)
--   · si la compra anulada era la que fijó el costo del producto, lo restaura
--     desde la línea de compra restante más reciente (usando su tipo_factura y
--     los atributos fiscales actuales del producto); si no hay, deja el costo
--     y lo reporta en warnings
--   · tagea stock_historico vía GUCs (origen 'compra_anulada')
-- ============================================================================

DROP FUNCTION IF EXISTS public.anular_compra_atomica(bigint, uuid);

CREATE FUNCTION public.anular_compra_atomica(p_compra_id bigint, p_usuario_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal   BIGINT := current_sucursal_id();
  v_user_role  TEXT;
  v_compra     RECORD;
  v_row        RECORD;
  v_ult        RECORD;
  v_neto       NUMERIC;
  v_warnings   JSONB := '[]'::JSONB;
  v_negativos  JSONB;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden anular compras');
  END IF;

  SELECT id, estado, tipo_factura, fecha_compra
    INTO v_compra
    FROM compras
   WHERE id = p_compra_id AND sucursal_id = v_sucursal
   FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada');
  END IF;
  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La compra ya está cancelada');
  END IF;

  PERFORM set_config('app.stock_origen', 'compra_anulada', true);
  PERFORM set_config('app.stock_ref_tipo', 'compra', true);
  PERFORM set_config('app.stock_ref_id', p_compra_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

  -- Lock determinista de los productos afectados
  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (SELECT producto_id FROM compra_items
                 WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal)
   ORDER BY id
   FOR UPDATE;

  -- Chequeo de no-negatividad ANTES de tocar nada
  SELECT jsonb_agg(jsonb_build_object('producto_id', p.id, 'nombre', p.nombre,
                                      'stock', p.stock, 'reversa', q.qty))
    INTO v_negativos
    FROM (SELECT producto_id, SUM(cantidad)::INT AS qty
            FROM compra_items
           WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
           GROUP BY producto_id) q
    JOIN productos p ON p.id = q.producto_id AND p.sucursal_id = v_sucursal
   WHERE p.stock - q.qty < 0;

  IF v_negativos IS NOT NULL AND jsonb_array_length(v_negativos) > 0 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'La anulación dejaría stock negativo en: ' ||
      (SELECT string_agg((w->>'nombre') || ' (' || (w->>'stock') || ' − ' || (w->>'reversa') || ')', ', ')
         FROM jsonb_array_elements(v_negativos) w));
  END IF;

  -- Reversa de stock
  UPDATE productos p
     SET stock = p.stock - q.qty,
         updated_at = NOW()
    FROM (SELECT producto_id, SUM(cantidad)::INT AS qty
            FROM compra_items
           WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
           GROUP BY producto_id) q
   WHERE p.id = q.producto_id AND p.sucursal_id = v_sucursal;

  UPDATE compras
     SET estado = 'cancelada', updated_at = NOW()
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;

  -- Restauración de costo: solo para productos cuya ÚLTIMA compra válida era esta
  FOR v_row IN
    SELECT DISTINCT ci.producto_id
      FROM compra_items ci
     WHERE ci.compra_id = p_compra_id AND ci.sucursal_id = v_sucursal
  LOOP
    -- ¿Queda una compra más reciente o igual que ya gobierna el costo? Entonces nada.
    SELECT c.tipo_factura, ci.costo_unitario, ci.bonificacion,
           ci.impuestos_internos AS ii_linea, ci.porcentaje_iva AS iva_linea,
           ci.costo_neto_unitario, ci.costo_real_unitario
      INTO v_ult
      FROM compra_items ci
      JOIN compras c ON c.id = ci.compra_id
     WHERE ci.producto_id = v_row.producto_id
       AND ci.sucursal_id = v_sucursal
       AND c.estado <> 'cancelada'
       AND c.id <> p_compra_id
       AND COALESCE(ci.bonificacion, 0) < 100
       AND ci.costo_unitario > 0
     ORDER BY c.fecha_compra DESC, c.id DESC
     LIMIT 1;

    IF FOUND THEN
      v_neto := COALESCE(v_ult.costo_neto_unitario,
                         v_ult.costo_unitario * (1 - COALESCE(v_ult.bonificacion, 0) / 100));
      UPDATE productos p
         SET costo_sin_iva      = v_neto,
             costo_real         = COALESCE(v_ult.costo_real_unitario,
                                    costo_real_unitario(v_neto, COALESCE(v_ult.ii_linea, p.impuestos_internos), v_ult.tipo_factura)),
             costo_con_iva      = costo_financiero_unitario(
                                    v_neto,
                                    COALESCE(v_ult.iva_linea, p.porcentaje_iva),
                                    COALESCE(v_ult.ii_linea, p.impuestos_internos),
                                    v_ult.tipo_factura),
             ultimo_tipo_compra = v_ult.tipo_factura,
             updated_at         = NOW()
       WHERE p.id = v_row.producto_id AND p.sucursal_id = v_sucursal;
    ELSE
      v_warnings := v_warnings || jsonb_build_object(
        'producto_id', v_row.producto_id,
        'warning', 'costo_no_restaurado: sin otra compra válida de referencia');
    END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'compra_id', p_compra_id,
    'warnings', CASE WHEN jsonb_array_length(v_warnings) > 0 THEN v_warnings ELSE NULL END
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

GRANT EXECUTE ON FUNCTION public.anular_compra_atomica(bigint, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.anular_compra_atomica(bigint, uuid) FROM anon, public;
