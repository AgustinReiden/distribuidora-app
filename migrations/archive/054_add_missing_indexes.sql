-- Migration 054: Add missing indexes for scaling
-- These tables lack indexes on frequently filtered/joined columns

-- pedidos: filtered by estado, cliente, transportista, fecha in almost every query
CREATE INDEX IF NOT EXISTS idx_pedidos_cliente_id ON public.pedidos (cliente_id);
CREATE INDEX IF NOT EXISTS idx_pedidos_transportista_id ON public.pedidos (transportista_id);
CREATE INDEX IF NOT EXISTS idx_pedidos_estado ON public.pedidos (estado);
CREATE INDEX IF NOT EXISTS idx_pedidos_fecha ON public.pedidos (fecha DESC);
CREATE INDEX IF NOT EXISTS idx_pedidos_fecha_entrega ON public.pedidos (fecha_entrega_programada);

-- pedido_items: joined with pedidos and productos constantly
CREATE INDEX IF NOT EXISTS idx_pedido_items_pedido_id ON public.pedido_items (pedido_id);
CREATE INDEX IF NOT EXISTS idx_pedido_items_producto_id ON public.pedido_items (producto_id);

-- pagos: filtered by cliente and fecha for account statements
CREATE INDEX IF NOT EXISTS idx_pagos_cliente_id ON public.pagos (cliente_id);
CREATE INDEX IF NOT EXISTS idx_pagos_fecha ON public.pagos (created_at DESC);

-- pedido_historial: always queried by pedido_id
CREATE INDEX IF NOT EXISTS idx_pedido_historial_pedido_id ON public.pedido_historial (pedido_id);

-- audit_logs: queried by table and record for audit history
CREATE INDEX IF NOT EXISTS idx_audit_logs_tabla_registro ON public.audit_logs (tabla, registro_id);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON public.audit_logs (created_at DESC);

-- compra_items: joined with compras
CREATE INDEX IF NOT EXISTS idx_compra_items_compra_id ON public.compra_items (compra_id);

-- mermas_stock: filtered by producto and fecha
CREATE INDEX IF NOT EXISTS idx_mermas_producto_id ON public.mermas_stock (producto_id);

-- rendicion_items: joined with rendiciones
CREATE INDEX IF NOT EXISTS idx_rendicion_items_rendicion_id ON public.rendicion_items (rendicion_id);
