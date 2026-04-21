-- Migración 038: Sistema de Promociones Temporales
--
-- Soporta dos tipos de promoción:
--   1. bonificacion: Compra X unidades, lleva Y gratis (acumulable)
--      Ejemplo: Manaos Citrus — cada 12 uds comprás, te regalan 2
--   2. precio_par: Descuento por pares con umbral de precio completo
--      Ejemplo: Alfajores — de a 2 salen $4.000 c/u, 1 suelto $4.200, 4+ todo $4.000
--
-- Las bonificaciones se almacenan como líneas separadas en pedido_items con es_bonificacion=true
-- El stock se descuenta para TODOS los items incluyendo bonificaciones.

-- =============================================================================
-- 1. Tabla de promociones
-- =============================================================================

CREATE TABLE IF NOT EXISTS promociones (
  id BIGSERIAL PRIMARY KEY,
  nombre VARCHAR(200) NOT NULL,
  tipo VARCHAR(30) NOT NULL CHECK (tipo IN ('bonificacion', 'precio_par')),
  activo BOOLEAN DEFAULT true,
  fecha_inicio DATE NOT NULL,
  fecha_fin DATE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_promociones_activas ON promociones(activo, fecha_inicio, fecha_fin);

-- =============================================================================
-- 2. Productos de cada promoción
-- =============================================================================

CREATE TABLE IF NOT EXISTS promocion_productos (
  id BIGSERIAL PRIMARY KEY,
  promocion_id BIGINT NOT NULL REFERENCES promociones(id) ON DELETE CASCADE,
  producto_id BIGINT NOT NULL REFERENCES productos(id) ON DELETE CASCADE,
  UNIQUE(promocion_id, producto_id)
);

CREATE INDEX IF NOT EXISTS idx_pp_producto ON promocion_productos(producto_id);

-- =============================================================================
-- 3. Reglas de cada promoción (key-value)
-- =============================================================================
--
-- Bonificación:
--   cantidad_compra = 12       (comprar esta cantidad)
--   cantidad_bonificacion = 2  (recibir esta cantidad gratis)
--
-- Precio por pares:
--   precio_regular = 4200      (precio sin promo / unidad suelta)
--   precio_promo = 4000        (precio con promo / par completo)
--   umbral_todo_promo = 4      (a partir de esta qty, todo al precio promo)

CREATE TABLE IF NOT EXISTS promocion_reglas (
  id BIGSERIAL PRIMARY KEY,
  promocion_id BIGINT NOT NULL REFERENCES promociones(id) ON DELETE CASCADE,
  clave VARCHAR(50) NOT NULL,
  valor NUMERIC NOT NULL,
  UNIQUE(promocion_id, clave)
);

-- =============================================================================
-- 4. Columna es_bonificacion en pedido_items
-- =============================================================================

ALTER TABLE pedido_items ADD COLUMN IF NOT EXISTS es_bonificacion BOOLEAN DEFAULT false;

-- =============================================================================
-- 5. RLS — mismo patrón que grupos_precio
-- =============================================================================

ALTER TABLE promociones ENABLE ROW LEVEL SECURITY;
ALTER TABLE promocion_productos ENABLE ROW LEVEL SECURITY;
ALTER TABLE promocion_reglas ENABLE ROW LEVEL SECURITY;

-- promociones
DROP POLICY IF EXISTS "Admin full access promociones" ON promociones;
CREATE POLICY "Admin full access promociones" ON promociones
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

DROP POLICY IF EXISTS "Users can view promociones" ON promociones;
CREATE POLICY "Users can view promociones" ON promociones
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  );

-- promocion_productos
DROP POLICY IF EXISTS "Admin full access promocion_productos" ON promocion_productos;
CREATE POLICY "Admin full access promocion_productos" ON promocion_productos
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

DROP POLICY IF EXISTS "Users can view promocion_productos" ON promocion_productos;
CREATE POLICY "Users can view promocion_productos" ON promocion_productos
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  );

-- promocion_reglas
DROP POLICY IF EXISTS "Admin full access promocion_reglas" ON promocion_reglas;
CREATE POLICY "Admin full access promocion_reglas" ON promocion_reglas
  FOR ALL USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin')
  );

DROP POLICY IF EXISTS "Users can view promocion_reglas" ON promocion_reglas;
CREATE POLICY "Users can view promocion_reglas" ON promocion_reglas
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND activo = true)
  );

-- =============================================================================
-- 6. Trigger para updated_at
-- =============================================================================

CREATE OR REPLACE FUNCTION update_promociones_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trigger_update_promociones_timestamp ON promociones;
CREATE TRIGGER trigger_update_promociones_timestamp
  BEFORE UPDATE ON promociones
  FOR EACH ROW
  EXECUTE FUNCTION update_promociones_updated_at();

-- =============================================================================
-- 7. Actualizar RPC crear_pedido_completo para soportar bonificaciones y subtotal override
-- =============================================================================

CREATE OR REPLACE FUNCTION public.crear_pedido_completo(
  p_cliente_id integer,
  p_total numeric,
  p_usuario_id uuid,
  p_items jsonb,
  p_notas text DEFAULT NULL::text,
  p_forma_pago text DEFAULT 'efectivo'::text,
  p_estado_pago text DEFAULT 'pendiente'::text,
  p_fecha date DEFAULT CURRENT_DATE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_pedido_id INT;
  item JSONB;
  v_producto_id INT;
  v_cantidad INT;
  v_precio_unitario DECIMAL;
  v_es_bonificacion BOOLEAN;
  v_subtotal_override DECIMAL;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  errores TEXT[] := '{}';
  v_user_role TEXT;
  -- Para acumular cantidades por producto (regular + bonificación)
  v_cantidades_totales JSONB := '{}'::JSONB;
  v_cant_acumulada INT;
BEGIN
  -- Authorization check: only admin and preventista can create orders
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos'));
  END IF;

  -- 1. Acumular cantidades totales por producto (sumando regular + bonificación)
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad inválida para producto ID ' || v_producto_id || ': debe ser mayor a 0');
      CONTINUE;
    END IF;

    v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
    v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);
  END LOOP;

  -- 2. Verificar stock usando cantidades acumuladas (con bloqueo)
  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales)
  LOOP
    v_cantidad := (v_cantidades_totales->>v_producto_id::TEXT)::INT;

    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
    FROM productos
    WHERE id = v_producto_id
    FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN
      errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  -- 3. Crear el pedido con fecha seleccionada
  INSERT INTO pedidos (cliente_id, fecha, total, estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago)
  VALUES (p_cliente_id, p_fecha, p_total, 'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago)
  RETURNING id INTO v_pedido_id;

  -- 4. Crear items y descontar stock
  FOR item IN SELECT * FROM jsonb_array_elements(p_items)
  LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_subtotal_override := (item->>'subtotal')::DECIMAL;

    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion)
    VALUES (
      v_pedido_id,
      v_producto_id,
      v_cantidad,
      v_precio_unitario,
      COALESCE(v_subtotal_override, v_cantidad * v_precio_unitario),
      v_es_bonificacion
    );

    -- Stock se descuenta para TODOS los items (incluyendo bonificaciones)
    UPDATE productos
    SET stock = stock - v_cantidad
    WHERE id = v_producto_id;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$function$;

-- =============================================================================
-- 8. Actualizar RPC actualizar_pedido_items para soportar bonificaciones y subtotal
-- =============================================================================

CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(
  p_pedido_id BIGINT,
  p_items_nuevos JSONB,
  p_usuario_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_item_original RECORD;
  v_item_nuevo JSONB;
  v_producto_id INT;
  v_cantidad_original INT;
  v_cantidad_nueva INT;
  v_precio_unitario DECIMAL;
  v_es_bonificacion BOOLEAN;
  v_subtotal_override DECIMAL;
  v_diferencia INT;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_total_nuevo DECIMAL := 0;
  v_total_anterior DECIMAL;
  v_errores TEXT[] := '{}';
  v_items_originales JSONB;
  -- Para acumular cantidades por producto
  v_cantidades_nuevas JSONB := '{}'::JSONB;
  v_cantidades_originales JSONB := '{}'::JSONB;
  v_cant_acum INT;
BEGIN
  SELECT total INTO v_total_anterior FROM pedidos WHERE id = p_pedido_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  -- Guardar items originales para historial
  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id,
    'cantidad', cantidad,
    'precio_unitario', precio_unitario,
    'es_bonificacion', es_bonificacion
  )) INTO v_items_originales
  FROM pedido_items WHERE pedido_id = p_pedido_id;

  -- Acumular cantidades originales por producto
  FOR v_item_original IN
    SELECT producto_id, SUM(cantidad) as cant_total
    FROM pedido_items WHERE pedido_id = p_pedido_id
    GROUP BY producto_id
  LOOP
    v_cantidades_originales := v_cantidades_originales || jsonb_build_object(
      v_item_original.producto_id::TEXT, v_item_original.cant_total
    );
  END LOOP;

  -- Acumular cantidades nuevas por producto
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos)
  LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_cant_acum := COALESCE((v_cantidades_nuevas->>v_producto_id::TEXT)::INT, 0) + v_cantidad_nueva;
    v_cantidades_nuevas := v_cantidades_nuevas || jsonb_build_object(v_producto_id::TEXT, v_cant_acum);
  END LOOP;

  -- Validar stock para incrementos (comparando totales acumulados por producto)
  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_nuevas)
  LOOP
    v_cantidad_nueva := (v_cantidades_nuevas->>v_producto_id::TEXT)::INT;
    v_cantidad_original := COALESCE((v_cantidades_originales->>v_producto_id::TEXT)::INT, 0);
    v_diferencia := v_cantidad_nueva - v_cantidad_original;

    IF v_diferencia > 0 THEN
      SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id FOR UPDATE;

      IF v_stock_actual IS NULL THEN
        v_errores := array_append(v_errores, 'Producto ID ' || v_producto_id || ' no encontrado');
      ELSIF v_stock_actual < v_diferencia THEN
        v_errores := array_append(v_errores,
          COALESCE(v_producto_nombre, 'Producto ' || v_producto_id) ||
          ': stock insuficiente (disponible: ' || v_stock_actual ||
          ', adicional requerido: ' || v_diferencia || ')');
      END IF;
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(v_errores));
  END IF;

  -- Restaurar stock de todos los items originales
  FOR v_item_original IN
    SELECT producto_id, cantidad FROM pedido_items WHERE pedido_id = p_pedido_id
  LOOP
    UPDATE productos SET stock = stock + v_item_original.cantidad
    WHERE id = v_item_original.producto_id;
  END LOOP;

  -- Eliminar items actuales
  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id;

  -- Insertar nuevos items y descontar stock
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos)
  LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_subtotal_override := (v_item_nuevo->>'subtotal')::DECIMAL;

    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion)
    VALUES (
      p_pedido_id,
      v_producto_id,
      v_cantidad_nueva,
      v_precio_unitario,
      COALESCE(v_subtotal_override, v_cantidad_nueva * v_precio_unitario),
      v_es_bonificacion
    );

    -- Solo sumar al total si NO es bonificación
    IF NOT v_es_bonificacion THEN
      v_total_nuevo := v_total_nuevo + COALESCE(v_subtotal_override, v_cantidad_nueva * v_precio_unitario);
    END IF;

    UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id;
  END LOOP;

  UPDATE pedidos SET total = v_total_nuevo, updated_at = NOW() WHERE id = p_pedido_id;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), p_items_nuevos::TEXT);

  IF v_total_anterior <> v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT);
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$function$;

-- =============================================================================
-- 9. Comentarios
-- =============================================================================

COMMENT ON TABLE promociones IS 'Promociones temporales con fecha inicio/fin';
COMMENT ON TABLE promocion_productos IS 'Productos asociados a cada promoción';
COMMENT ON TABLE promocion_reglas IS 'Parámetros key-value de cada promoción (cantidad_compra, precio_promo, etc.)';
COMMENT ON COLUMN pedido_items.es_bonificacion IS 'true = unidad gratis por promoción (precio_unitario=0, stock se descuenta)';
