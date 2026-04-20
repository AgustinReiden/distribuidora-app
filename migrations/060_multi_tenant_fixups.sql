-- Migration 060: Fix structural issues in 057/058/059
--
-- Context: Migration 057 seeded sucursales with ON CONFLICT DO NOTHING but
-- row id=1 already existed as 'TACO POZO', so the tenant was never renamed
-- to 'ManaosApp'. Migration 059 references columns that don't exist on
-- stock_historico and leaves a dangerous overload of registrar_compra_completa.
-- Migration 058 drops policies by exact legacy name -- survivors OR-permissive
-- bypass the tenant filter.

-- =========================================================
-- 1. Rename existing sucursal id=1 to 'ManaosApp' and set tipo
-- =========================================================
UPDATE sucursales SET nombre = 'ManaosApp', tipo = 'principal' WHERE id = 1;
UPDATE sucursales SET nombre = 'TP Export', tipo = 'secundaria' WHERE id = 2;

-- Mark every other row as transfer-type (sub-branches used in ModalTransferencia)
UPDATE sucursales SET tipo = 'distribuidora' WHERE id NOT IN (1, 2) AND tipo IS NULL;

-- =========================================================
-- 2. Fix stock_historico: ensure usuario_id column exists
-- =========================================================
ALTER TABLE stock_historico ADD COLUMN IF NOT EXISTS usuario_id UUID REFERENCES auth.users(id);

-- =========================================================
-- 3. Drop the 13-param overloads of registrar_compra_completa.
--    The legacy overload exists in BOTH `text` and `character varying`
--    signatures depending on which historical migration created it
--    (045 used text, later one re-declared with character varying).
--    Drop both so only the sucursal-aware version we re-create below
--    remains.
-- =========================================================
DROP FUNCTION IF EXISTS public.registrar_compra_completa(
  bigint, character varying, character varying, date,
  numeric, numeric, numeric, numeric, character varying,
  text, uuid, jsonb, character varying
);
DROP FUNCTION IF EXISTS public.registrar_compra_completa(
  bigint, character varying, character varying, date,
  numeric, numeric, numeric, numeric, character varying,
  text, uuid, jsonb, text
);

-- =========================================================
-- 4. Re-create the 13-param overload with sucursal_id support
--    (delegates to the 12-param overload from migration 059 after adding sucursal_id)
-- =========================================================
CREATE OR REPLACE FUNCTION public.registrar_compra_completa(
  p_proveedor_id BIGINT,
  p_proveedor_nombre VARCHAR,
  p_numero_factura VARCHAR,
  p_fecha_compra DATE,
  p_subtotal NUMERIC,
  p_iva NUMERIC,
  p_otros_impuestos NUMERIC,
  p_total NUMERIC,
  p_forma_pago VARCHAR,
  p_notas TEXT,
  p_usuario_id UUID,
  p_items JSONB,
  p_tipo_factura VARCHAR DEFAULT 'FC'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_compra_id BIGINT;
  v_item JSONB;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  INSERT INTO compras (
    proveedor_id, proveedor_nombre, numero_factura, fecha_compra,
    subtotal, iva, otros_impuestos, total, forma_pago, notas,
    usuario_id, tipo_factura, sucursal_id
  ) VALUES (
    p_proveedor_id, p_proveedor_nombre, p_numero_factura, p_fecha_compra,
    p_subtotal, p_iva, p_otros_impuestos, p_total, p_forma_pago, p_notas,
    p_usuario_id, p_tipo_factura, v_sucursal
  )
  RETURNING id INTO v_compra_id;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      bonificacion, porcentaje_iva, impuestos_internos, sucursal_id
    ) VALUES (
      v_compra_id,
      (v_item->>'producto_id')::BIGINT,
      (v_item->>'cantidad')::NUMERIC,
      (v_item->>'costo_unitario')::NUMERIC,
      (v_item->>'subtotal')::NUMERIC,
      COALESCE((v_item->>'bonificacion')::NUMERIC, 0),
      COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21),
      COALESCE((v_item->>'impuestos_internos')::NUMERIC, 0),
      v_sucursal
    );

    UPDATE productos
       SET stock = stock + (v_item->>'cantidad')::NUMERIC
     WHERE id = (v_item->>'producto_id')::BIGINT AND sucursal_id = v_sucursal;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'compra_id', v_compra_id);
END;
$$;

-- =========================================================
-- 5. Add role check to registrar_nota_credito (H8)
-- =========================================================
CREATE OR REPLACE FUNCTION public.registrar_nota_credito(
  p_compra_id BIGINT,
  p_numero_nota VARCHAR DEFAULT NULL,
  p_motivo TEXT DEFAULT NULL,
  p_subtotal DECIMAL DEFAULT 0,
  p_iva DECIMAL DEFAULT 0,
  p_total DECIMAL DEFAULT 0,
  p_usuario_id UUID DEFAULT NULL,
  p_items JSONB DEFAULT '[]'
) RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_nota_id BIGINT; v_item JSONB; v_stock_actual INTEGER;
  v_producto_id BIGINT; v_cantidad INTEGER; v_costo DECIMAL; v_sub DECIMAL;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;

  -- NEW: role check (reuse es_encargado_o_admin helper from migration 041)
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

-- =========================================================
-- 6. audit_log_changes: FAIL instead of silent fallback to sucursal_id=1 (H7)
-- =========================================================
-- Replace the INSERT: drop `COALESCE(v_sucursal_id, 1)` -> require v_sucursal_id.
-- If the row being audited has no sucursal_id and current_sucursal_id() is NULL,
-- raise exception rather than leaking audit rows into tenant 1.
CREATE OR REPLACE FUNCTION public.audit_log_changes()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE
  v_old_data JSONB; v_new_data JSONB; v_campos_modificados TEXT[];
  v_usuario_id UUID; v_usuario_email TEXT; v_usuario_rol TEXT;
  v_registro_id TEXT; v_key TEXT;
  v_old_changed JSONB; v_new_changed JSONB;
  v_sucursal_id BIGINT;
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
    v_sucursal_id := COALESCE((to_jsonb(NEW)->>'sucursal_id')::BIGINT, (to_jsonb(OLD)->>'sucursal_id')::BIGINT, current_sucursal_id());

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

  -- FIX H7: no silent fallback to 1
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'audit_log_changes: cannot determine sucursal_id for table %', TG_TABLE_NAME;
  END IF;

  INSERT INTO public.audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados, usuario_id, usuario_email, usuario_rol, sucursal_id)
  VALUES (TG_TABLE_NAME, v_registro_id, TG_OP, v_old_data, v_new_data, v_campos_modificados, v_usuario_id, v_usuario_email, v_usuario_rol, v_sucursal_id);

  IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
END;
$$;

-- =========================================================
-- 7. Drop any non-mt_* policies by loop (H6) -- prevents surviving
--    OR-permissive legacy policies on multi-tenant tables.
-- =========================================================
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT schemaname, tablename, policyname
      FROM pg_policies
     WHERE schemaname = 'public'
       AND tablename IN (
         'clientes','productos','pedidos','pedido_items','pagos','compras','compra_items',
         'proveedores','mermas_stock','stock_historico','recorridos','recorrido_pedidos',
         'rendiciones','rendicion_items','rendicion_ajustes','salvedades_items','salvedad_historial',
         'notas_credito','nota_credito_items','transferencias_stock','transferencia_items',
         'promociones','promocion_productos','promocion_reglas','promo_ajustes',
         'grupos_precio','grupo_precio_productos','grupo_precio_escalas',
         'pedidos_eliminados','audit_logs','zonas','preventista_zonas','historial_cambios','pedido_historial'
       )
       -- DO NOT drop the mt_* policies from migration 058
       AND policyname NOT LIKE 'mt\_%' ESCAPE '\'
       -- DO NOT touch usuario_sucursales (RLS from 057)
       AND policyname NOT IN ('usuario_sucursales_select_own','usuario_sucursales_admin_all')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON %I.%I', r.policyname, r.schemaname, r.tablename);
  END LOOP;
END $$;
