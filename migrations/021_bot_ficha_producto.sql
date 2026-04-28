-- Migración 021 — Bot Telegram: ficha de producto
--
-- Función para que el bot pueda devolver el detalle de un producto con
-- métricas de ventas básicas (cantidad vendida en los últimos 30 días,
-- fecha de última venta). Diseñada para alimentar:
--   * el callback `v1:producto:<id>` del inline keyboard de /producto.
--   * un futuro slash command /producto-ficha si lo necesitamos.
--
-- Patrón de seguridad calcado de obtener_resumen_cuenta_cliente_bot
-- (migration 015): SECURITY DEFINER + REVOKE FROM PUBLIC + GRANT solo a
-- service_role. La edge function valida rol/sucursal antes de invocar.

CREATE OR REPLACE FUNCTION public.bot_ficha_producto(
  p_producto_id BIGINT,
  p_sucursal_id BIGINT
)
RETURNS JSON
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  resultado JSON;
BEGIN
  SELECT json_build_object(
    'producto', json_build_object(
      'id', p.id,
      'codigo', p.codigo,
      'nombre', p.nombre,
      'precio', p.precio,
      'precio_sin_iva', p.precio_sin_iva,
      'stock', p.stock,
      'stock_minimo', p.stock_minimo,
      'categoria', p.categoria,
      'proveedor_id', p.proveedor_id
    ),
    -- Cantidad total vendida en los últimos 30 días para esta sucursal.
    -- Filtramos por sucursal_id directo en pedido_items (la tabla la tiene)
    -- para evitar el join cuando no hace falta.
    'ventas_30d_cantidad', (
      SELECT COALESCE(SUM(pi.cantidad), 0)::INTEGER
      FROM pedido_items pi
      JOIN pedidos pe ON pe.id = pi.pedido_id
      WHERE pi.producto_id = p_producto_id
        AND pi.sucursal_id = p_sucursal_id
        AND pe.created_at > now() - interval '30 days'
    ),
    -- Fecha de la última venta de este producto en esta sucursal.
    -- NULL si nunca se vendió.
    'ultima_venta', (
      SELECT MAX(pe.created_at)
      FROM pedido_items pi
      JOIN pedidos pe ON pe.id = pi.pedido_id
      WHERE pi.producto_id = p_producto_id
        AND pi.sucursal_id = p_sucursal_id
    )
  ) INTO resultado
  FROM productos p
  WHERE p.id = p_producto_id
    AND p.sucursal_id = p_sucursal_id;

  -- Si el producto no existe o es de otra sucursal, devolvemos NULL.
  -- La tool TS lo interpreta como "Producto no encontrado o sin permiso".
  RETURN resultado;
END;
$$;

ALTER FUNCTION public.bot_ficha_producto(BIGINT, BIGINT) OWNER TO postgres;

REVOKE ALL    ON FUNCTION public.bot_ficha_producto(BIGINT, BIGINT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.bot_ficha_producto(BIGINT, BIGINT) TO service_role;
