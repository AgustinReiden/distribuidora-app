-- ============================================================================
-- 125 · cambiar_proveedor_compra: corrige el proveedor de una compra cargada
--       al proveedor equivocado, sin reescribir la fila.
-- ============================================================================
-- Analogo a cambiar_cliente_pedido (mig 094) pero para compras: en vez de un
-- UPDATE proveedor_id, ANULA la compra vieja y CLONA una nueva identica (mismos
-- items, importes, fecha, factura, tipo, forma de pago) cambiando solo el
-- proveedor en la cabecera. Conserva trazabilidad/auditoria (queda la vieja
-- cancelada + la nueva como rastro de la correccion) en lugar de pisar
-- silenciosamente el proveedor de una factura ya registrada.
--
-- POR QUE NO anular_compra_atomica + registrar_compra_completa:
--   anular RESTA stock y RECHAZA si quedaria negativo (apenas vendiste parte de
--   lo comprado, ya falla), y registrar lo volveria a SUMAR -> dos movimientos
--   de stock_historico y riesgo de fallar en el caso comun. Aca la mercaderia
--   llego fisicamente y sigue en deposito: solo reasignamos la contraparte de la
--   factura. Por eso el clon NO toca stock ni costos (productos.stock, costo_real,
--   etc.): el neto de stock es cero por construccion, sin guardas ni churn. Los
--   reportes ya excluyen las compras 'cancelada', asi que la vieja sale de los
--   totales y la nueva entra con valores identicos.
--
-- Solo admin. La cabecera nueva copia todo menos el proveedor (y no arrastra
-- tp_import_id). La auditoria la cubre el trigger audit_compras (INSERT de la
-- nueva + UPDATE de la vieja). Atomico: cualquier error revierte toda la
-- transaccion via EXCEPTION WHEN OTHERS.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.cambiar_proveedor_compra(
  p_compra_id bigint,
  p_usuario_id uuid,
  p_nuevo_proveedor_id bigint DEFAULT NULL,
  p_nuevo_proveedor_nombre character varying DEFAULT NULL,
  p_motivo text DEFAULT 'Cambio de proveedor'
) RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal   BIGINT := current_sucursal_id();
  v_acting     UUID := auth.uid();
  v_role       TEXT;
  v_compra     RECORD;
  v_nc_count   INTEGER;
  v_nueva_id   BIGINT;
BEGIN
  -- ---- Validaciones ----
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No hay sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM v_acting THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_role FROM perfiles WHERE id = v_acting;
  IF v_role IS NULL OR v_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede cambiar el proveedor de una compra');
  END IF;

  IF p_nuevo_proveedor_id IS NULL AND COALESCE(TRIM(p_nuevo_proveedor_nombre), '') = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Debe indicar el proveedor nuevo');
  END IF;

  -- Lock de la compra vieja
  SELECT * INTO v_compra FROM compras WHERE id = p_compra_id AND sucursal_id = v_sucursal FOR UPDATE;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada');
  END IF;

  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La compra ya esta cancelada');
  END IF;

  -- Debe ser realmente otro proveedor
  IF p_nuevo_proveedor_id IS NOT NULL AND p_nuevo_proveedor_id IS NOT DISTINCT FROM v_compra.proveedor_id THEN
    RETURN jsonb_build_object('success', false, 'error', 'El proveedor nuevo es el mismo que el actual');
  END IF;
  IF p_nuevo_proveedor_id IS NULL AND v_compra.proveedor_id IS NULL
     AND lower(COALESCE(TRIM(p_nuevo_proveedor_nombre), '')) = lower(COALESCE(TRIM(v_compra.proveedor_nombre), '')) THEN
    RETURN jsonb_build_object('success', false, 'error', 'El proveedor nuevo es el mismo que el actual');
  END IF;

  -- El proveedor nuevo (si es por id) debe existir en la sucursal
  IF p_nuevo_proveedor_id IS NOT NULL THEN
    PERFORM 1 FROM proveedores WHERE id = p_nuevo_proveedor_id AND sucursal_id = v_sucursal;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'El proveedor nuevo no existe en esta sucursal');
    END IF;
  END IF;

  -- Bloquear si la compra tiene notas de credito: referencian la compra vieja y
  -- ya revirtieron stock; el clon las dejaria huerfanas / doble-contadas.
  SELECT count(*) INTO v_nc_count FROM notas_credito
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;
  IF v_nc_count > 0 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'La compra tiene notas de credito asociadas; gestionalas antes de cambiar el proveedor');
  END IF;

  -- ---- 1) Clonar la cabecera con el proveedor nuevo (todo lo demas identico) ----
  INSERT INTO compras (
    proveedor_id, proveedor_nombre, numero_factura, fecha_compra, fecha_recepcion,
    subtotal, iva, impuestos_internos, percepcion_iva, percepcion_iibb, no_gravado,
    otros_impuestos, total, forma_pago, notas, usuario_id, estado, tipo_factura, sucursal_id
  )
  SELECT
    p_nuevo_proveedor_id,
    CASE WHEN p_nuevo_proveedor_id IS NULL THEN p_nuevo_proveedor_nombre ELSE NULL END,
    c.numero_factura, c.fecha_compra, c.fecha_recepcion,
    c.subtotal, c.iva, c.impuestos_internos, c.percepcion_iva, c.percepcion_iibb, c.no_gravado,
    c.otros_impuestos, c.total, c.forma_pago,
    COALESCE(c.notas, '') || ' (cambio de proveedor desde compra #' || p_compra_id || ')',
    c.usuario_id, 'recibida', c.tipo_factura, c.sucursal_id
  FROM compras c
  WHERE c.id = p_compra_id AND c.sucursal_id = v_sucursal
  RETURNING id INTO v_nueva_id;

  -- ---- 2) Clonar los items verbatim (incluye snapshots fiscales), SIN mover stock ----
  INSERT INTO compra_items (
    compra_id, producto_id, cantidad, costo_unitario, subtotal,
    stock_anterior, stock_nuevo, bonificacion, sucursal_id,
    porcentaje_iva, impuestos_internos, costo_neto_unitario, costo_real_unitario
  )
  SELECT
    v_nueva_id, ci.producto_id, ci.cantidad, ci.costo_unitario, ci.subtotal,
    ci.stock_anterior, ci.stock_nuevo, ci.bonificacion, ci.sucursal_id,
    ci.porcentaje_iva, ci.impuestos_internos, ci.costo_neto_unitario, ci.costo_real_unitario
  FROM compra_items ci
  WHERE ci.compra_id = p_compra_id AND ci.sucursal_id = v_sucursal;

  -- ---- 3) Anular la compra vieja (NO revierte stock: la mercaderia queda) ----
  UPDATE compras
     SET estado = 'cancelada',
         notas  = COALESCE(notas, '') || ' -> reemplazada por compra #' || v_nueva_id || ' (' || p_motivo || ')',
         updated_at = NOW()
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'success', true,
    'nueva_compra_id', v_nueva_id,
    'compra_anulada_id', p_compra_id
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.cambiar_proveedor_compra(bigint, uuid, bigint, character varying, text) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.cambiar_proveedor_compra(bigint, uuid, bigint, character varying, text) FROM anon, public;
