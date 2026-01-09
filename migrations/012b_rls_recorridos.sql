-- Migración 012b: Políticas RLS para tablas de recorridos
-- Ejecutar después de 012_zonas_pagos_recorridos.sql

-- Habilitar RLS en las tablas
ALTER TABLE recorridos ENABLE ROW LEVEL SECURITY;
ALTER TABLE recorrido_pedidos ENABLE ROW LEVEL SECURITY;

-- Políticas para recorridos
-- Admins pueden ver todos los recorridos
CREATE POLICY "Admins pueden ver todos los recorridos"
ON recorridos FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM perfiles
    WHERE perfiles.id = auth.uid()
    AND perfiles.rol = 'admin'
  )
);

-- Transportistas pueden ver sus propios recorridos
CREATE POLICY "Transportistas pueden ver sus recorridos"
ON recorridos FOR SELECT
TO authenticated
USING (transportista_id = auth.uid());

-- Admins pueden insertar recorridos
CREATE POLICY "Admins pueden insertar recorridos"
ON recorridos FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM perfiles
    WHERE perfiles.id = auth.uid()
    AND perfiles.rol = 'admin'
  )
);

-- Admins pueden actualizar recorridos
CREATE POLICY "Admins pueden actualizar recorridos"
ON recorridos FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM perfiles
    WHERE perfiles.id = auth.uid()
    AND perfiles.rol = 'admin'
  )
);

-- Políticas para recorrido_pedidos
-- Admins pueden ver todos los detalles
CREATE POLICY "Admins pueden ver detalles de recorridos"
ON recorrido_pedidos FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM perfiles
    WHERE perfiles.id = auth.uid()
    AND perfiles.rol = 'admin'
  )
);

-- Transportistas pueden ver detalles de sus recorridos
CREATE POLICY "Transportistas pueden ver detalles de sus recorridos"
ON recorrido_pedidos FOR SELECT
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM recorridos
    WHERE recorridos.id = recorrido_pedidos.recorrido_id
    AND recorridos.transportista_id = auth.uid()
  )
);

-- Admins pueden insertar detalles
CREATE POLICY "Admins pueden insertar detalles de recorridos"
ON recorrido_pedidos FOR INSERT
TO authenticated
WITH CHECK (
  EXISTS (
    SELECT 1 FROM perfiles
    WHERE perfiles.id = auth.uid()
    AND perfiles.rol = 'admin'
  )
);

-- Admins pueden actualizar detalles
CREATE POLICY "Admins pueden actualizar detalles de recorridos"
ON recorrido_pedidos FOR UPDATE
TO authenticated
USING (
  EXISTS (
    SELECT 1 FROM perfiles
    WHERE perfiles.id = auth.uid()
    AND perfiles.rol = 'admin'
  )
);
