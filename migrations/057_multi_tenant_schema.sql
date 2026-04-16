-- Migration 057: Multi-tenant Schema
--
-- Transforms the existing single-tenant database into a multi-tenant schema.
-- This is the foundation for unifying two Supabase instances (ManaosApp + TP Export).
--
-- Changes:
--   1. Seed sucursales with ManaosApp and TP Export tenants
--   2. Create usuario_sucursales junction table
--   3. Add sucursal_id to all tenant-scoped tables (backfill with 1)
--   4. Create helper function current_sucursal_id()
--   5. Create RPC cambiar_sucursal()
--   6. Create RPC obtener_sucursales_usuario()
--   7. Populate usuario_sucursales for existing users

-- ============================================================
-- 1. Seed sucursales table with tenant records
-- ============================================================

-- Add tipo column to distinguish tenant types
ALTER TABLE sucursales ADD COLUMN IF NOT EXISTS tipo VARCHAR(50) DEFAULT 'distribuidora';

-- Insert tenant records (idempotent)
INSERT INTO sucursales (id, nombre, tipo)
VALUES (1, 'ManaosApp', 'principal')
ON CONFLICT (id) DO NOTHING;

INSERT INTO sucursales (id, nombre, tipo)
VALUES (2, 'TP Export', 'secundaria')
ON CONFLICT (id) DO NOTHING;

-- Ensure the sequence is ahead of our manually inserted IDs
SELECT setval('sucursales_id_seq', GREATEST(nextval('sucursales_id_seq'), 3));

-- ============================================================
-- 2. Create usuario_sucursales junction table
-- ============================================================

CREATE TABLE IF NOT EXISTS usuario_sucursales (
  id BIGSERIAL PRIMARY KEY,
  usuario_id UUID NOT NULL REFERENCES perfiles(id) ON DELETE CASCADE,
  sucursal_id BIGINT NOT NULL REFERENCES sucursales(id) ON DELETE CASCADE,
  rol VARCHAR(20) DEFAULT 'mismo',
  es_default BOOLEAN DEFAULT false,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(usuario_id, sucursal_id)
);

-- Enable RLS
ALTER TABLE usuario_sucursales ENABLE ROW LEVEL SECURITY;

-- Users can read their own sucursal assignments
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'usuario_sucursales' AND policyname = 'usuario_sucursales_select_own') THEN
    CREATE POLICY usuario_sucursales_select_own ON usuario_sucursales
      FOR SELECT TO authenticated
      USING (usuario_id = auth.uid());
  END IF;
END $$;

-- Admins can manage all usuario_sucursales
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'usuario_sucursales' AND policyname = 'usuario_sucursales_admin_all') THEN
    CREATE POLICY usuario_sucursales_admin_all ON usuario_sucursales
      FOR ALL TO authenticated
      USING (
        EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
      )
      WITH CHECK (
        EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
      );
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_usuario_sucursales_usuario ON usuario_sucursales(usuario_id);
CREATE INDEX IF NOT EXISTS idx_usuario_sucursales_sucursal ON usuario_sucursales(sucursal_id);
CREATE INDEX IF NOT EXISTS idx_usuario_sucursales_default ON usuario_sucursales(usuario_id) WHERE es_default = true;

-- ============================================================
-- 3. Add sucursal_id to all tenant-scoped tables
-- ============================================================

-- Helper: For each table, add column nullable, backfill with 1, set NOT NULL, add index.
-- Using DO blocks for idempotent ALTER COLUMN SET NOT NULL (avoiding error if already NOT NULL).

-- --- clientes ---
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE clientes SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE clientes ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_clientes_sucursal ON clientes(sucursal_id);

-- --- productos ---
ALTER TABLE productos ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE productos SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE productos ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_productos_sucursal ON productos(sucursal_id);

-- --- pedidos ---
ALTER TABLE pedidos ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE pedidos SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE pedidos ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_pedidos_sucursal ON pedidos(sucursal_id);

-- --- pedido_items ---
ALTER TABLE pedido_items ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE pedido_items SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE pedido_items ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_pedido_items_sucursal ON pedido_items(sucursal_id);

-- --- pedido_historial ---
ALTER TABLE pedido_historial ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE pedido_historial SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE pedido_historial ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_pedido_historial_sucursal ON pedido_historial(sucursal_id);

-- --- pagos ---
ALTER TABLE pagos ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE pagos SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE pagos ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_pagos_sucursal ON pagos(sucursal_id);

-- --- compras ---
ALTER TABLE compras ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE compras SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE compras ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_compras_sucursal ON compras(sucursal_id);

-- --- compra_items ---
ALTER TABLE compra_items ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE compra_items SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE compra_items ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_compra_items_sucursal ON compra_items(sucursal_id);

-- --- proveedores ---
ALTER TABLE proveedores ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE proveedores SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE proveedores ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_proveedores_sucursal ON proveedores(sucursal_id);

-- --- mermas_stock ---
ALTER TABLE mermas_stock ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE mermas_stock SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE mermas_stock ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_mermas_stock_sucursal ON mermas_stock(sucursal_id);

-- --- stock_historico ---
ALTER TABLE stock_historico ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE stock_historico SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE stock_historico ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_stock_historico_sucursal ON stock_historico(sucursal_id);

-- --- recorridos ---
ALTER TABLE recorridos ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE recorridos SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE recorridos ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_recorridos_sucursal ON recorridos(sucursal_id);

-- --- recorrido_pedidos ---
ALTER TABLE recorrido_pedidos ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE recorrido_pedidos SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE recorrido_pedidos ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_recorrido_pedidos_sucursal ON recorrido_pedidos(sucursal_id);

-- --- rendiciones ---
ALTER TABLE rendiciones ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE rendiciones SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE rendiciones ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_rendiciones_sucursal ON rendiciones(sucursal_id);

-- --- rendicion_items ---
ALTER TABLE rendicion_items ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE rendicion_items SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE rendicion_items ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_rendicion_items_sucursal ON rendicion_items(sucursal_id);

-- --- rendicion_ajustes ---
ALTER TABLE rendicion_ajustes ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE rendicion_ajustes SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE rendicion_ajustes ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_rendicion_ajustes_sucursal ON rendicion_ajustes(sucursal_id);

-- --- salvedades_items ---
ALTER TABLE salvedades_items ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE salvedades_items SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE salvedades_items ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_salvedades_items_sucursal ON salvedades_items(sucursal_id);

-- --- salvedad_historial ---
ALTER TABLE salvedad_historial ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE salvedad_historial SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE salvedad_historial ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_salvedad_historial_sucursal ON salvedad_historial(sucursal_id);

-- --- notas_credito ---
ALTER TABLE notas_credito ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE notas_credito SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE notas_credito ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_notas_credito_sucursal ON notas_credito(sucursal_id);

-- --- nota_credito_items ---
ALTER TABLE nota_credito_items ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE nota_credito_items SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE nota_credito_items ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_nota_credito_items_sucursal ON nota_credito_items(sucursal_id);

-- --- transferencias_stock (SPECIAL: use tenant_sucursal_id, keep existing sucursal_id as-is) ---
ALTER TABLE transferencias_stock ADD COLUMN IF NOT EXISTS tenant_sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE transferencias_stock SET tenant_sucursal_id = 1 WHERE tenant_sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE transferencias_stock ALTER COLUMN tenant_sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_transferencias_stock_tenant_sucursal ON transferencias_stock(tenant_sucursal_id);

-- --- transferencia_items ---
ALTER TABLE transferencia_items ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE transferencia_items SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE transferencia_items ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_transferencia_items_sucursal ON transferencia_items(sucursal_id);

-- --- promociones ---
ALTER TABLE promociones ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE promociones SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE promociones ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_promociones_sucursal ON promociones(sucursal_id);

-- --- promocion_productos ---
ALTER TABLE promocion_productos ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE promocion_productos SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE promocion_productos ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_promocion_productos_sucursal ON promocion_productos(sucursal_id);

-- --- promocion_reglas ---
ALTER TABLE promocion_reglas ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE promocion_reglas SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE promocion_reglas ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_promocion_reglas_sucursal ON promocion_reglas(sucursal_id);

-- --- promo_ajustes ---
ALTER TABLE promo_ajustes ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE promo_ajustes SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE promo_ajustes ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_promo_ajustes_sucursal ON promo_ajustes(sucursal_id);

-- --- grupos_precio ---
ALTER TABLE grupos_precio ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE grupos_precio SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE grupos_precio ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_grupos_precio_sucursal ON grupos_precio(sucursal_id);

-- --- grupo_precio_productos ---
ALTER TABLE grupo_precio_productos ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE grupo_precio_productos SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE grupo_precio_productos ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_grupo_precio_productos_sucursal ON grupo_precio_productos(sucursal_id);

-- --- grupo_precio_escalas ---
ALTER TABLE grupo_precio_escalas ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE grupo_precio_escalas SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE grupo_precio_escalas ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_grupo_precio_escalas_sucursal ON grupo_precio_escalas(sucursal_id);

-- --- pedidos_eliminados ---
ALTER TABLE pedidos_eliminados ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE pedidos_eliminados SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE pedidos_eliminados ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_pedidos_eliminados_sucursal ON pedidos_eliminados(sucursal_id);

-- --- audit_logs ---
ALTER TABLE audit_logs ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE audit_logs SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE audit_logs ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_audit_logs_sucursal ON audit_logs(sucursal_id);

-- --- zonas ---
ALTER TABLE zonas ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE zonas SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE zonas ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_zonas_sucursal ON zonas(sucursal_id);

-- --- preventista_zonas ---
ALTER TABLE preventista_zonas ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE preventista_zonas SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE preventista_zonas ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_preventista_zonas_sucursal ON preventista_zonas(sucursal_id);

-- --- historial_cambios ---
ALTER TABLE historial_cambios ADD COLUMN IF NOT EXISTS sucursal_id BIGINT REFERENCES sucursales(id);
UPDATE historial_cambios SET sucursal_id = 1 WHERE sucursal_id IS NULL;
DO $$ BEGIN ALTER TABLE historial_cambios ALTER COLUMN sucursal_id SET NOT NULL; EXCEPTION WHEN others THEN NULL; END $$;
CREATE INDEX IF NOT EXISTS idx_historial_cambios_sucursal ON historial_cambios(sucursal_id);

-- ============================================================
-- 4. Helper function: current_sucursal_id()
-- ============================================================

CREATE OR REPLACE FUNCTION current_sucursal_id()
RETURNS BIGINT
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = public
AS $$
  SELECT sucursal_id FROM usuario_sucursales
  WHERE usuario_id = auth.uid() AND es_default = true
  LIMIT 1;
$$;

-- ============================================================
-- 5. RPC: cambiar_sucursal(p_sucursal_id)
-- ============================================================

CREATE OR REPLACE FUNCTION cambiar_sucursal(p_sucursal_id BIGINT)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Verify user has access to this sucursal
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado para esta sucursal');
  END IF;

  -- Clear all defaults for this user
  UPDATE usuario_sucursales SET es_default = false WHERE usuario_id = auth.uid();
  -- Set new default
  UPDATE usuario_sucursales SET es_default = true WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id;

  RETURN jsonb_build_object('success', true, 'sucursal_id', p_sucursal_id);
END;
$$;

-- ============================================================
-- 6. RPC: obtener_sucursales_usuario()
-- ============================================================

CREATE OR REPLACE FUNCTION obtener_sucursales_usuario()
RETURNS JSONB
LANGUAGE plpgsql STABLE SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN (
    SELECT jsonb_agg(jsonb_build_object(
      'sucursal_id', us.sucursal_id,
      'nombre', s.nombre,
      'rol', us.rol,
      'es_default', us.es_default
    ))
    FROM usuario_sucursales us
    JOIN sucursales s ON s.id = us.sucursal_id
    WHERE us.usuario_id = auth.uid() AND s.activa = true
  );
END;
$$;

-- ============================================================
-- 7. Populate usuario_sucursales for existing ManaosApp users
-- ============================================================

INSERT INTO usuario_sucursales (usuario_id, sucursal_id, rol, es_default)
SELECT id, 1, 'mismo', true FROM perfiles
ON CONFLICT (usuario_id, sucursal_id) DO NOTHING;
