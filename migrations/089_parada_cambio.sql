-- Migración 089 — Parada de cambio/devolución en el recorrido
--
-- El cliente tiene un producto vencido/erróneo y necesita un cambio. Hoy el
-- recorrido solo rutea pedidos (recorrido_pedidos.pedido_id es NOT NULL y la
-- vista del chofer filtra pedido != null). Para que un cambio sea una PARADA
-- sin reescribir el modelo de paradas, se modela como un "pedido especial":
--   canal = 'cambio', total = 0, estado_pago = 'pagado'.
-- Con total = 0 el trigger actualizar_saldo_pedido NO mueve saldo_cuenta, y no
-- hay trigger de stock en la entrega (el stock se descuenta al CREAR un pedido
-- normal, en JS). Así el pedido de cambio fluye por todo el pipeline
-- (optimizador, aplicar_orden_ruta, recorrido_pedidos, ruta del chofer, hoja de
-- ruta, comandas) sin efectos de venta indeseados.
--
-- El detalle del cambio (producto devuelto/entregado + cantidades) vive en la
-- tabla nueva recorrido_cambios (1:1 con el pedido). Cuando el chofer completa
-- la parada se ejecuta aplicar_cambio_de_parada, que recién ahí ajusta stock +
-- saldo_cuenta reusando la misma lógica que registrar_cambio_producto (mig 024),
-- factorizada en _aplicar_cambio_producto.
--
-- NO aplicada en prod todavía (pendiente de apply_migration vía MCP).

-- ============================================================================
-- 1. Tabla recorrido_cambios — detalle 1:1 del cambio asociado a un pedido
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.recorrido_cambios (
  id BIGSERIAL PRIMARY KEY,
  pedido_id BIGINT NOT NULL UNIQUE REFERENCES public.pedidos(id) ON DELETE CASCADE,
  cliente_id INTEGER NOT NULL REFERENCES public.clientes(id),
  producto_devuelto_id BIGINT NOT NULL REFERENCES public.productos(id),
  producto_devuelto_nombre TEXT,
  cantidad_devuelta INTEGER NOT NULL CHECK (cantidad_devuelta > 0),
  producto_entregado_id BIGINT NOT NULL REFERENCES public.productos(id),
  producto_entregado_nombre TEXT,
  cantidad_entregada INTEGER NOT NULL CHECK (cantidad_entregada > 0),
  observaciones TEXT,
  sucursal_id BIGINT NOT NULL REFERENCES public.sucursales(id),
  -- Auditoría de aplicación: NULL = todavía no se ejecutó el cambio real.
  aplicado_at TIMESTAMPTZ,
  cambio_producto_id BIGINT REFERENCES public.cambios_productos(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT recorrido_cambios_distintos
    CHECK (producto_devuelto_id <> producto_entregado_id)
);

ALTER TABLE public.recorrido_cambios OWNER TO postgres;

CREATE INDEX IF NOT EXISTS idx_recorrido_cambios_sucursal
  ON public.recorrido_cambios (sucursal_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_recorrido_cambios_cliente
  ON public.recorrido_cambios (cliente_id, created_at DESC);

COMMENT ON TABLE public.recorrido_cambios IS
  'Detalle 1:1 de una parada de cambio/devolución (pedido con canal=cambio). El producto devuelto/entregado y cantidades; aplicado_at marca cuándo el chofer la completó (stock+saldo ajustados vía aplicar_cambio_de_parada).';

-- ============================================================================
-- 2. RLS — admin/encargado de la sucursal; el transportista ve el detalle de
--    las paradas de su recorrido. Las escrituras van por RPC SECURITY DEFINER.
-- ============================================================================

ALTER TABLE public.recorrido_cambios ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS rc_select ON public.recorrido_cambios;
CREATE POLICY rc_select ON public.recorrido_cambios
  FOR SELECT TO authenticated
  USING (
    sucursal_id = public.current_sucursal_id()
    AND (
      public.es_encargado_o_admin()
      OR EXISTS (
        SELECT 1
        FROM public.recorrido_pedidos rp
        JOIN public.recorridos r ON r.id = rp.recorrido_id
        WHERE rp.pedido_id = recorrido_cambios.pedido_id
          AND r.transportista_id = auth.uid()
      )
    )
  );

-- INSERT/UPDATE/DELETE: solo vía RPC (SECURITY DEFINER, owner postgres). No
-- abrimos políticas de escritura directa para mantener invariantes.
GRANT SELECT ON TABLE public.recorrido_cambios TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.recorrido_cambios_id_seq TO authenticated;

-- ============================================================================
-- 3. _aplicar_cambio_producto — núcleo del cambio (stock + saldo + auditoría)
--    Factorizado desde registrar_cambio_producto (mig 024). SIN chequeo de
--    autorización ni resolución de sucursal: el caller (wrapper DEFINER) las
--    provee. Valida productos, cantidades, cliente y stock.
-- ============================================================================

CREATE OR REPLACE FUNCTION public._aplicar_cambio_producto(
  p_cliente_id INTEGER,
  p_producto_devuelto_id BIGINT,
  p_cantidad_devuelta INTEGER,
  p_producto_entregado_id BIGINT,
  p_cantidad_entregada INTEGER,
  p_observaciones TEXT,
  p_sucursal_id BIGINT,
  p_usuario_id UUID
) RETURNS BIGINT
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_precio_devuelto NUMERIC(12,2);
  v_precio_entregado NUMERIC(12,2);
  v_stock_entregado INT;
  v_diferencia NUMERIC(12,2);
  v_cambio_id BIGINT;
  v_first BIGINT;
  v_second BIGINT;
BEGIN
  IF p_producto_devuelto_id = p_producto_entregado_id THEN
    RAISE EXCEPTION 'Los productos deben ser distintos';
  END IF;

  IF p_cantidad_devuelta <= 0 OR p_cantidad_entregada <= 0 THEN
    RAISE EXCEPTION 'Las cantidades deben ser mayores a 0';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM clientes WHERE id = p_cliente_id AND sucursal_id = p_sucursal_id
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
    v_diferencia, p_observaciones, p_usuario_id, p_sucursal_id
  ) RETURNING id INTO v_cambio_id;

  RETURN v_cambio_id;
END;
$$;

ALTER FUNCTION public._aplicar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT, BIGINT, UUID
) OWNER TO postgres;

-- Solo lo llaman los wrappers DEFINER; no se expone a clientes.
REVOKE ALL ON FUNCTION public._aplicar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT, BIGINT, UUID
) FROM PUBLIC;

-- ============================================================================
-- 4. registrar_cambio_producto (mig 024) → delega en _aplicar_cambio_producto
--    Misma firma y semántica pública (cambio standalone admin/encargado).
-- ============================================================================

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
    v_sucursal, v_user
  );
END;
$$;

ALTER FUNCTION public.registrar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT
) OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.registrar_cambio_producto(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT
) TO authenticated;

-- ============================================================================
-- 5. crear_pedido_cambio_en_ruta — crea el pedido especial + el detalle
-- ============================================================================

CREATE OR REPLACE FUNCTION public.crear_pedido_cambio_en_ruta(
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

  -- Pedido especial de cambio: total 0 (no mueve saldo), estado_pago pagado
  -- (el chofer no entra al modal de cobro), canal 'cambio' (diferenciador).
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
    observaciones, sucursal_id
  ) VALUES (
    v_pedido_id, p_cliente_id,
    p_producto_devuelto_id, v_nombre_devuelto, p_cantidad_devuelta,
    p_producto_entregado_id, v_nombre_entregado, p_cantidad_entregada,
    p_observaciones, v_sucursal
  );

  RETURN v_pedido_id;
END;
$$;

ALTER FUNCTION public.crear_pedido_cambio_en_ruta(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT
) OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.crear_pedido_cambio_en_ruta(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT
) TO authenticated;

COMMENT ON FUNCTION public.crear_pedido_cambio_en_ruta(
  INTEGER, BIGINT, INTEGER, BIGINT, INTEGER, TEXT
) IS 'Crea un pedido especial canal=cambio (total 0) + su detalle en recorrido_cambios, para agregarlo como parada del recorrido. NO ajusta stock/saldo (eso ocurre al completar la parada vía aplicar_cambio_de_parada).';

-- ============================================================================
-- 6. aplicar_cambio_de_parada — ejecuta el cambio real al completar la parada
--    Idempotente (aplicado_at). Autoriza al transportista del recorrido o a
--    admin/encargado.
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

  -- Idempotencia: si ya se aplicó, devolver el cambio existente.
  IF v_rc.aplicado_at IS NOT NULL THEN
    RETURN v_rc.cambio_producto_id;
  END IF;

  -- Autorización: admin/encargado de la sucursal, o el transportista a cargo
  -- del recorrido que contiene esta parada.
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
    v_rc.observaciones, v_rc.sucursal_id, v_user
  );

  UPDATE recorrido_cambios
     SET aplicado_at = NOW(), cambio_producto_id = v_cambio_id
   WHERE pedido_id = p_pedido_id;

  RETURN v_cambio_id;
END;
$$;

ALTER FUNCTION public.aplicar_cambio_de_parada(BIGINT) OWNER TO postgres;

GRANT EXECUTE ON FUNCTION public.aplicar_cambio_de_parada(BIGINT) TO authenticated;

COMMENT ON FUNCTION public.aplicar_cambio_de_parada(BIGINT) IS
  'Ejecuta el cambio real de una parada (suma stock devuelto, resta entregado, ajusta saldo_cuenta, inserta cambios_productos) y marca aplicado_at. Idempotente. Autoriza al transportista del recorrido o a admin/encargado.';
