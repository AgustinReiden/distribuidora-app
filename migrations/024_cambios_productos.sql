-- Migración 024 — Cambios de productos cliente↔depósito
--
-- Permite registrar un intercambio: el cliente devuelve un producto (sube
-- stock) y se le entrega otro (baja stock). La diferencia de precio impacta
-- saldo_cuenta del cliente (positivo = cliente debe; negativo = a favor).
--
-- El trigger existente registrar_cambio_stock alimenta stock_historico ante
-- cualquier UPDATE de productos.stock, así que no replicamos esa escritura
-- desde la RPC.

-- ============================================================================
-- 1. Tabla cambios_productos
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.cambios_productos (
  id BIGSERIAL PRIMARY KEY,
  cliente_id INTEGER NOT NULL REFERENCES public.clientes(id),
  producto_devuelto_id BIGINT NOT NULL REFERENCES public.productos(id),
  cantidad_devuelta INTEGER NOT NULL CHECK (cantidad_devuelta > 0),
  precio_devuelto NUMERIC(12,2) NOT NULL DEFAULT 0,
  producto_entregado_id BIGINT NOT NULL REFERENCES public.productos(id),
  cantidad_entregada INTEGER NOT NULL CHECK (cantidad_entregada > 0),
  precio_entregado NUMERIC(12,2) NOT NULL DEFAULT 0,
  diferencia_monto NUMERIC(12,2) NOT NULL DEFAULT 0,
  observaciones TEXT,
  usuario_id UUID REFERENCES public.perfiles(id) ON DELETE SET NULL,
  sucursal_id BIGINT NOT NULL REFERENCES public.sucursales(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT cambios_productos_distintos CHECK (producto_devuelto_id <> producto_entregado_id)
);

ALTER TABLE public.cambios_productos OWNER TO postgres;

CREATE INDEX IF NOT EXISTS idx_cambios_productos_cliente
  ON public.cambios_productos (cliente_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cambios_productos_sucursal
  ON public.cambios_productos (sucursal_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_cambios_productos_producto_devuelto
  ON public.cambios_productos (producto_devuelto_id);
CREATE INDEX IF NOT EXISTS idx_cambios_productos_producto_entregado
  ON public.cambios_productos (producto_entregado_id);

-- ============================================================================
-- 2. RLS — solo admin/encargado de la sucursal activa
-- ============================================================================

ALTER TABLE public.cambios_productos ENABLE ROW LEVEL SECURITY;

CREATE POLICY mt_cambios_productos_select ON public.cambios_productos
  FOR SELECT TO authenticated
  USING (public.es_encargado_o_admin() AND sucursal_id = public.current_sucursal_id());

CREATE POLICY mt_cambios_productos_insert ON public.cambios_productos
  FOR INSERT TO authenticated
  WITH CHECK (public.es_encargado_o_admin() AND sucursal_id = public.current_sucursal_id());

CREATE POLICY mt_cambios_productos_delete ON public.cambios_productos
  FOR DELETE TO authenticated
  USING (public.es_admin() AND sucursal_id = public.current_sucursal_id());

GRANT SELECT, INSERT, DELETE ON TABLE public.cambios_productos TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.cambios_productos_id_seq TO authenticated;

-- ============================================================================
-- 3. RPC registrar_cambio_producto
-- ============================================================================
-- Operación atómica:
--   * Lock FOR UPDATE de ambos productos (orden estable por id para evitar
--     deadlocks bajo concurrencia).
--   * Valida stock del producto a entregar.
--   * Suma stock al devuelto, resta al entregado (trigger
--     registrar_cambio_stock se encarga de stock_historico).
--   * Calcula diferencia = precio_entregado*cant_entregada -
--     precio_devuelto*cant_devuelta y la suma a clientes.saldo_cuenta.
--   * Inserta el registro de auditoría en cambios_productos.

CREATE OR REPLACE FUNCTION public.registrar_cambio_producto(
  p_cliente_id INTEGER,
  p_producto_devuelto_id BIGINT,
  p_cantidad_devuelta INTEGER,
  p_producto_entregado_id BIGINT,
  p_cantidad_entregada INTEGER,
  p_observaciones TEXT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := public.current_sucursal_id();
  v_user UUID := auth.uid();
  v_precio_devuelto NUMERIC(12,2);
  v_precio_entregado NUMERIC(12,2);
  v_stock_entregado INT;
  v_diferencia NUMERIC(12,2);
  v_cambio_id BIGINT;
  v_first BIGINT;
  v_second BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sin sucursal activa';
  END IF;

  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_producto_devuelto_id = p_producto_entregado_id THEN
    RAISE EXCEPTION 'Los productos deben ser distintos';
  END IF;

  IF p_cantidad_devuelta <= 0 OR p_cantidad_entregada <= 0 THEN
    RAISE EXCEPTION 'Las cantidades deben ser mayores a 0';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = v_sucursal
  ) THEN
    RAISE EXCEPTION 'Cliente no encontrado en la sucursal';
  END IF;

  -- Lock en orden estable para evitar deadlocks
  IF p_producto_devuelto_id < p_producto_entregado_id THEN
    v_first := p_producto_devuelto_id;
    v_second := p_producto_entregado_id;
  ELSE
    v_first := p_producto_entregado_id;
    v_second := p_producto_devuelto_id;
  END IF;

  PERFORM 1 FROM productos
   WHERE id = v_first AND sucursal_id = v_sucursal FOR UPDATE;
  PERFORM 1 FROM productos
   WHERE id = v_second AND sucursal_id = v_sucursal FOR UPDATE;

  SELECT precio, stock INTO v_precio_entregado, v_stock_entregado
    FROM productos
   WHERE id = p_producto_entregado_id AND sucursal_id = v_sucursal;
  IF v_precio_entregado IS NULL THEN
    RAISE EXCEPTION 'Producto a entregar no encontrado';
  END IF;
  IF v_stock_entregado < p_cantidad_entregada THEN
    RAISE EXCEPTION 'Stock insuficiente del producto a entregar (% disponibles)', v_stock_entregado;
  END IF;

  SELECT precio INTO v_precio_devuelto
    FROM productos
   WHERE id = p_producto_devuelto_id AND sucursal_id = v_sucursal;
  IF v_precio_devuelto IS NULL THEN
    RAISE EXCEPTION 'Producto a devolver no encontrado';
  END IF;

  UPDATE productos SET stock = stock + p_cantidad_devuelta
   WHERE id = p_producto_devuelto_id;
  UPDATE productos SET stock = stock - p_cantidad_entregada
   WHERE id = p_producto_entregado_id;

  v_diferencia := (v_precio_entregado * p_cantidad_entregada)
                - (v_precio_devuelto * p_cantidad_devuelta);

  UPDATE clientes
     SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + v_diferencia
   WHERE id = p_cliente_id;

  INSERT INTO cambios_productos (
    cliente_id, producto_devuelto_id, cantidad_devuelta, precio_devuelto,
    producto_entregado_id, cantidad_entregada, precio_entregado,
    diferencia_monto, observaciones, usuario_id, sucursal_id
  ) VALUES (
    p_cliente_id, p_producto_devuelto_id, p_cantidad_devuelta, v_precio_devuelto,
    p_producto_entregado_id, p_cantidad_entregada, v_precio_entregado,
    v_diferencia, p_observaciones, v_user, v_sucursal
  ) RETURNING id INTO v_cambio_id;

  RETURN v_cambio_id;
END;
$$;

ALTER FUNCTION public.registrar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT
) OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.registrar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT
) TO authenticated;

COMMENT ON FUNCTION public.registrar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT
) IS 'Registra un cambio de productos cliente↔depósito de forma atómica. Suma stock al devuelto, resta al entregado, ajusta saldo_cuenta del cliente con la diferencia de precio.';
