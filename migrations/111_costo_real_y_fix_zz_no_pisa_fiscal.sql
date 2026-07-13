-- ============================================================================
-- 111 · Costo real canónico + las compras ZZ dejan de pisar el IVA del producto
-- ============================================================================
-- Problema (auditoría fiscal 2026-07-13):
--   1) registrar_compra_completa / actualizar_compra_items pisaban
--      productos.porcentaje_iva = 0 en compras ZZ (hack para neutralizar
--      calcularNetoCosto, hoy código muerto en el front) → 42 productos con
--      IVA 0% en prod; una venta FC de esos productos calcularía desglose 0.
--   2) productos.impuestos_internos era numeric(12,2): no puede almacenar la
--      tasa efectiva 8,6956 (colas) → se amplía a numeric(12,4).
--   3) "Costo real" (neto post-bonif + imp. internos; IVA y percepciones son
--      créditos fiscales, NO costo) se derivaba con fórmulas distintas en
--      reporte/rentabilidad/export. Se materializa en productos.costo_real
--      con funciones canónicas únicas.
--
-- Reglas nuevas:
--   · Los atributos fiscales del producto (porcentaje_iva, impuestos_internos)
--     NUNCA se auto-actualizan desde una compra (ni FC ni ZZ): se corrigen
--     explícitamente editando el producto. La compra los usa solo para
--     calcular costos.
--   · costo_real:      FC → neto×(1+II/100) ; ZZ → neto (lo pagado, sin add-on)
--   · costo_con_iva:   FC → neto×(1+IVA/100+II/100) ; ZZ → neto  (financiero)
--   · ultimo_tipo_compra deja rastro de qué tipo fijó el costo.
--   · Guard: líneas con bonificación ≥100% o costo 0 (regalos/promos) suman
--     stock pero NO tocan el costo del producto.
--   · Se dropea el overload legacy de 12 args de registrar_compra_completa
--     (body viejo con el zeroing; el front llama al de 13 args y un caller de
--     12 args resuelve al de 13 por el DEFAULT).
-- ============================================================================

-- ─── 1. Columnas ────────────────────────────────────────────────────────────

ALTER TABLE public.productos
  ALTER COLUMN impuestos_internos TYPE numeric(12,4);

ALTER TABLE public.productos
  ADD COLUMN IF NOT EXISTS costo_real numeric(12,4),
  ADD COLUMN IF NOT EXISTS ultimo_tipo_compra varchar(2);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'productos_ultimo_tipo_compra_check'
  ) THEN
    ALTER TABLE public.productos
      ADD CONSTRAINT productos_ultimo_tipo_compra_check
      CHECK (ultimo_tipo_compra IN ('ZZ','FC'));
  END IF;
END $$;

COMMENT ON COLUMN public.productos.costo_real IS
  'Costo REAL unitario canónico: FC = costo_sin_iva*(1+impuestos_internos/100); ZZ = costo_sin_iva (precio pagado, sin add-on). IVA y percepciones NO son costo (créditos fiscales). Mantenido por registrar_compra_completa / actualizar_compra_items / edición manual del producto.';
COMMENT ON COLUMN public.productos.ultimo_tipo_compra IS
  'Tipo de la última compra que fijó el costo (FC/ZZ). NULL = costo cargado a mano o sin compra registrada (se asume semántica FC).';
COMMENT ON COLUMN public.productos.costo_con_iva IS
  'Costo FINANCIERO pagado por unidad: FC = neto*(1+iva/100+ii/100); ZZ = neto. NO usar para margen real; usar costo_real.';
COMMENT ON COLUMN public.productos.impuestos_internos IS
  'Tasa EFECTIVA de impuestos internos en % sobre el neto (ej: 8.6956 colas, 4.1667 aguas/saborizadas). Atributo fiscal del producto: no lo pisa ninguna compra.';

-- ─── 2. Funciones canónicas ─────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION public.costo_real_unitario(
  p_costo_neto numeric,
  p_pct_ii numeric,
  p_tipo_factura text
) RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_tipo_factura = 'ZZ' THEN p_costo_neto
    ELSE round(p_costo_neto * (1 + COALESCE(p_pct_ii, 0) / 100), 4)
  END;
$$;

COMMENT ON FUNCTION public.costo_real_unitario(numeric, numeric, text) IS
  'Costo real por unidad: FC = neto post-bonif + imp. internos (IVA es crédito, no costo); ZZ = lo pagado (nada recuperable, el precio informal ya incluye todo).';

CREATE OR REPLACE FUNCTION public.costo_financiero_unitario(
  p_costo_neto numeric,
  p_pct_iva numeric,
  p_pct_ii numeric,
  p_tipo_factura text
) RETURNS numeric
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN p_tipo_factura = 'ZZ' THEN p_costo_neto
    ELSE round(p_costo_neto * (1 + COALESCE(p_pct_iva, 0) / 100 + COALESCE(p_pct_ii, 0) / 100), 4)
  END;
$$;

COMMENT ON FUNCTION public.costo_financiero_unitario(numeric, numeric, numeric, text) IS
  'Costo financiero (desembolso) por unidad, sin percepciones: FC = neto*(1+iva+ii); ZZ = neto. Alimenta productos.costo_con_iva.';

-- ─── 3. Drop del overload legacy (12 args, body viejo con zeroing) ─────────

DROP FUNCTION IF EXISTS public.registrar_compra_completa(
  bigint, character varying, character varying, date,
  numeric, numeric, numeric, numeric,
  character varying, text, uuid, jsonb
);

-- ─── 4. registrar_compra_completa (13 args, misma firma ⇒ OR REPLACE) ──────

CREATE OR REPLACE FUNCTION public.registrar_compra_completa(
  p_proveedor_id bigint, p_proveedor_nombre character varying,
  p_numero_factura character varying, p_fecha_compra date,
  p_subtotal numeric, p_iva numeric, p_otros_impuestos numeric, p_total numeric,
  p_forma_pago character varying, p_notas text, p_usuario_id uuid,
  p_items jsonb, p_tipo_factura character varying DEFAULT 'FC'
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public'
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
  v_costo_real          NUMERIC;
  v_actualiza_costo     BOOLEAN;
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

    v_costo_neto    := v_costo_unitario * (1 - v_bonificacion / 100);
    v_costo_con_iva := costo_financiero_unitario(v_costo_neto, v_porcentaje_iva, v_impuestos_internos, v_tipo_factura);
    v_costo_real    := costo_real_unitario(v_costo_neto, v_impuestos_internos, v_tipo_factura);

    -- Regalos / promos (bonif 100% o costo 0) suman stock pero no fijan costo.
    v_actualiza_costo := (v_bonificacion < 100 AND v_costo_neto > 0);

    IF v_actualiza_costo THEN
      UPDATE productos
         SET stock              = stock + v_cantidad,
             costo_sin_iva      = v_costo_neto,
             costo_con_iva      = v_costo_con_iva,
             costo_real         = v_costo_real,
             ultimo_tipo_compra = v_tipo_factura,
             updated_at         = NOW()
       WHERE id = (v_item->>'producto_id')::BIGINT
         AND sucursal_id = v_sucursal;
    ELSE
      UPDATE productos
         SET stock      = stock + v_cantidad,
             updated_at = NOW()
       WHERE id = (v_item->>'producto_id')::BIGINT
         AND sucursal_id = v_sucursal;
    END IF;

    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id',       (v_item->>'producto_id')::BIGINT,
      'cantidad',          v_cantidad,
      'stock_anterior',    v_stock_anterior,
      'stock_nuevo',       v_stock_nuevo,
      'costo_sin_iva',     v_costo_neto,
      'costo_con_iva',     v_costo_con_iva,
      'costo_real',        v_costo_real,
      'costo_actualizado', v_actualiza_costo
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

-- ─── 5. actualizar_compra_items (misma firma de 104 ⇒ OR REPLACE) ──────────

CREATE OR REPLACE FUNCTION public.actualizar_compra_items(p_compra_id bigint, p_items_nuevos jsonb, p_subtotal numeric, p_iva numeric, p_total numeric, p_usuario_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_user_role TEXT;
  v_compra RECORD;
  v_dias NUMERIC;
  v_item JSONB;
  v_producto_id BIGINT;
  v_cantidad INTEGER;
  v_costo_unitario NUMERIC;
  v_bonificacion NUMERIC;
  v_porcentaje_iva NUMERIC;
  v_impuestos_internos NUMERIC;
  v_subtotal_item NUMERIC;
  v_costo_neto NUMERIC;
  v_costo_con_iva NUMERIC;
  v_costo_real NUMERIC;
  v_actualiza_costo BOOLEAN;
  v_stock_anterior INTEGER;
  v_stock_nuevo INTEGER;
  v_max_fecha DATE;
  v_es_mas_reciente BOOLEAN;
  v_iva_efectivo NUMERIC;
  v_items_procesados JSONB := '[]'::JSONB;
  v_costo_actualizado JSONB := '[]'::JSONB;
  v_snapshot_stock JSONB := '{}'::JSONB;
  v_warnings_stock_negativo JSONB;
  v_warnings JSONB;
BEGIN
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa');
  END IF;
  IF p_usuario_id IS DISTINCT FROM auth.uid() THEN
    RETURN jsonb_build_object('success', false, 'error', 'ID de usuario no coincide con la sesion autenticada');
  END IF;

  SELECT rol INTO v_user_role FROM perfiles WHERE id = p_usuario_id;
  IF v_user_role IS NULL OR v_user_role <> 'admin' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No autorizado: solo admin puede editar compras');
  END IF;

  SELECT id, estado, tipo_factura, created_at, fecha_compra
    INTO v_compra
    FROM compras
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;
  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Compra no encontrada');
  END IF;

  IF v_compra.estado = 'cancelada' THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se puede editar una compra cancelada');
  END IF;

  v_dias := EXTRACT(EPOCH FROM (now() - v_compra.created_at)) / 86400;
  IF v_dias > 7 THEN
    RETURN jsonb_build_object('success', false, 'error',
      'No se puede editar una compra creada hace mas de 7 dias');
  END IF;

  v_iva_efectivo := CASE WHEN v_compra.tipo_factura = 'ZZ' THEN 0 ELSE p_iva END;

  PERFORM set_config('app.stock_origen', 'compra_editada', true);
  PERFORM set_config('app.stock_ref_tipo', 'compra', true);
  PERFORM set_config('app.stock_ref_id', p_compra_id::TEXT, true);
  PERFORM set_config('app.stock_user_id', p_usuario_id::TEXT, true);

  PERFORM 1 FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (
       SELECT producto_id FROM compra_items
        WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       UNION
       SELECT (item->>'producto_id')::BIGINT
         FROM jsonb_array_elements(p_items_nuevos) AS item
     )
   ORDER BY id
   FOR UPDATE;

  SELECT jsonb_object_agg(id::text, stock) INTO v_snapshot_stock
    FROM productos
   WHERE sucursal_id = v_sucursal
     AND id IN (
       SELECT producto_id FROM compra_items
        WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       UNION
       SELECT (item->>'producto_id')::BIGINT
         FROM jsonb_array_elements(p_items_nuevos) AS item
     );

  WITH viejos AS (
    SELECT producto_id, SUM(cantidad)::INT AS qty_old
      FROM compra_items
     WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     GROUP BY producto_id
  ),
  nuevos AS (
    SELECT (item->>'producto_id')::BIGINT AS producto_id,
           SUM((item->>'cantidad')::INT)::INT AS qty_new
      FROM jsonb_array_elements(p_items_nuevos) AS item
     GROUP BY (item->>'producto_id')::BIGINT
  ),
  deltas AS (
    SELECT COALESCE(v.producto_id, n.producto_id) AS producto_id,
           COALESCE(n.qty_new, 0) - COALESCE(v.qty_old, 0) AS delta
      FROM viejos v FULL OUTER JOIN nuevos n USING (producto_id)
  )
  UPDATE productos p
     SET stock = p.stock + d.delta,
         updated_at = NOW()
    FROM deltas d
   WHERE p.id = d.producto_id
     AND p.sucursal_id = v_sucursal
     AND d.delta <> 0;

  SELECT jsonb_agg(jsonb_build_object('producto_id', id, 'nombre', nombre, 'stock', stock))
    INTO v_warnings_stock_negativo
    FROM productos
   WHERE sucursal_id = v_sucursal
     AND stock < 0
     AND id IN (
       SELECT producto_id FROM compra_items
        WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
       UNION
       SELECT (item->>'producto_id')::BIGINT
         FROM jsonb_array_elements(p_items_nuevos) AS item
     );

  -- Invariante de no-negatividad: si la edición dejaría stock negativo, RECHAZAR
  IF v_warnings_stock_negativo IS NOT NULL AND jsonb_array_length(v_warnings_stock_negativo) > 0 THEN
    RAISE EXCEPTION 'La edición dejaría stock negativo en: %. Ajustá las cantidades o reconciliá el stock primero.',
      (SELECT string_agg((w->>'nombre') || ' (' || (w->>'stock') || ')', ', ')
         FROM jsonb_array_elements(v_warnings_stock_negativo) w);
  END IF;

  DELETE FROM compra_items WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items_nuevos) LOOP
    v_producto_id        := (v_item->>'producto_id')::BIGINT;
    v_cantidad           := (v_item->>'cantidad')::INTEGER;
    v_costo_unitario     := COALESCE((v_item->>'costo_unitario')::NUMERIC, 0);
    v_bonificacion       := COALESCE((v_item->>'bonificacion')::NUMERIC, 0);
    v_porcentaje_iva     := COALESCE((v_item->>'porcentaje_iva')::NUMERIC, 21);
    v_impuestos_internos := COALESCE((v_item->>'impuestos_internos')::NUMERIC, 0);
    v_subtotal_item      := COALESCE((v_item->>'subtotal')::NUMERIC, 0);

    IF v_cantidad IS NULL OR v_cantidad <= 0 THEN
      RAISE EXCEPTION 'Cantidad invalida para producto %', v_producto_id;
    END IF;

    v_stock_anterior := COALESCE((v_snapshot_stock->>v_producto_id::TEXT)::INTEGER, 0);
    v_stock_nuevo := v_stock_anterior + v_cantidad;

    INSERT INTO compra_items (
      compra_id, producto_id, cantidad, costo_unitario, subtotal,
      stock_anterior, stock_nuevo, bonificacion, sucursal_id
    ) VALUES (
      p_compra_id, v_producto_id, v_cantidad, v_costo_unitario,
      v_subtotal_item, v_stock_anterior, v_stock_nuevo, v_bonificacion, v_sucursal
    );

    v_costo_neto    := v_costo_unitario * (1 - v_bonificacion / 100);
    v_costo_con_iva := costo_financiero_unitario(v_costo_neto, v_porcentaje_iva, v_impuestos_internos, v_compra.tipo_factura);
    v_costo_real    := costo_real_unitario(v_costo_neto, v_impuestos_internos, v_compra.tipo_factura);
    v_actualiza_costo := (v_bonificacion < 100 AND v_costo_neto > 0);

    SELECT MAX(c.fecha_compra) INTO v_max_fecha
      FROM compras c
      JOIN compra_items ci ON ci.compra_id = c.id AND ci.sucursal_id = c.sucursal_id
     WHERE ci.producto_id = v_producto_id
       AND ci.sucursal_id = v_sucursal
       AND c.estado <> 'cancelada'
       AND c.id <> p_compra_id;

    v_es_mas_reciente := (v_max_fecha IS NULL) OR (v_compra.fecha_compra >= v_max_fecha);

    IF v_es_mas_reciente AND v_actualiza_costo THEN
      UPDATE productos
         SET costo_sin_iva      = v_costo_neto,
             costo_con_iva      = v_costo_con_iva,
             costo_real         = v_costo_real,
             ultimo_tipo_compra = v_compra.tipo_factura,
             updated_at         = NOW()
       WHERE id = v_producto_id AND sucursal_id = v_sucursal;
      v_costo_actualizado := v_costo_actualizado || jsonb_build_object(
        'producto_id', v_producto_id,
        'costo_sin_iva', v_costo_neto,
        'costo_con_iva', v_costo_con_iva,
        'costo_real', v_costo_real
      );
    END IF;

    v_items_procesados := v_items_procesados || jsonb_build_object(
      'producto_id', v_producto_id,
      'cantidad', v_cantidad,
      'stock_anterior', v_stock_anterior,
      'stock_nuevo', v_stock_nuevo,
      'costo_actualizado', (v_es_mas_reciente AND v_actualiza_costo)
    );
  END LOOP;

  UPDATE compras
     SET subtotal = p_subtotal,
         iva = v_iva_efectivo,
         total = p_total,
         updated_at = NOW()
   WHERE id = p_compra_id AND sucursal_id = v_sucursal;

  v_warnings := NULL;

  RETURN jsonb_build_object(
    'success', true,
    'compra_id', p_compra_id,
    'items_procesados', v_items_procesados,
    'costo_actualizado', v_costo_actualizado,
    'warnings', v_warnings
  );
EXCEPTION WHEN OTHERS THEN
  RETURN jsonb_build_object('success', false, 'error', SQLERRM);
END;
$function$;
