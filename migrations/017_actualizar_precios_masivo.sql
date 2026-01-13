-- Migración 017: RPC para actualización masiva de precios desde Excel
-- Permite actualizar múltiples productos en una sola transacción

CREATE OR REPLACE FUNCTION actualizar_precios_masivo(
  p_productos JSONB -- [{producto_id, precio_neto, imp_internos, precio_final}]
)
RETURNS JSONB AS $$
DECLARE
  v_item JSONB;
  v_actualizados INT := 0;
  v_errores TEXT[] := '{}';
  v_producto_id INT;
BEGIN
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_productos)
  LOOP
    BEGIN
      v_producto_id := (v_item->>'producto_id')::INT;

      UPDATE productos
      SET
        precio_sin_iva = COALESCE((v_item->>'precio_neto')::DECIMAL, precio_sin_iva),
        impuestos_internos = COALESCE((v_item->>'imp_internos')::DECIMAL, impuestos_internos),
        precio = COALESCE((v_item->>'precio_final')::DECIMAL, precio),
        updated_at = NOW()
      WHERE id = v_producto_id;

      IF FOUND THEN
        v_actualizados := v_actualizados + 1;
      ELSE
        v_errores := array_append(v_errores,
          'Producto ID ' || v_producto_id || ' no encontrado');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errores := array_append(v_errores,
        'Error en producto ID ' || COALESCE(v_producto_id::TEXT, 'desconocido') || ': ' || SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', array_length(v_errores, 1) IS NULL,
    'actualizados', v_actualizados,
    'errores', COALESCE(to_jsonb(v_errores), '[]'::jsonb)
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Comentario de documentación
COMMENT ON FUNCTION actualizar_precios_masivo(JSONB) IS
'Actualiza precios de múltiples productos. Recibe array de {producto_id, precio_neto, imp_internos, precio_final}';
