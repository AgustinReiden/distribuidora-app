-- ============================================================================
-- 126 · Proveedor obligatorio al registrar una compra
-- ============================================================================
-- Hasta ahora se podía cargar una compra sin proveedor (proveedor_id NULL y
-- proveedor_nombre NULL) → filas "Sin proveedor". No debería poder hacerse.
-- Se agrega una guarda a registrar_compra_completa que rechaza si no viene ni
-- id ni nombre de proveedor. El resto de la función es idéntico a la mig 114
-- (misma firma de 17 args). El front (ModalCompra) también valida antes de
-- enviar. Las compras viejas sin proveedor quedan como están (esto solo afecta
-- altas nuevas).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.registrar_compra_completa(
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
AS $function$
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

  -- Proveedor obligatorio: id existente o nombre denormalizado.
  IF p_proveedor_id IS NULL AND COALESCE(TRIM(p_proveedor_nombre), '') = '' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Debe indicar un proveedor para la compra');
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
$function$;

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
