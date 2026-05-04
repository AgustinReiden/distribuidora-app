-- Migración 030 — Bot Telegram: schema para tomar pedido (write tool fase 1)
--
-- Componentes:
--   1. pedidos.canal (varchar) — distingue 'app' vs 'bot' para filtrar/auditar.
--   2. bot_pedidos_pendientes — tabla efímera con TTL 10 min para anti doble-click
--      y para que el callback del Confirmar tenga datos confiables.
--   3. crear_pedido_completo_bot — variante de crear_pedido_completo que NO
--      chequea auth.uid() (las edge functions corren con service_role) y
--      acepta los items desde bot_pedidos_pendientes vía confirmacion_id.
--
-- NOTA: el cálculo de precios mayoristas/promos lo hace el edge function en
-- TS (reusa src/utils/precioMayorista.ts y promociones.ts). El RPC solo
-- INSERTa pedidos+items con los precios ya pre-computados, igual que
-- crear_pedido_completo (que recibe precio_unitario en el JSONB).

-- ============================================================================
-- 1. Columna canal
-- ============================================================================
ALTER TABLE public.pedidos
  ADD COLUMN IF NOT EXISTS canal VARCHAR(20) NOT NULL DEFAULT 'app';

COMMENT ON COLUMN public.pedidos.canal IS
  'Canal de origen del pedido: app | bot. Forward-compat para futuros canales (whatsapp, etc).';

-- Index parcial — solo para queries del filtro "cargados via bot" (no necesitamos
-- indexar el caso common 'app' que es 99% del tráfico).
CREATE INDEX IF NOT EXISTS idx_pedidos_canal_no_app
  ON public.pedidos (canal, sucursal_id)
  WHERE canal <> 'app';

-- ============================================================================
-- 2. Tabla bot_pedidos_pendientes (efímera, TTL 10 min)
-- ============================================================================
-- Cada vez que el bot muestra un resumen para confirmar, persiste un row acá.
-- El callback de Confirmar lee el row, valida (no expirado, no consumido,
-- pertenece al usuario) y ejecuta el INSERT real del pedido.

CREATE TABLE IF NOT EXISTS public.bot_pedidos_pendientes (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  perfil_id UUID NOT NULL,
  sucursal_id BIGINT NOT NULL,
  cliente_id BIGINT NOT NULL,
  -- items: JSONB con shape [{producto_id, cantidad, precio_unitario, neto_unitario,
  -- iva_unitario, impuestos_internos_unitario, porcentaje_iva, es_bonificacion,
  -- promocion_id}, ...] — mismo shape que el p_items que crear_pedido_completo
  -- ya espera de la app web.
  items JSONB NOT NULL,
  total NUMERIC NOT NULL,
  total_neto NUMERIC,
  total_iva NUMERIC NOT NULL DEFAULT 0,
  forma_pago TEXT NOT NULL DEFAULT 'efectivo',
  notas TEXT,
  consumido BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at TIMESTAMPTZ NOT NULL DEFAULT (now() + INTERVAL '10 minutes')
);

COMMENT ON TABLE public.bot_pedidos_pendientes IS
  'Borradores de pedido del bot Telegram. TTL 10 min. consumido=true al crear el pedido real.';

-- Index parcial: solo nos interesan los no-consumidos no-expirados.
CREATE INDEX IF NOT EXISTS idx_bot_pedidos_pendientes_perfil_active
  ON public.bot_pedidos_pendientes (perfil_id, expires_at)
  WHERE NOT consumido;

ALTER TABLE public.bot_pedidos_pendientes OWNER TO postgres;
REVOKE ALL ON public.bot_pedidos_pendientes FROM PUBLIC;
GRANT SELECT, INSERT, UPDATE ON public.bot_pedidos_pendientes TO service_role;

-- ============================================================================
-- 3. crear_pedido_completo_bot
-- ============================================================================
-- Variante de crear_pedido_completo (mig 000_baseline:1013) sin el check de
-- auth.uid() (porque la edge function corre con service_role, sin sesión).
-- Recibe el confirmacion_id, lee bot_pedidos_pendientes, valida, y ejecuta
-- el INSERT clonando la lógica de crear_pedido_completo (incluido el
-- auto-ajuste de promos).
--
-- Devuelve {success: bool, pedido_id?, total?, error?, errores?}.

CREATE OR REPLACE FUNCTION public.crear_pedido_completo_bot(
  p_perfil_id      UUID,
  p_confirmacion_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pendiente RECORD;
  v_user_role TEXT;
  v_pedido_id INT;
  v_fecha_pedido DATE := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  v_fecha_entrega DATE := (v_fecha_pedido + INTERVAL '1 day')::date;
  v_cantidades_totales JSONB := '{}'::JSONB;
  v_cant_acumulada INT;
  v_regalo_mueve_stock BOOLEAN;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  errores TEXT[] := '{}';
  item JSONB;
  v_producto_id INT;
  v_cantidad INT;
  v_precio_unitario DECIMAL;
  v_es_bonificacion BOOLEAN;
  v_promocion_id BIGINT;
  v_neto_unitario DECIMAL;
  v_iva_unitario DECIMAL;
  v_imp_internos_unitario DECIMAL;
  v_porcentaje_iva DECIMAL;
  v_promo RECORD;
  v_usos_pendientes_actual INT;
  v_bloques_completos INT;
  v_ajustar_usos INT;
  v_ajustar_stock INT;
  v_stock_ajuste_anterior INT;
  v_stock_ajuste_nuevo INT;
  v_ajuste_producto_nombre TEXT;
  v_merma_id BIGINT;
BEGIN
  -- 1) Validar el confirmacion_id
  SELECT * INTO v_pendiente
    FROM bot_pedidos_pendientes
    WHERE id = p_confirmacion_id
    FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Confirmación inválida');
  END IF;

  IF v_pendiente.consumido THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido ya creado, revisalo en la app');
  END IF;

  IF v_pendiente.expires_at < now() THEN
    RETURN jsonb_build_object('success', false, 'error', 'La confirmación expiró, hacé el pedido de nuevo');
  END IF;

  IF v_pendiente.perfil_id <> p_perfil_id THEN
    -- Defensa: confirmacion_id no pertenece al usuario que llama.
    RETURN jsonb_build_object('success', false, 'error', 'Confirmación no pertenece al usuario');
  END IF;

  -- 2) Validar rol del perfil (admin, encargado o preventista)
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_perfil_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No tiene permisos para crear pedidos');
  END IF;

  -- 3) Re-check de stock atómico (entre preview y confirmar pueden haber pasado segundos)
  -- Sumamos cantidades por producto contemplando bonificaciones que mueven stock.
  FOR item IN SELECT * FROM jsonb_array_elements(v_pendiente.items) LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad inválida para producto ID ' || v_producto_id);
      CONTINUE;
    END IF;

    IF v_es_bonificacion THEN
      v_promocion_id := (item->>'promocion_id')::BIGINT;
      IF v_promocion_id IS NOT NULL THEN
        SELECT regalo_mueve_stock INTO v_regalo_mueve_stock
          FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
        IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
          v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
          v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);
        END IF;
      END IF;
    ELSE
      v_cant_acumulada := COALESCE((v_cantidades_totales->>v_producto_id::TEXT)::INT, 0) + v_cantidad;
      v_cantidades_totales := v_cantidades_totales || jsonb_build_object(v_producto_id::TEXT, v_cant_acumulada);
    END IF;
  END LOOP;

  FOR v_producto_id IN SELECT (key)::INT FROM jsonb_each_text(v_cantidades_totales) LOOP
    v_cantidad := (v_cantidades_totales->>v_producto_id::TEXT)::INT;
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;
    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN
      errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  -- 4) INSERT pedidos con canal='bot'
  INSERT INTO pedidos (
    cliente_id, fecha, total, total_neto, total_iva, tipo_factura,
    estado, usuario_id, stock_descontado, notas, forma_pago,
    estado_pago, fecha_entrega_programada, sucursal_id, canal
  )
  VALUES (
    v_pendiente.cliente_id, v_fecha_pedido, v_pendiente.total,
    COALESCE(v_pendiente.total_neto, v_pendiente.total),
    COALESCE(v_pendiente.total_iva, 0),
    'ZZ',
    'pendiente', p_perfil_id, true, v_pendiente.notas, v_pendiente.forma_pago,
    'pendiente', v_fecha_entrega, v_pendiente.sucursal_id, 'bot'
  )
  RETURNING id INTO v_pedido_id;

  -- 5) INSERT pedido_items + UPDATE stock (mismo bloque que crear_pedido_completo)
  FOR item IN SELECT * FROM jsonb_array_elements(v_pendiente.items) LOOP
    v_producto_id := (item->>'producto_id')::INT;
    v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (item->>'promocion_id')::BIGINT;
    v_neto_unitario := (item->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((item->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((item->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((item->>'porcentaje_iva')::DECIMAL, 0);

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id, neto_unitario, iva_unitario,
      impuestos_internos_unitario, porcentaje_iva, sucursal_id
    ) VALUES (
      v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario,
      v_cantidad * v_precio_unitario,
      v_es_bonificacion, v_promocion_id, v_neto_unitario, v_iva_unitario,
      v_imp_internos_unitario, v_porcentaje_iva, v_pendiente.sucursal_id
    );

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad
        WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id;
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad
          WHERE id = v_producto_id AND sucursal_id = v_pendiente.sucursal_id;
      END IF;
    END IF;

    -- Auto-ajuste de promos (mismo flujo que crear_pedido_completo)
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad
        WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;

      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes
        INTO v_promo
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;

      IF v_promo.ajuste_automatico
         AND v_promo.ajuste_producto_id IS NOT NULL
         AND COALESCE(v_promo.unidades_por_bloque, 0) > 0
         AND COALESCE(v_promo.stock_por_bloque, 0) > 0 THEN
        v_usos_pendientes_actual := v_promo.usos_pendientes;
        v_bloques_completos := v_usos_pendientes_actual / v_promo.unidades_por_bloque;
        IF v_bloques_completos > 0 THEN
          v_ajustar_usos := v_bloques_completos * v_promo.unidades_por_bloque;
          v_ajustar_stock := v_bloques_completos * v_promo.stock_por_bloque;

          SELECT stock, nombre INTO v_stock_ajuste_anterior, v_ajuste_producto_nombre
            FROM productos WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_pendiente.sucursal_id FOR UPDATE;

          IF v_stock_ajuste_anterior IS NULL THEN
            RAISE EXCEPTION 'Auto-ajuste: producto destino no encontrado (promo %)', v_promocion_id;
          END IF;
          IF v_stock_ajuste_anterior < v_ajustar_stock THEN
            RAISE EXCEPTION 'Auto-ajuste: stock insuficiente en % (disponible: %, requerido: %)',
              v_ajuste_producto_nombre, v_stock_ajuste_anterior, v_ajustar_stock;
          END IF;

          v_stock_ajuste_nuevo := v_stock_ajuste_anterior - v_ajustar_stock;

          INSERT INTO mermas_stock (
            producto_id, cantidad, motivo, observaciones,
            stock_anterior, stock_nuevo, usuario_id, sucursal_id
          ) VALUES (
            v_promo.ajuste_producto_id, v_ajustar_stock, 'promociones',
            'Auto-ajuste (Promo: ' || v_promo.nombre || ', Pedido #' || v_pedido_id || ' via bot)',
            v_stock_ajuste_anterior, v_stock_ajuste_nuevo, p_perfil_id, v_pendiente.sucursal_id
          ) RETURNING id INTO v_merma_id;

          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
            WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_pendiente.sucursal_id;

          INSERT INTO promo_ajustes (
            promocion_id, usos_ajustados, unidades_ajustadas, producto_id,
            merma_id, usuario_id, observaciones, sucursal_id
          ) VALUES (
            v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_promo.ajuste_producto_id,
            v_merma_id, p_perfil_id,
            'Auto-ajuste por pedido #' || v_pedido_id || ' via bot', v_pendiente.sucursal_id
          );

          UPDATE promociones
            SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
            WHERE id = v_promocion_id AND sucursal_id = v_pendiente.sucursal_id;
        END IF;
      END IF;
    END IF;
  END LOOP;

  -- 6) Marcar pendiente como consumido (dentro de la misma transacción)
  UPDATE bot_pedidos_pendientes SET consumido = TRUE WHERE id = p_confirmacion_id;

  RETURN jsonb_build_object(
    'success', true,
    'pedido_id', v_pedido_id,
    'total', v_pendiente.total
  );
END;
$$;

ALTER FUNCTION public.crear_pedido_completo_bot(UUID, UUID) OWNER TO postgres;
REVOKE ALL    ON FUNCTION public.crear_pedido_completo_bot(UUID, UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.crear_pedido_completo_bot(UUID, UUID) TO service_role;
