-- ============================================================================
-- 037: Notas de Crédito en Compras + Envíos a Sucursal (Transferencias)
-- ============================================================================

-- ============================================================================
-- NOTAS DE CREDITO
-- ============================================================================

CREATE TABLE IF NOT EXISTS notas_credito (
  id BIGSERIAL PRIMARY KEY,
  compra_id BIGINT NOT NULL REFERENCES compras(id) ON DELETE CASCADE,
  numero_nota VARCHAR(50),
  fecha DATE NOT NULL DEFAULT CURRENT_DATE,
  subtotal DECIMAL(12, 2) NOT NULL DEFAULT 0,
  iva DECIMAL(12, 2) NOT NULL DEFAULT 0,
  total DECIMAL(12, 2) NOT NULL DEFAULT 0,
  motivo TEXT,
  usuario_id UUID REFERENCES perfiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS nota_credito_items (
  id BIGSERIAL PRIMARY KEY,
  nota_credito_id BIGINT NOT NULL REFERENCES notas_credito(id) ON DELETE CASCADE,
  producto_id BIGINT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
  cantidad INTEGER NOT NULL CHECK (cantidad > 0),
  costo_unitario DECIMAL(12, 2) NOT NULL DEFAULT 0,
  subtotal DECIMAL(12, 2) NOT NULL DEFAULT 0,
  stock_anterior INTEGER NOT NULL DEFAULT 0,
  stock_nuevo INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_notas_credito_compra ON notas_credito(compra_id);
CREATE INDEX IF NOT EXISTS idx_notas_credito_fecha ON notas_credito(fecha DESC);
CREATE INDEX IF NOT EXISTS idx_nota_credito_items_nota ON nota_credito_items(nota_credito_id);

-- ============================================================================
-- SUCURSALES Y TRANSFERENCIAS
-- ============================================================================

CREATE TABLE IF NOT EXISTS sucursales (
  id BIGSERIAL PRIMARY KEY,
  nombre VARCHAR(200) NOT NULL,
  direccion TEXT,
  activa BOOLEAN DEFAULT true,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS transferencias_stock (
  id BIGSERIAL PRIMARY KEY,
  sucursal_id BIGINT NOT NULL REFERENCES sucursales(id),
  fecha DATE NOT NULL DEFAULT CURRENT_DATE,
  notas TEXT,
  total_costo DECIMAL(12, 2) NOT NULL DEFAULT 0,
  usuario_id UUID REFERENCES perfiles(id) ON DELETE SET NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS transferencia_items (
  id BIGSERIAL PRIMARY KEY,
  transferencia_id BIGINT NOT NULL REFERENCES transferencias_stock(id) ON DELETE CASCADE,
  producto_id BIGINT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
  cantidad INTEGER NOT NULL CHECK (cantidad > 0),
  costo_unitario DECIMAL(12, 2) NOT NULL DEFAULT 0,
  subtotal DECIMAL(12, 2) NOT NULL DEFAULT 0,
  stock_anterior INTEGER NOT NULL DEFAULT 0,
  stock_nuevo INTEGER NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_transferencias_sucursal ON transferencias_stock(sucursal_id);
CREATE INDEX IF NOT EXISTS idx_transferencias_fecha ON transferencias_stock(fecha DESC);
CREATE INDEX IF NOT EXISTS idx_transferencia_items_trans ON transferencia_items(transferencia_id);

-- ============================================================================
-- RPC: registrar_nota_credito
-- Inserta NC + items y reduce stock atómicamente
-- ============================================================================

CREATE OR REPLACE FUNCTION public.registrar_nota_credito(
  p_compra_id BIGINT,
  p_numero_nota VARCHAR DEFAULT NULL,
  p_motivo TEXT DEFAULT NULL,
  p_subtotal DECIMAL DEFAULT 0,
  p_iva DECIMAL DEFAULT 0,
  p_total DECIMAL DEFAULT 0,
  p_usuario_id UUID DEFAULT NULL,
  p_items JSONB DEFAULT '[]'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_nota_id BIGINT;
  v_item JSONB;
  v_stock_actual INTEGER;
  v_producto_id BIGINT;
  v_cantidad INTEGER;
  v_costo DECIMAL;
  v_sub DECIMAL;
BEGIN
  -- Verificar que la compra existe y no está cancelada
  IF NOT EXISTS (SELECT 1 FROM compras WHERE id = p_compra_id AND estado != 'cancelada') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada o cancelada');
  END IF;

  INSERT INTO notas_credito (compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id)
  VALUES (p_compra_id, p_numero_nota, CURRENT_DATE, p_subtotal, p_iva, p_total, p_motivo, p_usuario_id)
  RETURNING id INTO v_nota_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (v_item->>'producto_id')::BIGINT;
    v_cantidad := (v_item->>'cantidad')::INTEGER;
    v_costo := (v_item->>'costo_unitario')::DECIMAL;
    v_sub := (v_item->>'subtotal')::DECIMAL;

    SELECT stock INTO v_stock_actual FROM productos WHERE id = v_producto_id FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      RAISE EXCEPTION 'Producto % no encontrado', v_producto_id;
    END IF;

    INSERT INTO nota_credito_items (nota_credito_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo)
    VALUES (v_nota_id, v_producto_id, v_cantidad, v_costo, v_sub, v_stock_actual, GREATEST(0, v_stock_actual - v_cantidad));

    UPDATE productos SET stock = GREATEST(0, v_stock_actual - v_cantidad) WHERE id = v_producto_id;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'nota_credito_id', v_nota_id);
END;
$$;

-- ============================================================================
-- RPC: registrar_transferencia
-- Inserta transferencia + items y reduce stock atómicamente
-- ============================================================================

CREATE OR REPLACE FUNCTION public.registrar_transferencia(
  p_sucursal_id BIGINT,
  p_fecha DATE DEFAULT CURRENT_DATE,
  p_notas TEXT DEFAULT NULL,
  p_total_costo DECIMAL DEFAULT 0,
  p_usuario_id UUID DEFAULT NULL,
  p_items JSONB DEFAULT '[]'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_trans_id BIGINT;
  v_item JSONB;
  v_stock_actual INTEGER;
  v_producto_id BIGINT;
  v_cantidad INTEGER;
  v_costo DECIMAL;
  v_sub DECIMAL;
BEGIN
  INSERT INTO transferencias_stock (sucursal_id, fecha, notas, total_costo, usuario_id)
  VALUES (p_sucursal_id, p_fecha, p_notas, p_total_costo, p_usuario_id)
  RETURNING id INTO v_trans_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (v_item->>'producto_id')::BIGINT;
    v_cantidad := (v_item->>'cantidad')::INTEGER;
    v_costo := (v_item->>'costo_unitario')::DECIMAL;
    v_sub := (v_item->>'subtotal')::DECIMAL;

    SELECT stock INTO v_stock_actual FROM productos WHERE id = v_producto_id FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      RAISE EXCEPTION 'Producto % no encontrado', v_producto_id;
    END IF;

    INSERT INTO transferencia_items (transferencia_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo)
    VALUES (v_trans_id, v_producto_id, v_cantidad, v_costo, v_sub, v_stock_actual, GREATEST(0, v_stock_actual - v_cantidad));

    UPDATE productos SET stock = GREATEST(0, v_stock_actual - v_cantidad) WHERE id = v_producto_id;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'transferencia_id', v_trans_id);
END;
$$;

-- ============================================================================
-- RLS POLICIES
-- ============================================================================

ALTER TABLE notas_credito ENABLE ROW LEVEL SECURITY;
ALTER TABLE nota_credito_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE sucursales ENABLE ROW LEVEL SECURITY;
ALTER TABLE transferencias_stock ENABLE ROW LEVEL SECURITY;
ALTER TABLE transferencia_items ENABLE ROW LEVEL SECURITY;

-- Admin full access
CREATE POLICY "admin_notas_credito" ON notas_credito FOR ALL
  USING (EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'));

CREATE POLICY "admin_nota_credito_items" ON nota_credito_items FOR ALL
  USING (EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'));

CREATE POLICY "admin_sucursales" ON sucursales FOR ALL
  USING (EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'));

CREATE POLICY "admin_transferencias_stock" ON transferencias_stock FOR ALL
  USING (EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'));

CREATE POLICY "admin_transferencia_items" ON transferencia_items FOR ALL
  USING (EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'));

-- Authenticated users can read
CREATE POLICY "read_notas_credito" ON notas_credito FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "read_nota_credito_items" ON nota_credito_items FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "read_sucursales" ON sucursales FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "read_transferencias_stock" ON transferencias_stock FOR SELECT
  USING (auth.role() = 'authenticated');

CREATE POLICY "read_transferencia_items" ON transferencia_items FOR SELECT
  USING (auth.role() = 'authenticated');
