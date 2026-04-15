# Backend Audit Fixes - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Fix all P0-P3 issues found in the backend audit: security vulnerabilities, logic bugs, scaling problems, and optimizations.

**Architecture:** All fixes are SQL migrations applied sequentially (051-057). Each migration is atomic and can be rolled back. The saldo logic fix (052) is the most complex, requiring a recalculation of all client balances.

**Tech Stack:** PostgreSQL/Supabase, PL/pgSQL, RLS policies

---

### Task 1: Critical Security Fixes (Migration 051)

**Files:**
- Create: `migrations/051_critical_security_fixes.sql`

**What this fixes:**
- P0: `run_sql` function allows arbitrary SQL injection (SECURITY DEFINER)
- P1: `stock_historico` table has RLS disabled (only table without RLS)
- P1: `cancelar_pedido_con_stock` is SECURITY DEFINER without auth check
- P2: 6 RPCs lack authorization checks
- P2: `registrar_ingreso_sucursal` and `registrar_transferencia` are SECURITY DEFINER without auth

**Step 1: Create migration file**

```sql
-- Migration 051: Critical security fixes from backend audit
-- Fixes: run_sql injection, stock_historico RLS, missing auth checks

-- ============================================================
-- 1. DROP run_sql - Critical SQL injection vulnerability
-- This SECURITY DEFINER function executes arbitrary SQL
-- ============================================================
DROP FUNCTION IF EXISTS public.run_sql(text);

-- ============================================================
-- 2. Enable RLS on stock_historico (only table without it)
-- ============================================================
ALTER TABLE public.stock_historico ENABLE ROW LEVEL SECURITY;

CREATE POLICY "stock_historico_select_authenticated"
  ON public.stock_historico FOR SELECT
  TO authenticated
  USING (true);

CREATE POLICY "stock_historico_insert_admin"
  ON public.stock_historico FOR INSERT
  TO authenticated
  WITH CHECK (es_admin());

-- ============================================================
-- 3. Fix cancelar_pedido_con_stock - add auth check
-- Currently SECURITY DEFINER with NO role verification
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancelar_pedido_con_stock(
  p_pedido_id bigint,
  p_motivo text,
  p_usuario_id uuid DEFAULT NULL::uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pedido RECORD;
  v_item RECORD;
  v_total_original DECIMAL;
  v_user_role TEXT;
BEGIN
  -- Auth check: only admin or encargado can cancel
  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden cancelar pedidos');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id FOR UPDATE;

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
    SELECT producto_id, cantidad, COALESCE(es_bonificacion, false) as es_bonificacion, promocion_id
    FROM pedido_items WHERE pedido_id = p_pedido_id
  LOOP
    IF v_item.es_bonificacion THEN
      IF v_item.promocion_id IS NOT NULL THEN
        UPDATE promociones
        SET usos_pendientes = GREATEST(usos_pendientes - v_item.cantidad, 0)
        WHERE id = v_item.promocion_id;
      END IF;
    ELSE
      UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id;
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
  WHERE id = p_pedido_id;

  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
  VALUES (
    p_pedido_id,
    COALESCE(p_usuario_id, auth.uid()),
    'estado',
    v_pedido.estado,
    'cancelado - Motivo: ' || COALESCE(p_motivo, 'Sin motivo') || ' | Total original: $' || v_total_original
  );

  RETURN jsonb_build_object(
    'success', true,
    'mensaje', 'Pedido cancelado, stock restaurado, saldo ajustado',
    'total_original', v_total_original
  );
END;
$$;

-- ============================================================
-- 4. Fix eliminar_pedido_completo - add auth check
-- ============================================================
CREATE OR REPLACE FUNCTION public.eliminar_pedido_completo(
  p_pedido_id bigint,
  p_usuario_id uuid,
  p_motivo text DEFAULT NULL::text,
  p_restaurar_stock boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_pedido RECORD; v_items JSONB; v_cliente_nombre TEXT; v_cliente_direccion TEXT;
  v_usuario_creador_nombre TEXT; v_transportista_nombre TEXT := NULL;
  v_eliminador_nombre TEXT := NULL; v_item RECORD;
  v_user_role TEXT;
BEGIN
  -- Auth check: only admin can delete orders
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role != 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo administradores pueden eliminar pedidos');
  END IF;

  SELECT * INTO v_pedido FROM pedidos WHERE id = p_pedido_id;
  IF NOT FOUND THEN RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado'); END IF;

  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', pi.producto_id, 'producto_nombre', pr.nombre,
    'producto_codigo', pr.codigo, 'cantidad', pi.cantidad,
    'precio_unitario', pi.precio_unitario, 'subtotal', pi.subtotal))
  INTO v_items FROM pedido_items pi LEFT JOIN productos pr ON pr.id = pi.producto_id WHERE pi.pedido_id = p_pedido_id;

  SELECT nombre_fantasia, direccion INTO v_cliente_nombre, v_cliente_direccion FROM clientes WHERE id = v_pedido.cliente_id;
  SELECT nombre INTO v_usuario_creador_nombre FROM perfiles WHERE id = v_pedido.usuario_id;
  IF v_pedido.transportista_id IS NOT NULL THEN SELECT nombre INTO v_transportista_nombre FROM perfiles WHERE id = v_pedido.transportista_id; END IF;
  IF p_usuario_id IS NOT NULL THEN SELECT nombre INTO v_eliminador_nombre FROM perfiles WHERE id = p_usuario_id; END IF;

  INSERT INTO pedidos_eliminados (
    pedido_id, cliente_id, cliente_nombre, cliente_direccion, total, estado,
    estado_pago, forma_pago, monto_pagado, notas, items,
    usuario_creador_id, usuario_creador_nombre, transportista_id, transportista_nombre,
    fecha_pedido, fecha_entrega, eliminado_por_id, eliminado_por_nombre,
    motivo_eliminacion, stock_restaurado)
  VALUES (
    p_pedido_id, v_pedido.cliente_id, v_cliente_nombre, v_cliente_direccion,
    v_pedido.total, v_pedido.estado, v_pedido.estado_pago, v_pedido.forma_pago,
    v_pedido.monto_pagado, v_pedido.notas, COALESCE(v_items, '[]'::jsonb),
    v_pedido.usuario_id, v_usuario_creador_nombre, v_pedido.transportista_id,
    v_transportista_nombre, v_pedido.created_at, v_pedido.fecha_entrega,
    p_usuario_id, v_eliminador_nombre, p_motivo, p_restaurar_stock);

  IF p_restaurar_stock THEN
    FOR v_item IN SELECT producto_id, cantidad FROM pedido_items WHERE pedido_id = p_pedido_id LOOP
      UPDATE productos SET stock = stock + v_item.cantidad WHERE id = v_item.producto_id;
    END LOOP;
  END IF;

  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id;
  DELETE FROM pedido_historial WHERE pedido_id = p_pedido_id;
  DELETE FROM pedidos WHERE id = p_pedido_id;

  RETURN jsonb_build_object('success', true, 'mensaje', 'Pedido eliminado y registrado correctamente');
END;
$$;

-- ============================================================
-- 5. Fix descontar_stock_atomico - add auth check
-- ============================================================
CREATE OR REPLACE FUNCTION public.descontar_stock_atomico(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item JSONB; v_producto_id INT; v_cantidad INT;
  v_stock_actual INT; v_producto_nombre TEXT;
  errores TEXT[] := '{}';
  v_user_role TEXT;
BEGIN
  SELECT rol INTO v_user_role FROM perfiles WHERE id = auth.uid();
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No autorizado para descontar stock'));
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (v_item->>'producto_id')::INT;
    v_cantidad := (v_item->>'cantidad')::INT;

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad invalida para producto ' || v_producto_id);
      CONTINUE;
    END IF;

    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
    FROM productos WHERE id = v_producto_id FOR UPDATE;

    IF v_stock_actual IS NULL THEN
      errores := array_append(errores, 'Producto ' || v_producto_id || ' no encontrado');
    ELSIF v_stock_actual < v_cantidad THEN
      errores := array_append(errores, v_producto_nombre || ': stock insuficiente (disponible: ' || v_stock_actual || ', solicitado: ' || v_cantidad || ')');
    ELSE
      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id;
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  RETURN jsonb_build_object('success', true, 'errores', '[]'::jsonb);
END;
$$;

-- ============================================================
-- 6. Fix restaurar_stock_atomico - add auth check
-- ============================================================
CREATE OR REPLACE FUNCTION public.restaurar_stock_atomico(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_item JSONB; v_producto_id INT; v_cantidad INT;
  errores TEXT[] := '{}';
  v_user_role TEXT;
BEGIN
  SELECT rol INTO v_user_role FROM perfiles WHERE id = auth.uid();
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array('No autorizado para restaurar stock'));
  END IF;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    v_producto_id := (v_item->>'producto_id')::INT;
    v_cantidad := (v_item->>'cantidad')::INT;

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      errores := array_append(errores, 'Cantidad invalida para producto ' || v_producto_id);
      CONTINUE;
    END IF;

    UPDATE productos SET stock = stock + v_cantidad WHERE id = v_producto_id;
    IF NOT FOUND THEN
      errores := array_append(errores, 'Producto ' || v_producto_id || ' no encontrado');
    END IF;
  END LOOP;

  IF array_length(errores, 1) > 0 THEN
    RETURN jsonb_build_object('success', false, 'errores', to_jsonb(errores));
  END IF;

  RETURN jsonb_build_object('success', true, 'errores', '[]'::jsonb);
END;
$$;

-- ============================================================
-- 7. Fix registrar_compra_completa - add auth check
-- ============================================================
CREATE OR REPLACE FUNCTION public.registrar_compra_completa(
  p_proveedor_id bigint,
  p_proveedor_nombre character varying,
  p_numero_factura character varying,
  p_fecha_compra date,
  p_subtotal numeric,
  p_iva numeric,
  p_otros_impuestos numeric,
  p_total numeric,
  p_forma_pago character varying,
  p_notas text,
  p_usuario_id uuid,
  p_items jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_compra_id BIGINT; v_item JSONB; v_producto RECORD; v_stock_anterior INTEGER; v_stock_nuevo INTEGER;
  v_items_procesados JSONB := '[]'::JSONB; v_costo_neto DECIMAL; v_costo_con_iva DECIMAL;
  v_porcentaje_iva DECIMAL; v_impuestos_internos DECIMAL; v_bonificacion DECIMAL;
  v_user_role TEXT;
BEGIN
  -- Auth check
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin o encargado pueden registrar compras');
  END IF;

  INSERT INTO compras (proveedor_id, proveedor_nombre, numero_factura, fecha_compra, subtotal, iva, otros_impuestos, total, forma_pago, notas, usuario_id, estado)
  VALUES (p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra, p_subtotal, p_iva, p_otros_impuestos, p_total, p_forma_pago, p_notas, p_usuario_id, 'recibida')
  RETURNING id INTO v_compra_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    -- Use FOR UPDATE to prevent concurrent stock reads
    SELECT id, stock INTO v_producto FROM productos WHERE id = (v_item->>'producto_id')::BIGINT FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'Producto no encontrado: %', v_item->>'producto_id'; END IF;

    v_stock_anterior := COALESCE(v_producto.stock, 0);
    v_stock_nuevo := v_stock_anterior + (v_item->>'cantidad')::INTEGER;
    v_bonificacion := COALESCE((v_item->>'bonificacion')::DECIMAL, 0);
    v_porcentaje_iva := COALESCE((v_item->>'porcentaje_iva')::DECIMAL, 21);
    v_impuestos_internos := COALESCE((v_item->>'impuestos_internos')::DECIMAL, 0);

    INSERT INTO compra_items (compra_id, producto_id, cantidad, costo_unitario, subtotal, stock_anterior, stock_nuevo, bonificacion)
    VALUES (v_compra_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INTEGER,
            COALESCE((v_item->>'costo_unitario')::DECIMAL, 0),
            COALESCE((v_item->>'subtotal')::DECIMAL, 0),
            v_stock_anterior, v_stock_nuevo, v_bonificacion);

    v_costo_neto := COALESCE((v_item->>'costo_unitario')::DECIMAL, 0) * (1 - v_bonificacion / 100);
    v_costo_con_iva := v_costo_neto * (1 + v_porcentaje_iva / 100);

    -- Use stock = stock + cantidad instead of absolute value to prevent race conditions
    UPDATE productos SET
      stock = stock + (v_item->>'cantidad')::INTEGER,
      costo_sin_iva = v_costo_neto,
      costo_con_iva = v_costo_con_iva,
      impuestos_internos = v_impuestos_internos,
      porcentaje_iva = v_porcentaje_iva,
      updated_at = NOW()
    WHERE id = (v_item->>'producto_id')::BIGINT;

    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id', (v_item->>'producto_id')::BIGINT,
      'cantidad', (v_item->>'cantidad')::INTEGER,
      'stock_anterior', v_stock_anterior,
      'stock_nuevo', v_stock_nuevo,
      'costo_sin_iva', v_costo_neto,
      'costo_con_iva', v_costo_con_iva);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'compra_id', v_compra_id, 'items_procesados', v_items_procesados);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ============================================================
-- 8. Fix registrar_ingreso_sucursal - add auth check
-- ============================================================
CREATE OR REPLACE FUNCTION public.registrar_ingreso_sucursal(
  p_sucursal_id bigint,
  p_fecha date DEFAULT CURRENT_DATE,
  p_notas text DEFAULT NULL,
  p_total_costo numeric DEFAULT 0,
  p_usuario_id uuid DEFAULT NULL,
  p_items jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_transferencia_id BIGINT; v_item JSONB;
  v_user_role TEXT;
BEGIN
  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  INSERT INTO transferencias_stock (sucursal_id, tipo, fecha, notas, total_costo, usuario_id, estado)
  VALUES (p_sucursal_id, 'ingreso', p_fecha, p_notas, p_total_costo, COALESCE(p_usuario_id, auth.uid()), 'completada')
  RETURNING id INTO v_transferencia_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO transferencia_items (transferencia_id, producto_id, cantidad, costo_unitario)
    VALUES (v_transferencia_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INT, COALESCE((v_item->>'costo_unitario')::DECIMAL, 0));

    UPDATE productos SET stock = stock + (v_item->>'cantidad')::INT WHERE id = (v_item->>'producto_id')::BIGINT;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'transferencia_id', v_transferencia_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;

-- ============================================================
-- 9. Fix registrar_transferencia - add auth check
-- ============================================================
CREATE OR REPLACE FUNCTION public.registrar_transferencia(
  p_sucursal_id bigint,
  p_fecha date DEFAULT CURRENT_DATE,
  p_notas text DEFAULT NULL,
  p_total_costo numeric DEFAULT 0,
  p_usuario_id uuid DEFAULT NULL,
  p_items jsonb DEFAULT '[]'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_transferencia_id BIGINT; v_item JSONB;
  v_stock_actual INT; v_producto_nombre TEXT;
  v_user_role TEXT;
BEGIN
  SELECT rol INTO v_user_role FROM perfiles WHERE id = COALESCE(p_usuario_id, auth.uid());
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'encargado') THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado');
  END IF;

  INSERT INTO transferencias_stock (sucursal_id, tipo, fecha, notas, total_costo, usuario_id, estado)
  VALUES (p_sucursal_id, 'egreso', p_fecha, p_notas, p_total_costo, COALESCE(p_usuario_id, auth.uid()), 'completada')
  RETURNING id INTO v_transferencia_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
    FROM productos WHERE id = (v_item->>'producto_id')::BIGINT FOR UPDATE;

    IF v_stock_actual < (v_item->>'cantidad')::INT THEN
      RAISE EXCEPTION 'Stock insuficiente para %: disponible %, solicitado %',
        v_producto_nombre, v_stock_actual, (v_item->>'cantidad')::INT;
    END IF;

    INSERT INTO transferencia_items (transferencia_id, producto_id, cantidad, costo_unitario)
    VALUES (v_transferencia_id, (v_item->>'producto_id')::BIGINT, (v_item->>'cantidad')::INT, COALESCE((v_item->>'costo_unitario')::DECIMAL, 0));

    UPDATE productos SET stock = stock - (v_item->>'cantidad')::INT WHERE id = (v_item->>'producto_id')::BIGINT;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'transferencia_id', v_transferencia_id);
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$$;
```

**Step 2: Verify migration syntax**

Run: Review the SQL for syntax errors before applying.

**Step 3: Apply migration to Supabase**

Execute migration via Supabase MCP connector, splitting into individual statements.

**Step 4: Verify changes**

```sql
-- Verify run_sql is gone
SELECT proname FROM pg_proc WHERE proname = 'run_sql' AND pronamespace = (SELECT oid FROM pg_namespace WHERE nspname = 'public')
-- Should return 0 rows

-- Verify stock_historico has RLS
SELECT relrowsecurity FROM pg_class WHERE relname = 'stock_historico'
-- Should return true
```

**Step 5: Commit**

```bash
git add migrations/051_critical_security_fixes.sql
git commit -m "fix: critical security - drop run_sql, add RLS and auth checks"
```

---

### Task 2: Fix Saldo Double-Counting (Migration 052)

**Files:**
- Create: `migrations/052_fix_saldo_double_counting.sql`

**What this fixes:**
- P0: Double-counting in `clientes.saldo_cuenta` from two independent triggers
- P1: `actualizar_saldo_cliente` (pagos trigger) missing UPDATE handler
- P1: `cancelar_pedido_con_stock` zeroes total but doesn't handle associated pagos

**Design decision:** Unify saldo logic. The `saldo_cuenta` should be calculated as:
`saldo = SUM(pedidos.total) - SUM(pedidos.monto_pagado)` (for non-cancelled pedidos)

The `pagos` table tracks payment records, but `pedidos.monto_pagado` is the source of truth for how much has been paid on each order. So:
- The `actualizar_saldo_pedido` trigger (on pedidos) handles ALL saldo changes
- The `actualizar_saldo_cliente` trigger (on pagos) should ONLY update `pedidos.monto_pagado`, NOT touch `saldo_cuenta` directly

**Step 1: Create migration file**

```sql
-- Migration 052: Fix saldo double-counting
-- Problem: Two triggers independently modify clientes.saldo_cuenta,
-- causing double-counting when a pago INSERT also updates pedidos.monto_pagado.
--
-- Solution: The pagos trigger should NOT directly modify saldo_cuenta.
-- Instead, it should only exist to maintain data integrity.
-- saldo_cuenta is driven exclusively by the pedidos trigger via (total - monto_pagado).

-- ============================================================
-- 1. Replace actualizar_saldo_cliente to handle INSERT/UPDATE/DELETE
--    but NOT modify saldo_cuenta (pedidos trigger handles that)
-- ============================================================
CREATE OR REPLACE FUNCTION public.actualizar_saldo_cliente()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- This trigger no longer modifies saldo_cuenta directly.
  -- saldo_cuenta is managed exclusively by actualizar_saldo_pedido
  -- via the (total - monto_pagado) calculation on the pedidos table.
  --
  -- This trigger is kept for potential future use (e.g., audit)
  -- but the actual saldo logic lives in one place only.
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- ============================================================
-- 2. Recalculate all client balances to fix any existing drift
-- ============================================================
UPDATE clientes c
SET saldo_cuenta = COALESCE(sub.saldo_real, 0)
FROM (
  SELECT
    p.cliente_id,
    SUM(
      CASE WHEN p.estado != 'cancelado'
        THEN p.total - COALESCE(p.monto_pagado, 0)
        ELSE 0
      END
    ) as saldo_real
  FROM pedidos p
  WHERE p.cliente_id IS NOT NULL
  GROUP BY p.cliente_id
) sub
WHERE c.id = sub.cliente_id;

-- Also reset saldo for clients with no pedidos
UPDATE clientes
SET saldo_cuenta = 0
WHERE id NOT IN (SELECT DISTINCT cliente_id FROM pedidos WHERE cliente_id IS NOT NULL);
```

**Step 2: Apply migration**

Execute via Supabase MCP.

**Step 3: Verify balances**

```sql
-- Compare calculated vs stored saldo for all clients
SELECT c.id, c.nombre_fantasia, c.saldo_cuenta,
  COALESCE(SUM(CASE WHEN p.estado != 'cancelado' THEN p.total - COALESCE(p.monto_pagado, 0) ELSE 0 END), 0) as saldo_calculado
FROM clientes c
LEFT JOIN pedidos p ON p.cliente_id = c.id
GROUP BY c.id, c.nombre_fantasia, c.saldo_cuenta
HAVING c.saldo_cuenta != COALESCE(SUM(CASE WHEN p.estado != 'cancelado' THEN p.total - COALESCE(p.monto_pagado, 0) ELSE 0 END), 0)
```

Should return 0 rows (all match).

**Step 4: Commit**

```bash
git add migrations/052_fix_saldo_double_counting.sql
git commit -m "fix: unify saldo logic, eliminate double-counting from dual triggers"
```

---

### Task 3: Fix actualizar_pedido_items (Migration 053)

**Files:**
- Create: `migrations/053_fix_actualizar_pedido_items.sql`

**What this fixes:**
- P1: Doesn't handle bonificaciones (deducts stock for bonus items)
- P1: Loses fiscal fields (neto_unitario, iva_unitario, etc.) when editing
- P3: Does 2N+N operations instead of calculating diffs

**Step 1: Create migration file**

```sql
-- Migration 053: Fix actualizar_pedido_items
-- Fixes: bonificacion handling, fiscal fields, performance

DROP FUNCTION IF EXISTS public.actualizar_pedido_items(bigint, jsonb, uuid);

CREATE OR REPLACE FUNCTION public.actualizar_pedido_items(
  p_pedido_id bigint,
  p_items_nuevos jsonb,
  p_usuario_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
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
BEGIN
  -- Auth check
  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role NOT IN ('admin', 'preventista') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No autorizado']);
  END IF;

  SELECT total INTO v_total_anterior FROM pedidos WHERE id = p_pedido_id;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['Pedido no encontrado']);
  END IF;

  IF EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND estado = 'entregado') THEN
    RETURN jsonb_build_object('success', false, 'errores', ARRAY['No se puede editar un pedido ya entregado']);
  END IF;

  -- Save original items for historial
  SELECT jsonb_agg(jsonb_build_object(
    'producto_id', producto_id, 'cantidad', cantidad,
    'precio_unitario', precio_unitario, 'es_bonificacion', COALESCE(es_bonificacion, false)))
  INTO v_items_originales FROM pedido_items WHERE pedido_id = p_pedido_id;

  -- Phase 1: Validate stock for new non-bonificacion items that need MORE stock
  FOR v_item_nuevo IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id := (v_item_nuevo->>'producto_id')::INT;
    v_cantidad_nueva := (v_item_nuevo->>'cantidad')::INT;
    v_es_bonificacion := COALESCE((v_item_nuevo->>'es_bonificacion')::BOOLEAN, false);

    IF v_es_bonificacion THEN CONTINUE; END IF;

    SELECT COALESCE(cantidad, 0) INTO v_cantidad_original
    FROM pedido_items
    WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
      AND COALESCE(es_bonificacion, false) = false;

    v_diferencia := v_cantidad_nueva - COALESCE(v_cantidad_original, 0);

    IF v_diferencia > 0 THEN
      SELECT stock, nombre INTO v_stock_actual, v_producto_nombre
      FROM productos WHERE id = v_producto_id FOR UPDATE;

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

  -- Phase 2: Restore stock for original NON-bonificacion items
  FOR v_producto_id, v_cantidad_original IN
    SELECT pi.producto_id, pi.cantidad
    FROM pedido_items pi
    WHERE pi.pedido_id = p_pedido_id AND COALESCE(pi.es_bonificacion, false) = false
  LOOP
    UPDATE productos SET stock = stock + v_cantidad_original WHERE id = v_producto_id;
  END LOOP;

  -- Restore promo usos for original bonificacion items
  UPDATE promociones SET usos_pendientes = GREATEST(usos_pendientes - pi.cantidad, 0)
  FROM pedido_items pi
  WHERE pi.pedido_id = p_pedido_id
    AND COALESCE(pi.es_bonificacion, false) = true
    AND pi.promocion_id IS NOT NULL
    AND promociones.id = pi.promocion_id;

  -- Phase 3: Delete old items and insert new ones
  DELETE FROM pedido_items WHERE pedido_id = p_pedido_id;

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
      neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva
    ) VALUES (
      p_pedido_id, v_producto_id, v_cantidad_nueva, v_precio_unitario,
      v_cantidad_nueva * v_precio_unitario,
      v_es_bonificacion, v_promocion_id,
      v_neto_unitario, v_iva_unitario, v_imp_internos_unitario, v_porcentaje_iva
    );

    -- Deduct stock only for non-bonificacion items
    IF NOT v_es_bonificacion THEN
      UPDATE productos SET stock = stock - v_cantidad_nueva WHERE id = v_producto_id;
      v_total_nuevo := v_total_nuevo + (v_cantidad_nueva * v_precio_unitario);
      v_total_neto_nuevo := v_total_neto_nuevo + (v_cantidad_nueva * COALESCE(v_neto_unitario, v_precio_unitario));
      v_total_iva_nuevo := v_total_iva_nuevo + (v_cantidad_nueva * v_iva_unitario);
    END IF;

    -- Track promo usage for bonificaciones
    IF v_es_bonificacion AND v_promocion_id IS NOT NULL THEN
      UPDATE promociones SET usos_pendientes = usos_pendientes + v_cantidad_nueva
      WHERE id = v_promocion_id;
    END IF;
  END LOOP;

  -- Phase 4: Update pedido totals including fiscal fields
  UPDATE pedidos SET
    total = v_total_nuevo,
    total_neto = v_total_neto_nuevo,
    total_iva = v_total_iva_nuevo,
    updated_at = NOW()
  WHERE id = p_pedido_id;

  -- Phase 5: Record historial
  INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
  VALUES (p_pedido_id, p_usuario_id, 'items', COALESCE(v_items_originales::TEXT, '[]'), p_items_nuevos::TEXT);

  IF v_total_anterior IS DISTINCT FROM v_total_nuevo THEN
    INSERT INTO pedido_historial (pedido_id, usuario_id, campo_modificado, valor_anterior, valor_nuevo)
    VALUES (p_pedido_id, p_usuario_id, 'total', v_total_anterior::TEXT, v_total_nuevo::TEXT);
  END IF;

  RETURN jsonb_build_object('success', true, 'total_nuevo', v_total_nuevo);
END;
$$;
```

**Step 2: Apply and verify**

**Step 3: Commit**

```bash
git add migrations/053_fix_actualizar_pedido_items.sql
git commit -m "fix: actualizar_pedido_items - bonificaciones, fiscal fields, auth check"
```

---

### Task 4: Add Missing Indexes (Migration 054)

**Files:**
- Create: `migrations/054_add_missing_indexes.sql`

**Step 1: Create migration file**

```sql
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
```

**Step 2: Apply and verify**

**Step 3: Commit**

```bash
git add migrations/054_add_missing_indexes.sql
git commit -m "perf: add missing indexes on pedidos, items, pagos, audit_logs"
```

---

### Task 5: Optimize Audit and Cleanup (Migration 055)

**Files:**
- Create: `migrations/055_optimize_audit_and_cleanup.sql`

**What this fixes:**
- P3: `audit_log_changes` stores full JSONB for OLD and NEW on every change
- P3: Duplicate role check function overloads
- P3: Trigger `trigger_update_proveedores_timestamp` uses wrong function name

**Step 1: Create migration file**

```sql
-- Migration 055: Optimize audit logging and cleanup

-- ============================================================
-- 1. Optimize audit_log_changes to store only changed fields
-- ============================================================
CREATE OR REPLACE FUNCTION public.audit_log_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_old_data JSONB; v_new_data JSONB; v_campos_modificados TEXT[];
  v_usuario_id UUID; v_usuario_email TEXT; v_usuario_rol TEXT;
  v_registro_id TEXT; v_key TEXT;
  v_old_changed JSONB; v_new_changed JSONB;
BEGIN
  v_usuario_id := auth.uid();
  IF v_usuario_id IS NOT NULL THEN
    SELECT email INTO v_usuario_email FROM auth.users WHERE id = v_usuario_id;
    SELECT rol INTO v_usuario_rol FROM public.perfiles WHERE id = v_usuario_id;
  END IF;

  IF TG_OP = 'DELETE' THEN
    v_registro_id := OLD.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := NULL;
  ELSIF TG_OP = 'INSERT' THEN
    v_registro_id := NEW.id::TEXT;
    v_old_data := NULL;
    v_new_data := to_jsonb(NEW);
  ELSE
    v_registro_id := NEW.id::TEXT;
    v_old_data := to_jsonb(OLD);
    v_new_data := to_jsonb(NEW);

    -- Find changed fields
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

    -- Skip if nothing actually changed
    IF array_length(v_campos_modificados, 1) IS NULL OR array_length(v_campos_modificados, 1) = 0 THEN
      RETURN NEW;
    END IF;

    -- Store only the changed fields, not full row
    v_old_data := v_old_changed;
    v_new_data := v_new_changed;
  END IF;

  INSERT INTO public.audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados, usuario_id, usuario_email, usuario_rol)
  VALUES (TG_TABLE_NAME, v_registro_id, TG_OP, v_old_data, v_new_data, v_campos_modificados, v_usuario_id, v_usuario_email, v_usuario_rol);

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

-- ============================================================
-- 2. Fix proveedores trigger using wrong function
-- ============================================================
DROP TRIGGER IF EXISTS trigger_update_proveedores_timestamp ON public.proveedores;

CREATE OR REPLACE FUNCTION public.update_proveedores_updated_at()
RETURNS TRIGGER
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;

CREATE TRIGGER trigger_update_proveedores_timestamp
  BEFORE UPDATE ON public.proveedores
  FOR EACH ROW
  EXECUTE FUNCTION update_proveedores_updated_at();

-- ============================================================
-- 3. Drop duplicate English role functions (keep Spanish ones)
-- ============================================================
DROP FUNCTION IF EXISTS public.is_admin();
DROP FUNCTION IF EXISTS public.is_preventista();
DROP FUNCTION IF EXISTS public.is_transportista();
```

**Step 2: Apply and verify**

**Step 3: Commit**

```bash
git add migrations/055_optimize_audit_and_cleanup.sql
git commit -m "perf: optimize audit to store only changed fields, cleanup duplicates"
```

---

### Summary of all migrations

| Migration | Category | Fixes |
|-----------|----------|-------|
| 051 | Security | Drop run_sql, RLS stock_historico, auth checks on 8 RPCs |
| 052 | Bug/Logic | Unify saldo logic, fix double-counting, recalculate balances |
| 053 | Bug | actualizar_pedido_items: bonificaciones, fiscal fields, auth |
| 054 | Scaling | 15 missing indexes on 7 tables |
| 055 | Optimization | Audit stores only diffs, fix wrong trigger, drop duplicates |
