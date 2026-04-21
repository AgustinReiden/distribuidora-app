-- Migración 021: Sistema de Rendición de Transportistas
-- Fecha: 2026-01-22
-- Descripción:
--   1. Crea tabla de rendiciones para cierre diario de transportistas
--   2. Crea tabla de items de rendición (detalle de cobros)
--   3. Crea tabla de ajustes para diferencias
--   4. Funciones RPC para crear, presentar y revisar rendiciones
--   5. Vista para reportes

-- =====================================================
-- 1. TABLA PRINCIPAL: rendiciones
-- =====================================================

CREATE TABLE IF NOT EXISTS rendiciones (
  id BIGSERIAL PRIMARY KEY,
  recorrido_id BIGINT NOT NULL REFERENCES recorridos(id) ON DELETE CASCADE,
  transportista_id UUID NOT NULL REFERENCES perfiles(id) ON DELETE CASCADE,
  fecha DATE NOT NULL DEFAULT CURRENT_DATE,

  -- Montos esperados (calculados del recorrido)
  total_efectivo_esperado DECIMAL(12,2) NOT NULL DEFAULT 0,
  total_otros_medios DECIMAL(12,2) NOT NULL DEFAULT 0,

  -- Montos rendidos
  monto_rendido DECIMAL(12,2) NOT NULL DEFAULT 0,

  -- Diferencia calculada
  diferencia DECIMAL(12,2) GENERATED ALWAYS AS (monto_rendido - total_efectivo_esperado) STORED,

  -- Estado y aprobación
  estado VARCHAR(30) NOT NULL DEFAULT 'pendiente'
    CHECK (estado IN ('pendiente', 'presentada', 'aprobada', 'rechazada', 'con_observaciones')),

  -- Observaciones
  justificacion_transportista TEXT,
  observaciones_admin TEXT,

  -- Auditoría
  presentada_at TIMESTAMP WITH TIME ZONE,
  revisada_at TIMESTAMP WITH TIME ZONE,
  revisada_por UUID REFERENCES perfiles(id),

  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  UNIQUE(recorrido_id)
);

-- Índices para rendiciones
CREATE INDEX IF NOT EXISTS idx_rendiciones_transportista ON rendiciones(transportista_id);
CREATE INDEX IF NOT EXISTS idx_rendiciones_fecha ON rendiciones(fecha DESC);
CREATE INDEX IF NOT EXISTS idx_rendiciones_estado ON rendiciones(estado);

-- Comentarios
COMMENT ON TABLE rendiciones IS 'Registro de rendiciones de efectivo de transportistas al final del día';
COMMENT ON COLUMN rendiciones.diferencia IS 'Diferencia entre monto rendido y esperado (positivo=sobrante, negativo=faltante)';
COMMENT ON COLUMN rendiciones.estado IS 'Estado: pendiente, presentada, aprobada, rechazada, con_observaciones';

-- =====================================================
-- 2. TABLA DE DETALLE: rendicion_items
-- =====================================================

CREATE TABLE IF NOT EXISTS rendicion_items (
  id BIGSERIAL PRIMARY KEY,
  rendicion_id BIGINT NOT NULL REFERENCES rendiciones(id) ON DELETE CASCADE,
  pedido_id BIGINT NOT NULL REFERENCES pedidos(id) ON DELETE CASCADE,

  -- Detalle del cobro
  monto_cobrado DECIMAL(12,2) NOT NULL DEFAULT 0,
  forma_pago VARCHAR(30) NOT NULL,
  referencia VARCHAR(100),

  -- Estado
  incluido_en_rendicion BOOLEAN DEFAULT TRUE,
  notas TEXT,

  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

  UNIQUE(rendicion_id, pedido_id)
);

CREATE INDEX IF NOT EXISTS idx_rendicion_items_rendicion ON rendicion_items(rendicion_id);

COMMENT ON TABLE rendicion_items IS 'Detalle de cobros incluidos en cada rendición';

-- =====================================================
-- 3. TABLA DE AJUSTES: rendicion_ajustes
-- =====================================================

CREATE TABLE IF NOT EXISTS rendicion_ajustes (
  id BIGSERIAL PRIMARY KEY,
  rendicion_id BIGINT NOT NULL REFERENCES rendiciones(id) ON DELETE CASCADE,

  tipo VARCHAR(30) NOT NULL
    CHECK (tipo IN ('faltante', 'sobrante', 'vuelto_no_dado', 'error_cobro', 'descuento_autorizado', 'otro')),
  monto DECIMAL(12,2) NOT NULL,
  descripcion TEXT NOT NULL,

  -- Evidencia
  foto_url TEXT,

  -- Aprobación
  aprobado BOOLEAN,
  aprobado_por UUID REFERENCES perfiles(id),
  aprobado_at TIMESTAMP WITH TIME ZONE,

  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rendicion_ajustes_rendicion ON rendicion_ajustes(rendicion_id);

COMMENT ON TABLE rendicion_ajustes IS 'Ajustes y justificaciones de diferencias en rendiciones';

-- =====================================================
-- 4. RLS POLICIES
-- =====================================================

ALTER TABLE rendiciones ENABLE ROW LEVEL SECURITY;
ALTER TABLE rendicion_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE rendicion_ajustes ENABLE ROW LEVEL SECURITY;

-- Función helper para verificar admin
CREATE OR REPLACE FUNCTION es_admin_rendiciones()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid()
    AND rol = 'admin'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Función helper para verificar transportista
CREATE OR REPLACE FUNCTION es_transportista_rendiciones()
RETURNS BOOLEAN AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid()
    AND rol = 'transportista'
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Políticas para rendiciones
CREATE POLICY "Admin full access rendiciones" ON rendiciones
  FOR ALL USING (es_admin_rendiciones());

CREATE POLICY "Transportista ve sus rendiciones" ON rendiciones
  FOR SELECT USING (transportista_id = auth.uid());

CREATE POLICY "Transportista crea sus rendiciones" ON rendiciones
  FOR INSERT WITH CHECK (transportista_id = auth.uid());

CREATE POLICY "Transportista actualiza sus rendiciones pendientes" ON rendiciones
  FOR UPDATE USING (
    transportista_id = auth.uid()
    AND estado IN ('pendiente', 'presentada', 'con_observaciones')
  );

-- Políticas para rendicion_items
CREATE POLICY "Admin full access rendicion_items" ON rendicion_items
  FOR ALL USING (es_admin_rendiciones());

CREATE POLICY "Transportista ve items de sus rendiciones" ON rendicion_items
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM rendiciones r
      WHERE r.id = rendicion_id
      AND r.transportista_id = auth.uid()
    )
  );

CREATE POLICY "Transportista crea items en sus rendiciones" ON rendicion_items
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM rendiciones r
      WHERE r.id = rendicion_id
      AND (r.transportista_id = auth.uid() OR es_admin_rendiciones())
    )
  );

-- Políticas para rendicion_ajustes
CREATE POLICY "Admin full access rendicion_ajustes" ON rendicion_ajustes
  FOR ALL USING (es_admin_rendiciones());

CREATE POLICY "Transportista ve ajustes de sus rendiciones" ON rendicion_ajustes
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM rendiciones r
      WHERE r.id = rendicion_id
      AND r.transportista_id = auth.uid()
    )
  );

CREATE POLICY "Transportista crea ajustes en sus rendiciones" ON rendicion_ajustes
  FOR INSERT WITH CHECK (
    EXISTS (
      SELECT 1 FROM rendiciones r
      WHERE r.id = rendicion_id
      AND (r.transportista_id = auth.uid() OR es_admin_rendiciones())
      AND r.estado IN ('pendiente', 'presentada', 'con_observaciones')
    )
  );

-- =====================================================
-- 5. FUNCIÓN RPC: Crear rendición desde recorrido
-- =====================================================

CREATE OR REPLACE FUNCTION crear_rendicion_recorrido(
  p_recorrido_id BIGINT,
  p_transportista_id UUID DEFAULT NULL
)
RETURNS BIGINT AS $$
DECLARE
  v_rendicion_id BIGINT;
  v_total_efectivo DECIMAL := 0;
  v_total_otros DECIMAL := 0;
  v_pedido RECORD;
  v_transportista_real UUID;
  v_es_admin BOOLEAN;
BEGIN
  -- Verificar si es admin
  v_es_admin := es_admin_rendiciones();

  -- Si es admin y no se especifica transportista, obtenerlo del recorrido
  IF v_es_admin THEN
    IF p_transportista_id IS NULL THEN
      SELECT transportista_id INTO v_transportista_real
      FROM recorridos WHERE id = p_recorrido_id;
    ELSE
      v_transportista_real := p_transportista_id;
    END IF;
  ELSE
    v_transportista_real := auth.uid();
  END IF;

  -- Verificar que el recorrido existe y pertenece al transportista (o es admin)
  IF NOT EXISTS (
    SELECT 1 FROM recorridos
    WHERE id = p_recorrido_id
    AND (transportista_id = v_transportista_real OR v_es_admin)
  ) THEN
    RAISE EXCEPTION 'Recorrido no válido o no pertenece al transportista';
  END IF;

  -- Verificar que no existe ya una rendición para este recorrido
  IF EXISTS (SELECT 1 FROM rendiciones WHERE recorrido_id = p_recorrido_id) THEN
    RAISE EXCEPTION 'Ya existe una rendición para este recorrido';
  END IF;

  -- Calcular totales por forma de pago de pedidos entregados
  FOR v_pedido IN
    SELECT p.id, COALESCE(p.monto_pagado, 0) as monto_pagado, COALESCE(p.forma_pago, 'efectivo') as forma_pago
    FROM pedidos p
    JOIN recorrido_pedidos rp ON rp.pedido_id = p.id
    WHERE rp.recorrido_id = p_recorrido_id
    AND rp.estado_entrega = 'entregado'
    AND p.estado = 'entregado'
  LOOP
    IF v_pedido.forma_pago = 'efectivo' THEN
      v_total_efectivo := v_total_efectivo + v_pedido.monto_pagado;
    ELSE
      v_total_otros := v_total_otros + v_pedido.monto_pagado;
    END IF;
  END LOOP;

  -- Crear la rendición
  INSERT INTO rendiciones (
    recorrido_id,
    transportista_id,
    fecha,
    total_efectivo_esperado,
    total_otros_medios,
    estado
  ) VALUES (
    p_recorrido_id,
    v_transportista_real,
    CURRENT_DATE,
    v_total_efectivo,
    v_total_otros,
    'pendiente'
  )
  RETURNING id INTO v_rendicion_id;

  -- Crear items de rendición para cada pedido entregado
  INSERT INTO rendicion_items (rendicion_id, pedido_id, monto_cobrado, forma_pago)
  SELECT
    v_rendicion_id,
    p.id,
    COALESCE(p.monto_pagado, 0),
    COALESCE(p.forma_pago, 'efectivo')
  FROM pedidos p
  JOIN recorrido_pedidos rp ON rp.pedido_id = p.id
  WHERE rp.recorrido_id = p_recorrido_id
  AND rp.estado_entrega = 'entregado';

  RETURN v_rendicion_id;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION crear_rendicion_recorrido IS 'Crea una nueva rendición a partir de un recorrido completado';

-- =====================================================
-- 6. FUNCIÓN RPC: Presentar rendición
-- =====================================================

CREATE OR REPLACE FUNCTION presentar_rendicion(
  p_rendicion_id BIGINT,
  p_monto_rendido DECIMAL,
  p_justificacion TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_transportista_id UUID;
  v_estado VARCHAR;
  v_diferencia DECIMAL;
  v_es_admin BOOLEAN;
BEGIN
  v_es_admin := es_admin_rendiciones();

  -- Verificar que la rendición existe y está en estado válido
  SELECT transportista_id, estado INTO v_transportista_id, v_estado
  FROM rendiciones
  WHERE id = p_rendicion_id;

  IF v_transportista_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Rendición no encontrada');
  END IF;

  IF v_estado NOT IN ('pendiente', 'con_observaciones') THEN
    RETURN jsonb_build_object('success', false, 'error', 'La rendición no está en estado editable');
  END IF;

  IF v_transportista_id != auth.uid() AND NOT v_es_admin THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  -- Actualizar rendición
  UPDATE rendiciones SET
    monto_rendido = p_monto_rendido,
    justificacion_transportista = p_justificacion,
    estado = 'presentada',
    presentada_at = NOW(),
    updated_at = NOW()
  WHERE id = p_rendicion_id;

  -- Obtener diferencia calculada
  SELECT diferencia INTO v_diferencia
  FROM rendiciones WHERE id = p_rendicion_id;

  RETURN jsonb_build_object(
    'success', true,
    'diferencia', v_diferencia,
    'requiere_justificacion', ABS(v_diferencia) > 0
  );
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION presentar_rendicion IS 'Presenta una rendición con el monto rendido';

-- =====================================================
-- 7. FUNCIÓN RPC: Revisar rendición (Admin)
-- =====================================================

CREATE OR REPLACE FUNCTION revisar_rendicion(
  p_rendicion_id BIGINT,
  p_accion VARCHAR, -- 'aprobar', 'rechazar', 'observar'
  p_observaciones TEXT DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_nuevo_estado VARCHAR;
  v_recorrido_id BIGINT;
BEGIN
  -- Solo admin puede revisar
  IF NOT es_admin_rendiciones() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo administradores pueden revisar rendiciones');
  END IF;

  -- Verificar que la rendición está presentada
  IF NOT EXISTS (SELECT 1 FROM rendiciones WHERE id = p_rendicion_id AND estado = 'presentada') THEN
    RETURN jsonb_build_object('success', false, 'error', 'Rendición no encontrada o no está presentada');
  END IF;

  -- Determinar nuevo estado
  v_nuevo_estado := CASE p_accion
    WHEN 'aprobar' THEN 'aprobada'
    WHEN 'rechazar' THEN 'rechazada'
    WHEN 'observar' THEN 'con_observaciones'
    ELSE NULL
  END;

  IF v_nuevo_estado IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Acción no válida');
  END IF;

  -- Obtener recorrido_id
  SELECT recorrido_id INTO v_recorrido_id FROM rendiciones WHERE id = p_rendicion_id;

  -- Actualizar rendición
  UPDATE rendiciones SET
    estado = v_nuevo_estado,
    observaciones_admin = p_observaciones,
    revisada_at = NOW(),
    revisada_por = auth.uid(),
    updated_at = NOW()
  WHERE id = p_rendicion_id;

  -- Si se aprueba, marcar el recorrido como completado
  IF v_nuevo_estado = 'aprobada' THEN
    UPDATE recorridos SET
      estado = 'completado',
      completed_at = NOW()
    WHERE id = v_recorrido_id;
  END IF;

  RETURN jsonb_build_object('success', true, 'nuevo_estado', v_nuevo_estado);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

COMMENT ON FUNCTION revisar_rendicion IS 'Permite al admin aprobar, rechazar u observar una rendición';

-- =====================================================
-- 8. FUNCIÓN RPC: Obtener estadísticas de rendiciones
-- =====================================================

CREATE OR REPLACE FUNCTION obtener_estadisticas_rendiciones(
  p_fecha_desde DATE DEFAULT NULL,
  p_fecha_hasta DATE DEFAULT NULL,
  p_transportista_id UUID DEFAULT NULL
)
RETURNS JSONB AS $$
DECLARE
  v_resultado JSONB;
BEGIN
  SELECT jsonb_build_object(
    'total', COUNT(*),
    'pendientes', COUNT(*) FILTER (WHERE estado IN ('pendiente', 'presentada')),
    'aprobadas', COUNT(*) FILTER (WHERE estado = 'aprobada'),
    'rechazadas', COUNT(*) FILTER (WHERE estado = 'rechazada'),
    'con_observaciones', COUNT(*) FILTER (WHERE estado = 'con_observaciones'),
    'total_efectivo_esperado', COALESCE(SUM(total_efectivo_esperado), 0),
    'total_rendido', COALESCE(SUM(monto_rendido) FILTER (WHERE estado = 'aprobada'), 0),
    'total_diferencias', COALESCE(SUM(diferencia) FILTER (WHERE estado = 'aprobada'), 0),
    'por_transportista', (
      SELECT jsonb_agg(jsonb_build_object(
        'transportista_id', transportista_id,
        'transportista_nombre', p.nombre,
        'rendiciones', cnt,
        'total_rendido', total_rend,
        'total_diferencias', total_dif
      ))
      FROM (
        SELECT
          r.transportista_id,
          COUNT(*) as cnt,
          SUM(r.monto_rendido) as total_rend,
          SUM(r.diferencia) as total_dif
        FROM rendiciones r
        WHERE (p_fecha_desde IS NULL OR r.fecha >= p_fecha_desde)
          AND (p_fecha_hasta IS NULL OR r.fecha <= p_fecha_hasta)
          AND (p_transportista_id IS NULL OR r.transportista_id = p_transportista_id)
        GROUP BY r.transportista_id
      ) t
      JOIN perfiles p ON p.id = t.transportista_id
    )
  ) INTO v_resultado
  FROM rendiciones
  WHERE (p_fecha_desde IS NULL OR fecha >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR fecha <= p_fecha_hasta)
    AND (p_transportista_id IS NULL OR transportista_id = p_transportista_id);

  RETURN v_resultado;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- =====================================================
-- 9. VISTA: Resumen de rendiciones
-- =====================================================

CREATE OR REPLACE VIEW vista_rendiciones AS
SELECT
  r.id,
  r.recorrido_id,
  r.transportista_id,
  p.nombre AS transportista_nombre,
  r.fecha,
  r.total_efectivo_esperado,
  r.total_otros_medios,
  r.monto_rendido,
  r.diferencia,
  r.estado,
  r.justificacion_transportista,
  r.observaciones_admin,
  r.presentada_at,
  r.revisada_at,
  pr.nombre AS revisada_por_nombre,
  rec.total_pedidos,
  rec.pedidos_entregados,
  rec.total_facturado,
  rec.total_cobrado,
  (SELECT COUNT(*) FROM rendicion_ajustes ra WHERE ra.rendicion_id = r.id) AS total_ajustes,
  r.created_at,
  r.updated_at
FROM rendiciones r
JOIN perfiles p ON p.id = r.transportista_id
JOIN recorridos rec ON rec.id = r.recorrido_id
LEFT JOIN perfiles pr ON pr.id = r.revisada_por
ORDER BY r.fecha DESC, r.created_at DESC;

COMMENT ON VIEW vista_rendiciones IS 'Vista de rendiciones con información del transportista y recorrido';

-- =====================================================
-- 10. TRIGGER: Actualizar updated_at
-- =====================================================

CREATE OR REPLACE FUNCTION update_rendiciones_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_rendiciones_updated_at ON rendiciones;
CREATE TRIGGER trigger_rendiciones_updated_at
  BEFORE UPDATE ON rendiciones
  FOR EACH ROW
  EXECUTE FUNCTION update_rendiciones_updated_at();
