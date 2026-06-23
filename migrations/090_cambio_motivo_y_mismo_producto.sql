-- Migración 090 — Cambio/devolución: motivo (stock tipo salvedad) + mismo producto
--
-- Dos cambios sobre el feature de cambio (mig 024 + 089):
-- 1) MISMO PRODUCTO: se permite que el producto devuelto == el entregado (caso
--    vencimiento: el cliente devuelve el vencido y recibe el mismo producto
--    fresco). Se dropean los CHECK de "distintos" y los IF que lo rechazaban.
-- 2) MOTIVO + STOCK condicional (análogo a entrega con salvedad): el cambio
--    lleva un `motivo`. Si es 'vencimiento' o 'rotura', el producto devuelto NO
--    reingresa al stock (se da de baja y se registra en mermas_stock); el
--    entregado SIEMPRE sale del stock. Si es 'erroneo'/'otro' (buen estado), el
--    devuelto reingresa (canje, comportamiento histórico).
--
-- Las tablas cambios_productos y recorrido_cambios están vacías en prod, así que
-- agregar `motivo NOT NULL DEFAULT 'erroneo'` es seguro.
--
-- NO aplicada en prod todavía (pendiente de apply_migration vía MCP).

-- ============================================================================
-- 1. Permitir mismo producto: dropear CHECK de distintos
-- ============================================================================
ALTER TABLE public.cambios_productos DROP CONSTRAINT IF EXISTS cambios_productos_distintos;
ALTER TABLE public.recorrido_cambios DROP CONSTRAINT IF EXISTS recorrido_cambios_distintos;

-- ============================================================================
-- 2. Columna motivo en ambas tablas (+ CHECK de valores válidos)
-- ============================================================================
ALTER TABLE public.cambios_productos
  ADD COLUMN IF NOT EXISTS motivo TEXT NOT NULL DEFAULT 'erroneo';
ALTER TABLE public.recorrido_cambios
  ADD COLUMN IF NOT EXISTS motivo TEXT NOT NULL DEFAULT 'erroneo';

ALTER TABLE public.cambios_productos DROP CONSTRAINT IF EXISTS cambios_productos_motivo_check;
ALTER TABLE public.cambios_productos
  ADD CONSTRAINT cambios_productos_motivo_check
  CHECK (motivo IN ('vencimiento','rotura','erroneo','otro'));
ALTER TABLE public.recorrido_cambios DROP CONSTRAINT IF EXISTS recorrido_cambios_motivo_check;
ALTER TABLE public.recorrido_cambios
  ADD CONSTRAINT recorrido_cambios_motivo_check
  CHECK (motivo IN ('vencimiento','rotura','erroneo','otro'));

-- ============================================================================
-- 3. _aplicar_cambio_producto: nueva firma con p_motivo (deriva reingreso del
--    devuelto + merma condicional). Se DROPea la firma vieja (8 args).
-- ============================================================================
DROP FUNCTION IF EXISTS public._aplicar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT, BIGINT, UUID
);

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
  -- Reingresa el devuelto salvo que sea baja por vencimiento/rotura.
  v_reingresa BOOLEAN := (COALESCE(p_motivo,'erroneo') NOT IN ('vencimiento','rotura'));
BEGIN
  IF p_cantidad_devuelta <= 0 OR p_cantidad_entregada <= 0 THEN
    RAISE EXCEPTION 'Las cantidades deben ser mayores a 0';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = p_sucursal_id
  ) THEN
    RAISE EXCEPTION 'Cliente no encontrado en la sucursal';
  END IF;

  -- Lock en orden estable para evitar deadlocks (tolera ids iguales: re-lock).
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

  -- El devuelto reingresa solo si está en buen estado (no vencimiento/rotura).
  IF v_reingresa THEN
    UPDATE productos SET stock = stock + p_cantidad_devuelta
     WHERE id = p_producto_devuelto_id;
  END IF;
  -- El entregado SIEMPRE sale del stock.
  UPDATE productos SET stock = stock - p_cantidad_entregada
   WHERE id = p_producto_entregado_id;

  -- Baja por vencimiento/rotura: registrar la merma del devuelto (auditoría;
  -- sin decremento extra — el outflow ya lo refleja el entregado).
  IF NOT v_reingresa THEN
    SELECT stock INTO v_stock_dev_now
      FROM productos WHERE id = p_producto_devuelto_id AND sucursal_id = p_sucursal_id;
    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      p_producto_devuelto_id, p_cantidad_devuelta, p_motivo,
      'Cambio: producto devuelto no reingresado al stock (' || p_motivo || ')',
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

-- ============================================================================
-- 4. registrar_cambio_producto (standalone): suma p_motivo, sin check distintos.
--    Se DROPea la firma vieja (6 args) y se crea la nueva (7 args, motivo default).
-- ============================================================================
DROP FUNCTION IF EXISTS public.registrar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT
);

CREATE OR REPLACE FUNCTION public.registrar_cambio_producto(
  p_cliente_id INTEGER,
  p_producto_devuelto_id BIGINT,
  p_cantidad_devuelta INTEGER,
  p_producto_entregado_id BIGINT,
  p_cantidad_entregada INTEGER,
  p_observaciones TEXT DEFAULT NULL,
  p_motivo TEXT DEFAULT 'erroneo'
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := public.current_sucursal_id();
  v_user UUID := auth.uid();
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sin sucursal activa';
  END IF;
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN public._aplicar_cambio_producto(
    p_cliente_id, p_producto_devuelto_id, p_cantidad_devuelta,
    p_producto_entregado_id, p_cantidad_entregada, p_observaciones,
    v_sucursal, v_user, COALESCE(p_motivo,'erroneo')
  );
END;
$$;

ALTER FUNCTION public.registrar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT, TEXT
) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.registrar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT, TEXT
) TO authenticated;

-- ============================================================================
-- 5. crear_pedido_cambio_en_ruta: suma p_motivo, lo guarda en recorrido_cambios,
--    sin check distintos. Se DROPea la firma vieja (6 args).
-- ============================================================================
DROP FUNCTION IF EXISTS public.crear_pedido_cambio_en_ruta(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT
);

CREATE OR REPLACE FUNCTION public.crear_pedido_cambio_en_ruta(
  p_cliente_id INTEGER,
  p_producto_devuelto_id BIGINT,
  p_cantidad_devuelta INTEGER,
  p_producto_entregado_id BIGINT,
  p_cantidad_entregada INTEGER,
  p_observaciones TEXT DEFAULT NULL,
  p_motivo TEXT DEFAULT 'erroneo'
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := public.current_sucursal_id();
  v_user UUID := auth.uid();
  v_nombre_devuelto TEXT;
  v_nombre_entregado TEXT;
  v_pedido_id BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sin sucursal activa';
  END IF;
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  IF p_cantidad_devuelta <= 0 OR p_cantidad_entregada <= 0 THEN
    RAISE EXCEPTION 'Las cantidades deben ser mayores a 0';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = v_sucursal
  ) THEN
    RAISE EXCEPTION 'Cliente no encontrado en la sucursal';
  END IF;

  SELECT nombre INTO v_nombre_devuelto FROM productos
   WHERE id = p_producto_devuelto_id AND sucursal_id = v_sucursal;
  IF v_nombre_devuelto IS NULL THEN
    RAISE EXCEPTION 'Producto a devolver no encontrado';
  END IF;
  SELECT nombre INTO v_nombre_entregado FROM productos
   WHERE id = p_producto_entregado_id AND sucursal_id = v_sucursal;
  IF v_nombre_entregado IS NULL THEN
    RAISE EXCEPTION 'Producto a entregar no encontrado';
  END IF;

  INSERT INTO pedidos (
    cliente_id, fecha, estado, total, monto_pagado, estado_pago,
    canal, usuario_id, sucursal_id
  ) VALUES (
    p_cliente_id, CURRENT_DATE, 'pendiente', 0, 0, 'pagado',
    'cambio', v_user, v_sucursal
  ) RETURNING id INTO v_pedido_id;

  INSERT INTO recorrido_cambios (
    pedido_id, cliente_id,
    producto_devuelto_id, producto_devuelto_nombre, cantidad_devuelta,
    producto_entregado_id, producto_entregado_nombre, cantidad_entregada,
    observaciones, sucursal_id, motivo
  ) VALUES (
    v_pedido_id, p_cliente_id,
    p_producto_devuelto_id, v_nombre_devuelto, p_cantidad_devuelta,
    p_producto_entregado_id, v_nombre_entregado, p_cantidad_entregada,
    p_observaciones, v_sucursal, COALESCE(p_motivo,'erroneo')
  );

  RETURN v_pedido_id;
END;
$$;

ALTER FUNCTION public.crear_pedido_cambio_en_ruta(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT, TEXT
) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.crear_pedido_cambio_en_ruta(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT, TEXT
) TO authenticated;

-- ============================================================================
-- 6. aplicar_cambio_de_parada: pasa el motivo guardado a _aplicar_cambio_producto.
--    Misma firma pública (p_pedido_id) → CREATE OR REPLACE.
-- ============================================================================
CREATE OR REPLACE FUNCTION public.aplicar_cambio_de_parada(
  p_pedido_id BIGINT
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_rc RECORD;
  v_user UUID := auth.uid();
  v_cambio_id BIGINT;
  v_autorizado BOOLEAN;
BEGIN
  SELECT * INTO v_rc FROM recorrido_cambios WHERE pedido_id = p_pedido_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No hay detalle de cambio para el pedido %', p_pedido_id;
  END IF;

  IF v_rc.aplicado_at IS NOT NULL THEN
    RETURN v_rc.cambio_producto_id;
  END IF;

  v_autorizado := public.es_encargado_o_admin()
    OR EXISTS (
      SELECT 1
      FROM recorrido_pedidos rp
      JOIN recorridos r ON r.id = rp.recorrido_id
      WHERE rp.pedido_id = p_pedido_id
        AND r.transportista_id = v_user
    );
  IF NOT v_autorizado THEN
    RAISE EXCEPTION 'No autorizado para aplicar el cambio';
  END IF;

  v_cambio_id := public._aplicar_cambio_producto(
    v_rc.cliente_id,
    v_rc.producto_devuelto_id, v_rc.cantidad_devuelta,
    v_rc.producto_entregado_id, v_rc.cantidad_entregada,
    v_rc.observaciones, v_rc.sucursal_id, v_user, COALESCE(v_rc.motivo,'erroneo')
  );

  UPDATE recorrido_cambios
     SET aplicado_at = NOW(), cambio_producto_id = v_cambio_id
   WHERE pedido_id = p_pedido_id;

  RETURN v_cambio_id;
END;
$$;

ALTER FUNCTION public.aplicar_cambio_de_parada(BIGINT) OWNER TO postgres;
GRANT EXECUTE ON FUNCTION public.aplicar_cambio_de_parada(BIGINT) TO authenticated;
