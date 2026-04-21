-- =====================================================
-- 000_baseline.sql
-- Dump fiel del schema 'public' de ManaosApp (ref: hmuchlzmuqqxcldbzkgc)
-- Generado: 2026-04-21 con `supabase db dump` (Postgres 17.6.1)
-- Reemplaza 001-070 + hotfixes datados, ahora en migrations/archive/
-- Futuras migraciones: 001_*.sql, 002_*.sql, etc.
-- =====================================================

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE TYPE "public"."orden_entrega_item" AS (
	"pedido_id" bigint,
	"orden" integer
);


ALTER TYPE "public"."orden_entrega_item" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."actualizar_estado_pago_pedido"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Si el monto pagado es >= al total, marcar como pagado
  IF NEW.monto_pagado >= NEW.total THEN
    NEW.estado_pago := 'pagado';
  -- Si hay algo pagado pero no todo, marcar como parcial
  ELSIF NEW.monto_pagado > 0 THEN
    NEW.estado_pago := 'parcial';
  -- Si no hay nada pagado, marcar como pendiente
  ELSE
    NEW.estado_pago := 'pendiente';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."actualizar_estado_pago_pedido"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."actualizar_orden_entrega_batch"("ordenes" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  item JSONB;
BEGIN
  -- Iterar sobre cada item del array JSON
  FOR item IN SELECT * FROM jsonb_array_elements(ordenes)
  LOOP
    UPDATE pedidos
    SET orden_entrega = (item->>'orden')::INTEGER
    WHERE id = (item->>'pedido_id')::BIGINT;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."actualizar_orden_entrega_batch"("ordenes" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."actualizar_orden_entrega_batch"("ordenes" "public"."orden_entrega_item"[]) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  item orden_entrega_item;
BEGIN
  -- Iterar sobre cada item y actualizar
  FOREACH item IN ARRAY ordenes
  LOOP
    UPDATE pedidos
    SET orden_entrega = item.orden
    WHERE id = item.pedido_id;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."actualizar_orden_entrega_batch"("ordenes" "public"."orden_entrega_item"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."actualizar_pedido_items"("p_pedido_id" bigint, "p_items_nuevos" "jsonb", "p_usuario_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item_nuevo JSONB;
  v_producto_id INT;
  v_cantidad_original INT;
  v_cantidad_nueva INT;
  v_diferencia INT;
  v_es_bonificacion BOOLEAN;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_total_nuevo DECIMAL := 0;
  v_total_neto_nuevo DECIMAL := 0;
  v_total_iva_nuevo DECIMAL := 0;
  v_total_anterior DECIMAL;
  v_errores TEXT[] := '{}';
  v_items_originales JSONB;
  v_user_role TEXT;
  v_neto_unitario DECIMAL;
  v_iva_unitario DECIMAL;
  v_imp_internos_unitario DECIMAL;
  v_porcentaje_iva DECIMAL;
  v_precio_unitario DECIMAL;
  v_promocion_id BIGINT;
  v_regalo_mueve_stock BOOLEAN;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se pudo determinar la sucursal activa']);
  END IF;

  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['ID de usuario no coincide con la sesion autenticada']);
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No autorizado']);
  END IF;

  SELECT total INTO v_total_anterior FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false)))
  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;

    IF v_es_bonificacion THEN
      IF v_promocion_id IS NULL THEN CONTINUE; END IF;
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF NOT COALESCE(v_regalo_mueve_stock, FALSE) THEN CONTINUE; END IF;
    END IF;

    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = v_es_bonificacion
      AND sucursal_id = v_sucursal;

    v_diferencia := v_cantidad_nueva - COALESCE(v_cantidad_original, 0);

    IF v_diferencia > 0 THEN
      SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

      IF v_stock_actual IS NULL THEN
        v_errores := array_append(v_errores, 'Producto ID ' || v_producto_id || ' no encontrado');
      ELSIF v_stock_actual < v_diferencia THEN
        v_errores := array_append(v_errores, COALESCE(v_producto_nombre, 'Producto ' || v_producto_id)
          || ': stock insuficiente (disponible: ' || v_stock_actual || ', adicional: ' || v_diferencia || ')');
      END IF;
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(v_errores));
  END IF;

  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id
    AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = false
    AND p.id = pi.producto_id
    AND p.sucursal_id = v_sucursal;

  UPDATE productos p
  SET stock = p.stock + pi.cantidad
  FROM pedido_items pi
  JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
  WHERE pi.pedido_id = p_pedido_id
    AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND COALESCE(pr.regalo_mueve_stock, FALSE) = TRUE
    AND p.id = pi.producto_id
    AND p.sucursal_id = v_sucursal;

  UPDATE promociones pr
  SET usos_pendientes = GREATEST(pr.usos_pendientes - pi.cantidad, 0)
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id
    AND pi.sucursal_id = v_sucursal
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND pr.id = pi.promocion_id
    AND pr.sucursal_id = v_sucursal;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;

  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_precio_unitario := (v_item_nuevo->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (v_item_nuevo->>'promocion_id')::BIGINT;
    v_neto_unitario := (v_item_nuevo->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((v_item_nuevo->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((v_item_nuevo->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((v_item_nuevo->>'porcentaje_iva')::DECIMAL, 0);

    INSERT INTO pedido_items (
      pedido_id, producto_id, cantidad, precio_unitario, subtotal,
      es_bonificacion, promocion_id,
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva,
      sucursal_id
    ) VALUES (
      p_pedido_id, v_producto_id, v_cantidad_nueva, v_precio_unitario,
      v_cantidad_nueva * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva,
      v_sucursal
    );

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad_nueva
      WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      v_total_nuevo := v_total_nuevo + (v_cantidad_nueva * v_precio_unitario);
      v_total_neto_nuevo := v_total_neto_nuevo + (v_cantidad_nueva * COALESCE(v_neto_unitario, v_precio_unitario));
      v_total_iva_nuevo := v_total_iva_nuevo + (v_cantidad_nueva * v_iva_unitario);
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad_nueva
        WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      END IF;
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva
      WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  UPDATE pedidos SET
    total = v_total_nuevo,
    total_neto = v_total_neto_nuevo,
    total_iva = v_total_iva_nuevo,
    updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), p_items_nuevos::TEXT, v_sucursal);

  IF v_total_anterior IS DISTINCT FROM v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT, v_sucursal);
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$$;


ALTER FUNCTION "public"."actualizar_pedido_items"("p_pedido_id" bigint, "p_items_nuevos" "jsonb", "p_usuario_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."actualizar_precios_masivo"("p_productos" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_item JSONB;
  v_actualizados INT := 0;
  v_errores TEXT[] := '{}';
  v_producto_id INT;
BEGIN
  -- SECURITY FIX: Solo admins pueden actualizar precios masivamente
  IF NOT es_admin() THEN
    RETURN jsonb_build_object(
      'success', false,
      'actualizados', 0,
      'errores', jsonb_build_array('No autorizado: Solo administradores pueden actualizar precios')
    );
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_productos)
  LOOP
    BEGIN
      v_producto_id := (v_item->>'producto_id')::INT;

      UPDATE productos
      SET
        precio_sin_iva = COALESCE((v_item->>'precio_neto')::DECIMAL, precio_sin_iva),
        impuestos_internos = COALESCE((v_item->>'imp_internos')::DECIMAL, impuestos_internos),
        precio = COALESCE((v_item->>'precio_final')::DECIMAL, precio),
        updated_at = NOW()
      WHERE id = v_producto_id;

      IF FOUND THEN
        v_actualizados := v_actualizados + 1;
      ELSE
        v_errores := array_append(v_errores,
          'Producto ID ' || v_producto_id || ' no encontrado');
      END IF;
    EXCEPTION WHEN OTHERS THEN
      v_errores := array_append(v_errores,
        'Error en producto ID ' || COALESCE(v_producto_id::TEXT, 'desconocido') || ': ' || SQLERRM);
    END;
  END LOOP;

  RETURN jsonb_build_object(
    'success', array_length(v_errores, 1) IS NULL,
    'actualizados', v_actualizados,
    'errores', COALESCE(to_jsonb(v_errores), '[]'::jsonb)
  );
END;
$$;


ALTER FUNCTION "public"."actualizar_precios_masivo"("p_productos" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."actualizar_precios_masivo"("p_productos" "jsonb") IS 'Actualiza precios de múltiples productos. SOLO ADMINS. Recibe array de {producto_id, precio_neto, imp_internos, precio_final}';



CREATE OR REPLACE FUNCTION "public"."actualizar_recorrido_entrega"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_recorrido_id BIGINT;
  v_monto_pedido DECIMAL;
BEGIN
  -- Buscar si el pedido está en algún recorrido activo
  SELECT rp.recorrido_id INTO v_recorrido_id
  FROM recorrido_pedidos rp
  JOIN recorridos r ON r.id = rp.recorrido_id
  WHERE rp.pedido_id = NEW.id
    AND r.fecha = CURRENT_DATE
    AND r.estado = 'en_curso'
  LIMIT 1;

  IF v_recorrido_id IS NOT NULL THEN
    -- Actualizar el estado de entrega del pedido en el recorrido
    IF NEW.estado = 'entregado' AND (OLD.estado IS NULL OR OLD.estado != 'entregado') THEN
      UPDATE recorrido_pedidos
      SET estado_entrega = 'entregado', hora_entrega = NOW()
      WHERE recorrido_id = v_recorrido_id AND pedido_id = NEW.id;

      -- Actualizar contadores del recorrido
      UPDATE recorridos
      SET
        pedidos_entregados = pedidos_entregados + 1,
        total_cobrado = total_cobrado + COALESCE(NEW.monto_pagado, 0)
      WHERE id = v_recorrido_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."actualizar_recorrido_entrega"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."actualizar_saldo_cliente"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- NEUTRALIZED: saldo_cuenta is managed exclusively by actualizar_saldo_pedido
  -- via the (total - monto_pagado) calculation on the pedidos table.
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."actualizar_saldo_cliente"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."actualizar_saldo_pedido"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  saldo_anterior NUMERIC;
  saldo_nuevo NUMERIC;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Pedido nuevo: saldo aumenta por (total - monto_pagado)
    -- Si el pedido ya viene pagado, no suma nada al saldo
    saldo_nuevo := NEW.total - COALESCE(NEW.monto_pagado, 0);
    UPDATE clientes
    SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + saldo_nuevo
    WHERE id = NEW.cliente_id;

  ELSIF TG_OP = 'DELETE' THEN
    -- Pedido eliminado: restar lo que quedaba pendiente
    saldo_anterior := OLD.total - COALESCE(OLD.monto_pagado, 0);
    UPDATE clientes
    SET saldo_cuenta = COALESCE(saldo_cuenta, 0) - saldo_anterior
    WHERE id = OLD.cliente_id;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Calcular cambio neto en el saldo
    saldo_anterior := OLD.total - COALESCE(OLD.monto_pagado, 0);
    saldo_nuevo := NEW.total - COALESCE(NEW.monto_pagado, 0);

    -- Solo actualizar si hay diferencia
    IF saldo_anterior != saldo_nuevo THEN
      UPDATE clientes
      SET saldo_cuenta = COALESCE(saldo_cuenta, 0) - saldo_anterior + saldo_nuevo
      WHERE id = NEW.cliente_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."actualizar_saldo_pedido"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ajustar_stock_promocion_completo"("p_promocion_id" bigint, "p_producto_id" bigint, "p_cantidad_stock" integer, "p_usos_ajustados" integer, "p_usuario_id" "uuid", "p_observaciones" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_user_role TEXT;
  v_stock_anterior INT;
  v_stock_nuevo INT;
  v_producto_nombre TEXT;
  v_usos_pendientes INT;
  v_promo_nombre TEXT;
  v_merma_id BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role != 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede ajustar stock por promos');
  END IF;

  IF p_cantidad_stock IS NULL OR p_cantidad_stock <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'La cantidad a descontar del stock debe ser mayor a 0');
  END IF;

  IF p_usos_ajustados IS NULL OR p_usos_ajustados <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Los usos a resolver deben ser mayor a 0');
  END IF;

  SELECT nombre, usos_pendientes INTO v_promo_nombre, v_usos_pendientes
  FROM promociones WHERE id = p_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Promocion no encontrada');
  END IF;

  IF p_usos_ajustados > COALESCE(v_usos_pendientes, 0) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'No se pueden ajustar mas usos (' || p_usos_ajustados || ') que los pendientes (' || COALESCE(v_usos_pendientes, 0) || ')');
  END IF;

  SELECT stock, nombre INTO v_stock_anterior, v_producto_nombre
  FROM productos WHERE id = p_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Producto no encontrado');
  END IF;

  IF v_stock_anterior < p_cantidad_stock THEN
    RETURN jsonb_build_object('success', false, 'error',
      v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_anterior || ', solicitado: ' || p_cantidad_stock || ')');
  END IF;

  v_stock_nuevo := v_stock_anterior - p_cantidad_stock;

  INSERT INTO mermas_stock (
    producto_id, cantidad, motivo, observaciones,
    stock_anterior, stock_nuevo, usuario_id, sucursal_id
  ) VALUES (
    p_producto_id, p_cantidad_stock, 'promociones',
    COALESCE(p_observaciones, '') || ' (Promo: ' || v_promo_nombre || ')',
    v_stock_anterior, v_stock_nuevo, p_usuario_id, v_sucursal
  )
  RETURNING id INTO v_merma_id;

  UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
  WHERE id = p_producto_id AND sucursal_id = v_sucursal;

  INSERT INTO promo_ajustes (
    promocion_id, usos_ajustados, unidades_ajustadas, producto_id,
    merma_id, usuario_id, observaciones, sucursal_id
  ) VALUES (
    p_promocion_id, p_usos_ajustados, p_cantidad_stock, p_producto_id,
    v_merma_id, p_usuario_id, p_observaciones, v_sucursal
  );

  UPDATE promociones
  SET usos_pendientes = GREATEST(usos_pendientes - p_usos_ajustados, 0)
  WHERE id = p_promocion_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object(
    'success', true,
    'merma_id', v_merma_id,
    'stock_anterior', v_stock_anterior,
    'stock_nuevo', v_stock_nuevo,
    'usos_ajustados', p_usos_ajustados
  );
END;
$$;


ALTER FUNCTION "public"."ajustar_stock_promocion_completo"("p_promocion_id" bigint, "p_producto_id" bigint, "p_cantidad_stock" integer, "p_usos_ajustados" integer, "p_usuario_id" "uuid", "p_observaciones" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."anular_compra_atomica"("p_compra_id" bigint, "p_usuario_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_compra RECORD;
  v_item RECORD;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_user_role TEXT;
  v_errores TEXT[] := '{}';
BEGIN
  -- Auth check: verify p_usuario_id matches the authenticated user
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesión autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden anular compras');
  END IF;

  SELECT * INTO v_compra FROM compras WHERE id = p_compra_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada');
  END IF;

  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'La compra ya está cancelada');
  END IF;

  -- Validate stock availability before reverting (prevent negative stock)
  FOR v_item IN
    SELECT ci.producto_id, ci.cantidad, p.stock, p.nombre
    FROM compra_items ci
    JOIN productos p ON p.id = ci.producto_id
    WHERE ci.compra_id = p_compra_id
    FOR UPDATE OF p  -- Lock product rows
  LOOP
    IF v_item.stock < v_item.cantidad THEN
      v_errores := array_append(v_errores,
        COALESCE(v_item.nombre, 'Producto ' || v_item.producto_id)
        || ': stock insuficiente para revertir (actual: ' || v_item.stock || ', necesario: ' || v_item.cantidad || ')');
    END IF;
  END LOOP;

  IF array_length(v_errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede anular: ' || array_to_string(v_errores, '; '));
  END IF;

  -- Revert stock atomically
  UPDATE productos p
  SET stock = p.stock - ci.cantidad,
      updated_at = NOW()
  FROM compra_items ci
  WHERE ci.compra_id = p_compra_id
    AND p.id = ci.producto_id;

  -- Mark compra as cancelled
  UPDATE compras
  SET estado = 'cancelada',
      updated_at = NOW()
  WHERE id = p_compra_id;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Compra anulada y stock revertido correctamente');
END;
$$;


ALTER FUNCTION "public"."anular_compra_atomica"("p_compra_id" bigint, "p_usuario_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."anular_control_por_cambio_fecha_entrega"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF OLD.fecha_entrega IS NOT NULL
     AND OLD.transportista_id IS NOT NULL
     AND (
       NEW.fecha_entrega IS NULL
       OR OLD.fecha_entrega::date IS DISTINCT FROM NEW.fecha_entrega::date
       OR (NEW.estado = 'cancelado' AND OLD.estado = 'entregado')
       OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id
     ) THEN
    DELETE FROM rendiciones_control
    WHERE transportista_id = OLD.transportista_id
      AND sucursal_id = OLD.sucursal_id
      AND fecha = OLD.fecha_entrega::date;
  END IF;

  IF NEW.fecha_entrega IS NOT NULL
     AND NEW.transportista_id IS NOT NULL
     AND NEW.estado = 'entregado'
     AND (
       OLD.fecha_entrega IS NULL
       OR OLD.fecha_entrega::date IS DISTINCT FROM NEW.fecha_entrega::date
       OR OLD.transportista_id IS DISTINCT FROM NEW.transportista_id
     ) THEN
    DELETE FROM rendiciones_control
    WHERE transportista_id = NEW.transportista_id
      AND sucursal_id = NEW.sucursal_id
      AND fecha = NEW.fecha_entrega::date;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."anular_control_por_cambio_fecha_entrega"() OWNER TO "postgres";


COMMENT ON FUNCTION "public"."anular_control_por_cambio_fecha_entrega"() IS 'Trigger: anula rendiciones_control de los días afectados cuando cambia fecha_entrega, estado=cancelado o transportista de un pedido entregado.';



CREATE OR REPLACE FUNCTION "public"."anular_salvedad"("p_salvedad_id" bigint, "p_notas" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad RECORD;
  v_usuario_id UUID := auth.uid();
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;
  SELECT * INTO v_salvedad FROM salvedades_items WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'No encontrada'); END IF;
  IF v_salvedad.estado_resolucion = 'anulada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya anulada');
  END IF;
  IF EXISTS (SELECT 1 FROM pedido_items WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal) THEN
    UPDATE pedido_items SET
      cantidad = v_salvedad.cantidad_original,
      subtotal = v_salvedad.cantidad_original * v_salvedad.precio_unitario
    WHERE id = v_salvedad.pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, sucursal_id)
    VALUES (v_salvedad.pedido_id, v_salvedad.producto_id, v_salvedad.cantidad_original,
            v_salvedad.precio_unitario, v_salvedad.cantidad_original * v_salvedad.precio_unitario, v_sucursal);
  END IF;
  UPDATE pedidos SET
    total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = v_salvedad.pedido_id AND sucursal_id = v_sucursal),
    updated_at = NOW()
  WHERE id = v_salvedad.pedido_id AND sucursal_id = v_sucursal;
  IF v_salvedad.stock_devuelto THEN
    UPDATE productos SET stock = stock - v_salvedad.cantidad_afectada
     WHERE id = v_salvedad.producto_id AND sucursal_id = v_sucursal;
  END IF;
  UPDATE salvedades_items SET
    estado_resolucion = 'anulada',
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (p_salvedad_id, 'anulacion', v_salvedad.estado_resolucion, 'anulada', p_notas, v_usuario_id, v_sucursal);
  RETURN jsonb_build_object('success', true);
END;
$$;


ALTER FUNCTION "public"."anular_salvedad"("p_salvedad_id" bigint, "p_notas" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."asignar_usuario_sucursal"("p_usuario_id" "uuid", "p_sucursal_id" bigint, "p_rol" character varying DEFAULT 'mismo'::character varying, "p_es_default" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede asignar sucursales');
  END IF;

  INSERT INTO usuario_sucursales (usuario_id, sucursal_id, rol, es_default)
  VALUES (p_usuario_id, p_sucursal_id, p_rol, p_es_default)
  ON CONFLICT (usuario_id, sucursal_id) DO UPDATE
    SET rol = EXCLUDED.rol,
        es_default = EXCLUDED.es_default;

  IF p_es_default THEN
    UPDATE usuario_sucursales SET es_default = false
     WHERE usuario_id = p_usuario_id AND sucursal_id <> p_sucursal_id;
  END IF;

  RETURN jsonb_build_object('success', true);
END;
$$;


ALTER FUNCTION "public"."asignar_usuario_sucursal"("p_usuario_id" "uuid", "p_sucursal_id" bigint, "p_rol" character varying, "p_es_default" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."audit_log_changes"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_old_data JSONB; v_new_data JSONB; v_campos_modificados TEXT[];
  v_usuario_id UUID; v_usuario_email TEXT; v_usuario_rol TEXT;
  v_registro_id TEXT; v_key TEXT;
  v_old_changed JSONB; v_new_changed JSONB;
  v_sucursal_id BIGINT;
  v_has_sucursal_col BOOLEAN;
BEGIN
  v_usuario_id := auth.uid();
  IF v_usuario_id IS NOT NULL THEN
    SELECT email INTO v_usuario_email FROM auth.users WHERE id = v_usuario_id;
    SELECT rol INTO v_usuario_rol FROM public.perfiles WHERE id = v_usuario_id;
  END IF;

  -- Does the audited table have a sucursal_id column?
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
     WHERE table_schema = TG_TABLE_SCHEMA
       AND table_name   = TG_TABLE_NAME
       AND column_name  = 'sucursal_id'
  ) INTO v_has_sucursal_col;

  IF TG_OP = 'DELETE' THEN
    v_registro_id := OLD.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := NULL;
    v_sucursal_id := COALESCE((to_jsonb(OLD)->>'sucursal_id')::BIGINT, current_sucursal_id());
  ELSIF TG_OP = 'INSERT' THEN
    v_registro_id := NEW.id::TEXT;
    v_old_data := NULL;
    v_new_data := to_jsonb(NEW);
    v_sucursal_id := COALESCE((to_jsonb(NEW)->>'sucursal_id')::BIGINT, current_sucursal_id());
  ELSE
    v_registro_id := NEW.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := to_jsonb(NEW);
    v_sucursal_id := COALESCE(
      (to_jsonb(NEW)->>'sucursal_id')::BIGINT,
      (to_jsonb(OLD)->>'sucursal_id')::BIGINT,
      current_sucursal_id()
    );

    v_campos_modificados := ARRAY[]::TEXT[];
    v_old_changed := '{}'::JSONB;
    v_new_changed := '{}'::JSONB;
    FOR v_key IN SELECT jsonb_object_keys(v_new_data) LOOP
      IF v_old_data->v_key IS DISTINCT FROM v_new_data->v_key THEN
        v_campos_modificados := array_append(v_campos_modificados, v_key);
        v_old_changed := v_old_changed || jsonb_build_object(v_key, v_old_data->v_key);
        v_new_changed := v_new_changed || jsonb_build_object(v_key, v_new_data->v_key);
      END IF;
    END LOOP;
    IF array_length(v_campos_modificados, 1) IS NULL OR array_length(v_campos_modificados, 1) = 0 THEN
      RETURN NEW;
    END IF;
    v_old_data := v_old_changed;
    v_new_data := v_new_changed;
  END IF;

  -- FIX H7 (refined): only fail when the table HAS sucursal_id but we
  -- couldn't resolve one. For global tables (perfiles, sucursales, etc.)
  -- log with NULL sucursal_id - those rows are not tenant-scoped.
  IF v_has_sucursal_col AND v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'audit_log_changes: cannot determine sucursal_id for tenant-scoped table %', TG_TABLE_NAME;
  END IF;

  INSERT INTO public.audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados, usuario_id, usuario_email, usuario_rol, sucursal_id)
  VALUES (TG_TABLE_NAME, v_registro_id, TG_OP, v_old_data, v_new_data, v_campos_modificados, v_usuario_id, v_usuario_email, v_usuario_rol, v_sucursal_id);

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;


ALTER FUNCTION "public"."audit_log_changes"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cambiar_sucursal"("p_sucursal_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id
  ) THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado para esta sucursal');
  END IF;
  UPDATE usuario_sucursales SET es_default = false WHERE usuario_id = auth.uid();
  UPDATE usuario_sucursales SET es_default = true WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id;
  RETURN jsonb_build_object('success', true, 'sucursal_id', p_sucursal_id);
END;
$$;


ALTER FUNCTION "public"."cambiar_sucursal"("p_sucursal_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancelar_pedido_con_stock"("p_pedido_id" bigint, "p_motivo" "text", "p_usuario_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido RECORD;
  v_item RECORD;
  v_total_original DECIMAL;
  v_user_role TEXT;
  v_acting_user uuid;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  v_acting_user := auth.uid();
  IF p_usuario_id IS NOT NULL AND p_usuario_id IS DISTINCT FROM v_acting_user THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = v_acting_user;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden cancelar pedidos');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado');
  END IF;

  IF v_pedido.estado = 'cancelado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'El pedido ya esta cancelado');
  END IF;

  IF v_pedido.estado = 'entregado' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede cancelar un pedido entregado');
  END IF;

  v_total_original := v_pedido.total;

  FOR v_item IN
    SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
           pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
    FROM pedido_items pi
    LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
    WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
  LOOP
    IF v_item.es_bonificacion THEN
      IF v_item.promocion_id IS NOT NULL THEN
        UPDATE promociones
        SET usos_pendientes = GREATEST(usos_pendientes - v_item.cantidad, 0)
        WHERE id = v_item.promocion_id AND sucursal_id = v_sucursal;
      END IF;
      IF v_item.regalo_mueve_stock THEN
        UPDATE productos SET stock = stock + v_item.cantidad
        WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
    ELSE
      UPDATE productos SET stock = stock + v_item.cantidad
      WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    END IF;
  END LOOP;

  UPDATE pedidos
  SET estado = 'cancelado',
      motivo_cancelacion = p_motivo,
      total = 0,
      monto_pagado = 0,
      total_neto = 0,
      total_iva = 0,
      updated_at = NOW()
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (
    p_pedido_id,
    v_acting_user,
    'estado',
    v_pedido.estado,
    'cancelado - Motivo: ' || COALESCE(p_motivo, 'Sin motivo') || ' | Total original: $' || v_total_original,
    v_sucursal
  );

  RETURN jsonb_build_object(
    'success', true,
    'mensaje', 'Pedido cancelado, stock restaurado, saldo ajustado',
    'total_original', v_total_original
  );
END;
$_$;


ALTER FUNCTION "public"."cancelar_pedido_con_stock"("p_pedido_id" bigint, "p_motivo" "text", "p_usuario_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_promo_limite_usos"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.limite_usos IS NOT NULL AND NEW.usos_pendientes >= NEW.limite_usos AND NEW.activo = true THEN
    NEW.activo := false;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."check_promo_limite_usos"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."consultar_control_rendicion"("p_transportista_id" "uuid", "p_fecha" "date") RETURNS TABLE("controlada" boolean, "controlada_at" timestamp with time zone, "controlada_por_nombre" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();

  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN QUERY
  SELECT
    (rc.id IS NOT NULL) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre
  FROM (SELECT 1) x
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = p_fecha
   AND rc.transportista_id = p_transportista_id
   AND rc.sucursal_id = v_sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por;
END;
$$;


ALTER FUNCTION "public"."consultar_control_rendicion"("p_transportista_id" "uuid", "p_fecha" "date") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."consultar_control_rendicion"("p_transportista_id" "uuid", "p_fecha" "date") IS 'Consulta si una rendición (fecha, transportista) ya fue controlada. Retorna una única fila siempre.';



CREATE OR REPLACE FUNCTION "public"."crear_pedido_completo"("p_cliente_id" bigint, "p_total" numeric, "p_usuario_id" "uuid", "p_items" "jsonb", "p_notas" "text" DEFAULT NULL::"text", "p_forma_pago" "text" DEFAULT 'efectivo'::"text", "p_estado_pago" "text" DEFAULT 'pendiente'::"text", "p_fecha" "date" DEFAULT NULL::"date", "p_tipo_factura" "text" DEFAULT 'ZZ'::"text", "p_total_neto" numeric DEFAULT NULL::numeric, "p_total_iva" numeric DEFAULT 0, "p_fecha_entrega_programada" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido_id INT; item JSONB; v_producto_id INT; v_cantidad INT;
  v_precio_unitario DECIMAL; v_es_bonificacion BOOLEAN; v_promocion_id BIGINT;
  v_neto_unitario DECIMAL; v_iva_unitario DECIMAL; v_imp_internos_unitario DECIMAL;
  v_porcentaje_iva DECIMAL; v_stock_actual INT; v_producto_nombre TEXT;
  errores TEXT[] := '{}'; v_user_role TEXT;
  v_cantidades_totales JSONB := '{}'::JSONB; v_cant_acumulada INT;
  v_regalo_mueve_stock BOOLEAN;
  v_fecha_pedido DATE := COALESCE(
    p_fecha,
    (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
  );
  v_fecha_entrega DATE := COALESCE(
    p_fecha_entrega_programada,
    (v_fecha_pedido + INTERVAL '1 day')::date
  );
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
  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa')); END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('ID de usuario no coincide con la sesion autenticada')); END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No tiene permisos para crear pedidos')); END IF;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (item->>'producto_id')::INT; v_cantidad := (item->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN errores := array_append(errores, 'Cantidad invalida para producto ID ' || v_producto_id); CONTINUE; END IF;

    IF v_es_bonificacion THEN
      v_promocion_id := (item->>'promocion_id')::BIGINT;
      IF v_promocion_id IS NOT NULL THEN
        SELECT regalo_mueve_stock INTO v_regalo_mueve_stock
        FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
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
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_actual IS NULL THEN errores := array_append(errores, 'Producto ID ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')'); END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;

  INSERT INTO pedidos (cliente_id, fecha, total, total_neto, total_iva, tipo_factura, estado, usuario_id, stock_descontado, notas, forma_pago, estado_pago, fecha_entrega_programada, sucursal_id)
  VALUES (p_cliente_id, v_fecha_pedido, p_total, COALESCE(p_total_neto, p_total), COALESCE(p_total_iva, 0), COALESCE(p_tipo_factura, 'ZZ'), 'pendiente', p_usuario_id, true, p_notas, p_forma_pago, p_estado_pago, v_fecha_entrega, v_sucursal)
  RETURNING id INTO v_pedido_id;

  FOR item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (item->>'producto_id')::INT; v_cantidad := (item->>'cantidad')::INT;
    v_precio_unitario := (item->>'precio_unitario')::DECIMAL;
    v_es_bonificacion := COALESCE((item->>'es_bonificacion')::BOOLEAN, false);
    v_promocion_id := (item->>'promocion_id')::BIGINT;
    v_neto_unitario := (item->>'neto_unitario')::DECIMAL;
    v_iva_unitario := COALESCE((item->>'iva_unitario')::DECIMAL, 0);
    v_imp_internos_unitario := COALESCE((item->>'impuestos_internos_unitario')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((item->>'porcentaje_iva')::DECIMAL, 0);
    INSERT INTO pedido_items (pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id)
    VALUES (v_pedido_id, v_producto_id, v_cantidad, v_precio_unitario, v_cantidad * v_precio_unitario, v_es_bonificacion, v_promocion_id, v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva, v_sucursal);

    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    ELSIF v_promocion_id IS NOT NULL THEN
      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
        UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      END IF;
    END IF;

    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad
      WHERE id = v_promocion_id AND sucursal_id = v_sucursal;

      SELECT id, nombre, ajuste_automatico, ajuste_producto_id, unidades_por_bloque,
             stock_por_bloque, usos_pendientes
      INTO v_promo
      FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal FOR UPDATE;

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
          FROM productos WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal FOR UPDATE;

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
            'Auto-ajuste (Promo: ' || v_promo.nombre || ', Pedido #' || v_pedido_id || ')',
            v_stock_ajuste_anterior, v_stock_ajuste_nuevo, p_usuario_id, v_sucursal
          ) RETURNING id INTO v_merma_id;

          UPDATE productos SET stock = v_stock_ajuste_nuevo, updated_at = NOW()
          WHERE id = v_promo.ajuste_producto_id AND sucursal_id = v_sucursal;

          INSERT INTO promo_ajustes (
            promocion_id, usos_ajustados, unidades_ajustadas, producto_id,
            merma_id, usuario_id, observaciones, sucursal_id
          ) VALUES (
            v_promocion_id, v_ajustar_usos, v_ajustar_stock, v_promo.ajuste_producto_id,
            v_merma_id, p_usuario_id,
            'Auto-ajuste por pedido #' || v_pedido_id, v_sucursal
          );

          UPDATE promociones
          SET usos_pendientes = GREATEST(usos_pendientes - v_ajustar_usos, 0)
          WHERE id = v_promocion_id AND sucursal_id = v_sucursal;
        END IF;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'pedido_id', v_pedido_id);
END;
$$;


ALTER FUNCTION "public"."crear_pedido_completo"("p_cliente_id" bigint, "p_total" numeric, "p_usuario_id" "uuid", "p_items" "jsonb", "p_notas" "text", "p_forma_pago" "text", "p_estado_pago" "text", "p_fecha" "date", "p_tipo_factura" "text", "p_total_neto" numeric, "p_total_iva" numeric, "p_fecha_entrega_programada" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crear_recorrido"("p_transportista_id" "uuid", "p_pedidos" "jsonb", "p_distancia" numeric DEFAULT NULL::numeric, "p_duracion" integer DEFAULT NULL::integer) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_recorrido_id BIGINT;
  v_pedido JSONB;
  v_total_facturado DECIMAL := 0;
BEGIN
  IF v_sucursal IS NULL THEN RAISE EXCEPTION 'No se pudo determinar la sucursal activa'; END IF;
  SELECT COALESCE(SUM(total), 0) INTO v_total_facturado FROM pedidos
   WHERE id IN (SELECT (value->>'pedido_id')::BIGINT FROM jsonb_array_elements(p_pedidos) AS value)
     AND sucursal_id = v_sucursal;
  INSERT INTO recorridos (transportista_id, fecha, distancia_total, duracion_total, total_pedidos, total_facturado, estado, sucursal_id)
  VALUES (p_transportista_id, CURRENT_DATE, p_distancia, p_duracion, jsonb_array_length(p_pedidos), v_total_facturado, 'en_curso', v_sucursal)
  RETURNING id INTO v_recorrido_id;
  FOR v_pedido IN SELECT * FROM jsonb_array_elements(p_pedidos) LOOP
    INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, sucursal_id)
    VALUES (v_recorrido_id, (v_pedido->>'pedido_id')::BIGINT, (v_pedido->>'orden_entrega')::INTEGER, v_sucursal);
  END LOOP;
  RETURN v_recorrido_id;
END;
$$;


ALTER FUNCTION "public"."crear_recorrido"("p_transportista_id" "uuid", "p_pedidos" "jsonb", "p_distancia" numeric, "p_duracion" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crear_rendicion_por_fecha"("p_transportista_id" "uuid", "p_fecha" "date" DEFAULT CURRENT_DATE) RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_rendicion_id BIGINT;
  v_total_efectivo DECIMAL := 0;
  v_total_otros DECIMAL := 0;
  v_pedido RECORD;
BEGIN
  IF v_sucursal IS NULL THEN RAISE EXCEPTION 'No se pudo determinar la sucursal activa'; END IF;
  IF EXISTS (SELECT 1 FROM rendiciones WHERE transportista_id = p_transportista_id AND fecha = p_fecha AND sucursal_id = v_sucursal) THEN
    RAISE EXCEPTION 'Ya existe una rendicion para este transportista en esta fecha';
  END IF;
  FOR v_pedido IN
    SELECT p.id, COALESCE(p.total,0) as total, COALESCE(p.monto_pagado,p.total,0) as monto_pagado, COALESCE(p.forma_pago,'efectivo') as forma_pago
      FROM pedidos p
     WHERE p.transportista_id = p_transportista_id AND p.estado = 'entregado' AND p.sucursal_id = v_sucursal
       AND COALESCE(p.fecha_entrega, p.updated_at)::date = p_fecha
  LOOP
    IF v_pedido.forma_pago = 'efectivo' THEN v_total_efectivo := v_total_efectivo + v_pedido.monto_pagado;
    ELSE v_total_otros := v_total_otros + v_pedido.monto_pagado; END IF;
  END LOOP;
  INSERT INTO rendiciones (recorrido_id, transportista_id, fecha, total_efectivo_esperado, total_otros_medios, estado, sucursal_id)
  VALUES (NULL, p_transportista_id, p_fecha, v_total_efectivo, v_total_otros, 'pendiente', v_sucursal)
  RETURNING id INTO v_rendicion_id;
  INSERT INTO rendicion_items (rendicion_id, pedido_id, monto_cobrado, forma_pago, sucursal_id)
  SELECT v_rendicion_id, p.id, COALESCE(p.monto_pagado,p.total,0), COALESCE(p.forma_pago,'efectivo'), v_sucursal
    FROM pedidos p
   WHERE p.transportista_id = p_transportista_id AND p.estado = 'entregado' AND p.sucursal_id = v_sucursal
     AND COALESCE(p.fecha_entrega, p.updated_at)::date = p_fecha;
  RETURN v_rendicion_id;
END;
$$;


ALTER FUNCTION "public"."crear_rendicion_por_fecha"("p_transportista_id" "uuid", "p_fecha" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."crear_rendicion_recorrido"("p_recorrido_id" bigint, "p_transportista_id" "uuid" DEFAULT NULL::"uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_rendicion_id BIGINT;
  v_total_efectivo DECIMAL := 0;
  v_total_otros DECIMAL := 0;
  v_pedido RECORD;
  v_transportista_real UUID;
  v_es_admin BOOLEAN;
BEGIN
  IF v_sucursal IS NULL THEN RAISE EXCEPTION 'No se pudo determinar la sucursal activa'; END IF;
  v_es_admin := es_admin_rendiciones();
  IF v_es_admin THEN
    IF p_transportista_id IS NULL THEN
      SELECT transportista_id INTO v_transportista_real FROM recorridos WHERE id = p_recorrido_id AND sucursal_id = v_sucursal;
    ELSE v_transportista_real := p_transportista_id; END IF;
  ELSE v_transportista_real := auth.uid(); END IF;
  IF NOT EXISTS (SELECT 1 FROM recorridos WHERE id = p_recorrido_id AND sucursal_id = v_sucursal
                  AND (transportista_id = v_transportista_real OR v_es_admin)) THEN
    RAISE EXCEPTION 'Recorrido no valido o no pertenece al transportista';
  END IF;
  IF EXISTS (SELECT 1 FROM rendiciones WHERE recorrido_id = p_recorrido_id AND sucursal_id = v_sucursal) THEN
    RAISE EXCEPTION 'Ya existe una rendicion para este recorrido';
  END IF;
  FOR v_pedido IN
    SELECT p.id, COALESCE(p.monto_pagado,0) as monto_pagado, COALESCE(p.forma_pago,'efectivo') as forma_pago
      FROM pedidos p JOIN recorrido_pedidos rp ON rp.pedido_id = p.id AND rp.sucursal_id = v_sucursal
     WHERE rp.recorrido_id = p_recorrido_id AND rp.estado_entrega = 'entregado' AND p.estado = 'entregado' AND p.sucursal_id = v_sucursal
  LOOP
    IF v_pedido.forma_pago = 'efectivo' THEN v_total_efectivo := v_total_efectivo + v_pedido.monto_pagado;
    ELSE v_total_otros := v_total_otros + v_pedido.monto_pagado; END IF;
  END LOOP;
  INSERT INTO rendiciones (recorrido_id, transportista_id, fecha, total_efectivo_esperado, total_otros_medios, estado, sucursal_id)
  VALUES (p_recorrido_id, v_transportista_real, CURRENT_DATE, v_total_efectivo, v_total_otros, 'pendiente', v_sucursal)
  RETURNING id INTO v_rendicion_id;
  INSERT INTO rendicion_items (rendicion_id, pedido_id, monto_cobrado, forma_pago, sucursal_id)
  SELECT v_rendicion_id, p.id, COALESCE(p.monto_pagado,0), COALESCE(p.forma_pago,'efectivo'), v_sucursal
    FROM pedidos p JOIN recorrido_pedidos rp ON rp.pedido_id = p.id AND rp.sucursal_id = v_sucursal
   WHERE rp.recorrido_id = p_recorrido_id AND rp.estado_entrega = 'entregado' AND p.estado = 'entregado' AND p.sucursal_id = v_sucursal;
  RETURN v_rendicion_id;
END;
$$;


ALTER FUNCTION "public"."crear_rendicion_recorrido"("p_recorrido_id" bigint, "p_transportista_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."crear_rendicion_recorrido"("p_recorrido_id" bigint, "p_transportista_id" "uuid") IS 'Crea una nueva rendición a partir de un recorrido completado';



CREATE OR REPLACE FUNCTION "public"."current_sucursal_id"() RETURNS bigint
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_header_val TEXT;
  v_sucursal_id BIGINT;
  v_authorized BOOLEAN;
BEGIN
  BEGIN
    v_header_val := current_setting('request.headers', true)::json->>'x-sucursal-id';
  EXCEPTION WHEN others THEN
    v_header_val := NULL;
  END;

  IF v_header_val IS NOT NULL AND v_header_val <> '' THEN
    BEGIN
      v_sucursal_id := v_header_val::BIGINT;
    EXCEPTION WHEN others THEN
      v_sucursal_id := NULL;
    END;

    IF v_sucursal_id IS NOT NULL THEN
      SELECT EXISTS (
        SELECT 1 FROM usuario_sucursales
        WHERE usuario_id = auth.uid() AND sucursal_id = v_sucursal_id
      ) INTO v_authorized;

      IF v_authorized THEN
        RETURN v_sucursal_id;
      ELSE
        RETURN NULL;
      END IF;
    END IF;
  END IF;

  RETURN (
    SELECT sucursal_id FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND es_default = true
    LIMIT 1
  );
END;
$$;


ALTER FUNCTION "public"."current_sucursal_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."desasignar_usuario_sucursal"("p_usuario_id" "uuid", "p_sucursal_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NOT es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin puede desasignar sucursales');
  END IF;

  DELETE FROM usuario_sucursales
   WHERE usuario_id = p_usuario_id AND sucursal_id = p_sucursal_id;

  RETURN jsonb_build_object('success', true);
END;
$$;


ALTER FUNCTION "public"."desasignar_usuario_sucursal"("p_usuario_id" "uuid", "p_sucursal_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."descontar_stock_atomico"("p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item JSONB; v_producto_id INT; v_cantidad INT; v_stock_actual INT; v_producto_nombre TEXT;
  errores TEXT[] := '{}'; v_user_role TEXT;
BEGIN
  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa')); END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = auth.uid();
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No autorizado')); END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (v_item->>'producto_id')::INT; v_cantidad := (v_item->>'cantidad')::INT;
    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN errores := array_append(errores, 'Cantidad invalida'); CONTINUE; END IF;
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_actual IS NULL THEN errores := array_append(errores, 'Producto ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN errores := array_append(errores, v_producto_nombre || ': stock insuficiente');
    ELSE UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal; END IF;
  END LOOP;
  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;
  RETURN jsonb_build_object('success', true, 'errores', '[]'::jsonb);
END;
$$;


ALTER FUNCTION "public"."descontar_stock_atomico"("p_items" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."descontar_stock_atomico"("p_items" "jsonb") IS 'Descuenta stock de múltiples productos de forma atómica. Valida cantidades positivas y evita race conditions';



CREATE OR REPLACE FUNCTION "public"."desmarcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();

  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  DELETE FROM rendiciones_control
  WHERE fecha = p_fecha
    AND transportista_id = p_transportista_id
    AND sucursal_id = v_sucursal_id;
END;
$$;


ALTER FUNCTION "public"."desmarcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."desmarcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") IS 'Quita el control de una rendición diaria (fecha, transportista).';



CREATE OR REPLACE FUNCTION "public"."eliminar_pedido_completo"("p_pedido_id" bigint, "p_usuario_id" "uuid", "p_motivo" "text" DEFAULT NULL::"text", "p_restaurar_stock" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_pedido RECORD; v_items JSONB; v_cliente_nombre TEXT; v_cliente_direccion TEXT;
  v_usuario_creador_nombre TEXT; v_transportista_nombre TEXT := NULL;
  v_eliminador_nombre TEXT := NULL; v_item RECORD;
  v_user_role TEXT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role != 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo administradores pueden eliminar pedidos');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado'); END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', pi.producto_id, 'producto_nombre', pr.nombre,
    'producto_codigo', pr.codigo, 'cantidad', pi.cantidad,
    'precio_unitario', pi.precio_unitario, 'subtotal', pi.subtotal))
  INTO v_items FROM pedido_items pi LEFT JOIN productos pr ON pr.id = pi.producto_id
  WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal;

  SELECT nombre_fantasia, direccion INTO v_cliente_nombre, v_cliente_direccion
  FROM clientes WHERE id = v_pedido.cliente_id AND sucursal_id = v_sucursal;
  SELECT nombre INTO v_usuario_creador_nombre FROM perfiles WHERE id = v_pedido.usuario_id;
  IF v_pedido.transportista_id IS NOT NULL THEN SELECT nombre INTO v_transportista_nombre FROM perfiles WHERE id = v_pedido.transportista_id; END IF;
  IF p_usuario_id IS NOT NULL THEN SELECT nombre INTO v_eliminador_nombre FROM perfiles WHERE id = p_usuario_id; END IF;

  INSERT INTO pedidos_eliminados (
    pedido_id, cliente_id, cliente_nombre, cliente_direccion, total, estado,
    estado_pago, forma_pago, monto_pagado, notas, items,
    usuario_creador_id, usuario_creador_nombre, transportista_id, transportista_nombre,
    fecha_pedido, fecha_entrega, eliminado_por_id, eliminado_por_nombre,
    motivo_eliminacion, stock_restaurado, sucursal_id)
  VALUES (
    p_pedido_id, v_pedido.cliente_id, v_cliente_nombre, v_cliente_direccion,
    v_pedido.total, v_pedido.estado, v_pedido.estado_pago, v_pedido.forma_pago,
    v_pedido.monto_pagado, v_pedido.notas, COALESCE(v_items, '[]'::jsonb),
    v_pedido.usuario_id, v_usuario_creador_nombre, v_pedido.transportista_id,
    v_transportista_nombre, v_pedido.created_at, v_pedido.fecha_entrega,
    p_usuario_id, v_eliminador_nombre, p_motivo, p_restaurar_stock, v_sucursal);

  IF p_restaurar_stock THEN
    FOR v_item IN
      SELECT pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, false) AS es_bonificacion,
             pi.promocion_id, COALESCE(pr.regalo_mueve_stock, FALSE) AS regalo_mueve_stock
      FROM pedido_items pi
      LEFT JOIN promociones pr ON pr.id = pi.promocion_id AND pr.sucursal_id = pi.sucursal_id
      WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal
    LOOP
      IF NOT v_item.es_bonificacion OR v_item.regalo_mueve_stock THEN
        UPDATE productos SET stock = stock + v_item.cantidad
        WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
      END IF;
    END LOOP;
  END IF;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  DELETE FROM pedido_historial WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal;
  DELETE FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido eliminado y registrado correctamente');
END;
$$;


ALTER FUNCTION "public"."eliminar_pedido_completo"("p_pedido_id" bigint, "p_usuario_id" "uuid", "p_motivo" "text", "p_restaurar_stock" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_proveedor RECORD;
BEGIN
  -- Buscar el proveedor
  SELECT * INTO v_proveedor
  FROM proveedores
  WHERE id = p_proveedor_id;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Proveedor no encontrado');
  END IF;

  -- Guardar registro en tabla de auditoría
  INSERT INTO proveedores_eliminados (
    proveedor_id, nombre, cuit, direccion, telefono, email,
    contacto, notas, activo, fecha_creacion, eliminado_por
  ) VALUES (
    v_proveedor.id,
    v_proveedor.nombre,
    v_proveedor.cuit,
    v_proveedor.direccion,
    v_proveedor.telefono,
    v_proveedor.email,
    v_proveedor.contacto,
    v_proveedor.notas,
    v_proveedor.activo,
    v_proveedor.created_at,
    auth.uid()
  );

  -- Eliminar el proveedor (compras mantienen proveedor_nombre por ON DELETE SET NULL)
  DELETE FROM proveedores WHERE id = p_proveedor_id;

  RETURN jsonb_build_object(
    'success', true,
    'nombre', v_proveedor.nombre
  );
EXCEPTION
  WHEN OTHERS THEN
    RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" bigint) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" bigint) IS 'Elimina un proveedor guardando registro de auditoría';



CREATE OR REPLACE FUNCTION "public"."es_admin"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol = 'admin'
  );
END;
$$;


ALTER FUNCTION "public"."es_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."es_admin_rendiciones"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid()
    AND rol = 'admin'
  );
END;
$$;


ALTER FUNCTION "public"."es_admin_rendiciones"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."es_admin_salvedades"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol = 'admin'
  );
END;
$$;


ALTER FUNCTION "public"."es_admin_salvedades"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."es_encargado_o_admin"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'encargado')
  );
END;
$$;


ALTER FUNCTION "public"."es_encargado_o_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."es_preventista"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'preventista', 'encargado')
  );
END;
$$;


ALTER FUNCTION "public"."es_preventista"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."es_transportista"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'transportista')
  );
END;
$$;


ALTER FUNCTION "public"."es_transportista"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."es_transportista_rendiciones"() RETURNS boolean
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN EXISTS (
    SELECT 1 FROM perfiles
    WHERE id = auth.uid()
    AND rol = 'transportista'
  );
END;
$$;


ALTER FUNCTION "public"."es_transportista_rendiciones"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_audit_history"("p_tabla" "text", "p_registro_id" "text", "p_limit" integer DEFAULT 50) RETURNS TABLE("id" "uuid", "accion" "text", "old_data" "jsonb", "new_data" "jsonb", "campos_modificados" "text"[], "usuario_email" "text", "usuario_rol" "text", "created_at" timestamp with time zone)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Solo admin puede consultar
  IF NOT EXISTS (SELECT 1 FROM public.perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: solo administradores pueden ver auditoría';
  END IF;

  RETURN QUERY
  SELECT
    al.id,
    al.accion,
    al.old_data,
    al.new_data,
    al.campos_modificados,
    al.usuario_email,
    al.usuario_rol,
    al.created_at
  FROM public.audit_logs al
  WHERE al.tabla = p_tabla AND al.registro_id = p_registro_id
  ORDER BY al.created_at DESC
  LIMIT p_limit;
END;
$$;


ALTER FUNCTION "public"."get_audit_history"("p_tabla" "text", "p_registro_id" "text", "p_limit" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_mi_rol"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  mi_rol TEXT;
BEGIN
  SELECT rol INTO mi_rol FROM public.perfiles WHERE id = auth.uid() AND activo = true;
  RETURN COALESCE(mi_rol, 'none');
END;
$$;


ALTER FUNCTION "public"."get_mi_rol"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_suspicious_activity"("p_days" integer DEFAULT 7) RETURNS TABLE("usuario_email" "text", "usuario_rol" "text", "tabla" "text", "total_cambios" bigint, "deletes_count" bigint, "updates_precio_count" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  -- Solo admin puede consultar
  IF NOT EXISTS (SELECT 1 FROM public.perfiles WHERE id = auth.uid() AND rol = 'admin') THEN
    RAISE EXCEPTION 'Acceso denegado: solo administradores pueden ver actividad sospechosa';
  END IF;

  RETURN QUERY
  SELECT
    al.usuario_email,
    al.usuario_rol,
    al.tabla,
    COUNT(*) as total_cambios,
    COUNT(*) FILTER (WHERE al.accion = 'DELETE') as deletes_count,
    COUNT(*) FILTER (
      WHERE al.accion = 'UPDATE'
      AND (
        'precio' = ANY(al.campos_modificados) OR
        'precio_unitario' = ANY(al.campos_modificados) OR
        'total' = ANY(al.campos_modificados) OR
        'monto' = ANY(al.campos_modificados)
      )
    ) as updates_precio_count
  FROM public.audit_logs al
  WHERE al.created_at > NOW() - (p_days || ' days')::INTERVAL
  GROUP BY al.usuario_email, al.usuario_rol, al.tabla
  HAVING
    COUNT(*) FILTER (WHERE al.accion = 'DELETE') > 5 OR
    COUNT(*) FILTER (
      WHERE al.accion = 'UPDATE'
      AND (
        'precio' = ANY(al.campos_modificados) OR
        'precio_unitario' = ANY(al.campos_modificados) OR
        'total' = ANY(al.campos_modificados)
      )
    ) > 10
  ORDER BY total_cambios DESC;
END;
$$;


ALTER FUNCTION "public"."get_suspicious_activity"("p_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_role"() RETURNS "text"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT rol FROM public.perfiles WHERE id = auth.uid();
$$;


ALTER FUNCTION "public"."get_user_role"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  INSERT INTO public.perfiles (id, email, nombre, rol, activo)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(NEW.raw_user_meta_data->>'nombre', split_part(NEW.email, '@', 1)),
    COALESCE(NEW.raw_user_meta_data->>'rol', 'preventista'),
    true
  );
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_admin"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND rol = 'admin'
  );
$$;


ALTER FUNCTION "public"."is_admin"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_preventista"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'preventista')
  );
$$;


ALTER FUNCTION "public"."is_preventista"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_transportista"() RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.perfiles
    WHERE id = auth.uid() AND rol IN ('admin', 'transportista')
  );
$$;


ALTER FUNCTION "public"."is_transportista"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."limpiar_orden_entrega"("p_transportista_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  UPDATE pedidos
  SET orden_entrega = NULL
  WHERE transportista_id = p_transportista_id;
END;
$$;


ALTER FUNCTION "public"."limpiar_orden_entrega"("p_transportista_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."marcar_pagos_masivo"("p_pedido_ids" bigint[], "p_forma_pago" "text") RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar pagos masivos'
      USING ERRCODE = '42501';
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  UPDATE pedidos
     SET estado_pago = 'pagado',
         monto_pagado = total,
         forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$$;


ALTER FUNCTION "public"."marcar_pagos_masivo"("p_pedido_ids" bigint[], "p_forma_pago" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."marcar_pagos_masivo"("p_pedido_ids" bigint[], "p_forma_pago" "text") IS 'Marca multiples pedidos como pagados en batch. Restringido a encargado/admin y a la sucursal activa. Retorna cantidad de filas afectadas.';



CREATE OR REPLACE FUNCTION "public"."marcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();

  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  INSERT INTO rendiciones_control (fecha, transportista_id, sucursal_id, controlada_por)
  VALUES (p_fecha, p_transportista_id, v_sucursal_id, auth.uid())
  ON CONFLICT (fecha, transportista_id, sucursal_id) DO UPDATE
    SET controlada_at = NOW(),
        controlada_por = auth.uid()
  RETURNING id INTO v_id;

  RETURN v_id;
END;
$$;


ALTER FUNCTION "public"."marcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."marcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") IS 'Marca la rendición diaria (fecha, transportista) como controlada. Idempotente (upsert).';



CREATE OR REPLACE FUNCTION "public"."obtener_estadisticas_pedidos"("p_fecha_desde" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_fecha_hasta" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_usuario_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_result JSONB;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  SELECT jsonb_build_object(
    'total', COUNT(*)::int,
    'pendientes', COUNT(*) FILTER (WHERE estado = 'pendiente')::int,
    'en_preparacion', COUNT(*) FILTER (WHERE estado = 'en_preparacion')::int,
    'en_reparto', COUNT(*) FILTER (WHERE estado IN ('en_reparto', 'asignado'))::int,
    'entregados', COUNT(*) FILTER (WHERE estado = 'entregado')::int,
    'cancelados', COUNT(*) FILTER (WHERE estado = 'cancelado')::int,
    'total_ventas', COALESCE(SUM(total) FILTER (WHERE estado = 'entregado'), 0)::numeric(12,2),
    'promedio_ticket', COALESCE(AVG(total) FILTER (WHERE estado = 'entregado'), 0)::numeric(12,2),
    'por_estado', COALESCE(
      (SELECT jsonb_object_agg(estado, cnt)
       FROM (
         SELECT p.estado, COUNT(*)::int AS cnt
         FROM pedidos p
         WHERE p.sucursal_id = v_sucursal_id
           AND (p_fecha_desde IS NULL OR p.created_at >= p_fecha_desde)
           AND (p_fecha_hasta IS NULL OR p.created_at <= p_fecha_hasta)
           AND (p_usuario_id IS NULL OR p.usuario_id = p_usuario_id)
         GROUP BY p.estado
       ) s),
      '{}'::jsonb
    )
  ) INTO v_result
  FROM pedidos p
  WHERE p.sucursal_id = v_sucursal_id
    AND (p_fecha_desde IS NULL OR p.created_at >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR p.created_at <= p_fecha_hasta)
    AND (p_usuario_id IS NULL OR p.usuario_id = p_usuario_id);

  IF v_result IS NULL THEN
    v_result := jsonb_build_object(
      'total', 0,
      'pendientes', 0,
      'en_preparacion', 0,
      'en_reparto', 0,
      'entregados', 0,
      'cancelados', 0,
      'total_ventas', 0,
      'promedio_ticket', 0,
      'por_estado', '{}'::jsonb
    );
  END IF;

  RETURN v_result;
END;
$$;


ALTER FUNCTION "public"."obtener_estadisticas_pedidos"("p_fecha_desde" timestamp with time zone, "p_fecha_hasta" timestamp with time zone, "p_usuario_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."obtener_estadisticas_pedidos"("p_fecha_desde" timestamp with time zone, "p_fecha_hasta" timestamp with time zone, "p_usuario_id" "uuid") IS 'Estadisticas agregadas de pedidos para la sucursal activa. Requiere current_sucursal_id() no nulo. Filtra por rango opcional de fechas y usuario.';



CREATE OR REPLACE FUNCTION "public"."obtener_estadisticas_rendiciones"("p_fecha_desde" "date" DEFAULT NULL::"date", "p_fecha_hasta" "date" DEFAULT NULL::"date", "p_transportista_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."obtener_estadisticas_rendiciones"("p_fecha_desde" "date", "p_fecha_hasta" "date", "p_transportista_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."obtener_resumen_compras"("p_fecha_desde" "date" DEFAULT NULL::"date", "p_fecha_hasta" "date" DEFAULT NULL::"date") RETURNS TABLE("total_compras" bigint, "monto_total" numeric, "promedio_compra" numeric, "productos_comprados" bigint)
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  RETURN QUERY
  SELECT
    COUNT(DISTINCT c.id)::BIGINT as total_compras,
    COALESCE(SUM(c.total), 0)::DECIMAL as monto_total,
    COALESCE(AVG(c.total), 0)::DECIMAL as promedio_compra,
    COALESCE(SUM(ci.cantidad), 0)::BIGINT as productos_comprados
  FROM compras c
  LEFT JOIN compra_items ci ON c.id = ci.compra_id
  WHERE c.estado != 'cancelada'
    AND (p_fecha_desde IS NULL OR c.fecha_compra >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR c.fecha_compra <= p_fecha_hasta);
END;
$$;


ALTER FUNCTION "public"."obtener_resumen_compras"("p_fecha_desde" "date", "p_fecha_hasta" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."obtener_resumen_cuenta_cliente"("p_cliente_id" integer) RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  resultado JSON;
BEGIN
  -- Auth check: any authenticated user can view
  IF auth.uid() IS NULL THEN
    RETURN json_build_object('error', 'No autenticado');
  END IF;

  SELECT json_build_object(
    'saldo_actual', COALESCE(c.saldo_cuenta, 0),
    'limite_credito', COALESCE(c.limite_credito, 0),
    'credito_disponible', COALESCE(c.limite_credito, 0) - COALESCE(c.saldo_cuenta, 0),
    'total_pedidos', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id),
    'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos WHERE cliente_id = p_cliente_id),
    'total_pagos', (SELECT COALESCE(SUM(monto), 0) FROM pagos WHERE cliente_id = p_cliente_id),
    'pedidos_pendientes_pago', (SELECT COUNT(*) FROM pedidos WHERE cliente_id = p_cliente_id AND estado_pago != 'pagado'),
    'ultimo_pedido', (SELECT MAX(created_at) FROM pedidos WHERE cliente_id = p_cliente_id),
    'ultimo_pago', (SELECT MAX(created_at) FROM pagos WHERE cliente_id = p_cliente_id)
  ) INTO resultado
  FROM clientes c
  WHERE c.id = p_cliente_id;

  RETURN resultado;
END;
$$;


ALTER FUNCTION "public"."obtener_resumen_cuenta_cliente"("p_cliente_id" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."obtener_resumen_rendiciones"("p_fecha_desde" "date" DEFAULT ((CURRENT_DATE - '30 days'::interval))::"date", "p_fecha_hasta" "date" DEFAULT CURRENT_DATE, "p_transportista_id" "uuid" DEFAULT NULL::"uuid") RETURNS TABLE("fecha" "date", "transportista_id" "uuid", "transportista_nombre" "text", "total_efectivo" numeric, "total_transferencia" numeric, "total_cheque" numeric, "total_cuenta_corriente" numeric, "total_tarjeta" numeric, "total_otros" numeric, "total_general" numeric, "cantidad_pedidos" bigint, "controlada" boolean, "controlada_at" timestamp with time zone, "controlada_por_nombre" "text")
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal_id BIGINT;
BEGIN
  v_sucursal_id := current_sucursal_id();

  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  RETURN QUERY
  SELECT
    p.fecha_entrega::date AS fecha,
    p.transportista_id,
    tr.nombre::text AS transportista_nombre,
    COALESCE(SUM(CASE WHEN p.forma_pago = 'efectivo' THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_efectivo,
    COALESCE(SUM(CASE WHEN p.forma_pago = 'transferencia' THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_transferencia,
    COALESCE(SUM(CASE WHEN p.forma_pago = 'cheque' THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_cheque,
    COALESCE(SUM(CASE WHEN p.forma_pago = 'cuenta_corriente' THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_cuenta_corriente,
    COALESCE(SUM(CASE WHEN p.forma_pago = 'tarjeta' THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_tarjeta,
    COALESCE(SUM(CASE WHEN p.forma_pago NOT IN ('efectivo','transferencia','cheque','cuenta_corriente','tarjeta')
                           OR p.forma_pago IS NULL THEN p.monto_pagado ELSE 0 END), 0)::numeric AS total_otros,
    COALESCE(SUM(p.monto_pagado), 0)::numeric AS total_general,
    COUNT(p.id)::bigint AS cantidad_pedidos,
    (rc.id IS NOT NULL) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre
  FROM pedidos p
  JOIN perfiles tr ON tr.id = p.transportista_id
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = p.fecha_entrega::date
   AND rc.transportista_id = p.transportista_id
   AND rc.sucursal_id = p.sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por
  WHERE p.estado = 'entregado'
    AND p.fecha_entrega IS NOT NULL
    AND p.transportista_id IS NOT NULL
    AND p.fecha_entrega::date BETWEEN p_fecha_desde AND p_fecha_hasta
    AND p.sucursal_id = v_sucursal_id
    AND (p_transportista_id IS NULL OR p.transportista_id = p_transportista_id)
  GROUP BY
    p.fecha_entrega::date,
    p.transportista_id,
    tr.nombre,
    rc.id,
    rc.controlada_at,
    cp.nombre
  ORDER BY p.fecha_entrega::date DESC, tr.nombre ASC;
END;
$$;


ALTER FUNCTION "public"."obtener_resumen_rendiciones"("p_fecha_desde" "date", "p_fecha_hasta" "date", "p_transportista_id" "uuid") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."obtener_resumen_rendiciones"("p_fecha_desde" "date", "p_fecha_hasta" "date", "p_transportista_id" "uuid") IS 'Resumen auto-calculado de rendiciones por (fecha, transportista) con breakdown por forma de pago y estado de control.';



CREATE OR REPLACE FUNCTION "public"."obtener_sucursales_usuario"() RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
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


ALTER FUNCTION "public"."obtener_sucursales_usuario"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."presentar_rendicion"("p_rendicion_id" bigint, "p_monto_rendido" numeric, "p_justificacion" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."presentar_rendicion"("p_rendicion_id" bigint, "p_monto_rendido" numeric, "p_justificacion" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."presentar_rendicion"("p_rendicion_id" bigint, "p_monto_rendido" numeric, "p_justificacion" "text") IS 'Presenta una rendición con el monto rendido';



CREATE OR REPLACE FUNCTION "public"."registrar_cambio_pedido"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  usuario_actual UUID;
BEGIN
  BEGIN
    usuario_actual := current_setting('app.current_user_id', true)::UUID;
  EXCEPTION WHEN OTHERS THEN
    usuario_actual := NULL;
  END;

  IF OLD.estado IS DISTINCT FROM NEW.estado THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'estado', OLD.estado, NEW.estado, NEW.sucursal_id);
  END IF;

  IF OLD.transportista_id IS DISTINCT FROM NEW.transportista_id THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'transportista_id',
            COALESCE(OLD.transportista_id::TEXT, 'sin asignar'),
            COALESCE(NEW.transportista_id::TEXT, 'sin asignar'),
            NEW.sucursal_id);
  END IF;

  IF OLD.notas IS DISTINCT FROM NEW.notas THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'notas',
            COALESCE(OLD.notas, '(sin notas)'),
            COALESCE(NEW.notas, '(sin notas)'),
            NEW.sucursal_id);
  END IF;

  IF OLD.forma_pago IS DISTINCT FROM NEW.forma_pago THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'forma_pago',
            COALESCE(OLD.forma_pago, 'efectivo'),
            COALESCE(NEW.forma_pago, 'efectivo'),
            NEW.sucursal_id);
  END IF;

  IF OLD.estado_pago IS DISTINCT FROM NEW.estado_pago THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'estado_pago',
            COALESCE(OLD.estado_pago, 'pendiente'),
            COALESCE(NEW.estado_pago, 'pendiente'),
            NEW.sucursal_id);
  END IF;

  IF OLD.total IS DISTINCT FROM NEW.total THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
    VALUES (NEW.id, usuario_actual, 'total',
            OLD.total::TEXT,
            NEW.total::TEXT,
            NEW.sucursal_id);
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."registrar_cambio_pedido"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_cambio_stock"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF OLD.stock IS DISTINCT FROM NEW.stock THEN
    INSERT INTO stock_historico (producto_id, stock_anterior, stock_nuevo, origen, sucursal_id)
    VALUES (NEW.id, OLD.stock, NEW.stock, 'auto', NEW.sucursal_id);
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."registrar_cambio_stock"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_compra_completa"("p_proveedor_id" bigint, "p_proveedor_nombre" character varying, "p_numero_factura" character varying, "p_fecha_compra" "date", "p_subtotal" numeric, "p_iva" numeric, "p_otros_impuestos" numeric, "p_total" numeric, "p_forma_pago" character varying, "p_notas" "text", "p_usuario_id" "uuid", "p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_compra_id BIGINT; v_item JSONB; v_producto RECORD; v_stock_anterior INTEGER; v_stock_nuevo INTEGER;
  v_items_procesados JSONB := '[]'::JSONB; v_costo_neto DECIMAL; v_costo_con_iva DECIMAL;
  v_porcentaje_iva DECIMAL; v_impuestos_internos DECIMAL; v_bonificacion DECIMAL; v_user_role TEXT;
BEGIN
  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa'); END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide'); END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN RETURN jsonb_build_object('success', false, 'error', 'No autorizado'); END IF;
  INSERT INTO compras (proveedor_id, proveedor_nombre, numero_factura, fecha_compra, subtotal, iva, otros_impuestos, total, forma_pago, notas, usuario_id, estado, sucursal_id)
  VALUES (p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra, p_subtotal, p_iva, p_otros_impuestos, p_total, p_forma_pago, p_notas, p_usuario_id, 'recibida', v_sucursal)
  RETURNING id INTO v_compra_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT id, stock INTO v_producto FROM productos WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_sucursal FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto no encontrado: %', v_item->>'producto_id'; END IF;
    v_stock_anterior := COALESCE(v_producto.stock, 0);
    v_stock_nuevo := v_stock_anterior + (v_item->>'cantidad')::INTEGER;
    v_bonificacion := COALESCE((v_item->>'bonificacion')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((v_item->>'porcentaje_iva')::DECIMAL, 21);
    v_impuestos_internos := COALESCE((v_item->>'impuestos_internos')::DECIMAL, 0);
    INSERT INTO compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, bonificacion, sucursal_id)
    VALUES (v_compra_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INTEGER, COALESCE((v_item->>'costo_unitario')::DECIMAL, 0), COALESCE((v_item->>'subtotal')::DECIMAL, 0), v_stock_anterior, v_stock_nuevo, v_bonificacion, v_sucursal);
    v_costo_neto := COALESCE((v_item->>'costo_unitario')::DECIMAL, 0) * (1 - v_bonificacion / 100);
    v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);
    UPDATE productos SET stock = stock + (v_item->>'cantidad')::INTEGER, costo_sin_iva = v_costo_neto, costo_con_iva = v_costo_con_iva, impuestos_internos = v_impuestos_internos, porcentaje_iva = v_porcentaje_iva, updated_at = NOW() WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_sucursal;
    v_items_procesados := v_items_procesados || jsonb_build_object('producto_id', (v_item->>'producto_id')::BIGINT, 'cantidad', (v_item->>'cantidad')::INTEGER, 'stock_anterior', v_stock_anterior, 'stock_nuevo', v_stock_nuevo);
  END LOOP;
  RETURN jsonb_build_object('success', true, 'compra_id', v_compra_id, 'items_procesados', v_items_procesados);
EXCEPTION WHEN OTHERS THEN RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."registrar_compra_completa"("p_proveedor_id" bigint, "p_proveedor_nombre" character varying, "p_numero_factura" character varying, "p_fecha_compra" "date", "p_subtotal" numeric, "p_iva" numeric, "p_otros_impuestos" numeric, "p_total" numeric, "p_forma_pago" character varying, "p_notas" "text", "p_usuario_id" "uuid", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_compra_completa"("p_proveedor_id" bigint, "p_proveedor_nombre" character varying, "p_numero_factura" character varying, "p_fecha_compra" "date", "p_subtotal" numeric, "p_iva" numeric, "p_otros_impuestos" numeric, "p_total" numeric, "p_forma_pago" character varying, "p_notas" "text", "p_usuario_id" "uuid", "p_items" "jsonb", "p_tipo_factura" character varying DEFAULT 'FC'::character varying) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal            BIGINT := current_sucursal_id();
  v_compra_id           BIGINT;
  v_item                JSONB;
  v_producto            RECORD;
  v_stock_anterior      INTEGER;
  v_stock_nuevo         INTEGER;
  v_cantidad            INTEGER;
  v_bonificacion        NUMERIC;
  v_porcentaje_iva      NUMERIC;
  v_impuestos_internos  NUMERIC;
  v_costo_unitario      NUMERIC;
  v_costo_neto          NUMERIC;
  v_costo_con_iva       NUMERIC;
  v_tipo_factura        TEXT;
  v_items_procesados    JSONB := '[]'::JSONB;
  v_user_role           TEXT;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden registrar compras');
  END IF;

  v_tipo_factura := COALESCE(p_tipo_factura, 'FC');

  INSERT INTO compras (
    proveedor_id, proveedor_nombre, numero_factura, fecha_compra,
    subtotal, iva, otros_impuestos, total, forma_pago, notas,
    usuario_id, estado, tipo_factura, sucursal_id
  ) VALUES (
    p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra,
    p_subtotal,
    CASE WHEN v_tipo_factura = 'ZZ' THEN 0 ELSE p_iva END,
    p_otros_impuestos, p_total, p_forma_pago, p_notas,
    p_usuario_id, 'recibida', v_tipo_factura, v_sucursal
  )
  RETURNING id INTO v_compra_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT id, stock INTO v_producto
      FROM productos
     WHERE id = (v_item->>'producto_id')::BIGINT
       AND sucursal_id = v_sucursal
     FOR UPDATE;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'Producto no encontrado: %', v_item->>'producto_id';
    END IF;

    v_cantidad           := (v_item->>'cantidad')::INTEGER;
    v_stock_anterior     := COALESCE(v_producto.stock, 0);
    v_stock_nuevo        := v_stock_anterior + v_cantidad;
    v_costo_unitario     := COALESCE((v_item->>'costo_unitario')::NUMERIC, 0);
    v_bonificacion       := COALESCE((v_item->>'bonificacion')::NUMERIC, 0);
    v_porcentaje_iva     := COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21);
    v_impuestos_internos := COALESCE((v_item->>'impuestos_internos')::NUMERIC, 0);

    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      stock_anterior, stock_nuevo, bonificacion, sucursal_id
    ) VALUES (
      v_compra_id,
      (v_item->>'producto_id')::BIGINT,
      v_cantidad,
      v_costo_unitario,
      COALESCE((v_item->>'subtotal')::NUMERIC, 0),
      v_stock_anterior,
      v_stock_nuevo,
      v_bonificacion,
      v_sucursal
    );

    v_costo_neto := v_costo_unitario * (1 - v_bonificacion / 100);

    IF v_tipo_factura = 'ZZ' THEN
      v_costo_con_iva  := v_costo_neto;
      v_porcentaje_iva := 0;
    ELSE
      v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);
    END IF;

    UPDATE productos
       SET stock              = stock + v_cantidad,
           costo_sin_iva      = v_costo_neto,
           costo_con_iva      = v_costo_con_iva,
           impuestos_internos = v_impuestos_internos,
           porcentaje_iva     = v_porcentaje_iva,
           updated_at         = NOW()
     WHERE id = (v_item->>'producto_id')::BIGINT
       AND sucursal_id = v_sucursal;

    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id',    (v_item->>'producto_id')::BIGINT,
      'cantidad',       v_cantidad,
      'stock_anterior', v_stock_anterior,
      'stock_nuevo',    v_stock_nuevo,
      'costo_sin_iva',  v_costo_neto,
      'costo_con_iva',  v_costo_con_iva
    );
  END LOOP;

  RETURN jsonb_build_object(
    'success',          true,
    'compra_id',        v_compra_id,
    'items_procesados', v_items_procesados
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."registrar_compra_completa"("p_proveedor_id" bigint, "p_proveedor_nombre" character varying, "p_numero_factura" character varying, "p_fecha_compra" "date", "p_subtotal" numeric, "p_iva" numeric, "p_otros_impuestos" numeric, "p_total" numeric, "p_forma_pago" character varying, "p_notas" "text", "p_usuario_id" "uuid", "p_items" "jsonb", "p_tipo_factura" character varying) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_creacion_pedido"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
DECLARE
  usuario_actual UUID;
BEGIN
  BEGIN
    usuario_actual := current_setting('app.current_user_id', true)::UUID;
  EXCEPTION WHEN OTHERS THEN
    usuario_actual := NEW.usuario_id;
  END;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo, sucursal_id)
  VALUES (NEW.id, COALESCE(usuario_actual, NEW.usuario_id), 'creacion', NULL, 'Pedido creado', NEW.sucursal_id);

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."registrar_creacion_pedido"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_ingreso_sucursal"("p_sucursal_id" bigint, "p_fecha" "date" DEFAULT CURRENT_DATE, "p_notas" "text" DEFAULT NULL::"text", "p_total_costo" numeric DEFAULT 0, "p_usuario_id" "uuid" DEFAULT NULL::"uuid", "p_items" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_tenant BIGINT := current_sucursal_id();
  v_transferencia_id BIGINT;
  v_item JSONB;
  v_stock_actual INT;
  v_user_role TEXT;
BEGIN
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;
  INSERT INTO transferencias_stock (sucursal_id, tipo, fecha, notas, total_costo, usuario_id, tenant_sucursal_id)
  VALUES (p_sucursal_id, 'ingreso', p_fecha, p_notas, p_total_costo, COALESCE(p_usuario_id, auth.uid()), v_tenant)
  RETURNING id INTO v_transferencia_id;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT stock INTO v_stock_actual FROM productos
     WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_tenant FOR UPDATE;
    IF v_stock_actual IS NULL THEN RAISE EXCEPTION 'Producto % no encontrado en la sucursal', (v_item->>'producto_id'); END IF;
    INSERT INTO transferencia_items (transferencia_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, sucursal_id)
    VALUES (v_transferencia_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INT,
            COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
            (v_item->>'cantidad')::INT * COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
            v_stock_actual, v_stock_actual + (v_item->>'cantidad')::INT, v_tenant);
    UPDATE productos SET stock = stock + (v_item->>'cantidad')::INT
     WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_tenant;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'transferencia_id', v_transferencia_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."registrar_ingreso_sucursal"("p_sucursal_id" bigint, "p_fecha" "date", "p_notas" "text", "p_total_costo" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."registrar_ingreso_sucursal"("p_sucursal_id" bigint, "p_fecha" "date", "p_notas" "text", "p_total_costo" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") IS 'Registra un ingreso de stock desde una sucursal (aumenta stock central)';



CREATE OR REPLACE FUNCTION "public"."registrar_nota_credito"("p_compra_id" bigint, "p_numero_nota" character varying DEFAULT NULL::character varying, "p_motivo" "text" DEFAULT NULL::"text", "p_subtotal" numeric DEFAULT 0, "p_iva" numeric DEFAULT 0, "p_total" numeric DEFAULT 0, "p_usuario_id" "uuid" DEFAULT NULL::"uuid", "p_items" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_nota_id BIGINT; v_item JSONB; v_stock_actual INTEGER;
  v_producto_id BIGINT; v_cantidad INTEGER; v_costo DECIMAL; v_sub DECIMAL;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  IF NOT (es_encargado_o_admin()) THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado para registrar notas de credito');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM compras WHERE id = p_compra_id AND estado != 'cancelada' AND sucursal_id = v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada o cancelada');
  END IF;

  INSERT INTO notas_credito (compra_id, numero_nota, fecha, subtotal, iva, total, motivo, usuario_id, sucursal_id)
  VALUES (p_compra_id, p_numero_nota, CURRENT_DATE, p_subtotal, p_iva, p_total, p_motivo, p_usuario_id, v_sucursal)
  RETURNING id INTO v_nota_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (v_item->>'producto_id')::BIGINT;
    v_cantidad := (v_item->>'cantidad')::INTEGER;
    v_costo := (v_item->>'costo_unitario')::DECIMAL;
    v_sub := (v_item->>'subtotal')::DECIMAL;
    SELECT stock INTO v_stock_actual FROM productos WHERE id = v_producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    IF v_stock_actual IS NULL THEN RAISE EXCEPTION 'Producto % no encontrado', v_producto_id; END IF;
    INSERT INTO nota_credito_items (nota_credito_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, sucursal_id)
    VALUES (v_nota_id, v_producto_id, v_cantidad, v_costo, v_sub, v_stock_actual, GREATEST(v_stock_actual - v_cantidad, 0), v_sucursal);
    UPDATE productos SET stock = GREATEST(stock - v_cantidad, 0) WHERE id = v_producto_id AND sucursal_id = v_sucursal;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'nota_credito_id', v_nota_id);
END;
$$;


ALTER FUNCTION "public"."registrar_nota_credito"("p_compra_id" bigint, "p_numero_nota" character varying, "p_motivo" "text", "p_subtotal" numeric, "p_iva" numeric, "p_total" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_salvedad"("p_pedido_id" bigint, "p_pedido_item_id" bigint, "p_cantidad_afectada" integer, "p_motivo" character varying, "p_descripcion" "text" DEFAULT NULL::"text", "p_foto_url" "text" DEFAULT NULL::"text", "p_devolver_stock" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad_id BIGINT;
  v_item RECORD;
  v_cantidad_entregada INTEGER;
  v_monto_afectado DECIMAL;
  v_usuario_id UUID;
  v_es_admin BOOLEAN;
  v_subtotal_nuevo DECIMAL;
  v_stock_devuelto BOOLEAN := FALSE;
  v_merma_registrada BOOLEAN := FALSE;
  v_stock_actual INTEGER;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  v_usuario_id := auth.uid();
  IF v_usuario_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Usuario no autenticado');
  END IF;
  SELECT EXISTS (SELECT 1 FROM perfiles WHERE id = v_usuario_id AND rol = 'admin') INTO v_es_admin;
  IF NOT v_es_admin THEN
    IF NOT EXISTS (
      SELECT 1 FROM pedidos
      WHERE id = p_pedido_id AND transportista_id = v_usuario_id AND sucursal_id = v_sucursal
    ) THEN
      RETURN jsonb_build_object('success', false, 'error', 'No autorizado para este pedido');
    END IF;
  END IF;
  SELECT pi.id, pi.producto_id, pi.cantidad, pi.precio_unitario, pi.subtotal
    INTO v_item
    FROM pedido_items pi
   WHERE pi.id = p_pedido_item_id AND pi.pedido_id = p_pedido_id AND pi.sucursal_id = v_sucursal;
  IF v_item IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'Item de pedido no encontrado');
  END IF;
  IF p_cantidad_afectada > v_item.cantidad THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad afectada mayor a cantidad del item');
  END IF;
  IF p_cantidad_afectada <= 0 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Cantidad debe ser mayor a 0');
  END IF;
  v_cantidad_entregada := v_item.cantidad - p_cantidad_afectada;
  v_monto_afectado := p_cantidad_afectada * v_item.precio_unitario;
  v_subtotal_nuevo := v_cantidad_entregada * v_item.precio_unitario;
  IF p_motivo IN ('cliente_rechaza', 'error_pedido', 'diferencia_precio') THEN
    v_stock_devuelto := TRUE;
  END IF;
  INSERT INTO salvedades_items (
    pedido_id, pedido_item_id, producto_id, cantidad_original, cantidad_afectada,
    cantidad_entregada, motivo, descripcion, foto_url, monto_afectado, precio_unitario,
    reportado_por, stock_devuelto, stock_devuelto_at, estado_resolucion, sucursal_id
  ) VALUES (
    p_pedido_id, p_pedido_item_id, v_item.producto_id, v_item.cantidad, p_cantidad_afectada,
    v_cantidad_entregada, p_motivo, p_descripcion, p_foto_url, v_monto_afectado, v_item.precio_unitario,
    v_usuario_id, v_stock_devuelto, CASE WHEN v_stock_devuelto THEN NOW() ELSE NULL END, 'pendiente', v_sucursal
  ) RETURNING id INTO v_salvedad_id;
  IF v_salvedad_id IS NULL THEN RAISE EXCEPTION 'No se pudo crear la salvedad'; END IF;
  IF v_cantidad_entregada > 0 THEN
    UPDATE pedido_items SET cantidad = v_cantidad_entregada, subtotal = v_subtotal_nuevo
     WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  ELSE
    DELETE FROM pedido_items WHERE id = p_pedido_item_id AND sucursal_id = v_sucursal;
  END IF;
  UPDATE pedidos
     SET total = (SELECT COALESCE(SUM(subtotal), 0) FROM pedido_items WHERE pedido_id = p_pedido_id AND sucursal_id = v_sucursal),
         updated_at = NOW()
   WHERE id = p_pedido_id AND sucursal_id = v_sucursal;
  IF v_stock_devuelto THEN
    UPDATE productos SET stock = stock + p_cantidad_afectada WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
  END IF;
  IF p_motivo IN ('producto_danado', 'producto_vencido') THEN
    SELECT stock INTO v_stock_actual FROM productos
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal FOR UPDATE;
    INSERT INTO mermas_stock (
      producto_id, cantidad, motivo, observaciones,
      stock_anterior, stock_nuevo, usuario_id, sucursal_id
    ) VALUES (
      v_item.producto_id, p_cantidad_afectada,
      CASE p_motivo WHEN 'producto_danado' THEN 'rotura' WHEN 'producto_vencido' THEN 'vencimiento' END,
      COALESCE(p_descripcion, 'Salvedad pedido #' || p_pedido_id || ': ' || p_motivo),
      v_stock_actual, GREATEST(v_stock_actual - p_cantidad_afectada, 0), v_usuario_id, v_sucursal
    );
    UPDATE productos SET stock = GREATEST(stock - p_cantidad_afectada, 0)
     WHERE id = v_item.producto_id AND sucursal_id = v_sucursal;
    v_merma_registrada := TRUE;
  END IF;
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (v_salvedad_id, 'creacion', 'pendiente', p_descripcion, v_usuario_id, v_sucursal);
  RETURN jsonb_build_object(
    'success', true, 'salvedad_id', v_salvedad_id, 'monto_afectado', v_monto_afectado,
    'cantidad_entregada', v_cantidad_entregada, 'stock_devuelto', v_stock_devuelto,
    'merma_registrada', v_merma_registrada,
    'nuevo_total_pedido', (SELECT total FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal)
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."registrar_salvedad"("p_pedido_id" bigint, "p_pedido_item_id" bigint, "p_cantidad_afectada" integer, "p_motivo" character varying, "p_descripcion" "text", "p_foto_url" "text", "p_devolver_stock" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."registrar_transferencia"("p_sucursal_id" bigint, "p_fecha" "date" DEFAULT CURRENT_DATE, "p_notas" "text" DEFAULT NULL::"text", "p_total_costo" numeric DEFAULT 0, "p_usuario_id" "uuid" DEFAULT NULL::"uuid", "p_items" "jsonb" DEFAULT '[]'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_tenant BIGINT := current_sucursal_id();
  v_transferencia_id BIGINT;
  v_item JSONB;
  v_stock_actual INT;
  v_producto_nombre TEXT;
  v_user_role TEXT;
BEGIN
  IF v_tenant IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;
  INSERT INTO transferencias_stock (sucursal_id, tipo, fecha, notas, total_costo, usuario_id, tenant_sucursal_id)
  VALUES (p_sucursal_id, 'egreso', p_fecha, p_notas, p_total_costo, COALESCE(p_usuario_id, auth.uid()), v_tenant)
  RETURNING id INTO v_transferencia_id;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_tenant FOR UPDATE;
    IF v_stock_actual IS NULL THEN RAISE EXCEPTION 'Producto % no encontrado en la sucursal', (v_item->>'producto_id'); END IF;
    IF v_stock_actual < (v_item->>'cantidad')::INT THEN
      RAISE EXCEPTION 'Stock insuficiente para %: disponible %, solicitado %', v_producto_nombre, v_stock_actual, (v_item->>'cantidad')::INT;
    END IF;
    INSERT INTO transferencia_items (transferencia_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, sucursal_id)
    VALUES (v_transferencia_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INT,
            COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
            (v_item->>'cantidad')::INT * COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
            v_stock_actual, v_stock_actual - (v_item->>'cantidad')::INT, v_tenant);
    UPDATE productos SET stock = stock - (v_item->>'cantidad')::INT
     WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_tenant;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'transferencia_id', v_transferencia_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;


ALTER FUNCTION "public"."registrar_transferencia"("p_sucursal_id" bigint, "p_fecha" "date", "p_notas" "text", "p_total_costo" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolver_salvedad"("p_salvedad_id" bigint, "p_estado_resolucion" character varying, "p_notas" "text" DEFAULT NULL::"text", "p_pedido_reprogramado_id" bigint DEFAULT NULL::bigint) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_salvedad RECORD;
  v_usuario_id UUID := auth.uid();
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF NOT es_admin_salvedades() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo admin');
  END IF;
  SELECT * INTO v_salvedad FROM salvedades_items WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'No encontrada'); END IF;
  IF v_salvedad.estado_resolucion != 'pendiente' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Ya resuelta');
  END IF;
  UPDATE salvedades_items SET
    estado_resolucion = p_estado_resolucion,
    resolucion_notas = p_notas,
    resolucion_fecha = NOW(),
    resuelto_por = v_usuario_id,
    pedido_reprogramado_id = p_pedido_reprogramado_id,
    updated_at = NOW()
  WHERE id = p_salvedad_id AND sucursal_id = v_sucursal;
  INSERT INTO salvedad_historial (salvedad_id, accion, estado_anterior, estado_nuevo, notas, usuario_id, sucursal_id)
  VALUES (p_salvedad_id, 'resolucion', v_salvedad.estado_resolucion, p_estado_resolucion, p_notas, v_usuario_id, v_sucursal);
  RETURN jsonb_build_object('success', true, 'nuevo_estado', p_estado_resolucion);
END;
$$;


ALTER FUNCTION "public"."resolver_salvedad"("p_salvedad_id" bigint, "p_estado_resolucion" character varying, "p_notas" "text", "p_pedido_reprogramado_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."restaurar_stock_atomico"("p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item JSONB; v_producto_id INT; v_cantidad INT; errores TEXT[] := '{}'; v_user_role TEXT;
BEGIN
  IF v_sucursal IS NULL THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No se pudo determinar la sucursal activa')); END IF;
  SELECT rol INTO v_user_role FROM perfiles WHERE id = auth.uid();
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No autorizado')); END IF;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (v_item->>'producto_id')::INT; v_cantidad := (v_item->>'cantidad')::INT;
    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN errores := array_append(errores, 'Cantidad invalida'); CONTINUE; END IF;
    UPDATE productos SET stock = stock + v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;
    IF NOT FOUND THEN errores := array_append(errores, 'Producto ' || v_producto_id || ' no encontrado'); END IF;
  END LOOP;
  IF array_length(errores, 1) > 0 THEN RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores)); END IF;
  RETURN jsonb_build_object('success', true, 'errores', '[]'::jsonb);
END;
$$;


ALTER FUNCTION "public"."restaurar_stock_atomico"("p_items" "jsonb") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."restaurar_stock_atomico"("p_items" "jsonb") IS 'Restaura stock de múltiples productos de forma atómica. Valida cantidades positivas';



CREATE OR REPLACE FUNCTION "public"."revisar_rendicion"("p_rendicion_id" bigint, "p_accion" character varying, "p_observaciones" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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
$$;


ALTER FUNCTION "public"."revisar_rendicion"("p_rendicion_id" bigint, "p_accion" character varying, "p_observaciones" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."revisar_rendicion"("p_rendicion_id" bigint, "p_accion" character varying, "p_observaciones" "text") IS 'Permite al admin aprobar, rechazar u observar una rendición';



CREATE OR REPLACE FUNCTION "public"."set_sucursal_id_default"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
BEGIN
  IF NEW.sucursal_id IS NULL THEN
    NEW.sucursal_id := current_sucursal_id();
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_sucursal_id_default"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_compras_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_compras_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_grupos_precio_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_grupos_precio_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_productos_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_productos_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_promociones_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_promociones_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_proveedores_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_proveedores_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_rendiciones_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_rendiciones_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_salvedades_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_salvedades_updated_at"() OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."audit_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tabla" "text" NOT NULL,
    "registro_id" "text" NOT NULL,
    "accion" "text" NOT NULL,
    "old_data" "jsonb",
    "new_data" "jsonb",
    "campos_modificados" "text"[],
    "usuario_id" "uuid",
    "usuario_email" "text",
    "usuario_rol" "text",
    "ip_address" "inet",
    "user_agent" "text",
    "session_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sucursal_id" bigint,
    CONSTRAINT "audit_logs_accion_check" CHECK (("accion" = ANY (ARRAY['INSERT'::"text", 'UPDATE'::"text", 'DELETE'::"text"])))
);


ALTER TABLE "public"."audit_logs" OWNER TO "postgres";


COMMENT ON TABLE "public"."audit_logs" IS 'Registro inmutable de auditoría para detectar fraude y mantener trazabilidad';



COMMENT ON COLUMN "public"."audit_logs"."old_data" IS 'Estado anterior del registro (NULL para INSERT)';



COMMENT ON COLUMN "public"."audit_logs"."new_data" IS 'Estado nuevo del registro (NULL para DELETE)';



COMMENT ON COLUMN "public"."audit_logs"."campos_modificados" IS 'Lista de campos que fueron modificados (solo para UPDATE)';



CREATE TABLE IF NOT EXISTS "public"."perfiles" (
    "id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "nombre" "text" NOT NULL,
    "rol" "text" DEFAULT 'preventista'::"text" NOT NULL,
    "activo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "zona" character varying(50),
    CONSTRAINT "perfiles_rol_check" CHECK (("rol" = ANY (ARRAY['admin'::"text", 'preventista'::"text", 'transportista'::"text"])))
);


ALTER TABLE "public"."perfiles" OWNER TO "postgres";


COMMENT ON COLUMN "public"."perfiles"."zona" IS 'Zona asignada al preventista (ej: 1, 2, 3, Norte, Sur, etc.)';



CREATE OR REPLACE VIEW "public"."audit_logs_detallado" WITH ("security_invoker"='true') AS
 SELECT "al"."id",
    "al"."tabla",
    "al"."registro_id",
    "al"."accion",
    "al"."old_data",
    "al"."new_data",
    "al"."campos_modificados",
    "al"."usuario_id",
    "al"."usuario_email",
    "al"."usuario_rol",
    "al"."ip_address",
    "al"."user_agent",
    "al"."session_id",
    "al"."created_at",
    COALESCE("al"."usuario_email", ("u"."email")::"text") AS "email_resuelto",
    COALESCE("al"."usuario_rol", "p"."rol") AS "rol_resuelto"
   FROM (("public"."audit_logs" "al"
     LEFT JOIN "auth"."users" "u" ON (("u"."id" = "al"."usuario_id")))
     LEFT JOIN "public"."perfiles" "p" ON (("p"."id" = "al"."usuario_id")));


ALTER VIEW "public"."audit_logs_detallado" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."clientes_codigo_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."clientes_codigo_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clientes" (
    "id" bigint NOT NULL,
    "razon_social" "text" NOT NULL,
    "nombre_fantasia" "text" NOT NULL,
    "direccion" "text" NOT NULL,
    "telefono" "text",
    "zona" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "latitud" numeric(10,7),
    "longitud" numeric(10,7),
    "limite_credito" numeric(12,2) DEFAULT 0,
    "saldo_cuenta" numeric(12,2) DEFAULT 0,
    "dias_credito" integer DEFAULT 30,
    "cuit" character varying(13),
    "contacto" character varying(100),
    "horarios_atencion" "text",
    "rubro" character varying(100),
    "notas" "text",
    "tipo_documento" character varying(4) DEFAULT 'CUIT'::character varying,
    "preventista_id" "uuid",
    "activo" boolean DEFAULT true NOT NULL,
    "zona_id" bigint,
    "codigo" integer DEFAULT "nextval"('"public"."clientes_codigo_seq"'::"regclass") NOT NULL,
    "sucursal_id" bigint NOT NULL,
    "tp_import_id" bigint,
    CONSTRAINT "clientes_tipo_documento_check" CHECK ((("tipo_documento")::"text" = ANY ((ARRAY['CUIT'::character varying, 'DNI'::character varying])::"text"[])))
);


ALTER TABLE "public"."clientes" OWNER TO "postgres";


COMMENT ON COLUMN "public"."clientes"."razon_social" IS 'Razón social del cliente (nombre legal)';



COMMENT ON COLUMN "public"."clientes"."limite_credito" IS 'Límite de crédito asignado al cliente';



COMMENT ON COLUMN "public"."clientes"."saldo_cuenta" IS 'Saldo actual de la cuenta corriente (positivo = debe, negativo = a favor)';



COMMENT ON COLUMN "public"."clientes"."dias_credito" IS 'Días de crédito otorgados al cliente';



COMMENT ON COLUMN "public"."clientes"."cuit" IS 'Número de documento. CUIT: formato XX-XXXXXXXX-X, DNI: formato 00-XXXXXXXX-0 (estandarizado a 11 dígitos)';



COMMENT ON COLUMN "public"."clientes"."contacto" IS 'Nombre de la persona que atiende el teléfono';



COMMENT ON COLUMN "public"."clientes"."horarios_atencion" IS 'Horarios de atención del cliente';



COMMENT ON COLUMN "public"."clientes"."rubro" IS 'Clasificación del cliente (gimnasio, bar, kiosco, etc.)';



COMMENT ON COLUMN "public"."clientes"."notas" IS 'Notas adicionales sobre el cliente';



COMMENT ON COLUMN "public"."clientes"."tipo_documento" IS 'Tipo de documento: CUIT (XX-XXXXXXXX-X) o DNI (formato almacenado: 00-XXXXXXXX-0)';



COMMENT ON COLUMN "public"."clientes"."tp_import_id" IS 'TP Export source id for rows imported via migration 062.';



CREATE SEQUENCE IF NOT EXISTS "public"."clientes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."clientes_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."clientes_id_seq" OWNED BY "public"."clientes"."id";



CREATE TABLE IF NOT EXISTS "public"."compra_items" (
    "id" bigint NOT NULL,
    "compra_id" bigint NOT NULL,
    "producto_id" bigint NOT NULL,
    "cantidad" integer NOT NULL,
    "costo_unitario" numeric(12,2) DEFAULT 0 NOT NULL,
    "subtotal" numeric(12,2) DEFAULT 0 NOT NULL,
    "stock_anterior" integer DEFAULT 0 NOT NULL,
    "stock_nuevo" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "bonificacion" numeric DEFAULT 0,
    "sucursal_id" bigint NOT NULL,
    "tp_import_id" bigint,
    CONSTRAINT "compra_items_cantidad_check" CHECK (("cantidad" > 0))
);


ALTER TABLE "public"."compra_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."compra_items" IS 'Items individuales de cada compra';



COMMENT ON COLUMN "public"."compra_items"."stock_anterior" IS 'Stock del producto antes de la compra';



COMMENT ON COLUMN "public"."compra_items"."stock_nuevo" IS 'Stock del producto después de la compra';



CREATE SEQUENCE IF NOT EXISTS "public"."compra_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."compra_items_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."compra_items_id_seq" OWNED BY "public"."compra_items"."id";



CREATE TABLE IF NOT EXISTS "public"."compras" (
    "id" bigint NOT NULL,
    "proveedor_id" bigint,
    "proveedor_nombre" character varying(200),
    "numero_factura" character varying(100),
    "fecha_compra" "date" DEFAULT CURRENT_DATE NOT NULL,
    "fecha_recepcion" "date",
    "subtotal" numeric(12,2) DEFAULT 0 NOT NULL,
    "iva" numeric(12,2) DEFAULT 0 NOT NULL,
    "otros_impuestos" numeric(12,2) DEFAULT 0 NOT NULL,
    "total" numeric(12,2) DEFAULT 0 NOT NULL,
    "forma_pago" character varying(50) DEFAULT 'efectivo'::character varying,
    "estado" character varying(50) DEFAULT 'pendiente'::character varying,
    "notas" "text",
    "usuario_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "tipo_factura" character varying(2) DEFAULT 'FC'::character varying,
    "sucursal_id" bigint NOT NULL,
    "tp_import_id" bigint,
    CONSTRAINT "compras_estado_check" CHECK ((("estado")::"text" = ANY ((ARRAY['pendiente'::character varying, 'recibida'::character varying, 'parcial'::character varying, 'cancelada'::character varying])::"text"[]))),
    CONSTRAINT "compras_forma_pago_check" CHECK ((("forma_pago")::"text" = ANY ((ARRAY['efectivo'::character varying, 'transferencia'::character varying, 'cheque'::character varying, 'cuenta_corriente'::character varying, 'tarjeta'::character varying])::"text"[]))),
    CONSTRAINT "compras_tipo_factura_check" CHECK ((("tipo_factura")::"text" = ANY ((ARRAY['ZZ'::character varying, 'FC'::character varying])::"text"[])))
);


ALTER TABLE "public"."compras" OWNER TO "postgres";


COMMENT ON TABLE "public"."compras" IS 'Registro de compras a proveedores con actualización automática de stock';



COMMENT ON COLUMN "public"."compras"."estado" IS 'Estado de la compra: pendiente, recibida, parcial, cancelada';



CREATE SEQUENCE IF NOT EXISTS "public"."compras_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."compras_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."compras_id_seq" OWNED BY "public"."compras"."id";



CREATE TABLE IF NOT EXISTS "public"."grupo_precio_escalas" (
    "id" bigint NOT NULL,
    "grupo_precio_id" bigint NOT NULL,
    "cantidad_minima" integer NOT NULL,
    "precio_unitario" numeric(12,2) NOT NULL,
    "etiqueta" character varying(100),
    "activo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL,
    CONSTRAINT "grupo_precio_escalas_cantidad_minima_check" CHECK (("cantidad_minima" > 0)),
    CONSTRAINT "grupo_precio_escalas_precio_unitario_check" CHECK (("precio_unitario" > (0)::numeric))
);


ALTER TABLE "public"."grupo_precio_escalas" OWNER TO "postgres";


COMMENT ON TABLE "public"."grupo_precio_escalas" IS 'Escalas de precio por volumen (umbrales) para cada grupo';



COMMENT ON COLUMN "public"."grupo_precio_escalas"."cantidad_minima" IS 'Cantidad mínima total del grupo para aplicar este precio';



COMMENT ON COLUMN "public"."grupo_precio_escalas"."precio_unitario" IS 'Precio unitario que aplica a TODOS los productos del grupo al alcanzar el umbral';



COMMENT ON COLUMN "public"."grupo_precio_escalas"."etiqueta" IS 'Etiqueta descriptiva, ej: Mayorista, Super Mayorista';



CREATE SEQUENCE IF NOT EXISTS "public"."grupo_precio_escalas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."grupo_precio_escalas_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."grupo_precio_escalas_id_seq" OWNED BY "public"."grupo_precio_escalas"."id";



CREATE TABLE IF NOT EXISTS "public"."grupo_precio_productos" (
    "id" bigint NOT NULL,
    "grupo_precio_id" bigint NOT NULL,
    "producto_id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "cantidad_minima_pedido" integer,
    "sucursal_id" bigint NOT NULL,
    CONSTRAINT "chk_cantidad_minima_pedido_positiva" CHECK ((("cantidad_minima_pedido" IS NULL) OR ("cantidad_minima_pedido" > 0)))
);


ALTER TABLE "public"."grupo_precio_productos" OWNER TO "postgres";


COMMENT ON TABLE "public"."grupo_precio_productos" IS 'Productos pertenecientes a cada grupo de precio';



COMMENT ON COLUMN "public"."grupo_precio_productos"."cantidad_minima_pedido" IS 'Cantidad mínima de pedido por producto dentro de este grupo. NULL = sin mínimo.';



CREATE SEQUENCE IF NOT EXISTS "public"."grupo_precio_productos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."grupo_precio_productos_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."grupo_precio_productos_id_seq" OWNED BY "public"."grupo_precio_productos"."id";



CREATE TABLE IF NOT EXISTS "public"."grupos_precio" (
    "id" bigint NOT NULL,
    "nombre" character varying(200) NOT NULL,
    "descripcion" "text",
    "activo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."grupos_precio" OWNER TO "postgres";


COMMENT ON TABLE "public"."grupos_precio" IS 'Grupos de productos para precios mayoristas por volumen';



CREATE SEQUENCE IF NOT EXISTS "public"."grupos_precio_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."grupos_precio_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."grupos_precio_id_seq" OWNED BY "public"."grupos_precio"."id";



CREATE TABLE IF NOT EXISTS "public"."historial_cambios" (
    "id" integer NOT NULL,
    "tabla" character varying(50) NOT NULL,
    "registro_id" integer NOT NULL,
    "operacion" character varying(20) NOT NULL,
    "datos_anteriores" "jsonb",
    "datos_nuevos" "jsonb",
    "usuario_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."historial_cambios" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."historial_cambios_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."historial_cambios_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."historial_cambios_id_seq" OWNED BY "public"."historial_cambios"."id";



CREATE TABLE IF NOT EXISTS "public"."mermas_stock" (
    "id" bigint NOT NULL,
    "producto_id" bigint NOT NULL,
    "cantidad" integer NOT NULL,
    "motivo" character varying(50) NOT NULL,
    "observaciones" "text",
    "stock_anterior" integer NOT NULL,
    "stock_nuevo" integer NOT NULL,
    "usuario_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL,
    CONSTRAINT "mermas_stock_cantidad_check" CHECK (("cantidad" > 0)),
    CONSTRAINT "mermas_stock_motivo_check" CHECK ((("motivo")::"text" = ANY ((ARRAY['rotura'::character varying, 'vencimiento'::character varying, 'robo'::character varying, 'decomiso'::character varying, 'devolucion'::character varying, 'error_inventario'::character varying, 'muestra'::character varying, 'otro'::character varying, 'promociones'::character varying])::"text"[])))
);


ALTER TABLE "public"."mermas_stock" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."mermas_stock_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."mermas_stock_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."mermas_stock_id_seq" OWNED BY "public"."mermas_stock"."id";



CREATE TABLE IF NOT EXISTS "public"."nota_credito_items" (
    "id" bigint NOT NULL,
    "nota_credito_id" bigint NOT NULL,
    "producto_id" bigint NOT NULL,
    "cantidad" integer NOT NULL,
    "costo_unitario" numeric(12,2) DEFAULT 0 NOT NULL,
    "subtotal" numeric(12,2) DEFAULT 0 NOT NULL,
    "stock_anterior" integer DEFAULT 0 NOT NULL,
    "stock_nuevo" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL,
    CONSTRAINT "nota_credito_items_cantidad_check" CHECK (("cantidad" > 0))
);


ALTER TABLE "public"."nota_credito_items" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."nota_credito_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."nota_credito_items_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."nota_credito_items_id_seq" OWNED BY "public"."nota_credito_items"."id";



CREATE TABLE IF NOT EXISTS "public"."notas_credito" (
    "id" bigint NOT NULL,
    "compra_id" bigint NOT NULL,
    "numero_nota" character varying(50),
    "fecha" "date" DEFAULT CURRENT_DATE NOT NULL,
    "subtotal" numeric(12,2) DEFAULT 0 NOT NULL,
    "iva" numeric(12,2) DEFAULT 0 NOT NULL,
    "total" numeric(12,2) DEFAULT 0 NOT NULL,
    "motivo" "text",
    "usuario_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."notas_credito" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."notas_credito_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."notas_credito_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."notas_credito_id_seq" OWNED BY "public"."notas_credito"."id";



CREATE TABLE IF NOT EXISTS "public"."pagos" (
    "id" integer NOT NULL,
    "cliente_id" integer NOT NULL,
    "pedido_id" integer,
    "monto" numeric(12,2) NOT NULL,
    "forma_pago" character varying(50) DEFAULT 'efectivo'::character varying NOT NULL,
    "referencia" character varying(255),
    "notas" "text",
    "usuario_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."pagos" OWNER TO "postgres";


COMMENT ON TABLE "public"."pagos" IS 'Registro de pagos realizados por clientes';



CREATE SEQUENCE IF NOT EXISTS "public"."pagos_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pagos_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pagos_id_seq" OWNED BY "public"."pagos"."id";



CREATE TABLE IF NOT EXISTS "public"."pedido_historial" (
    "id" bigint NOT NULL,
    "pedido_id" bigint NOT NULL,
    "usuario_id" "uuid",
    "campo_modificado" "text" NOT NULL,
    "valor_anterior" "text",
    "valor_nuevo" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL,
    "tp_import_id" bigint
);


ALTER TABLE "public"."pedido_historial" OWNER TO "postgres";


COMMENT ON TABLE "public"."pedido_historial" IS 'Registro de todos los cambios realizados en los pedidos (auditoría)';



CREATE SEQUENCE IF NOT EXISTS "public"."pedido_historial_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pedido_historial_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pedido_historial_id_seq" OWNED BY "public"."pedido_historial"."id";



CREATE TABLE IF NOT EXISTS "public"."pedido_items" (
    "id" bigint NOT NULL,
    "pedido_id" bigint,
    "producto_id" bigint,
    "cantidad" integer NOT NULL,
    "precio_unitario" numeric(10,2) NOT NULL,
    "subtotal" numeric(10,2) NOT NULL,
    "es_bonificacion" boolean DEFAULT false,
    "promocion_id" bigint,
    "neto_unitario" numeric(12,2),
    "iva_unitario" numeric(12,2) DEFAULT 0,
    "impuestos_internos_unitario" numeric(12,2) DEFAULT 0,
    "porcentaje_iva" numeric(5,2) DEFAULT 0,
    "sucursal_id" bigint NOT NULL,
    "tp_import_id" bigint
);


ALTER TABLE "public"."pedido_items" OWNER TO "postgres";


COMMENT ON COLUMN "public"."pedido_items"."es_bonificacion" IS 'true = unidad gratis por promocion (precio_unitario=0, stock NO se descuenta)';



CREATE SEQUENCE IF NOT EXISTS "public"."pedido_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pedido_items_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pedido_items_id_seq" OWNED BY "public"."pedido_items"."id";



CREATE TABLE IF NOT EXISTS "public"."pedidos" (
    "id" bigint NOT NULL,
    "cliente_id" bigint,
    "fecha" "date" DEFAULT CURRENT_DATE NOT NULL,
    "estado" "text" DEFAULT 'pendiente'::"text" NOT NULL,
    "total" numeric(10,2) DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "usuario_id" "uuid",
    "transportista_id" "uuid",
    "fecha_entrega" timestamp with time zone,
    "stock_descontado" boolean DEFAULT false,
    "notas" "text",
    "forma_pago" "text" DEFAULT 'efectivo'::"text",
    "estado_pago" "text" DEFAULT 'pendiente'::"text",
    "orden_entrega" integer,
    "monto_pagado" numeric(12,2) DEFAULT 0,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "motivo_cancelacion" "text",
    "tipo_factura" character varying(2) DEFAULT 'ZZ'::character varying,
    "total_neto" numeric(12,2),
    "total_iva" numeric(12,2) DEFAULT 0,
    "fecha_entrega_programada" "date",
    "sucursal_id" bigint NOT NULL,
    "tp_import_id" bigint,
    CONSTRAINT "pedidos_tipo_factura_check" CHECK ((("tipo_factura")::"text" = ANY ((ARRAY['ZZ'::character varying, 'FC'::character varying])::"text"[])))
);


ALTER TABLE "public"."pedidos" OWNER TO "postgres";


COMMENT ON COLUMN "public"."pedidos"."notas" IS 'Observaciones o notas importantes para la preparación del pedido';



COMMENT ON COLUMN "public"."pedidos"."forma_pago" IS 'Método de pago: efectivo, transferencia, cheque, cuenta_corriente, etc.';



COMMENT ON COLUMN "public"."pedidos"."estado_pago" IS 'Estado del pago: pendiente, pagado, parcial';



COMMENT ON COLUMN "public"."pedidos"."orden_entrega" IS 'Orden de entrega optimizado por Google Routes API (1 = primera entrega, 2 = segunda, etc.)';



COMMENT ON COLUMN "public"."pedidos"."monto_pagado" IS 'Monto total pagado por el cliente para este pedido';



COMMENT ON COLUMN "public"."pedidos"."tp_import_id" IS 'TP Export source id for rows imported via migration 062.';



CREATE TABLE IF NOT EXISTS "public"."pedidos_eliminados" (
    "id" bigint NOT NULL,
    "pedido_id" bigint NOT NULL,
    "cliente_id" integer,
    "cliente_nombre" "text",
    "cliente_direccion" "text",
    "total" numeric(12,2),
    "estado" character varying(50),
    "estado_pago" character varying(50),
    "forma_pago" character varying(50),
    "monto_pagado" numeric(12,2),
    "notas" "text",
    "items" "jsonb",
    "usuario_creador_id" "uuid",
    "usuario_creador_nombre" "text",
    "transportista_id" "uuid",
    "transportista_nombre" "text",
    "fecha_pedido" timestamp with time zone,
    "fecha_entrega" timestamp with time zone,
    "eliminado_por_id" "uuid" NOT NULL,
    "eliminado_por_nombre" "text",
    "eliminado_at" timestamp with time zone DEFAULT "now"(),
    "motivo_eliminacion" "text",
    "stock_restaurado" boolean DEFAULT true,
    "sucursal_id" bigint NOT NULL,
    "tp_import_id" bigint
);


ALTER TABLE "public"."pedidos_eliminados" OWNER TO "postgres";


COMMENT ON TABLE "public"."pedidos_eliminados" IS 'Registro histórico de pedidos eliminados para trazabilidad';



COMMENT ON COLUMN "public"."pedidos_eliminados"."items" IS 'Snapshot de los items del pedido en formato JSON';



CREATE SEQUENCE IF NOT EXISTS "public"."pedidos_eliminados_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pedidos_eliminados_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pedidos_eliminados_id_seq" OWNED BY "public"."pedidos_eliminados"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."pedidos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."pedidos_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."pedidos_id_seq" OWNED BY "public"."pedidos"."id";



CREATE TABLE IF NOT EXISTS "public"."preventista_zonas" (
    "id" bigint NOT NULL,
    "perfil_id" "uuid" NOT NULL,
    "zona_id" bigint NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."preventista_zonas" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."preventista_zonas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."preventista_zonas_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."preventista_zonas_id_seq" OWNED BY "public"."preventista_zonas"."id";



CREATE TABLE IF NOT EXISTS "public"."productos" (
    "id" bigint NOT NULL,
    "nombre" "text" NOT NULL,
    "precio" numeric(10,2) NOT NULL,
    "stock" integer DEFAULT 0 NOT NULL,
    "categoria" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "codigo" character varying(50),
    "costo_sin_iva" numeric(12,2),
    "costo_con_iva" numeric(12,2),
    "impuestos_internos" numeric(12,2),
    "precio_sin_iva" numeric(12,2),
    "stock_minimo" integer DEFAULT 10,
    "porcentaje_iva" numeric(5,2) DEFAULT 21,
    "proveedor_id" bigint,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL,
    "tp_import_id" bigint
);


ALTER TABLE "public"."productos" OWNER TO "postgres";


COMMENT ON COLUMN "public"."productos"."costo_sin_iva" IS 'Costo neto del producto (sin IVA ni impuestos internos)';



COMMENT ON COLUMN "public"."productos"."costo_con_iva" IS 'Costo total = costo_neto + IVA(sobre neto) + impuestos_internos';



COMMENT ON COLUMN "public"."productos"."impuestos_internos" IS 'Porcentaje de impuestos internos (ej: 5 = 5%). Antes era monto fijo.';



COMMENT ON COLUMN "public"."productos"."stock_minimo" IS 'Stock mínimo de seguridad. Cuando el stock actual está por debajo de este valor, se activa la alerta de stock bajo';



COMMENT ON COLUMN "public"."productos"."porcentaje_iva" IS 'Porcentaje de IVA aplicable al producto (21, 10.5, 0, etc.)';



COMMENT ON COLUMN "public"."productos"."tp_import_id" IS 'TP Export source id for rows imported via migration 062. Use for FK remap; safe to drop after import.';



CREATE SEQUENCE IF NOT EXISTS "public"."productos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."productos_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."productos_id_seq" OWNED BY "public"."productos"."id";



CREATE TABLE IF NOT EXISTS "public"."promo_ajustes" (
    "id" bigint NOT NULL,
    "promocion_id" bigint NOT NULL,
    "usos_ajustados" integer NOT NULL,
    "usuario_id" "uuid",
    "observaciones" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL,
    "unidades_ajustadas" integer,
    "producto_id" bigint,
    "merma_id" bigint
);


ALTER TABLE "public"."promo_ajustes" OWNER TO "postgres";


COMMENT ON TABLE "public"."promo_ajustes" IS 'Historial de ajustes de stock por promociones';



COMMENT ON COLUMN "public"."promo_ajustes"."unidades_ajustadas" IS 'Unidades descontadas del stock del producto ajustado (puede diferir de usos_ajustados si hay conversion de unidades).';



COMMENT ON COLUMN "public"."promo_ajustes"."producto_id" IS 'Producto al que se le descontó el stock en este ajuste.';



COMMENT ON COLUMN "public"."promo_ajustes"."merma_id" IS 'Referencia a la merma_stock generada por este ajuste.';



CREATE SEQUENCE IF NOT EXISTS "public"."promo_ajustes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."promo_ajustes_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."promo_ajustes_id_seq" OWNED BY "public"."promo_ajustes"."id";



CREATE TABLE IF NOT EXISTS "public"."promocion_productos" (
    "id" bigint NOT NULL,
    "promocion_id" bigint NOT NULL,
    "producto_id" bigint NOT NULL,
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."promocion_productos" OWNER TO "postgres";


COMMENT ON TABLE "public"."promocion_productos" IS 'Productos asociados a cada promoción';



CREATE SEQUENCE IF NOT EXISTS "public"."promocion_productos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."promocion_productos_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."promocion_productos_id_seq" OWNED BY "public"."promocion_productos"."id";



CREATE TABLE IF NOT EXISTS "public"."promocion_reglas" (
    "id" bigint NOT NULL,
    "promocion_id" bigint NOT NULL,
    "clave" character varying(50) NOT NULL,
    "valor" numeric NOT NULL,
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."promocion_reglas" OWNER TO "postgres";


COMMENT ON TABLE "public"."promocion_reglas" IS 'Parámetros key-value de cada promoción (cantidad_compra, precio_promo, etc.)';



CREATE SEQUENCE IF NOT EXISTS "public"."promocion_reglas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."promocion_reglas_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."promocion_reglas_id_seq" OWNED BY "public"."promocion_reglas"."id";



CREATE TABLE IF NOT EXISTS "public"."promociones" (
    "id" bigint NOT NULL,
    "nombre" character varying(200) NOT NULL,
    "tipo" character varying(30) NOT NULL,
    "activo" boolean DEFAULT true,
    "fecha_inicio" "date" NOT NULL,
    "fecha_fin" "date",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "usos_pendientes" integer DEFAULT 0,
    "producto_regalo_id" bigint,
    "limite_usos" integer,
    "sucursal_id" bigint NOT NULL,
    "prioridad" integer DEFAULT 0 NOT NULL,
    "regalo_mueve_stock" boolean DEFAULT false NOT NULL,
    "modo_exclusion" "text" DEFAULT 'acumulable'::"text" NOT NULL,
    "ajuste_automatico" boolean DEFAULT false NOT NULL,
    "ajuste_producto_id" bigint,
    "unidades_por_bloque" integer,
    "stock_por_bloque" integer,
    CONSTRAINT "promociones_modo_exclusion_check" CHECK (("modo_exclusion" = ANY (ARRAY['acumulable'::"text", 'excluyente'::"text"]))),
    CONSTRAINT "promociones_tipo_check" CHECK ((("tipo")::"text" = 'bonificacion'::"text"))
);


ALTER TABLE "public"."promociones" OWNER TO "postgres";


COMMENT ON TABLE "public"."promociones" IS 'Promociones temporales con fecha inicio/fin';



COMMENT ON COLUMN "public"."promociones"."usos_pendientes" IS 'Contador de pedidos que usaron esta promo, pendientes de ajuste de stock';



COMMENT ON COLUMN "public"."promociones"."producto_regalo_id" IS 'Producto específico que se regala en la bonificación (si NULL, se usa el primer producto del pedido)';



COMMENT ON COLUMN "public"."promociones"."limite_usos" IS 'Numero maximo de bonificaciones antes de auto-desactivacion. NULL = sin limite.';



COMMENT ON COLUMN "public"."promociones"."prioridad" IS 'Desempate manual cuando dos promos superpuestas aplican al mismo pedido. Mayor = gana.';



COMMENT ON COLUMN "public"."promociones"."regalo_mueve_stock" IS 'Si TRUE, el item bonificado descuenta stock del producto regalo (como venta con precio 0). Si FALSE, el stock se ajusta manualmente via ajustar_stock_promocion_completo.';



CREATE SEQUENCE IF NOT EXISTS "public"."promociones_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."promociones_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."promociones_id_seq" OWNED BY "public"."promociones"."id";



CREATE TABLE IF NOT EXISTS "public"."proveedores" (
    "id" bigint NOT NULL,
    "nombre" character varying(200) NOT NULL,
    "cuit" character varying(20),
    "direccion" "text",
    "telefono" character varying(50),
    "email" character varying(100),
    "contacto" character varying(100),
    "notas" "text",
    "activo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "latitud" numeric(10,8),
    "longitud" numeric(11,8),
    "zona_id" bigint,
    "sucursal_id" bigint NOT NULL,
    "tp_import_id" bigint
);


ALTER TABLE "public"."proveedores" OWNER TO "postgres";


COMMENT ON TABLE "public"."proveedores" IS 'Catálogo de proveedores';



COMMENT ON COLUMN "public"."proveedores"."latitud" IS 'Latitud de la ubicación del proveedor';



COMMENT ON COLUMN "public"."proveedores"."longitud" IS 'Longitud de la ubicación del proveedor';



CREATE TABLE IF NOT EXISTS "public"."proveedores_eliminados" (
    "id" bigint NOT NULL,
    "proveedor_id" bigint NOT NULL,
    "nombre" character varying(200) NOT NULL,
    "cuit" character varying(20),
    "direccion" "text",
    "telefono" character varying(50),
    "email" character varying(100),
    "contacto" character varying(100),
    "notas" "text",
    "activo" boolean,
    "fecha_creacion" timestamp with time zone,
    "eliminado_at" timestamp with time zone DEFAULT "now"(),
    "eliminado_por" "uuid"
);


ALTER TABLE "public"."proveedores_eliminados" OWNER TO "postgres";


COMMENT ON TABLE "public"."proveedores_eliminados" IS 'Registro de auditoría de proveedores eliminados';



CREATE SEQUENCE IF NOT EXISTS "public"."proveedores_eliminados_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."proveedores_eliminados_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."proveedores_eliminados_id_seq" OWNED BY "public"."proveedores_eliminados"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."proveedores_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."proveedores_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."proveedores_id_seq" OWNED BY "public"."proveedores"."id";



CREATE TABLE IF NOT EXISTS "public"."recorrido_pedidos" (
    "id" bigint NOT NULL,
    "recorrido_id" bigint NOT NULL,
    "pedido_id" bigint NOT NULL,
    "orden_entrega" integer NOT NULL,
    "estado_entrega" character varying(20) DEFAULT 'pendiente'::character varying,
    "hora_entrega" timestamp with time zone,
    "notas" "text",
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."recorrido_pedidos" OWNER TO "postgres";


COMMENT ON TABLE "public"."recorrido_pedidos" IS 'Detalle de pedidos incluidos en cada recorrido con orden de entrega';



COMMENT ON COLUMN "public"."recorrido_pedidos"."estado_entrega" IS 'Estado de entrega: pendiente, entregado, no_entregado';



CREATE SEQUENCE IF NOT EXISTS "public"."recorrido_pedidos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."recorrido_pedidos_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."recorrido_pedidos_id_seq" OWNED BY "public"."recorrido_pedidos"."id";



CREATE TABLE IF NOT EXISTS "public"."recorridos" (
    "id" bigint NOT NULL,
    "transportista_id" "uuid" NOT NULL,
    "fecha" "date" DEFAULT CURRENT_DATE NOT NULL,
    "distancia_total" numeric(10,2),
    "duracion_total" integer,
    "total_pedidos" integer DEFAULT 0 NOT NULL,
    "pedidos_entregados" integer DEFAULT 0 NOT NULL,
    "total_facturado" numeric(12,2) DEFAULT 0,
    "total_cobrado" numeric(12,2) DEFAULT 0,
    "estado" character varying(20) DEFAULT 'en_curso'::character varying,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "completed_at" timestamp with time zone,
    "notas" "text",
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."recorridos" OWNER TO "postgres";


COMMENT ON TABLE "public"."recorridos" IS 'Registro de recorridos diarios de transportistas para rendición y estadísticas';



COMMENT ON COLUMN "public"."recorridos"."estado" IS 'Estado del recorrido: en_curso, completado, cancelado';



CREATE SEQUENCE IF NOT EXISTS "public"."recorridos_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."recorridos_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."recorridos_id_seq" OWNED BY "public"."recorridos"."id";



CREATE TABLE IF NOT EXISTS "public"."rendicion_ajustes" (
    "id" bigint NOT NULL,
    "rendicion_id" bigint NOT NULL,
    "tipo" character varying(30) NOT NULL,
    "monto" numeric(12,2) NOT NULL,
    "descripcion" "text" NOT NULL,
    "foto_url" "text",
    "aprobado" boolean,
    "aprobado_por" "uuid",
    "aprobado_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL,
    CONSTRAINT "rendicion_ajustes_tipo_check" CHECK ((("tipo")::"text" = ANY ((ARRAY['faltante'::character varying, 'sobrante'::character varying, 'vuelto_no_dado'::character varying, 'error_cobro'::character varying, 'descuento_autorizado'::character varying, 'otro'::character varying])::"text"[])))
);


ALTER TABLE "public"."rendicion_ajustes" OWNER TO "postgres";


COMMENT ON TABLE "public"."rendicion_ajustes" IS 'Ajustes y justificaciones de diferencias en rendiciones';



CREATE SEQUENCE IF NOT EXISTS "public"."rendicion_ajustes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."rendicion_ajustes_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."rendicion_ajustes_id_seq" OWNED BY "public"."rendicion_ajustes"."id";



CREATE TABLE IF NOT EXISTS "public"."rendicion_items" (
    "id" bigint NOT NULL,
    "rendicion_id" bigint NOT NULL,
    "pedido_id" bigint NOT NULL,
    "monto_cobrado" numeric(12,2) DEFAULT 0 NOT NULL,
    "forma_pago" character varying(30) NOT NULL,
    "referencia" character varying(100),
    "incluido_en_rendicion" boolean DEFAULT true,
    "notas" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."rendicion_items" OWNER TO "postgres";


COMMENT ON TABLE "public"."rendicion_items" IS 'Detalle de cobros incluidos en cada rendición';



CREATE SEQUENCE IF NOT EXISTS "public"."rendicion_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."rendicion_items_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."rendicion_items_id_seq" OWNED BY "public"."rendicion_items"."id";



CREATE TABLE IF NOT EXISTS "public"."rendiciones" (
    "id" bigint NOT NULL,
    "recorrido_id" bigint,
    "transportista_id" "uuid" NOT NULL,
    "fecha" "date" DEFAULT CURRENT_DATE NOT NULL,
    "total_efectivo_esperado" numeric(12,2) DEFAULT 0 NOT NULL,
    "total_otros_medios" numeric(12,2) DEFAULT 0 NOT NULL,
    "monto_rendido" numeric(12,2) DEFAULT 0 NOT NULL,
    "diferencia" numeric(12,2) GENERATED ALWAYS AS (("monto_rendido" - "total_efectivo_esperado")) STORED,
    "estado" character varying(30) DEFAULT 'pendiente'::character varying NOT NULL,
    "justificacion_transportista" "text",
    "observaciones_admin" "text",
    "presentada_at" timestamp with time zone,
    "revisada_at" timestamp with time zone,
    "revisada_por" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL,
    CONSTRAINT "rendiciones_estado_check" CHECK ((("estado")::"text" = ANY ((ARRAY['pendiente'::character varying, 'presentada'::character varying, 'aprobada'::character varying, 'rechazada'::character varying, 'con_observaciones'::character varying])::"text"[])))
);


ALTER TABLE "public"."rendiciones" OWNER TO "postgres";


COMMENT ON TABLE "public"."rendiciones" IS 'Registro de rendiciones de efectivo de transportistas al final del día';



COMMENT ON COLUMN "public"."rendiciones"."diferencia" IS 'Diferencia entre monto rendido y esperado (positivo=sobrante, negativo=faltante)';



COMMENT ON COLUMN "public"."rendiciones"."estado" IS 'Estado: pendiente, presentada, aprobada, rechazada, con_observaciones';



CREATE TABLE IF NOT EXISTS "public"."rendiciones_control" (
    "id" bigint NOT NULL,
    "fecha" "date" NOT NULL,
    "transportista_id" "uuid" NOT NULL,
    "sucursal_id" bigint NOT NULL,
    "controlada_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "controlada_por" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."rendiciones_control" OWNER TO "postgres";


COMMENT ON TABLE "public"."rendiciones_control" IS 'Registro de control diario de rendiciones por (fecha, transportista). Se borra automáticamente si cambia la fecha_entrega de un pedido afectado.';



CREATE SEQUENCE IF NOT EXISTS "public"."rendiciones_control_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."rendiciones_control_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."rendiciones_control_id_seq" OWNED BY "public"."rendiciones_control"."id";



CREATE SEQUENCE IF NOT EXISTS "public"."rendiciones_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."rendiciones_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."rendiciones_id_seq" OWNED BY "public"."rendiciones"."id";



CREATE TABLE IF NOT EXISTS "public"."salvedad_historial" (
    "id" bigint NOT NULL,
    "salvedad_id" bigint NOT NULL,
    "accion" character varying(50) NOT NULL,
    "estado_anterior" character varying(30),
    "estado_nuevo" character varying(30),
    "notas" "text",
    "usuario_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."salvedad_historial" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."salvedad_historial_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."salvedad_historial_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."salvedad_historial_id_seq" OWNED BY "public"."salvedad_historial"."id";



CREATE TABLE IF NOT EXISTS "public"."salvedades_items" (
    "id" bigint NOT NULL,
    "pedido_id" bigint NOT NULL,
    "pedido_item_id" bigint,
    "producto_id" bigint NOT NULL,
    "cantidad_original" integer NOT NULL,
    "cantidad_afectada" integer NOT NULL,
    "cantidad_entregada" integer DEFAULT 0 NOT NULL,
    "motivo" character varying(50) NOT NULL,
    "descripcion" "text",
    "foto_url" "text",
    "monto_afectado" numeric(12,2) NOT NULL,
    "precio_unitario" numeric(12,2) NOT NULL,
    "estado_resolucion" character varying(30) DEFAULT 'pendiente'::character varying NOT NULL,
    "resolucion_notas" "text",
    "resolucion_fecha" timestamp with time zone,
    "resuelto_por" "uuid",
    "stock_devuelto" boolean DEFAULT false,
    "stock_devuelto_at" timestamp with time zone,
    "pedido_reprogramado_id" bigint,
    "reportado_por" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL,
    CONSTRAINT "salvedades_items_cantidad_afectada_check" CHECK (("cantidad_afectada" > 0)),
    CONSTRAINT "salvedades_items_estado_resolucion_check" CHECK ((("estado_resolucion")::"text" = ANY ((ARRAY['pendiente'::character varying, 'reprogramada'::character varying, 'nota_credito'::character varying, 'descuento_transportista'::character varying, 'absorcion_empresa'::character varying, 'resuelto_otro'::character varying, 'anulada'::character varying])::"text"[]))),
    CONSTRAINT "salvedades_items_motivo_check" CHECK ((("motivo")::"text" = ANY ((ARRAY['faltante_stock'::character varying, 'producto_danado'::character varying, 'cliente_rechaza'::character varying, 'error_pedido'::character varying, 'producto_vencido'::character varying, 'diferencia_precio'::character varying, 'otro'::character varying])::"text"[])))
);


ALTER TABLE "public"."salvedades_items" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."salvedades_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."salvedades_items_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."salvedades_items_id_seq" OWNED BY "public"."salvedades_items"."id";



CREATE TABLE IF NOT EXISTS "public"."stock_historico" (
    "id" bigint NOT NULL,
    "producto_id" bigint NOT NULL,
    "stock_anterior" integer NOT NULL,
    "stock_nuevo" integer NOT NULL,
    "diferencia" integer GENERATED ALWAYS AS (("stock_nuevo" - "stock_anterior")) STORED,
    "origen" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "referencia_tipo" "text",
    "referencia_id" bigint,
    "sucursal_id" bigint NOT NULL,
    "usuario_id" "uuid",
    "tp_import_id" bigint
);


ALTER TABLE "public"."stock_historico" OWNER TO "postgres";


ALTER TABLE "public"."stock_historico" ALTER COLUMN "id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."stock_historico_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."sucursales" (
    "id" bigint NOT NULL,
    "nombre" character varying(200) NOT NULL,
    "direccion" "text",
    "activa" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "tipo" character varying(50) DEFAULT 'distribuidora'::character varying
);


ALTER TABLE "public"."sucursales" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."sucursales_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."sucursales_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."sucursales_id_seq" OWNED BY "public"."sucursales"."id";



CREATE TABLE IF NOT EXISTS "public"."transferencia_items" (
    "id" bigint NOT NULL,
    "transferencia_id" bigint NOT NULL,
    "producto_id" bigint NOT NULL,
    "cantidad" integer NOT NULL,
    "costo_unitario" numeric(12,2) DEFAULT 0 NOT NULL,
    "subtotal" numeric(12,2) DEFAULT 0 NOT NULL,
    "stock_anterior" integer DEFAULT 0 NOT NULL,
    "stock_nuevo" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL,
    CONSTRAINT "transferencia_items_cantidad_check" CHECK (("cantidad" > 0))
);


ALTER TABLE "public"."transferencia_items" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."transferencia_items_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."transferencia_items_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."transferencia_items_id_seq" OWNED BY "public"."transferencia_items"."id";



CREATE TABLE IF NOT EXISTS "public"."transferencias_stock" (
    "id" bigint NOT NULL,
    "sucursal_id" bigint NOT NULL,
    "fecha" "date" DEFAULT CURRENT_DATE NOT NULL,
    "notas" "text",
    "total_costo" numeric(12,2) DEFAULT 0 NOT NULL,
    "usuario_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "tipo" character varying(20) DEFAULT 'salida'::character varying NOT NULL,
    "tenant_sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."transferencias_stock" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."transferencias_stock_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."transferencias_stock_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."transferencias_stock_id_seq" OWNED BY "public"."transferencias_stock"."id";



CREATE TABLE IF NOT EXISTS "public"."usuario_sucursales" (
    "id" bigint NOT NULL,
    "usuario_id" "uuid" NOT NULL,
    "sucursal_id" bigint NOT NULL,
    "rol" character varying(20) DEFAULT 'mismo'::character varying,
    "es_default" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."usuario_sucursales" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."usuario_sucursales_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."usuario_sucursales_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."usuario_sucursales_id_seq" OWNED BY "public"."usuario_sucursales"."id";



CREATE OR REPLACE VIEW "public"."vista_recorridos_diarios" WITH ("security_invoker"='true') AS
 SELECT "r"."id",
    "r"."fecha",
    "r"."transportista_id",
    "p"."nombre" AS "transportista_nombre",
    "r"."total_pedidos",
    "r"."pedidos_entregados",
    "r"."total_facturado",
    "r"."total_cobrado",
    "r"."distancia_total",
    "r"."duracion_total",
    "r"."estado",
    "r"."created_at",
    "r"."completed_at",
        CASE
            WHEN ("r"."total_pedidos" > 0) THEN "round"(((("r"."pedidos_entregados")::numeric / ("r"."total_pedidos")::numeric) * (100)::numeric), 1)
            ELSE (0)::numeric
        END AS "porcentaje_completado"
   FROM ("public"."recorridos" "r"
     JOIN "public"."perfiles" "p" ON (("p"."id" = "r"."transportista_id")))
  ORDER BY "r"."fecha" DESC, "r"."created_at" DESC;


ALTER VIEW "public"."vista_recorridos_diarios" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."vista_rendiciones" WITH ("security_invoker"='true') AS
 SELECT "r"."id",
    "r"."recorrido_id",
    "r"."transportista_id",
    "p"."nombre" AS "transportista_nombre",
    "r"."fecha",
    "r"."total_efectivo_esperado",
    "r"."total_otros_medios",
    "r"."monto_rendido",
    "r"."diferencia",
    "r"."estado",
    "r"."justificacion_transportista",
    "r"."observaciones_admin",
    "r"."presentada_at",
    "r"."revisada_at",
    "pr"."nombre" AS "revisada_por_nombre",
    "rec"."total_pedidos",
    "rec"."pedidos_entregados",
    "rec"."total_facturado",
    "rec"."total_cobrado",
    ( SELECT "count"(*) AS "count"
           FROM "public"."rendicion_ajustes" "ra"
          WHERE ("ra"."rendicion_id" = "r"."id")) AS "total_ajustes",
    "r"."created_at",
    "r"."updated_at"
   FROM ((("public"."rendiciones" "r"
     JOIN "public"."perfiles" "p" ON (("p"."id" = "r"."transportista_id")))
     JOIN "public"."recorridos" "rec" ON (("rec"."id" = "r"."recorrido_id")))
     LEFT JOIN "public"."perfiles" "pr" ON (("pr"."id" = "r"."revisada_por")))
  ORDER BY "r"."fecha" DESC, "r"."created_at" DESC;


ALTER VIEW "public"."vista_rendiciones" OWNER TO "postgres";


COMMENT ON VIEW "public"."vista_rendiciones" IS 'Vista de rendiciones con información del transportista y recorrido';



CREATE TABLE IF NOT EXISTS "public"."zonas" (
    "id" bigint NOT NULL,
    "nombre" character varying(100) NOT NULL,
    "activo" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "sucursal_id" bigint NOT NULL
);


ALTER TABLE "public"."zonas" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."zonas_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."zonas_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."zonas_id_seq" OWNED BY "public"."zonas"."id";



ALTER TABLE ONLY "public"."clientes" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."clientes_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."compra_items" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."compra_items_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."compras" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."compras_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."grupo_precio_escalas" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."grupo_precio_escalas_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."grupo_precio_productos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."grupo_precio_productos_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."grupos_precio" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."grupos_precio_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."historial_cambios" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."historial_cambios_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."mermas_stock" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."mermas_stock_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."nota_credito_items" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."nota_credito_items_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."notas_credito" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."notas_credito_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pagos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pagos_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pedido_historial" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pedido_historial_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pedido_items" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pedido_items_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pedidos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pedidos_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."pedidos_eliminados" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."pedidos_eliminados_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."preventista_zonas" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."preventista_zonas_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."productos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."productos_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."promo_ajustes" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."promo_ajustes_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."promocion_productos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."promocion_productos_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."promocion_reglas" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."promocion_reglas_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."promociones" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."promociones_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."proveedores" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."proveedores_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."proveedores_eliminados" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."proveedores_eliminados_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."recorrido_pedidos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."recorrido_pedidos_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."recorridos" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."recorridos_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."rendicion_ajustes" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."rendicion_ajustes_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."rendicion_items" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."rendicion_items_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."rendiciones" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."rendiciones_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."rendiciones_control" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."rendiciones_control_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."salvedad_historial" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."salvedad_historial_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."salvedades_items" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."salvedades_items_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."sucursales" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."sucursales_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."transferencia_items" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."transferencia_items_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."transferencias_stock" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."transferencias_stock_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."usuario_sucursales" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."usuario_sucursales_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."zonas" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."zonas_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clientes"
    ADD CONSTRAINT "clientes_codigo_unique" UNIQUE ("codigo");



ALTER TABLE ONLY "public"."clientes"
    ADD CONSTRAINT "clientes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."compra_items"
    ADD CONSTRAINT "compra_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."compras"
    ADD CONSTRAINT "compras_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grupo_precio_escalas"
    ADD CONSTRAINT "grupo_precio_escalas_grupo_precio_id_cantidad_minima_key" UNIQUE ("grupo_precio_id", "cantidad_minima");



ALTER TABLE ONLY "public"."grupo_precio_escalas"
    ADD CONSTRAINT "grupo_precio_escalas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grupo_precio_productos"
    ADD CONSTRAINT "grupo_precio_productos_grupo_precio_id_producto_id_key" UNIQUE ("grupo_precio_id", "producto_id");



ALTER TABLE ONLY "public"."grupo_precio_productos"
    ADD CONSTRAINT "grupo_precio_productos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."grupos_precio"
    ADD CONSTRAINT "grupos_precio_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."historial_cambios"
    ADD CONSTRAINT "historial_cambios_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mermas_stock"
    ADD CONSTRAINT "mermas_stock_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nota_credito_items"
    ADD CONSTRAINT "nota_credito_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."notas_credito"
    ADD CONSTRAINT "notas_credito_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pagos"
    ADD CONSTRAINT "pagos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pedido_historial"
    ADD CONSTRAINT "pedido_historial_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pedido_items"
    ADD CONSTRAINT "pedido_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pedidos_eliminados"
    ADD CONSTRAINT "pedidos_eliminados_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."pedidos"
    ADD CONSTRAINT "pedidos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."perfiles"
    ADD CONSTRAINT "perfiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."preventista_zonas"
    ADD CONSTRAINT "preventista_zonas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."preventista_zonas"
    ADD CONSTRAINT "preventista_zonas_unique" UNIQUE ("perfil_id", "zona_id");



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promo_ajustes"
    ADD CONSTRAINT "promo_ajustes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promocion_productos"
    ADD CONSTRAINT "promocion_productos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promocion_productos"
    ADD CONSTRAINT "promocion_productos_promocion_id_producto_id_key" UNIQUE ("promocion_id", "producto_id");



ALTER TABLE ONLY "public"."promocion_reglas"
    ADD CONSTRAINT "promocion_reglas_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."promocion_reglas"
    ADD CONSTRAINT "promocion_reglas_promocion_id_clave_key" UNIQUE ("promocion_id", "clave");



ALTER TABLE ONLY "public"."promociones"
    ADD CONSTRAINT "promociones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."proveedores_eliminados"
    ADD CONSTRAINT "proveedores_eliminados_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."proveedores"
    ADD CONSTRAINT "proveedores_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recorrido_pedidos"
    ADD CONSTRAINT "recorrido_pedidos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recorrido_pedidos"
    ADD CONSTRAINT "recorrido_pedidos_recorrido_id_pedido_id_key" UNIQUE ("recorrido_id", "pedido_id");



ALTER TABLE ONLY "public"."recorridos"
    ADD CONSTRAINT "recorridos_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rendicion_ajustes"
    ADD CONSTRAINT "rendicion_ajustes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rendicion_items"
    ADD CONSTRAINT "rendicion_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rendicion_items"
    ADD CONSTRAINT "rendicion_items_rendicion_id_pedido_id_key" UNIQUE ("rendicion_id", "pedido_id");



ALTER TABLE ONLY "public"."rendiciones_control"
    ADD CONSTRAINT "rendiciones_control_fecha_transportista_id_sucursal_id_key" UNIQUE ("fecha", "transportista_id", "sucursal_id");



ALTER TABLE ONLY "public"."rendiciones_control"
    ADD CONSTRAINT "rendiciones_control_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rendiciones"
    ADD CONSTRAINT "rendiciones_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."rendiciones"
    ADD CONSTRAINT "rendiciones_recorrido_id_key" UNIQUE ("recorrido_id");



ALTER TABLE ONLY "public"."salvedad_historial"
    ADD CONSTRAINT "salvedad_historial_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."salvedades_items"
    ADD CONSTRAINT "salvedades_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."stock_historico"
    ADD CONSTRAINT "stock_historico_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sucursales"
    ADD CONSTRAINT "sucursales_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transferencia_items"
    ADD CONSTRAINT "transferencia_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usuario_sucursales"
    ADD CONSTRAINT "usuario_sucursales_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."usuario_sucursales"
    ADD CONSTRAINT "usuario_sucursales_usuario_id_sucursal_id_key" UNIQUE ("usuario_id", "sucursal_id");



ALTER TABLE ONLY "public"."zonas"
    ADD CONSTRAINT "zonas_nombre_unique" UNIQUE ("nombre");



ALTER TABLE ONLY "public"."zonas"
    ADD CONSTRAINT "zonas_pkey" PRIMARY KEY ("id");



CREATE INDEX "clientes_tp_import_idx" ON "public"."clientes" USING "btree" ("tp_import_id") WHERE ("tp_import_id" IS NOT NULL);



CREATE INDEX "idx_audit_logs_accion" ON "public"."audit_logs" USING "btree" ("accion");



CREATE INDEX "idx_audit_logs_created_at" ON "public"."audit_logs" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_audit_logs_registro_id" ON "public"."audit_logs" USING "btree" ("registro_id");



CREATE INDEX "idx_audit_logs_sucursal" ON "public"."audit_logs" USING "btree" ("sucursal_id");



CREATE INDEX "idx_audit_logs_tabla" ON "public"."audit_logs" USING "btree" ("tabla");



CREATE INDEX "idx_audit_logs_tabla_registro" ON "public"."audit_logs" USING "btree" ("tabla", "registro_id");



CREATE INDEX "idx_audit_logs_usuario_id" ON "public"."audit_logs" USING "btree" ("usuario_id");



CREATE INDEX "idx_clientes_coordenadas" ON "public"."clientes" USING "btree" ("latitud", "longitud") WHERE (("latitud" IS NOT NULL) AND ("longitud" IS NOT NULL));



CREATE INDEX "idx_clientes_cuit" ON "public"."clientes" USING "btree" ("cuit");



CREATE INDEX "idx_clientes_preventista_id" ON "public"."clientes" USING "btree" ("preventista_id");



CREATE INDEX "idx_clientes_rubro" ON "public"."clientes" USING "btree" ("rubro");



CREATE INDEX "idx_clientes_sucursal" ON "public"."clientes" USING "btree" ("sucursal_id");



CREATE INDEX "idx_clientes_tipo_documento" ON "public"."clientes" USING "btree" ("tipo_documento");



CREATE INDEX "idx_clientes_zona_id" ON "public"."clientes" USING "btree" ("zona_id");



CREATE INDEX "idx_compra_items_compra" ON "public"."compra_items" USING "btree" ("compra_id");



CREATE INDEX "idx_compra_items_compra_id" ON "public"."compra_items" USING "btree" ("compra_id");



CREATE INDEX "idx_compra_items_producto" ON "public"."compra_items" USING "btree" ("producto_id");



CREATE INDEX "idx_compra_items_sucursal" ON "public"."compra_items" USING "btree" ("sucursal_id");



CREATE INDEX "idx_compra_items_tp_import_id" ON "public"."compra_items" USING "btree" ("tp_import_id") WHERE ("tp_import_id" IS NOT NULL);



CREATE INDEX "idx_compras_created" ON "public"."compras" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_compras_estado" ON "public"."compras" USING "btree" ("estado");



CREATE INDEX "idx_compras_fecha" ON "public"."compras" USING "btree" ("fecha_compra" DESC);



CREATE INDEX "idx_compras_proveedor" ON "public"."compras" USING "btree" ("proveedor_id");



CREATE INDEX "idx_compras_sucursal" ON "public"."compras" USING "btree" ("sucursal_id");



CREATE INDEX "idx_compras_tipo_factura" ON "public"."compras" USING "btree" ("tipo_factura");



CREATE INDEX "idx_compras_tp_import_id" ON "public"."compras" USING "btree" ("tp_import_id") WHERE ("tp_import_id" IS NOT NULL);



CREATE INDEX "idx_gpe_grupo" ON "public"."grupo_precio_escalas" USING "btree" ("grupo_precio_id");



CREATE INDEX "idx_gpp_grupo" ON "public"."grupo_precio_productos" USING "btree" ("grupo_precio_id");



CREATE INDEX "idx_gpp_producto" ON "public"."grupo_precio_productos" USING "btree" ("producto_id");



CREATE INDEX "idx_grupo_precio_escalas_sucursal" ON "public"."grupo_precio_escalas" USING "btree" ("sucursal_id");



CREATE INDEX "idx_grupo_precio_productos_sucursal" ON "public"."grupo_precio_productos" USING "btree" ("sucursal_id");



CREATE INDEX "idx_grupos_precio_activo" ON "public"."grupos_precio" USING "btree" ("activo");



CREATE INDEX "idx_grupos_precio_sucursal" ON "public"."grupos_precio" USING "btree" ("sucursal_id");



CREATE INDEX "idx_historial_cambios_sucursal" ON "public"."historial_cambios" USING "btree" ("sucursal_id");



CREATE INDEX "idx_historial_tabla" ON "public"."historial_cambios" USING "btree" ("tabla", "registro_id");



CREATE INDEX "idx_mermas_fecha" ON "public"."mermas_stock" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_mermas_motivo" ON "public"."mermas_stock" USING "btree" ("motivo");



CREATE INDEX "idx_mermas_producto" ON "public"."mermas_stock" USING "btree" ("producto_id");



CREATE INDEX "idx_mermas_producto_id" ON "public"."mermas_stock" USING "btree" ("producto_id");



CREATE INDEX "idx_mermas_stock_sucursal" ON "public"."mermas_stock" USING "btree" ("sucursal_id");



CREATE INDEX "idx_nota_credito_items_nota" ON "public"."nota_credito_items" USING "btree" ("nota_credito_id");



CREATE INDEX "idx_nota_credito_items_sucursal" ON "public"."nota_credito_items" USING "btree" ("sucursal_id");



CREATE INDEX "idx_notas_credito_compra" ON "public"."notas_credito" USING "btree" ("compra_id");



CREATE INDEX "idx_notas_credito_fecha" ON "public"."notas_credito" USING "btree" ("fecha" DESC);



CREATE INDEX "idx_notas_credito_sucursal" ON "public"."notas_credito" USING "btree" ("sucursal_id");



CREATE INDEX "idx_pagos_cliente_id" ON "public"."pagos" USING "btree" ("cliente_id");



CREATE INDEX "idx_pagos_created_at" ON "public"."pagos" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_pagos_fecha" ON "public"."pagos" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_pagos_pedido_id" ON "public"."pagos" USING "btree" ("pedido_id");



CREATE INDEX "idx_pagos_sucursal" ON "public"."pagos" USING "btree" ("sucursal_id");



CREATE INDEX "idx_pedido_historial_created_at" ON "public"."pedido_historial" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_pedido_historial_pedido_id" ON "public"."pedido_historial" USING "btree" ("pedido_id");



CREATE INDEX "idx_pedido_historial_sucursal" ON "public"."pedido_historial" USING "btree" ("sucursal_id");



CREATE INDEX "idx_pedido_historial_tp_import_id" ON "public"."pedido_historial" USING "btree" ("tp_import_id") WHERE ("tp_import_id" IS NOT NULL);



CREATE INDEX "idx_pedido_items_pedido" ON "public"."pedido_items" USING "btree" ("pedido_id");



CREATE INDEX "idx_pedido_items_pedido_id" ON "public"."pedido_items" USING "btree" ("pedido_id");



CREATE INDEX "idx_pedido_items_producto_id" ON "public"."pedido_items" USING "btree" ("producto_id");



CREATE INDEX "idx_pedido_items_sucursal" ON "public"."pedido_items" USING "btree" ("sucursal_id");



CREATE INDEX "idx_pedido_items_tp_import_id" ON "public"."pedido_items" USING "btree" ("tp_import_id") WHERE ("tp_import_id" IS NOT NULL);



CREATE INDEX "idx_pedidos_cliente" ON "public"."pedidos" USING "btree" ("cliente_id");



CREATE INDEX "idx_pedidos_cliente_id" ON "public"."pedidos" USING "btree" ("cliente_id");



CREATE INDEX "idx_pedidos_created_at" ON "public"."pedidos" USING "btree" ("created_at");



CREATE INDEX "idx_pedidos_eliminados_cliente" ON "public"."pedidos_eliminados" USING "btree" ("cliente_id");



CREATE INDEX "idx_pedidos_eliminados_eliminado_por" ON "public"."pedidos_eliminados" USING "btree" ("eliminado_por_id");



CREATE INDEX "idx_pedidos_eliminados_fecha" ON "public"."pedidos_eliminados" USING "btree" ("eliminado_at");



CREATE INDEX "idx_pedidos_eliminados_pedido_id" ON "public"."pedidos_eliminados" USING "btree" ("pedido_id");



CREATE INDEX "idx_pedidos_eliminados_sucursal" ON "public"."pedidos_eliminados" USING "btree" ("sucursal_id");



CREATE INDEX "idx_pedidos_eliminados_tp_import_id" ON "public"."pedidos_eliminados" USING "btree" ("tp_import_id") WHERE ("tp_import_id" IS NOT NULL);



CREATE INDEX "idx_pedidos_estado" ON "public"."pedidos" USING "btree" ("estado");



CREATE INDEX "idx_pedidos_fecha" ON "public"."pedidos" USING "btree" ("fecha" DESC);



CREATE INDEX "idx_pedidos_fecha_entrega" ON "public"."pedidos" USING "btree" ("fecha_entrega_programada");



CREATE INDEX "idx_pedidos_fecha_entrega_programada" ON "public"."pedidos" USING "btree" ("fecha_entrega_programada") WHERE ("estado" <> ALL (ARRAY['entregado'::"text", 'cancelado'::"text"]));



CREATE INDEX "idx_pedidos_stock_descontado" ON "public"."pedidos" USING "btree" ("stock_descontado");



CREATE INDEX "idx_pedidos_sucursal" ON "public"."pedidos" USING "btree" ("sucursal_id");



CREATE INDEX "idx_pedidos_tipo_factura" ON "public"."pedidos" USING "btree" ("tipo_factura");



CREATE INDEX "idx_pedidos_transportista_id" ON "public"."pedidos" USING "btree" ("transportista_id");



CREATE INDEX "idx_pedidos_transportista_orden" ON "public"."pedidos" USING "btree" ("transportista_id", "orden_entrega") WHERE (("transportista_id" IS NOT NULL) AND ("orden_entrega" IS NOT NULL));



CREATE INDEX "idx_perfiles_zona" ON "public"."perfiles" USING "btree" ("zona");



CREATE INDEX "idx_pp_producto" ON "public"."promocion_productos" USING "btree" ("producto_id");



CREATE INDEX "idx_preventista_zonas_perfil" ON "public"."preventista_zonas" USING "btree" ("perfil_id");



CREATE INDEX "idx_preventista_zonas_sucursal" ON "public"."preventista_zonas" USING "btree" ("sucursal_id");



CREATE INDEX "idx_preventista_zonas_zona" ON "public"."preventista_zonas" USING "btree" ("zona_id");



CREATE INDEX "idx_productos_codigo" ON "public"."productos" USING "btree" ("codigo");



CREATE INDEX "idx_productos_sucursal" ON "public"."productos" USING "btree" ("sucursal_id");



CREATE INDEX "idx_promo_ajustes_promocion" ON "public"."promo_ajustes" USING "btree" ("promocion_id");



CREATE INDEX "idx_promo_ajustes_sucursal" ON "public"."promo_ajustes" USING "btree" ("sucursal_id");



CREATE INDEX "idx_promocion_productos_sucursal" ON "public"."promocion_productos" USING "btree" ("sucursal_id");



CREATE INDEX "idx_promocion_reglas_sucursal" ON "public"."promocion_reglas" USING "btree" ("sucursal_id");



CREATE INDEX "idx_promociones_activas" ON "public"."promociones" USING "btree" ("activo", "fecha_inicio", "fecha_fin");



CREATE INDEX "idx_promociones_modo_exclusion" ON "public"."promociones" USING "btree" ("sucursal_id", "activo", "modo_exclusion");



CREATE INDEX "idx_promociones_prioridad" ON "public"."promociones" USING "btree" ("sucursal_id", "activo", "prioridad" DESC);



CREATE INDEX "idx_promociones_sucursal" ON "public"."promociones" USING "btree" ("sucursal_id");



CREATE INDEX "idx_proveedores_coords" ON "public"."proveedores" USING "btree" ("latitud", "longitud");



CREATE INDEX "idx_proveedores_nombre" ON "public"."proveedores" USING "btree" ("nombre");



CREATE INDEX "idx_proveedores_sucursal" ON "public"."proveedores" USING "btree" ("sucursal_id");



CREATE INDEX "idx_proveedores_tp_import_id" ON "public"."proveedores" USING "btree" ("tp_import_id") WHERE ("tp_import_id" IS NOT NULL);



CREATE INDEX "idx_proveedores_zona_id" ON "public"."proveedores" USING "btree" ("zona_id");



CREATE INDEX "idx_recorrido_pedidos_pedido" ON "public"."recorrido_pedidos" USING "btree" ("pedido_id");



CREATE INDEX "idx_recorrido_pedidos_recorrido" ON "public"."recorrido_pedidos" USING "btree" ("recorrido_id");



CREATE INDEX "idx_recorrido_pedidos_sucursal" ON "public"."recorrido_pedidos" USING "btree" ("sucursal_id");



CREATE INDEX "idx_recorridos_estado" ON "public"."recorridos" USING "btree" ("estado");



CREATE INDEX "idx_recorridos_fecha" ON "public"."recorridos" USING "btree" ("fecha" DESC);



CREATE INDEX "idx_recorridos_sucursal" ON "public"."recorridos" USING "btree" ("sucursal_id");



CREATE INDEX "idx_recorridos_transportista" ON "public"."recorridos" USING "btree" ("transportista_id");



CREATE INDEX "idx_rendicion_ajustes_rendicion" ON "public"."rendicion_ajustes" USING "btree" ("rendicion_id");



CREATE INDEX "idx_rendicion_ajustes_sucursal" ON "public"."rendicion_ajustes" USING "btree" ("sucursal_id");



CREATE INDEX "idx_rendicion_items_rendicion" ON "public"."rendicion_items" USING "btree" ("rendicion_id");



CREATE INDEX "idx_rendicion_items_rendicion_id" ON "public"."rendicion_items" USING "btree" ("rendicion_id");



CREATE INDEX "idx_rendicion_items_sucursal" ON "public"."rendicion_items" USING "btree" ("sucursal_id");



CREATE INDEX "idx_rendiciones_control_fecha" ON "public"."rendiciones_control" USING "btree" ("fecha" DESC);



CREATE INDEX "idx_rendiciones_control_sucursal" ON "public"."rendiciones_control" USING "btree" ("sucursal_id");



CREATE INDEX "idx_rendiciones_control_transportista" ON "public"."rendiciones_control" USING "btree" ("transportista_id");



CREATE INDEX "idx_rendiciones_estado" ON "public"."rendiciones" USING "btree" ("estado");



CREATE INDEX "idx_rendiciones_fecha" ON "public"."rendiciones" USING "btree" ("fecha" DESC);



CREATE INDEX "idx_rendiciones_sucursal" ON "public"."rendiciones" USING "btree" ("sucursal_id");



CREATE INDEX "idx_rendiciones_transportista" ON "public"."rendiciones" USING "btree" ("transportista_id");



CREATE INDEX "idx_salvedad_historial_salvedad" ON "public"."salvedad_historial" USING "btree" ("salvedad_id");



CREATE INDEX "idx_salvedad_historial_sucursal" ON "public"."salvedad_historial" USING "btree" ("sucursal_id");



CREATE INDEX "idx_salvedades_estado" ON "public"."salvedades_items" USING "btree" ("estado_resolucion");



CREATE INDEX "idx_salvedades_fecha" ON "public"."salvedades_items" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_salvedades_items_sucursal" ON "public"."salvedades_items" USING "btree" ("sucursal_id");



CREATE INDEX "idx_salvedades_pedido" ON "public"."salvedades_items" USING "btree" ("pedido_id");



CREATE INDEX "idx_salvedades_producto" ON "public"."salvedades_items" USING "btree" ("producto_id");



CREATE INDEX "idx_stock_historico_fecha" ON "public"."stock_historico" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_stock_historico_producto" ON "public"."stock_historico" USING "btree" ("producto_id", "created_at" DESC);



CREATE INDEX "idx_stock_historico_sucursal" ON "public"."stock_historico" USING "btree" ("sucursal_id");



CREATE INDEX "idx_stock_historico_tp_import_id" ON "public"."stock_historico" USING "btree" ("tp_import_id") WHERE ("tp_import_id" IS NOT NULL);



CREATE INDEX "idx_transferencia_items_sucursal" ON "public"."transferencia_items" USING "btree" ("sucursal_id");



CREATE INDEX "idx_transferencia_items_trans" ON "public"."transferencia_items" USING "btree" ("transferencia_id");



CREATE INDEX "idx_transferencias_fecha" ON "public"."transferencias_stock" USING "btree" ("fecha" DESC);



CREATE INDEX "idx_transferencias_stock_tenant_sucursal" ON "public"."transferencias_stock" USING "btree" ("tenant_sucursal_id");



CREATE INDEX "idx_transferencias_sucursal" ON "public"."transferencias_stock" USING "btree" ("sucursal_id");



CREATE INDEX "idx_usuario_sucursales_default" ON "public"."usuario_sucursales" USING "btree" ("usuario_id") WHERE ("es_default" = true);



CREATE INDEX "idx_usuario_sucursales_sucursal" ON "public"."usuario_sucursales" USING "btree" ("sucursal_id");



CREATE INDEX "idx_usuario_sucursales_usuario" ON "public"."usuario_sucursales" USING "btree" ("usuario_id");



CREATE INDEX "idx_zonas_sucursal" ON "public"."zonas" USING "btree" ("sucursal_id");



CREATE INDEX "pedidos_tp_import_idx" ON "public"."pedidos" USING "btree" ("tp_import_id") WHERE ("tp_import_id" IS NOT NULL);



CREATE INDEX "productos_tp_import_idx" ON "public"."productos" USING "btree" ("tp_import_id") WHERE ("tp_import_id" IS NOT NULL);



CREATE OR REPLACE TRIGGER "audit_clientes" AFTER INSERT OR DELETE OR UPDATE ON "public"."clientes" FOR EACH ROW EXECUTE FUNCTION "public"."audit_log_changes"();



CREATE OR REPLACE TRIGGER "audit_compras" AFTER INSERT OR DELETE OR UPDATE ON "public"."compras" FOR EACH ROW EXECUTE FUNCTION "public"."audit_log_changes"();



CREATE OR REPLACE TRIGGER "audit_pagos" AFTER INSERT OR DELETE OR UPDATE ON "public"."pagos" FOR EACH ROW EXECUTE FUNCTION "public"."audit_log_changes"();



CREATE OR REPLACE TRIGGER "audit_pedido_items" AFTER INSERT OR DELETE OR UPDATE ON "public"."pedido_items" FOR EACH ROW EXECUTE FUNCTION "public"."audit_log_changes"();



CREATE OR REPLACE TRIGGER "audit_pedidos" AFTER INSERT OR DELETE OR UPDATE ON "public"."pedidos" FOR EACH ROW EXECUTE FUNCTION "public"."audit_log_changes"();



CREATE OR REPLACE TRIGGER "audit_perfiles" AFTER INSERT OR DELETE OR UPDATE ON "public"."perfiles" FOR EACH ROW EXECUTE FUNCTION "public"."audit_log_changes"();



CREATE OR REPLACE TRIGGER "audit_productos" AFTER INSERT OR DELETE OR UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."audit_log_changes"();



CREATE OR REPLACE TRIGGER "audit_rendiciones" AFTER INSERT OR DELETE OR UPDATE ON "public"."rendiciones" FOR EACH ROW EXECUTE FUNCTION "public"."audit_log_changes"();



CREATE OR REPLACE TRIGGER "trg_check_promo_limite" BEFORE UPDATE OF "usos_pendientes" ON "public"."promociones" FOR EACH ROW EXECUTE FUNCTION "public"."check_promo_limite_usos"();



CREATE OR REPLACE TRIGGER "trg_pedidos_anular_control" AFTER UPDATE OF "fecha_entrega", "estado", "transportista_id" ON "public"."pedidos" FOR EACH ROW WHEN ((("old"."fecha_entrega" IS DISTINCT FROM "new"."fecha_entrega") OR ("old"."estado" IS DISTINCT FROM "new"."estado") OR ("old"."transportista_id" IS DISTINCT FROM "new"."transportista_id"))) EXECUTE FUNCTION "public"."anular_control_por_cambio_fecha_entrega"();



CREATE OR REPLACE TRIGGER "trg_promo_ajustes_sucursal" BEFORE INSERT ON "public"."promo_ajustes" FOR EACH ROW EXECUTE FUNCTION "public"."set_sucursal_id_default"();



CREATE OR REPLACE TRIGGER "trg_promocion_productos_sucursal" BEFORE INSERT ON "public"."promocion_productos" FOR EACH ROW EXECUTE FUNCTION "public"."set_sucursal_id_default"();



CREATE OR REPLACE TRIGGER "trg_promocion_reglas_sucursal" BEFORE INSERT ON "public"."promocion_reglas" FOR EACH ROW EXECUTE FUNCTION "public"."set_sucursal_id_default"();



CREATE OR REPLACE TRIGGER "trg_promociones_sucursal" BEFORE INSERT ON "public"."promociones" FOR EACH ROW EXECUTE FUNCTION "public"."set_sucursal_id_default"();



CREATE OR REPLACE TRIGGER "trg_stock_historico" AFTER UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."registrar_cambio_stock"();



CREATE OR REPLACE TRIGGER "trigger_actualizar_estado_pago" BEFORE INSERT OR UPDATE OF "monto_pagado", "total" ON "public"."pedidos" FOR EACH ROW EXECUTE FUNCTION "public"."actualizar_estado_pago_pedido"();



CREATE OR REPLACE TRIGGER "trigger_actualizar_recorrido_entrega" AFTER UPDATE OF "estado" ON "public"."pedidos" FOR EACH ROW EXECUTE FUNCTION "public"."actualizar_recorrido_entrega"();



CREATE OR REPLACE TRIGGER "trigger_actualizar_saldo_pago" AFTER INSERT OR DELETE ON "public"."pagos" FOR EACH ROW EXECUTE FUNCTION "public"."actualizar_saldo_cliente"();



CREATE OR REPLACE TRIGGER "trigger_actualizar_saldo_pedido" AFTER INSERT OR DELETE OR UPDATE OF "total", "monto_pagado" ON "public"."pedidos" FOR EACH ROW EXECUTE FUNCTION "public"."actualizar_saldo_pedido"();



CREATE OR REPLACE TRIGGER "trigger_registrar_cambio_pedido" AFTER UPDATE ON "public"."pedidos" FOR EACH ROW EXECUTE FUNCTION "public"."registrar_cambio_pedido"();



CREATE OR REPLACE TRIGGER "trigger_registrar_creacion_pedido" AFTER INSERT ON "public"."pedidos" FOR EACH ROW EXECUTE FUNCTION "public"."registrar_creacion_pedido"();



CREATE OR REPLACE TRIGGER "trigger_rendiciones_updated_at" BEFORE UPDATE ON "public"."rendiciones" FOR EACH ROW EXECUTE FUNCTION "public"."update_rendiciones_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_salvedades_updated_at" BEFORE UPDATE ON "public"."salvedades_items" FOR EACH ROW EXECUTE FUNCTION "public"."update_salvedades_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_compras_timestamp" BEFORE UPDATE ON "public"."compras" FOR EACH ROW EXECUTE FUNCTION "public"."update_compras_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_grupos_precio_timestamp" BEFORE UPDATE ON "public"."grupos_precio" FOR EACH ROW EXECUTE FUNCTION "public"."update_grupos_precio_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_productos_timestamp" BEFORE UPDATE ON "public"."productos" FOR EACH ROW EXECUTE FUNCTION "public"."update_productos_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_promociones_timestamp" BEFORE UPDATE ON "public"."promociones" FOR EACH ROW EXECUTE FUNCTION "public"."update_promociones_updated_at"();



CREATE OR REPLACE TRIGGER "trigger_update_proveedores_timestamp" BEFORE UPDATE ON "public"."proveedores" FOR EACH ROW EXECUTE FUNCTION "public"."update_proveedores_updated_at"();



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."audit_logs"
    ADD CONSTRAINT "audit_logs_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."clientes"
    ADD CONSTRAINT "clientes_preventista_id_fkey" FOREIGN KEY ("preventista_id") REFERENCES "public"."perfiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."clientes"
    ADD CONSTRAINT "clientes_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."clientes"
    ADD CONSTRAINT "clientes_zona_id_fkey" FOREIGN KEY ("zona_id") REFERENCES "public"."zonas"("id");



ALTER TABLE ONLY "public"."compra_items"
    ADD CONSTRAINT "compra_items_compra_id_fkey" FOREIGN KEY ("compra_id") REFERENCES "public"."compras"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."compra_items"
    ADD CONSTRAINT "compra_items_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."compra_items"
    ADD CONSTRAINT "compra_items_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."compras"
    ADD CONSTRAINT "compras_proveedor_id_fkey" FOREIGN KEY ("proveedor_id") REFERENCES "public"."proveedores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."compras"
    ADD CONSTRAINT "compras_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."compras"
    ADD CONSTRAINT "compras_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."grupo_precio_escalas"
    ADD CONSTRAINT "grupo_precio_escalas_grupo_precio_id_fkey" FOREIGN KEY ("grupo_precio_id") REFERENCES "public"."grupos_precio"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."grupo_precio_escalas"
    ADD CONSTRAINT "grupo_precio_escalas_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."grupo_precio_productos"
    ADD CONSTRAINT "grupo_precio_productos_grupo_precio_id_fkey" FOREIGN KEY ("grupo_precio_id") REFERENCES "public"."grupos_precio"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."grupo_precio_productos"
    ADD CONSTRAINT "grupo_precio_productos_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."grupo_precio_productos"
    ADD CONSTRAINT "grupo_precio_productos_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."grupos_precio"
    ADD CONSTRAINT "grupos_precio_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."historial_cambios"
    ADD CONSTRAINT "historial_cambios_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."historial_cambios"
    ADD CONSTRAINT "historial_cambios_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."mermas_stock"
    ADD CONSTRAINT "mermas_stock_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."mermas_stock"
    ADD CONSTRAINT "mermas_stock_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."mermas_stock"
    ADD CONSTRAINT "mermas_stock_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."nota_credito_items"
    ADD CONSTRAINT "nota_credito_items_nota_credito_id_fkey" FOREIGN KEY ("nota_credito_id") REFERENCES "public"."notas_credito"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."nota_credito_items"
    ADD CONSTRAINT "nota_credito_items_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."nota_credito_items"
    ADD CONSTRAINT "nota_credito_items_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."notas_credito"
    ADD CONSTRAINT "notas_credito_compra_id_fkey" FOREIGN KEY ("compra_id") REFERENCES "public"."compras"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."notas_credito"
    ADD CONSTRAINT "notas_credito_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."notas_credito"
    ADD CONSTRAINT "notas_credito_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pagos"
    ADD CONSTRAINT "pagos_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "public"."clientes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pagos"
    ADD CONSTRAINT "pagos_pedido_id_fkey" FOREIGN KEY ("pedido_id") REFERENCES "public"."pedidos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pagos"
    ADD CONSTRAINT "pagos_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."pagos"
    ADD CONSTRAINT "pagos_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."pedido_historial"
    ADD CONSTRAINT "pedido_historial_pedido_id_fkey" FOREIGN KEY ("pedido_id") REFERENCES "public"."pedidos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pedido_historial"
    ADD CONSTRAINT "pedido_historial_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."pedido_historial"
    ADD CONSTRAINT "pedido_historial_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pedido_items"
    ADD CONSTRAINT "pedido_items_pedido_id_fkey" FOREIGN KEY ("pedido_id") REFERENCES "public"."pedidos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."pedido_items"
    ADD CONSTRAINT "pedido_items_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pedido_items"
    ADD CONSTRAINT "pedido_items_promocion_id_fkey" FOREIGN KEY ("promocion_id") REFERENCES "public"."promociones"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pedido_items"
    ADD CONSTRAINT "pedido_items_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."pedidos"
    ADD CONSTRAINT "pedidos_cliente_id_fkey" FOREIGN KEY ("cliente_id") REFERENCES "public"."clientes"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."pedidos_eliminados"
    ADD CONSTRAINT "pedidos_eliminados_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."pedidos"
    ADD CONSTRAINT "pedidos_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."pedidos"
    ADD CONSTRAINT "pedidos_transportista_id_fkey" FOREIGN KEY ("transportista_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."pedidos"
    ADD CONSTRAINT "pedidos_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."perfiles"
    ADD CONSTRAINT "perfiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preventista_zonas"
    ADD CONSTRAINT "preventista_zonas_perfil_id_fkey" FOREIGN KEY ("perfil_id") REFERENCES "public"."perfiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."preventista_zonas"
    ADD CONSTRAINT "preventista_zonas_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."preventista_zonas"
    ADD CONSTRAINT "preventista_zonas_zona_id_fkey" FOREIGN KEY ("zona_id") REFERENCES "public"."zonas"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_proveedor_id_fkey" FOREIGN KEY ("proveedor_id") REFERENCES "public"."proveedores"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."productos"
    ADD CONSTRAINT "productos_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."promo_ajustes"
    ADD CONSTRAINT "promo_ajustes_merma_id_fkey" FOREIGN KEY ("merma_id") REFERENCES "public"."mermas_stock"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."promo_ajustes"
    ADD CONSTRAINT "promo_ajustes_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."promo_ajustes"
    ADD CONSTRAINT "promo_ajustes_promocion_id_fkey" FOREIGN KEY ("promocion_id") REFERENCES "public"."promociones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promo_ajustes"
    ADD CONSTRAINT "promo_ajustes_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."promo_ajustes"
    ADD CONSTRAINT "promo_ajustes_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."promocion_productos"
    ADD CONSTRAINT "promocion_productos_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promocion_productos"
    ADD CONSTRAINT "promocion_productos_promocion_id_fkey" FOREIGN KEY ("promocion_id") REFERENCES "public"."promociones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promocion_productos"
    ADD CONSTRAINT "promocion_productos_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."promocion_reglas"
    ADD CONSTRAINT "promocion_reglas_promocion_id_fkey" FOREIGN KEY ("promocion_id") REFERENCES "public"."promociones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."promocion_reglas"
    ADD CONSTRAINT "promocion_reglas_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."promociones"
    ADD CONSTRAINT "promociones_ajuste_producto_id_fkey" FOREIGN KEY ("ajuste_producto_id") REFERENCES "public"."productos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."promociones"
    ADD CONSTRAINT "promociones_producto_regalo_id_fkey" FOREIGN KEY ("producto_regalo_id") REFERENCES "public"."productos"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."promociones"
    ADD CONSTRAINT "promociones_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."proveedores_eliminados"
    ADD CONSTRAINT "proveedores_eliminados_eliminado_por_fkey" FOREIGN KEY ("eliminado_por") REFERENCES "public"."perfiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."proveedores"
    ADD CONSTRAINT "proveedores_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."proveedores"
    ADD CONSTRAINT "proveedores_zona_id_fkey" FOREIGN KEY ("zona_id") REFERENCES "public"."zonas"("id");



ALTER TABLE ONLY "public"."recorrido_pedidos"
    ADD CONSTRAINT "recorrido_pedidos_pedido_id_fkey" FOREIGN KEY ("pedido_id") REFERENCES "public"."pedidos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recorrido_pedidos"
    ADD CONSTRAINT "recorrido_pedidos_recorrido_id_fkey" FOREIGN KEY ("recorrido_id") REFERENCES "public"."recorridos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."recorrido_pedidos"
    ADD CONSTRAINT "recorrido_pedidos_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."recorridos"
    ADD CONSTRAINT "recorridos_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."recorridos"
    ADD CONSTRAINT "recorridos_transportista_id_fkey" FOREIGN KEY ("transportista_id") REFERENCES "public"."perfiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rendicion_ajustes"
    ADD CONSTRAINT "rendicion_ajustes_aprobado_por_fkey" FOREIGN KEY ("aprobado_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."rendicion_ajustes"
    ADD CONSTRAINT "rendicion_ajustes_rendicion_id_fkey" FOREIGN KEY ("rendicion_id") REFERENCES "public"."rendiciones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rendicion_ajustes"
    ADD CONSTRAINT "rendicion_ajustes_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."rendicion_items"
    ADD CONSTRAINT "rendicion_items_pedido_id_fkey" FOREIGN KEY ("pedido_id") REFERENCES "public"."pedidos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rendicion_items"
    ADD CONSTRAINT "rendicion_items_rendicion_id_fkey" FOREIGN KEY ("rendicion_id") REFERENCES "public"."rendiciones"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rendicion_items"
    ADD CONSTRAINT "rendicion_items_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."rendiciones_control"
    ADD CONSTRAINT "rendiciones_control_controlada_por_fkey" FOREIGN KEY ("controlada_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."rendiciones_control"
    ADD CONSTRAINT "rendiciones_control_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rendiciones_control"
    ADD CONSTRAINT "rendiciones_control_transportista_id_fkey" FOREIGN KEY ("transportista_id") REFERENCES "public"."perfiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rendiciones"
    ADD CONSTRAINT "rendiciones_recorrido_id_fkey" FOREIGN KEY ("recorrido_id") REFERENCES "public"."recorridos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."rendiciones"
    ADD CONSTRAINT "rendiciones_revisada_por_fkey" FOREIGN KEY ("revisada_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."rendiciones"
    ADD CONSTRAINT "rendiciones_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."rendiciones"
    ADD CONSTRAINT "rendiciones_transportista_id_fkey" FOREIGN KEY ("transportista_id") REFERENCES "public"."perfiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."salvedad_historial"
    ADD CONSTRAINT "salvedad_historial_salvedad_id_fkey" FOREIGN KEY ("salvedad_id") REFERENCES "public"."salvedades_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."salvedad_historial"
    ADD CONSTRAINT "salvedad_historial_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."salvedad_historial"
    ADD CONSTRAINT "salvedad_historial_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."salvedades_items"
    ADD CONSTRAINT "salvedades_items_pedido_id_fkey" FOREIGN KEY ("pedido_id") REFERENCES "public"."pedidos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."salvedades_items"
    ADD CONSTRAINT "salvedades_items_pedido_item_id_fkey" FOREIGN KEY ("pedido_item_id") REFERENCES "public"."pedido_items"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."salvedades_items"
    ADD CONSTRAINT "salvedades_items_pedido_reprogramado_id_fkey" FOREIGN KEY ("pedido_reprogramado_id") REFERENCES "public"."pedidos"("id");



ALTER TABLE ONLY "public"."salvedades_items"
    ADD CONSTRAINT "salvedades_items_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."salvedades_items"
    ADD CONSTRAINT "salvedades_items_reportado_por_fkey" FOREIGN KEY ("reportado_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."salvedades_items"
    ADD CONSTRAINT "salvedades_items_resuelto_por_fkey" FOREIGN KEY ("resuelto_por") REFERENCES "public"."perfiles"("id");



ALTER TABLE ONLY "public"."salvedades_items"
    ADD CONSTRAINT "salvedades_items_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."stock_historico"
    ADD CONSTRAINT "stock_historico_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."stock_historico"
    ADD CONSTRAINT "stock_historico_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."stock_historico"
    ADD CONSTRAINT "stock_historico_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."transferencia_items"
    ADD CONSTRAINT "transferencia_items_producto_id_fkey" FOREIGN KEY ("producto_id") REFERENCES "public"."productos"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transferencia_items"
    ADD CONSTRAINT "transferencia_items_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."transferencia_items"
    ADD CONSTRAINT "transferencia_items_transferencia_id_fkey" FOREIGN KEY ("transferencia_id") REFERENCES "public"."transferencias_stock"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_tenant_sucursal_id_fkey" FOREIGN KEY ("tenant_sucursal_id") REFERENCES "public"."sucursales"("id");



ALTER TABLE ONLY "public"."transferencias_stock"
    ADD CONSTRAINT "transferencias_stock_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."usuario_sucursales"
    ADD CONSTRAINT "usuario_sucursales_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."usuario_sucursales"
    ADD CONSTRAINT "usuario_sucursales_usuario_id_fkey" FOREIGN KEY ("usuario_id") REFERENCES "public"."perfiles"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."zonas"
    ADD CONSTRAINT "zonas_sucursal_id_fkey" FOREIGN KEY ("sucursal_id") REFERENCES "public"."sucursales"("id");



CREATE POLICY "Admin full access proveedores_eliminados" ON "public"."proveedores_eliminados" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"text")))));



CREATE POLICY "Perfiles: actualizacion propio o admin" ON "public"."perfiles" FOR UPDATE USING ((("id" = "auth"."uid"()) OR "public"."es_admin"()));



CREATE POLICY "Perfiles: lectura usuarios autenticados" ON "public"."perfiles" FOR SELECT USING (("auth"."uid"() IS NOT NULL));



CREATE POLICY "admin_sucursales" ON "public"."sucursales" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"text")))));



ALTER TABLE "public"."audit_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."clientes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."compra_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."compras" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."grupo_precio_escalas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."grupo_precio_productos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."grupos_precio" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."historial_cambios" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mermas_stock" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "mt_audit_logs_insert" ON "public"."audit_logs" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_audit_logs_select" ON "public"."audit_logs" FOR SELECT TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_clientes_delete" ON "public"."clientes" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_clientes_insert" ON "public"."clientes" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_preventista"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_clientes_select" ON "public"."clientes" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_clientes_update" ON "public"."clientes" FOR UPDATE TO "authenticated" USING (("public"."es_preventista"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_preventista"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_compra_items_delete" ON "public"."compra_items" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_compra_items_insert" ON "public"."compra_items" FOR INSERT TO "authenticated" WITH CHECK ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'deposito'::"text"))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_compra_items_select" ON "public"."compra_items" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'deposito'::"text"))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_compra_items_update" ON "public"."compra_items" FOR UPDATE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_compras_delete" ON "public"."compras" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_compras_insert" ON "public"."compras" FOR INSERT TO "authenticated" WITH CHECK ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'deposito'::"text"))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_compras_select" ON "public"."compras" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'deposito'::"text"))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_compras_update" ON "public"."compras" FOR UPDATE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_grupo_precio_escalas_all" ON "public"."grupo_precio_escalas" TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_grupo_precio_escalas_select" ON "public"."grupo_precio_escalas" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_grupo_precio_productos_all" ON "public"."grupo_precio_productos" TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_grupo_precio_productos_select" ON "public"."grupo_precio_productos" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_grupos_precio_all" ON "public"."grupos_precio" TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_grupos_precio_select" ON "public"."grupos_precio" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_historial_cambios_insert" ON "public"."historial_cambios" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_historial_cambios_select" ON "public"."historial_cambios" FOR SELECT TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_mermas_stock_delete" ON "public"."mermas_stock" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_mermas_stock_insert" ON "public"."mermas_stock" FOR INSERT TO "authenticated" WITH CHECK ((("public"."es_admin"() OR "public"."es_transportista"()) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_mermas_stock_select" ON "public"."mermas_stock" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR "public"."es_transportista"()) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_mermas_stock_update" ON "public"."mermas_stock" FOR UPDATE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_nota_credito_items_all" ON "public"."nota_credito_items" TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_nota_credito_items_select" ON "public"."nota_credito_items" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_notas_credito_all" ON "public"."notas_credito" TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_notas_credito_select" ON "public"."notas_credito" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_pagos_delete" ON "public"."pagos" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pagos_insert" ON "public"."pagos" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_preventista"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pagos_select" ON "public"."pagos" FOR SELECT TO "authenticated" USING (("public"."es_preventista"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pagos_update" ON "public"."pagos" FOR UPDATE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedido_historial_delete" ON "public"."pedido_historial" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedido_historial_insert" ON "public"."pedido_historial" FOR INSERT TO "authenticated" WITH CHECK (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_pedido_historial_select" ON "public"."pedido_historial" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_pedido_historial_update" ON "public"."pedido_historial" FOR UPDATE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedido_items_delete" ON "public"."pedido_items" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedido_items_insert" ON "public"."pedido_items" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_preventista"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedido_items_select" ON "public"."pedido_items" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."pedidos" "p"
  WHERE (("p"."id" = "pedido_items"."pedido_id") AND ("public"."es_encargado_o_admin"() OR ("p"."usuario_id" = "auth"."uid"()) OR ("p"."transportista_id" = "auth"."uid"()))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedido_items_update" ON "public"."pedido_items" FOR UPDATE TO "authenticated" USING (("public"."es_preventista"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_preventista"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedidos_delete" ON "public"."pedidos" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedidos_eliminados_insert" ON "public"."pedidos_eliminados" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedidos_eliminados_select" ON "public"."pedidos_eliminados" FOR SELECT TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedidos_insert" ON "public"."pedidos" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_preventista"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedidos_select" ON "public"."pedidos" FOR SELECT TO "authenticated" USING ((("public"."es_encargado_o_admin"() OR ("usuario_id" = "auth"."uid"()) OR ("transportista_id" = "auth"."uid"())) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_pedidos_update" ON "public"."pedidos" FOR UPDATE TO "authenticated" USING ((("public"."es_encargado_o_admin"() OR ("usuario_id" = "auth"."uid"()) OR ("transportista_id" = "auth"."uid"())) AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK ((("public"."es_encargado_o_admin"() OR ("usuario_id" = "auth"."uid"()) OR ("transportista_id" = "auth"."uid"())) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_preventista_zonas_delete" ON "public"."preventista_zonas" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_preventista_zonas_insert" ON "public"."preventista_zonas" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_preventista_zonas_select" ON "public"."preventista_zonas" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_preventista_zonas_update" ON "public"."preventista_zonas" FOR UPDATE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_productos_delete" ON "public"."productos" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_productos_insert" ON "public"."productos" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_productos_select" ON "public"."productos" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_productos_update" ON "public"."productos" FOR UPDATE TO "authenticated" USING ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'deposito'::"text"))))) AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'deposito'::"text"))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_promo_ajustes_all" ON "public"."promo_ajustes" TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_promo_ajustes_select" ON "public"."promo_ajustes" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_promocion_productos_all" ON "public"."promocion_productos" TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_promocion_productos_select" ON "public"."promocion_productos" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_promocion_reglas_all" ON "public"."promocion_reglas" TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_promocion_reglas_select" ON "public"."promocion_reglas" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_promociones_all" ON "public"."promociones" TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_promociones_select" ON "public"."promociones" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_proveedores_delete" ON "public"."proveedores" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_proveedores_insert" ON "public"."proveedores" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_proveedores_select" ON "public"."proveedores" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'deposito'::"text"))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_proveedores_update" ON "public"."proveedores" FOR UPDATE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_recorrido_pedidos_insert" ON "public"."recorrido_pedidos" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_recorrido_pedidos_select" ON "public"."recorrido_pedidos" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."recorridos" "r"
  WHERE (("r"."id" = "recorrido_pedidos"."recorrido_id") AND ("r"."transportista_id" = "auth"."uid"()))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_recorrido_pedidos_update" ON "public"."recorrido_pedidos" FOR UPDATE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_recorridos_delete" ON "public"."recorridos" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_recorridos_insert" ON "public"."recorridos" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_recorridos_select" ON "public"."recorridos" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR ("transportista_id" = "auth"."uid"())) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_recorridos_update" ON "public"."recorridos" FOR UPDATE TO "authenticated" USING ((("public"."es_admin"() OR ("transportista_id" = "auth"."uid"())) AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK ((("public"."es_admin"() OR ("transportista_id" = "auth"."uid"())) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendicion_ajustes_insert" ON "public"."rendicion_ajustes" FOR INSERT TO "authenticated" WITH CHECK ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."rendiciones" "r"
  WHERE (("r"."id" = "rendicion_ajustes"."rendicion_id") AND ("r"."transportista_id" = "auth"."uid"()))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendicion_ajustes_select" ON "public"."rendicion_ajustes" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."rendiciones" "r"
  WHERE (("r"."id" = "rendicion_ajustes"."rendicion_id") AND ("r"."transportista_id" = "auth"."uid"()))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendicion_items_insert" ON "public"."rendicion_items" FOR INSERT TO "authenticated" WITH CHECK ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."rendiciones" "r"
  WHERE (("r"."id" = "rendicion_items"."rendicion_id") AND ("r"."transportista_id" = "auth"."uid"()))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendicion_items_select" ON "public"."rendicion_items" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."rendiciones" "r"
  WHERE (("r"."id" = "rendicion_items"."rendicion_id") AND ("r"."transportista_id" = "auth"."uid"()))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendiciones_control_delete" ON "public"."rendiciones_control" FOR DELETE TO "authenticated" USING (("public"."es_encargado_o_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendiciones_control_insert" ON "public"."rendiciones_control" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_encargado_o_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendiciones_control_select" ON "public"."rendiciones_control" FOR SELECT TO "authenticated" USING (("public"."es_encargado_o_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendiciones_delete" ON "public"."rendiciones" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendiciones_insert" ON "public"."rendiciones" FOR INSERT TO "authenticated" WITH CHECK ((("public"."es_admin"() OR ("transportista_id" = "auth"."uid"())) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendiciones_select" ON "public"."rendiciones" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR ("transportista_id" = "auth"."uid"())) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_rendiciones_update" ON "public"."rendiciones" FOR UPDATE TO "authenticated" USING ((("public"."es_admin"() OR (("transportista_id" = "auth"."uid"()) AND (("estado")::"text" = 'pendiente'::"text"))) AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK ((("public"."es_admin"() OR (("transportista_id" = "auth"."uid"()) AND (("estado")::"text" = 'pendiente'::"text"))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_salvedad_historial_insert" ON "public"."salvedad_historial" FOR INSERT TO "authenticated" WITH CHECK ((("public"."es_admin"() OR "public"."es_transportista"()) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_salvedad_historial_select" ON "public"."salvedad_historial" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM ("public"."salvedades_items" "si"
     JOIN "public"."pedidos" "p" ON (("p"."id" = "si"."pedido_id")))
  WHERE (("si"."id" = "salvedad_historial"."salvedad_id") AND (("p"."usuario_id" = "auth"."uid"()) OR ("p"."transportista_id" = "auth"."uid"())))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_salvedades_items_delete" ON "public"."salvedades_items" FOR DELETE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_salvedades_items_insert" ON "public"."salvedades_items" FOR INSERT TO "authenticated" WITH CHECK ((("public"."es_admin"() OR "public"."es_transportista"()) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_salvedades_items_select" ON "public"."salvedades_items" FOR SELECT TO "authenticated" USING ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."pedidos" "p"
  WHERE (("p"."id" = "salvedades_items"."pedido_id") AND (("p"."usuario_id" = "auth"."uid"()) OR ("p"."transportista_id" = "auth"."uid"())))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_salvedades_items_update" ON "public"."salvedades_items" FOR UPDATE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_stock_historico_insert" ON "public"."stock_historico" FOR INSERT TO "authenticated" WITH CHECK ((("public"."es_admin"() OR (EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'deposito'::"text"))))) AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_stock_historico_select" ON "public"."stock_historico" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_transferencia_items_all" ON "public"."transferencia_items" TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_transferencia_items_select" ON "public"."transferencia_items" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_transferencias_stock_all" ON "public"."transferencias_stock" TO "authenticated" USING (("public"."es_admin"() AND ("tenant_sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("tenant_sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_transferencias_stock_select" ON "public"."transferencias_stock" FOR SELECT TO "authenticated" USING (("tenant_sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_zonas_insert" ON "public"."zonas" FOR INSERT TO "authenticated" WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



CREATE POLICY "mt_zonas_select" ON "public"."zonas" FOR SELECT TO "authenticated" USING (("sucursal_id" = "public"."current_sucursal_id"()));



CREATE POLICY "mt_zonas_update" ON "public"."zonas" FOR UPDATE TO "authenticated" USING (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"()))) WITH CHECK (("public"."es_admin"() AND ("sucursal_id" = "public"."current_sucursal_id"())));



ALTER TABLE "public"."nota_credito_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notas_credito" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pagos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pedido_historial" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pedido_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pedidos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pedidos_eliminados" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."perfiles" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "perfiles_delete_admin" ON "public"."perfiles" FOR DELETE USING ("public"."is_admin"());



CREATE POLICY "perfiles_insert_admin" ON "public"."perfiles" FOR INSERT WITH CHECK ("public"."is_admin"());



CREATE POLICY "perfiles_select_admin" ON "public"."perfiles" FOR SELECT TO "authenticated" USING ("public"."es_admin"());



CREATE POLICY "perfiles_select_all" ON "public"."perfiles" FOR SELECT USING (true);



CREATE POLICY "perfiles_select_propio" ON "public"."perfiles" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "id"));



CREATE POLICY "perfiles_update_admin" ON "public"."perfiles" FOR UPDATE USING ("public"."is_admin"());



CREATE POLICY "perfiles_update_self" ON "public"."perfiles" FOR UPDATE USING (("id" = "auth"."uid"())) WITH CHECK (("id" = "auth"."uid"()));



ALTER TABLE "public"."preventista_zonas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."productos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."promo_ajustes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."promocion_productos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."promocion_reglas" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."promociones" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."proveedores" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."proveedores_eliminados" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "read_sucursales" ON "public"."sucursales" FOR SELECT USING (("auth"."role"() = 'authenticated'::"text"));



ALTER TABLE "public"."recorrido_pedidos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recorridos" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rendicion_ajustes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rendicion_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rendiciones" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."rendiciones_control" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."salvedad_historial" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."salvedades_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."stock_historico" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sucursales" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transferencia_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."transferencias_stock" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."usuario_sucursales" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "usuario_sucursales_admin_all" ON "public"."usuario_sucursales" TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"text"))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."perfiles"
  WHERE (("perfiles"."id" = "auth"."uid"()) AND ("perfiles"."rol" = 'admin'::"text")))));



CREATE POLICY "usuario_sucursales_select_own" ON "public"."usuario_sucursales" FOR SELECT TO "authenticated" USING (("usuario_id" = "auth"."uid"()));



ALTER TABLE "public"."zonas" ENABLE ROW LEVEL SECURITY;


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."actualizar_estado_pago_pedido"() TO "anon";
GRANT ALL ON FUNCTION "public"."actualizar_estado_pago_pedido"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_estado_pago_pedido"() TO "service_role";



GRANT ALL ON FUNCTION "public"."actualizar_orden_entrega_batch"("ordenes" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."actualizar_orden_entrega_batch"("ordenes" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_orden_entrega_batch"("ordenes" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."actualizar_orden_entrega_batch"("ordenes" "public"."orden_entrega_item"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."actualizar_orden_entrega_batch"("ordenes" "public"."orden_entrega_item"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_orden_entrega_batch"("ordenes" "public"."orden_entrega_item"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."actualizar_pedido_items"("p_pedido_id" bigint, "p_items_nuevos" "jsonb", "p_usuario_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."actualizar_pedido_items"("p_pedido_id" bigint, "p_items_nuevos" "jsonb", "p_usuario_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_pedido_items"("p_pedido_id" bigint, "p_items_nuevos" "jsonb", "p_usuario_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."actualizar_precios_masivo"("p_productos" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."actualizar_precios_masivo"("p_productos" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_precios_masivo"("p_productos" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."actualizar_recorrido_entrega"() TO "anon";
GRANT ALL ON FUNCTION "public"."actualizar_recorrido_entrega"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_recorrido_entrega"() TO "service_role";



GRANT ALL ON FUNCTION "public"."actualizar_saldo_cliente"() TO "anon";
GRANT ALL ON FUNCTION "public"."actualizar_saldo_cliente"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_saldo_cliente"() TO "service_role";



GRANT ALL ON FUNCTION "public"."actualizar_saldo_pedido"() TO "anon";
GRANT ALL ON FUNCTION "public"."actualizar_saldo_pedido"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."actualizar_saldo_pedido"() TO "service_role";



GRANT ALL ON FUNCTION "public"."ajustar_stock_promocion_completo"("p_promocion_id" bigint, "p_producto_id" bigint, "p_cantidad_stock" integer, "p_usos_ajustados" integer, "p_usuario_id" "uuid", "p_observaciones" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."ajustar_stock_promocion_completo"("p_promocion_id" bigint, "p_producto_id" bigint, "p_cantidad_stock" integer, "p_usos_ajustados" integer, "p_usuario_id" "uuid", "p_observaciones" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."ajustar_stock_promocion_completo"("p_promocion_id" bigint, "p_producto_id" bigint, "p_cantidad_stock" integer, "p_usos_ajustados" integer, "p_usuario_id" "uuid", "p_observaciones" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."anular_compra_atomica"("p_compra_id" bigint, "p_usuario_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."anular_compra_atomica"("p_compra_id" bigint, "p_usuario_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."anular_compra_atomica"("p_compra_id" bigint, "p_usuario_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."anular_control_por_cambio_fecha_entrega"() TO "anon";
GRANT ALL ON FUNCTION "public"."anular_control_por_cambio_fecha_entrega"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."anular_control_por_cambio_fecha_entrega"() TO "service_role";



GRANT ALL ON FUNCTION "public"."anular_salvedad"("p_salvedad_id" bigint, "p_notas" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."anular_salvedad"("p_salvedad_id" bigint, "p_notas" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."anular_salvedad"("p_salvedad_id" bigint, "p_notas" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."asignar_usuario_sucursal"("p_usuario_id" "uuid", "p_sucursal_id" bigint, "p_rol" character varying, "p_es_default" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."asignar_usuario_sucursal"("p_usuario_id" "uuid", "p_sucursal_id" bigint, "p_rol" character varying, "p_es_default" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."asignar_usuario_sucursal"("p_usuario_id" "uuid", "p_sucursal_id" bigint, "p_rol" character varying, "p_es_default" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."audit_log_changes"() TO "anon";
GRANT ALL ON FUNCTION "public"."audit_log_changes"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."audit_log_changes"() TO "service_role";



GRANT ALL ON FUNCTION "public"."cambiar_sucursal"("p_sucursal_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."cambiar_sucursal"("p_sucursal_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."cambiar_sucursal"("p_sucursal_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."cancelar_pedido_con_stock"("p_pedido_id" bigint, "p_motivo" "text", "p_usuario_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."cancelar_pedido_con_stock"("p_pedido_id" bigint, "p_motivo" "text", "p_usuario_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancelar_pedido_con_stock"("p_pedido_id" bigint, "p_motivo" "text", "p_usuario_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_promo_limite_usos"() TO "anon";
GRANT ALL ON FUNCTION "public"."check_promo_limite_usos"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_promo_limite_usos"() TO "service_role";



GRANT ALL ON FUNCTION "public"."consultar_control_rendicion"("p_transportista_id" "uuid", "p_fecha" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."consultar_control_rendicion"("p_transportista_id" "uuid", "p_fecha" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."consultar_control_rendicion"("p_transportista_id" "uuid", "p_fecha" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."crear_pedido_completo"("p_cliente_id" bigint, "p_total" numeric, "p_usuario_id" "uuid", "p_items" "jsonb", "p_notas" "text", "p_forma_pago" "text", "p_estado_pago" "text", "p_fecha" "date", "p_tipo_factura" "text", "p_total_neto" numeric, "p_total_iva" numeric, "p_fecha_entrega_programada" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."crear_pedido_completo"("p_cliente_id" bigint, "p_total" numeric, "p_usuario_id" "uuid", "p_items" "jsonb", "p_notas" "text", "p_forma_pago" "text", "p_estado_pago" "text", "p_fecha" "date", "p_tipo_factura" "text", "p_total_neto" numeric, "p_total_iva" numeric, "p_fecha_entrega_programada" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crear_pedido_completo"("p_cliente_id" bigint, "p_total" numeric, "p_usuario_id" "uuid", "p_items" "jsonb", "p_notas" "text", "p_forma_pago" "text", "p_estado_pago" "text", "p_fecha" "date", "p_tipo_factura" "text", "p_total_neto" numeric, "p_total_iva" numeric, "p_fecha_entrega_programada" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."crear_recorrido"("p_transportista_id" "uuid", "p_pedidos" "jsonb", "p_distancia" numeric, "p_duracion" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."crear_recorrido"("p_transportista_id" "uuid", "p_pedidos" "jsonb", "p_distancia" numeric, "p_duracion" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."crear_recorrido"("p_transportista_id" "uuid", "p_pedidos" "jsonb", "p_distancia" numeric, "p_duracion" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."crear_rendicion_por_fecha"("p_transportista_id" "uuid", "p_fecha" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."crear_rendicion_por_fecha"("p_transportista_id" "uuid", "p_fecha" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crear_rendicion_por_fecha"("p_transportista_id" "uuid", "p_fecha" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."crear_rendicion_recorrido"("p_recorrido_id" bigint, "p_transportista_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."crear_rendicion_recorrido"("p_recorrido_id" bigint, "p_transportista_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."crear_rendicion_recorrido"("p_recorrido_id" bigint, "p_transportista_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."current_sucursal_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."current_sucursal_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_sucursal_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."desasignar_usuario_sucursal"("p_usuario_id" "uuid", "p_sucursal_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."desasignar_usuario_sucursal"("p_usuario_id" "uuid", "p_sucursal_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."desasignar_usuario_sucursal"("p_usuario_id" "uuid", "p_sucursal_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."descontar_stock_atomico"("p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."descontar_stock_atomico"("p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."descontar_stock_atomico"("p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."desmarcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."desmarcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."desmarcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."eliminar_pedido_completo"("p_pedido_id" bigint, "p_usuario_id" "uuid", "p_motivo" "text", "p_restaurar_stock" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."eliminar_pedido_completo"("p_pedido_id" bigint, "p_usuario_id" "uuid", "p_motivo" "text", "p_restaurar_stock" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_pedido_completo"("p_pedido_id" bigint, "p_usuario_id" "uuid", "p_motivo" "text", "p_restaurar_stock" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."eliminar_proveedor"("p_proveedor_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."es_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."es_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."es_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."es_admin_rendiciones"() TO "anon";
GRANT ALL ON FUNCTION "public"."es_admin_rendiciones"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."es_admin_rendiciones"() TO "service_role";



GRANT ALL ON FUNCTION "public"."es_admin_salvedades"() TO "anon";
GRANT ALL ON FUNCTION "public"."es_admin_salvedades"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."es_admin_salvedades"() TO "service_role";



GRANT ALL ON FUNCTION "public"."es_encargado_o_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."es_encargado_o_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."es_encargado_o_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."es_preventista"() TO "anon";
GRANT ALL ON FUNCTION "public"."es_preventista"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."es_preventista"() TO "service_role";



GRANT ALL ON FUNCTION "public"."es_transportista"() TO "anon";
GRANT ALL ON FUNCTION "public"."es_transportista"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."es_transportista"() TO "service_role";



GRANT ALL ON FUNCTION "public"."es_transportista_rendiciones"() TO "anon";
GRANT ALL ON FUNCTION "public"."es_transportista_rendiciones"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."es_transportista_rendiciones"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_audit_history"("p_tabla" "text", "p_registro_id" "text", "p_limit" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_audit_history"("p_tabla" "text", "p_registro_id" "text", "p_limit" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_audit_history"("p_tabla" "text", "p_registro_id" "text", "p_limit" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_mi_rol"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_mi_rol"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_mi_rol"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_suspicious_activity"("p_days" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_suspicious_activity"("p_days" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_suspicious_activity"("p_days" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_role"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_role"() TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_admin"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_admin"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_preventista"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_preventista"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_preventista"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_transportista"() TO "anon";
GRANT ALL ON FUNCTION "public"."is_transportista"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_transportista"() TO "service_role";



GRANT ALL ON FUNCTION "public"."limpiar_orden_entrega"("p_transportista_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."limpiar_orden_entrega"("p_transportista_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."limpiar_orden_entrega"("p_transportista_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."marcar_pagos_masivo"("p_pedido_ids" bigint[], "p_forma_pago" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."marcar_pagos_masivo"("p_pedido_ids" bigint[], "p_forma_pago" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."marcar_pagos_masivo"("p_pedido_ids" bigint[], "p_forma_pago" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."marcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."marcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."marcar_rendicion_controlada"("p_fecha" "date", "p_transportista_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."obtener_estadisticas_pedidos"("p_fecha_desde" timestamp with time zone, "p_fecha_hasta" timestamp with time zone, "p_usuario_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."obtener_estadisticas_pedidos"("p_fecha_desde" timestamp with time zone, "p_fecha_hasta" timestamp with time zone, "p_usuario_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."obtener_estadisticas_pedidos"("p_fecha_desde" timestamp with time zone, "p_fecha_hasta" timestamp with time zone, "p_usuario_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."obtener_estadisticas_rendiciones"("p_fecha_desde" "date", "p_fecha_hasta" "date", "p_transportista_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."obtener_estadisticas_rendiciones"("p_fecha_desde" "date", "p_fecha_hasta" "date", "p_transportista_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."obtener_estadisticas_rendiciones"("p_fecha_desde" "date", "p_fecha_hasta" "date", "p_transportista_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."obtener_resumen_compras"("p_fecha_desde" "date", "p_fecha_hasta" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."obtener_resumen_compras"("p_fecha_desde" "date", "p_fecha_hasta" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."obtener_resumen_compras"("p_fecha_desde" "date", "p_fecha_hasta" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."obtener_resumen_cuenta_cliente"("p_cliente_id" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."obtener_resumen_cuenta_cliente"("p_cliente_id" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."obtener_resumen_cuenta_cliente"("p_cliente_id" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."obtener_resumen_rendiciones"("p_fecha_desde" "date", "p_fecha_hasta" "date", "p_transportista_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."obtener_resumen_rendiciones"("p_fecha_desde" "date", "p_fecha_hasta" "date", "p_transportista_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."obtener_resumen_rendiciones"("p_fecha_desde" "date", "p_fecha_hasta" "date", "p_transportista_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."obtener_sucursales_usuario"() TO "anon";
GRANT ALL ON FUNCTION "public"."obtener_sucursales_usuario"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."obtener_sucursales_usuario"() TO "service_role";



GRANT ALL ON FUNCTION "public"."presentar_rendicion"("p_rendicion_id" bigint, "p_monto_rendido" numeric, "p_justificacion" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."presentar_rendicion"("p_rendicion_id" bigint, "p_monto_rendido" numeric, "p_justificacion" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."presentar_rendicion"("p_rendicion_id" bigint, "p_monto_rendido" numeric, "p_justificacion" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."registrar_cambio_pedido"() TO "anon";
GRANT ALL ON FUNCTION "public"."registrar_cambio_pedido"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_cambio_pedido"() TO "service_role";



GRANT ALL ON FUNCTION "public"."registrar_cambio_stock"() TO "anon";
GRANT ALL ON FUNCTION "public"."registrar_cambio_stock"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_cambio_stock"() TO "service_role";



GRANT ALL ON FUNCTION "public"."registrar_compra_completa"("p_proveedor_id" bigint, "p_proveedor_nombre" character varying, "p_numero_factura" character varying, "p_fecha_compra" "date", "p_subtotal" numeric, "p_iva" numeric, "p_otros_impuestos" numeric, "p_total" numeric, "p_forma_pago" character varying, "p_notas" "text", "p_usuario_id" "uuid", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."registrar_compra_completa"("p_proveedor_id" bigint, "p_proveedor_nombre" character varying, "p_numero_factura" character varying, "p_fecha_compra" "date", "p_subtotal" numeric, "p_iva" numeric, "p_otros_impuestos" numeric, "p_total" numeric, "p_forma_pago" character varying, "p_notas" "text", "p_usuario_id" "uuid", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_compra_completa"("p_proveedor_id" bigint, "p_proveedor_nombre" character varying, "p_numero_factura" character varying, "p_fecha_compra" "date", "p_subtotal" numeric, "p_iva" numeric, "p_otros_impuestos" numeric, "p_total" numeric, "p_forma_pago" character varying, "p_notas" "text", "p_usuario_id" "uuid", "p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."registrar_compra_completa"("p_proveedor_id" bigint, "p_proveedor_nombre" character varying, "p_numero_factura" character varying, "p_fecha_compra" "date", "p_subtotal" numeric, "p_iva" numeric, "p_otros_impuestos" numeric, "p_total" numeric, "p_forma_pago" character varying, "p_notas" "text", "p_usuario_id" "uuid", "p_items" "jsonb", "p_tipo_factura" character varying) TO "anon";
GRANT ALL ON FUNCTION "public"."registrar_compra_completa"("p_proveedor_id" bigint, "p_proveedor_nombre" character varying, "p_numero_factura" character varying, "p_fecha_compra" "date", "p_subtotal" numeric, "p_iva" numeric, "p_otros_impuestos" numeric, "p_total" numeric, "p_forma_pago" character varying, "p_notas" "text", "p_usuario_id" "uuid", "p_items" "jsonb", "p_tipo_factura" character varying) TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_compra_completa"("p_proveedor_id" bigint, "p_proveedor_nombre" character varying, "p_numero_factura" character varying, "p_fecha_compra" "date", "p_subtotal" numeric, "p_iva" numeric, "p_otros_impuestos" numeric, "p_total" numeric, "p_forma_pago" character varying, "p_notas" "text", "p_usuario_id" "uuid", "p_items" "jsonb", "p_tipo_factura" character varying) TO "service_role";



GRANT ALL ON FUNCTION "public"."registrar_creacion_pedido"() TO "anon";
GRANT ALL ON FUNCTION "public"."registrar_creacion_pedido"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_creacion_pedido"() TO "service_role";



GRANT ALL ON FUNCTION "public"."registrar_ingreso_sucursal"("p_sucursal_id" bigint, "p_fecha" "date", "p_notas" "text", "p_total_costo" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."registrar_ingreso_sucursal"("p_sucursal_id" bigint, "p_fecha" "date", "p_notas" "text", "p_total_costo" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_ingreso_sucursal"("p_sucursal_id" bigint, "p_fecha" "date", "p_notas" "text", "p_total_costo" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."registrar_nota_credito"("p_compra_id" bigint, "p_numero_nota" character varying, "p_motivo" "text", "p_subtotal" numeric, "p_iva" numeric, "p_total" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."registrar_nota_credito"("p_compra_id" bigint, "p_numero_nota" character varying, "p_motivo" "text", "p_subtotal" numeric, "p_iva" numeric, "p_total" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_nota_credito"("p_compra_id" bigint, "p_numero_nota" character varying, "p_motivo" "text", "p_subtotal" numeric, "p_iva" numeric, "p_total" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."registrar_salvedad"("p_pedido_id" bigint, "p_pedido_item_id" bigint, "p_cantidad_afectada" integer, "p_motivo" character varying, "p_descripcion" "text", "p_foto_url" "text", "p_devolver_stock" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."registrar_salvedad"("p_pedido_id" bigint, "p_pedido_item_id" bigint, "p_cantidad_afectada" integer, "p_motivo" character varying, "p_descripcion" "text", "p_foto_url" "text", "p_devolver_stock" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_salvedad"("p_pedido_id" bigint, "p_pedido_item_id" bigint, "p_cantidad_afectada" integer, "p_motivo" character varying, "p_descripcion" "text", "p_foto_url" "text", "p_devolver_stock" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."registrar_transferencia"("p_sucursal_id" bigint, "p_fecha" "date", "p_notas" "text", "p_total_costo" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."registrar_transferencia"("p_sucursal_id" bigint, "p_fecha" "date", "p_notas" "text", "p_total_costo" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."registrar_transferencia"("p_sucursal_id" bigint, "p_fecha" "date", "p_notas" "text", "p_total_costo" numeric, "p_usuario_id" "uuid", "p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."resolver_salvedad"("p_salvedad_id" bigint, "p_estado_resolucion" character varying, "p_notas" "text", "p_pedido_reprogramado_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."resolver_salvedad"("p_salvedad_id" bigint, "p_estado_resolucion" character varying, "p_notas" "text", "p_pedido_reprogramado_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolver_salvedad"("p_salvedad_id" bigint, "p_estado_resolucion" character varying, "p_notas" "text", "p_pedido_reprogramado_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."restaurar_stock_atomico"("p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."restaurar_stock_atomico"("p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."restaurar_stock_atomico"("p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."revisar_rendicion"("p_rendicion_id" bigint, "p_accion" character varying, "p_observaciones" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."revisar_rendicion"("p_rendicion_id" bigint, "p_accion" character varying, "p_observaciones" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revisar_rendicion"("p_rendicion_id" bigint, "p_accion" character varying, "p_observaciones" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_sucursal_id_default"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_sucursal_id_default"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_sucursal_id_default"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_compras_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_compras_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_compras_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_grupos_precio_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_grupos_precio_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_grupos_precio_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_productos_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_productos_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_productos_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_promociones_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_promociones_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_promociones_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_proveedores_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_proveedores_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_proveedores_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_rendiciones_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_rendiciones_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_rendiciones_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_salvedades_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_salvedades_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_salvedades_updated_at"() TO "service_role";



GRANT ALL ON TABLE "public"."audit_logs" TO "anon";
GRANT ALL ON TABLE "public"."audit_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs" TO "service_role";



GRANT ALL ON TABLE "public"."perfiles" TO "anon";
GRANT ALL ON TABLE "public"."perfiles" TO "authenticated";
GRANT ALL ON TABLE "public"."perfiles" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,MAINTAIN ON TABLE "public"."audit_logs_detallado" TO "authenticated";
GRANT ALL ON TABLE "public"."audit_logs_detallado" TO "service_role";



GRANT ALL ON SEQUENCE "public"."clientes_codigo_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."clientes_codigo_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."clientes_codigo_seq" TO "service_role";



GRANT ALL ON TABLE "public"."clientes" TO "anon";
GRANT ALL ON TABLE "public"."clientes" TO "authenticated";
GRANT ALL ON TABLE "public"."clientes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."clientes_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."clientes_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."clientes_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."compra_items" TO "anon";
GRANT ALL ON TABLE "public"."compra_items" TO "authenticated";
GRANT ALL ON TABLE "public"."compra_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."compra_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."compra_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."compra_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."compras" TO "anon";
GRANT ALL ON TABLE "public"."compras" TO "authenticated";
GRANT ALL ON TABLE "public"."compras" TO "service_role";



GRANT ALL ON SEQUENCE "public"."compras_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."compras_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."compras_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."grupo_precio_escalas" TO "anon";
GRANT ALL ON TABLE "public"."grupo_precio_escalas" TO "authenticated";
GRANT ALL ON TABLE "public"."grupo_precio_escalas" TO "service_role";



GRANT ALL ON SEQUENCE "public"."grupo_precio_escalas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."grupo_precio_escalas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."grupo_precio_escalas_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."grupo_precio_productos" TO "anon";
GRANT ALL ON TABLE "public"."grupo_precio_productos" TO "authenticated";
GRANT ALL ON TABLE "public"."grupo_precio_productos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."grupo_precio_productos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."grupo_precio_productos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."grupo_precio_productos_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."grupos_precio" TO "anon";
GRANT ALL ON TABLE "public"."grupos_precio" TO "authenticated";
GRANT ALL ON TABLE "public"."grupos_precio" TO "service_role";



GRANT ALL ON SEQUENCE "public"."grupos_precio_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."grupos_precio_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."grupos_precio_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."historial_cambios" TO "anon";
GRANT ALL ON TABLE "public"."historial_cambios" TO "authenticated";
GRANT ALL ON TABLE "public"."historial_cambios" TO "service_role";



GRANT ALL ON SEQUENCE "public"."historial_cambios_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."historial_cambios_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."historial_cambios_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."mermas_stock" TO "anon";
GRANT ALL ON TABLE "public"."mermas_stock" TO "authenticated";
GRANT ALL ON TABLE "public"."mermas_stock" TO "service_role";



GRANT ALL ON SEQUENCE "public"."mermas_stock_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."mermas_stock_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."mermas_stock_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."nota_credito_items" TO "anon";
GRANT ALL ON TABLE "public"."nota_credito_items" TO "authenticated";
GRANT ALL ON TABLE "public"."nota_credito_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."nota_credito_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."nota_credito_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."nota_credito_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."notas_credito" TO "anon";
GRANT ALL ON TABLE "public"."notas_credito" TO "authenticated";
GRANT ALL ON TABLE "public"."notas_credito" TO "service_role";



GRANT ALL ON SEQUENCE "public"."notas_credito_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."notas_credito_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."notas_credito_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pagos" TO "anon";
GRANT ALL ON TABLE "public"."pagos" TO "authenticated";
GRANT ALL ON TABLE "public"."pagos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pagos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pagos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pagos_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pedido_historial" TO "anon";
GRANT ALL ON TABLE "public"."pedido_historial" TO "authenticated";
GRANT ALL ON TABLE "public"."pedido_historial" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pedido_historial_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pedido_historial_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pedido_historial_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pedido_items" TO "anon";
GRANT ALL ON TABLE "public"."pedido_items" TO "authenticated";
GRANT ALL ON TABLE "public"."pedido_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pedido_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pedido_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pedido_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."pedidos" TO "anon";
GRANT ALL ON TABLE "public"."pedidos" TO "authenticated";
GRANT ALL ON TABLE "public"."pedidos" TO "service_role";



GRANT ALL ON TABLE "public"."pedidos_eliminados" TO "anon";
GRANT ALL ON TABLE "public"."pedidos_eliminados" TO "authenticated";
GRANT ALL ON TABLE "public"."pedidos_eliminados" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pedidos_eliminados_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pedidos_eliminados_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pedidos_eliminados_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."pedidos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."pedidos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."pedidos_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."preventista_zonas" TO "anon";
GRANT ALL ON TABLE "public"."preventista_zonas" TO "authenticated";
GRANT ALL ON TABLE "public"."preventista_zonas" TO "service_role";



GRANT ALL ON SEQUENCE "public"."preventista_zonas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."preventista_zonas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."preventista_zonas_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."productos" TO "anon";
GRANT ALL ON TABLE "public"."productos" TO "authenticated";
GRANT ALL ON TABLE "public"."productos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."productos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."productos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."productos_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."promo_ajustes" TO "anon";
GRANT ALL ON TABLE "public"."promo_ajustes" TO "authenticated";
GRANT ALL ON TABLE "public"."promo_ajustes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."promo_ajustes_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."promo_ajustes_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."promo_ajustes_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."promocion_productos" TO "anon";
GRANT ALL ON TABLE "public"."promocion_productos" TO "authenticated";
GRANT ALL ON TABLE "public"."promocion_productos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."promocion_productos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."promocion_productos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."promocion_productos_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."promocion_reglas" TO "anon";
GRANT ALL ON TABLE "public"."promocion_reglas" TO "authenticated";
GRANT ALL ON TABLE "public"."promocion_reglas" TO "service_role";



GRANT ALL ON SEQUENCE "public"."promocion_reglas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."promocion_reglas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."promocion_reglas_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."promociones" TO "anon";
GRANT ALL ON TABLE "public"."promociones" TO "authenticated";
GRANT ALL ON TABLE "public"."promociones" TO "service_role";



GRANT ALL ON SEQUENCE "public"."promociones_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."promociones_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."promociones_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."proveedores" TO "anon";
GRANT ALL ON TABLE "public"."proveedores" TO "authenticated";
GRANT ALL ON TABLE "public"."proveedores" TO "service_role";



GRANT ALL ON TABLE "public"."proveedores_eliminados" TO "anon";
GRANT ALL ON TABLE "public"."proveedores_eliminados" TO "authenticated";
GRANT ALL ON TABLE "public"."proveedores_eliminados" TO "service_role";



GRANT ALL ON SEQUENCE "public"."proveedores_eliminados_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."proveedores_eliminados_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."proveedores_eliminados_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."proveedores_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."proveedores_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."proveedores_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."recorrido_pedidos" TO "anon";
GRANT ALL ON TABLE "public"."recorrido_pedidos" TO "authenticated";
GRANT ALL ON TABLE "public"."recorrido_pedidos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."recorrido_pedidos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."recorrido_pedidos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."recorrido_pedidos_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."recorridos" TO "anon";
GRANT ALL ON TABLE "public"."recorridos" TO "authenticated";
GRANT ALL ON TABLE "public"."recorridos" TO "service_role";



GRANT ALL ON SEQUENCE "public"."recorridos_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."recorridos_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."recorridos_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."rendicion_ajustes" TO "anon";
GRANT ALL ON TABLE "public"."rendicion_ajustes" TO "authenticated";
GRANT ALL ON TABLE "public"."rendicion_ajustes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."rendicion_ajustes_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."rendicion_ajustes_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."rendicion_ajustes_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."rendicion_items" TO "anon";
GRANT ALL ON TABLE "public"."rendicion_items" TO "authenticated";
GRANT ALL ON TABLE "public"."rendicion_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."rendicion_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."rendicion_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."rendicion_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."rendiciones" TO "anon";
GRANT ALL ON TABLE "public"."rendiciones" TO "authenticated";
GRANT ALL ON TABLE "public"."rendiciones" TO "service_role";



GRANT ALL ON TABLE "public"."rendiciones_control" TO "anon";
GRANT ALL ON TABLE "public"."rendiciones_control" TO "authenticated";
GRANT ALL ON TABLE "public"."rendiciones_control" TO "service_role";



GRANT ALL ON SEQUENCE "public"."rendiciones_control_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."rendiciones_control_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."rendiciones_control_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."rendiciones_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."rendiciones_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."rendiciones_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."salvedad_historial" TO "anon";
GRANT ALL ON TABLE "public"."salvedad_historial" TO "authenticated";
GRANT ALL ON TABLE "public"."salvedad_historial" TO "service_role";



GRANT ALL ON SEQUENCE "public"."salvedad_historial_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."salvedad_historial_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."salvedad_historial_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."salvedades_items" TO "anon";
GRANT ALL ON TABLE "public"."salvedades_items" TO "authenticated";
GRANT ALL ON TABLE "public"."salvedades_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."salvedades_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."salvedades_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."salvedades_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."stock_historico" TO "anon";
GRANT ALL ON TABLE "public"."stock_historico" TO "authenticated";
GRANT ALL ON TABLE "public"."stock_historico" TO "service_role";



GRANT ALL ON SEQUENCE "public"."stock_historico_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."stock_historico_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."stock_historico_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sucursales" TO "anon";
GRANT ALL ON TABLE "public"."sucursales" TO "authenticated";
GRANT ALL ON TABLE "public"."sucursales" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sucursales_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sucursales_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sucursales_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."transferencia_items" TO "anon";
GRANT ALL ON TABLE "public"."transferencia_items" TO "authenticated";
GRANT ALL ON TABLE "public"."transferencia_items" TO "service_role";



GRANT ALL ON SEQUENCE "public"."transferencia_items_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."transferencia_items_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."transferencia_items_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."transferencias_stock" TO "anon";
GRANT ALL ON TABLE "public"."transferencias_stock" TO "authenticated";
GRANT ALL ON TABLE "public"."transferencias_stock" TO "service_role";



GRANT ALL ON SEQUENCE "public"."transferencias_stock_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."transferencias_stock_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."transferencias_stock_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."usuario_sucursales" TO "anon";
GRANT ALL ON TABLE "public"."usuario_sucursales" TO "authenticated";
GRANT ALL ON TABLE "public"."usuario_sucursales" TO "service_role";



GRANT ALL ON SEQUENCE "public"."usuario_sucursales_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."usuario_sucursales_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."usuario_sucursales_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."vista_recorridos_diarios" TO "anon";
GRANT ALL ON TABLE "public"."vista_recorridos_diarios" TO "authenticated";
GRANT ALL ON TABLE "public"."vista_recorridos_diarios" TO "service_role";



GRANT ALL ON TABLE "public"."vista_rendiciones" TO "anon";
GRANT ALL ON TABLE "public"."vista_rendiciones" TO "authenticated";
GRANT ALL ON TABLE "public"."vista_rendiciones" TO "service_role";



GRANT ALL ON TABLE "public"."zonas" TO "anon";
GRANT ALL ON TABLE "public"."zonas" TO "authenticated";
GRANT ALL ON TABLE "public"."zonas" TO "service_role";



GRANT ALL ON SEQUENCE "public"."zonas_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."zonas_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."zonas_id_seq" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";







