-- Migración 091 — Cambio/devolución: nuevo motivo 'mal_estado'
--
-- Pedido de la usuaria: agregar "Producto en mal estado" como motivo usual (sin
-- reemplazar "Otro"). Ej: papas no vencidas pero húmedas/feas de sabor, o
-- alfajores con hongos sin estar vencidos. Como vencimiento/rotura, el producto
-- devuelto en mal estado NO reingresa al stock (se da de baja como merma).
--
-- mermas_stock.motivo NO acepta 'mal_estado' (su CHECK es fijo), así que la merma
-- del cambio mapea: mal_estado → 'decomiso' (producto dado de baja por no apto);
-- la observación guarda el motivo real. Las tablas del cambio sí guardan
-- 'mal_estado' como motivo.
--
-- NO aplicada en prod todavía (pendiente de apply_migration vía MCP).

-- 1. Agregar 'mal_estado' a los CHECK de motivo de las tablas de cambio
ALTER TABLE public.cambios_productos DROP CONSTRAINT IF EXISTS cambios_productos_motivo_check;
ALTER TABLE public.cambios_productos
  ADD CONSTRAINT cambios_productos_motivo_check
  CHECK (motivo IN ('vencimiento','rotura','mal_estado','erroneo','otro'));

ALTER TABLE public.recorrido_cambios DROP CONSTRAINT IF EXISTS recorrido_cambios_motivo_check;
ALTER TABLE public.recorrido_cambios
  ADD CONSTRAINT recorrido_cambios_motivo_check
  CHECK (motivo IN ('vencimiento','rotura','mal_estado','erroneo','otro'));

-- 2. _aplicar_cambio_producto: mal_estado tampoco reingresa el devuelto; la merma
--    mapea el motivo a uno válido de mermas_stock. Misma firma (9 args).
CREATE OR REPLACE FUNCTION public._aplicar_cambio_producto(
  p_cliente_id INTEGER,
  p_producto_devuelto_id BIGINT,
  p_cantidad_devuelta INTEGER,
  p_producto_entregado_id BIGINT,
  p_cantidad_entregada INTEGER,
  p_observaciones TEXT,
  p_sucursal_id BIGINT,
  p_usuario_id UUID,
  p_motivo TEXT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_precio_devuelto NUMERIC(12,2);
  v_precio_entregado NUMERIC(12,2);
  v_stock_entregado INT;
  v_stock_dev_now INT;
  v_diferencia NUMERIC(12,2);
  v_cambio_id BIGINT;
  v_first BIGINT;
  v_second BIGINT;
  v_merma_motivo TEXT;
  -- vencimiento/rotura/mal_estado → el devuelto se da de baja (no reingresa).
  v_reingresa BOOLEAN := (COALESCE(p_motivo,'erroneo') NOT IN ('vencimiento','rotura','mal_estado'));
BEGIN
  IF p_cantidad_devuelta <= 0 OR p_cantidad_entregada <= 0 THEN
    RAISE EXCEPTION 'Las cantidades deben ser mayores a 0';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = p_sucursal_id
  ) THEN
    RAISE EXCEPTION 'Cliente no encontrado en la sucursal';
  END IF;

  IF p_producto_devuelto_id <= p_producto_entregado_id THEN
    v_first := p_producto_devuelto_id;
    v_second := p_producto_entregado_id;
  ELSE
    v_first := p_producto_entregado_id;
    v_second := p_producto_devuelto_id;
  END IF;

  PERFORM 1 FROM productos
   WHERE id = v_first AND sucursal_id = p_sucursal_id FOR UPDATE;
  PERFORM 1 FROM productos
   WHERE id = v_second AND sucursal_id = p_sucursal_id FOR UPDATE;

  SELECT precio, stock INTO v_precio_entregado, v_stock_entregado
    FROM productos
   WHERE id = p_producto_entregado_id AND sucursal_id = p_sucursal_id;
  IF v_precio_entregado IS NULL THEN
    RAISE EXCEPTION 'Producto a entregar no encontrado';
  END IF;
  IF v_stock_entregado < p_cantidad_entregada THEN
    RAISE EXCEPTION 'Stock insuficiente del producto a entregar (% disponibles)', v_stock_entregado;
  END IF;

  SELECT precio INTO v_precio_devuelto
    FROM productos
   WHERE id = p_producto_devuelto_id AND sucursal_id = p_sucursal_id;
  IF v_precio_devuelto IS NULL THEN
    RAISE EXCEPTION 'Producto a devolver no encontrado';
  END IF;

  IF v_reingresa THEN
    UPDATE productos SET stock = stock + p_cantidad_devuelta
     WHERE id = p_producto_devuelto_id;
  END IF;
  UPDATE productos SET stock = stock - p_cantidad_entregada
   WHERE id = p_producto_entregado_id;

  IF NOT v_reingresa THEN
    SELECT stock INTO v_stock_dev_now
      FROM productos WHERE id = p_producto_devuelto_id AND sucursal_id = p_sucursal_id;
    -- mermas_stock.motivo tiene un CHECK fijo: mapear el motivo del cambio a uno válido.
    v_merma_motivo := CASE COALESCE(p_motivo,'')
      WHEN 'vencimiento' THEN 'vencimiento'
      WHEN 'rotura' THEN 'rotura'
      ELSE 'decomiso'  -- mal_estado (u otros no-reingreso) → baja por no apto
    END;
    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      p_producto_devuelto_id, p_cantidad_devuelta, v_merma_motivo,
      'Cambio: producto devuelto no reingresado al stock (' || COALESCE(p_motivo,'') || ')',
      v_stock_dev_now, v_stock_dev_now, p_usuario_id, p_sucursal_id
    );
  END IF;

  v_diferencia := (v_precio_entregado * p_cantidad_entregada)
                - (v_precio_devuelto * p_cantidad_devuelta);

  UPDATE clientes
     SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + v_diferencia
   WHERE id = p_cliente_id;

  INSERT INTO cambios_productos (
    cliente_id, producto_devuelto_id, cantidad_devuelta, precio_devuelto,
    producto_entregado_id, cantidad_entregada, precio_entregado,
    diferencia_monto, observaciones, usuario_id, sucursal_id, motivo
  ) VALUES (
    p_cliente_id, p_producto_devuelto_id, p_cantidad_devuelta, v_precio_devuelto,
    p_producto_entregado_id, p_cantidad_entregada, v_precio_entregado,
    v_diferencia, p_observaciones, p_usuario_id, p_sucursal_id, COALESCE(p_motivo,'erroneo')
  ) RETURNING id INTO v_cambio_id;

  RETURN v_cambio_id;
END;
$$;

ALTER FUNCTION public._aplicar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT, BIGINT, UUID, TEXT
) OWNER TO postgres;
REVOKE ALL ON FUNCTION public._aplicar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT, BIGINT, UUID, TEXT
) FROM PUBLIC;
