-- 003_rendiciones_refactor.sql
--
-- Refactor del sistema de rendiciones: pasa de agrupar por pedidos.fecha_entrega
-- a basarse en la fecha contable de los pagos (pagos.fecha).
--
-- Incluye:
--   1. Columna pagos.fecha DATE + backfill desde pedidos.monto_pagado.
--   2. Ampliacion de rendiciones_control (estado, observaciones, resuelta_*).
--   3. Tabla rendicion_gastos (registro sin impacto en caja).
--   4. RLS sobre rendicion_gastos + trigger de audit.
--   5. RPC marcar_pagos_masivo ahora crea filas en pagos con fecha elegible.
--   6. RPC marcar_entregas_masivo nueva para elegir fecha de entrega.
--   7. RPC obtener_resumen_rendiciones reescrita sobre pagos + gastos + estado.
--   8. RPCs confirmar_rendicion (con gastos) y resolver_rendicion (disconformidad).

BEGIN;

-- =========================================================================
-- 1. pagos.fecha + backfill
-- =========================================================================

ALTER TABLE public.pagos
  ADD COLUMN IF NOT EXISTS fecha DATE NOT NULL DEFAULT CURRENT_DATE;

COMMENT ON COLUMN public.pagos.fecha IS
  'Fecha contable del pago (editable desde flujos masivos/individuales). created_at permanece como timestamp inmutable de insercion.';

CREATE INDEX IF NOT EXISTS idx_pagos_fecha ON public.pagos(fecha);

-- Backfill: crear una fila en pagos por cada pedido que tiene monto_pagado > 0
-- pero no tiene ninguna fila en pagos (caso tipico: pagos masivos previos al refactor).
INSERT INTO public.pagos (cliente_id, pedido_id, monto, forma_pago, fecha, notas, sucursal_id, usuario_id)
SELECT
  p.cliente_id,
  p.id,
  p.monto_pagado,
  COALESCE(p.forma_pago, 'efectivo'),
  COALESCE(p.fecha_entrega::date, p.fecha::date, CURRENT_DATE),
  '[backfill 003] migrado desde pedidos.monto_pagado en refactor rendiciones',
  p.sucursal_id,
  p.transportista_id
FROM public.pedidos p
LEFT JOIN public.pagos pg ON pg.pedido_id = p.id
WHERE p.monto_pagado > 0
  AND pg.id IS NULL;

-- =========================================================================
-- 2. rendiciones_control: estado + observaciones + resolucion
-- =========================================================================

-- Las columnas controlada_at/por ya no son obligatorias: una rendicion puede
-- quedar en 'disconformidad' sin estar confirmada.
ALTER TABLE public.rendiciones_control
  ALTER COLUMN controlada_at DROP NOT NULL,
  ALTER COLUMN controlada_por DROP NOT NULL;

ALTER TABLE public.rendiciones_control
  ADD COLUMN IF NOT EXISTS estado TEXT NOT NULL DEFAULT 'pendiente'
    CHECK (estado IN ('pendiente','confirmada','disconformidad','resuelta')),
  ADD COLUMN IF NOT EXISTS observaciones TEXT,
  ADD COLUMN IF NOT EXISTS resuelta_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS resuelta_por UUID REFERENCES public.perfiles(id);

COMMENT ON COLUMN public.rendiciones_control.estado IS
  'Estado de la rendicion: pendiente -> confirmada | disconformidad -> resuelta.';

-- Migrar filas existentes: las que ya tenian controlada_at pasan a 'confirmada'.
UPDATE public.rendiciones_control
   SET estado = 'confirmada'
 WHERE controlada_at IS NOT NULL
   AND estado = 'pendiente';

-- =========================================================================
-- 3. rendicion_gastos
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.rendicion_gastos (
  id BIGSERIAL PRIMARY KEY,
  fecha DATE NOT NULL,
  transportista_id UUID NOT NULL REFERENCES public.perfiles(id),
  sucursal_id BIGINT NOT NULL REFERENCES public.sucursales(id),
  descripcion TEXT NOT NULL,
  monto NUMERIC(12,2) NOT NULL CHECK (monto >= 0),
  creado_por UUID NOT NULL REFERENCES public.perfiles(id),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.rendicion_gastos IS
  'Gastos asociados a una rendicion diaria. Registro sin impacto en caja/stock: solo constancia auditable.';

CREATE INDEX IF NOT EXISTS idx_rendicion_gastos_rend
  ON public.rendicion_gastos(fecha, transportista_id, sucursal_id);

-- RLS
ALTER TABLE public.rendicion_gastos ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "rg_select" ON public.rendicion_gastos;
CREATE POLICY "rg_select" ON public.rendicion_gastos FOR SELECT TO authenticated
USING (
  sucursal_id = public.current_sucursal_id()
  AND (
    public.es_encargado_o_admin()
    OR transportista_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "rg_insert" ON public.rendicion_gastos;
CREATE POLICY "rg_insert" ON public.rendicion_gastos FOR INSERT TO authenticated
WITH CHECK (
  sucursal_id = public.current_sucursal_id()
  AND (
    public.es_encargado_o_admin()
    OR transportista_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "rg_update" ON public.rendicion_gastos;
CREATE POLICY "rg_update" ON public.rendicion_gastos FOR UPDATE TO authenticated
USING (public.es_admin() AND sucursal_id = public.current_sucursal_id())
WITH CHECK (public.es_admin() AND sucursal_id = public.current_sucursal_id());

DROP POLICY IF EXISTS "rg_delete" ON public.rendicion_gastos;
CREATE POLICY "rg_delete" ON public.rendicion_gastos FOR DELETE TO authenticated
USING (public.es_admin() AND sucursal_id = public.current_sucursal_id());

-- =========================================================================
-- 4. Audit triggers en tablas nuevas
-- =========================================================================

DROP TRIGGER IF EXISTS audit_rendicion_gastos ON public.rendicion_gastos;
CREATE TRIGGER audit_rendicion_gastos
  AFTER INSERT OR UPDATE OR DELETE ON public.rendicion_gastos
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

DROP TRIGGER IF EXISTS audit_rendiciones_control ON public.rendiciones_control;
CREATE TRIGGER audit_rendiciones_control
  AFTER INSERT OR UPDATE OR DELETE ON public.rendiciones_control
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- =========================================================================
-- 5. RPC: marcar_pagos_masivo (v2, acepta fecha)
-- =========================================================================

-- El cambio de firma (agregar tercer parametro) requiere DROP + CREATE.
DROP FUNCTION IF EXISTS public.marcar_pagos_masivo(bigint[], text);

CREATE OR REPLACE FUNCTION public.marcar_pagos_masivo(
  p_pedido_ids bigint[],
  p_forma_pago text,
  p_fecha date DEFAULT CURRENT_DATE
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_pedido RECORD;
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

  -- Insertar una fila en pagos por cada pedido pendiente. Monto = saldo
  -- pendiente (total - monto_pagado actual) para no duplicar parciales.
  FOR v_pedido IN
    SELECT id, cliente_id, total, COALESCE(monto_pagado, 0) AS ya_pagado
    FROM pedidos
    WHERE id = ANY(p_pedido_ids)
      AND sucursal_id = v_sucursal_id
      AND COALESCE(estado_pago, 'pendiente') <> 'pagado'
      AND total > COALESCE(monto_pagado, 0)
  LOOP
    INSERT INTO pagos (cliente_id, pedido_id, monto, forma_pago, fecha, usuario_id, sucursal_id)
    VALUES (
      v_pedido.cliente_id,
      v_pedido.id,
      v_pedido.total - v_pedido.ya_pagado,
      p_forma_pago,
      p_fecha,
      auth.uid(),
      v_sucursal_id
    );
  END LOOP;

  -- Actualizar pedidos para que queden como pagados (el trigger actualiza estado_pago).
  UPDATE pedidos
     SET monto_pagado = total,
         forma_pago = p_forma_pago,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$$;

ALTER FUNCTION public.marcar_pagos_masivo(bigint[], text, date) OWNER TO postgres;
COMMENT ON FUNCTION public.marcar_pagos_masivo(bigint[], text, date) IS
  'Marca multiples pedidos como pagados en batch en una fecha dada. Crea filas en pagos y actualiza pedidos. Default fecha = CURRENT_DATE.';

-- =========================================================================
-- 6. RPC: marcar_entregas_masivo (nueva, acepta fecha)
-- =========================================================================

CREATE OR REPLACE FUNCTION public.marcar_entregas_masivo(
  p_pedido_ids bigint[],
  p_transportista_id uuid,
  p_fecha date DEFAULT CURRENT_DATE
) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_affected INTEGER;
  v_fecha_ts TIMESTAMPTZ;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo encargado o admin pueden marcar entregas masivas'
      USING ERRCODE = '42501';
  END IF;

  IF p_pedido_ids IS NULL OR array_length(p_pedido_ids, 1) IS NULL THEN
    RETURN 0;
  END IF;

  -- Anclar al mediodia AR para evitar corrimientos por timezone.
  v_fecha_ts := (p_fecha::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz;

  UPDATE pedidos
     SET estado = 'entregado',
         fecha_entrega = v_fecha_ts,
         transportista_id = p_transportista_id,
         updated_at = now()
   WHERE id = ANY(p_pedido_ids)
     AND sucursal_id = v_sucursal_id;

  GET DIAGNOSTICS v_affected = ROW_COUNT;
  RETURN v_affected;
END;
$$;

ALTER FUNCTION public.marcar_entregas_masivo(bigint[], uuid, date) OWNER TO postgres;
COMMENT ON FUNCTION public.marcar_entregas_masivo(bigint[], uuid, date) IS
  'Marca multiples pedidos como entregados asignando transportista y fecha de entrega (default CURRENT_DATE).';

-- =========================================================================
-- 7. RPC: obtener_resumen_rendiciones (reescrita sobre pagos)
-- =========================================================================

DROP FUNCTION IF EXISTS public.obtener_resumen_rendiciones(date, date, uuid);

CREATE OR REPLACE FUNCTION public.obtener_resumen_rendiciones(
  p_fecha_desde date DEFAULT ((CURRENT_DATE - '30 days'::interval))::date,
  p_fecha_hasta date DEFAULT CURRENT_DATE,
  p_transportista_id uuid DEFAULT NULL
) RETURNS TABLE (
  fecha date,
  transportista_id uuid,
  transportista_nombre text,
  total_efectivo numeric,
  total_transferencia numeric,
  total_cheque numeric,
  total_cuenta_corriente numeric,
  total_tarjeta numeric,
  total_otros numeric,
  total_general numeric,
  cantidad_pedidos bigint,
  total_entregado numeric,
  total_gastos numeric,
  cantidad_gastos bigint,
  estado text,
  observaciones text,
  controlada boolean,
  controlada_at timestamptz,
  controlada_por_nombre text,
  resuelta_at timestamptz,
  resuelta_por_nombre text
)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path TO 'public'
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
  WITH pagos_agg AS (
    SELECT
      pd.transportista_id AS t_id,
      pg.fecha AS f,
      SUM(CASE WHEN pg.forma_pago = 'efectivo' THEN pg.monto ELSE 0 END)::numeric AS tot_ef,
      SUM(CASE WHEN pg.forma_pago = 'transferencia' THEN pg.monto ELSE 0 END)::numeric AS tot_tr,
      SUM(CASE WHEN pg.forma_pago = 'cheque' THEN pg.monto ELSE 0 END)::numeric AS tot_ch,
      SUM(CASE WHEN pg.forma_pago = 'cuenta_corriente' THEN pg.monto ELSE 0 END)::numeric AS tot_cc,
      SUM(CASE WHEN pg.forma_pago = 'tarjeta' THEN pg.monto ELSE 0 END)::numeric AS tot_tj,
      SUM(CASE WHEN pg.forma_pago NOT IN ('efectivo','transferencia','cheque','cuenta_corriente','tarjeta')
                OR pg.forma_pago IS NULL THEN pg.monto ELSE 0 END)::numeric AS tot_ot,
      SUM(pg.monto)::numeric AS tot_gen
    FROM pagos pg
    JOIN pedidos pd ON pd.id = pg.pedido_id
    WHERE pg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND pd.sucursal_id = v_sucursal_id
      AND pd.transportista_id IS NOT NULL
      AND (p_transportista_id IS NULL OR pd.transportista_id = p_transportista_id)
    GROUP BY pd.transportista_id, pg.fecha
  ),
  entregas_agg AS (
    SELECT
      pd.transportista_id AS t_id,
      pd.fecha_entrega::date AS f,
      SUM(pd.total)::numeric AS tot_entregado,
      COUNT(*)::bigint AS cant
    FROM pedidos pd
    WHERE pd.estado = 'entregado'
      AND pd.fecha_entrega IS NOT NULL
      AND pd.transportista_id IS NOT NULL
      AND pd.fecha_entrega::date BETWEEN p_fecha_desde AND p_fecha_hasta
      AND pd.sucursal_id = v_sucursal_id
      AND (p_transportista_id IS NULL OR pd.transportista_id = p_transportista_id)
    GROUP BY pd.transportista_id, pd.fecha_entrega::date
  ),
  gastos_agg AS (
    SELECT
      rg.transportista_id AS t_id,
      rg.fecha AS f,
      SUM(rg.monto)::numeric AS tot_g,
      COUNT(*)::bigint AS cant_g
    FROM rendicion_gastos rg
    WHERE rg.fecha BETWEEN p_fecha_desde AND p_fecha_hasta
      AND rg.sucursal_id = v_sucursal_id
      AND (p_transportista_id IS NULL OR rg.transportista_id = p_transportista_id)
    GROUP BY rg.transportista_id, rg.fecha
  ),
  fechas_activas AS (
    SELECT t_id, f FROM pagos_agg
    UNION
    SELECT t_id, f FROM entregas_agg
  )
  SELECT
    fa.f::date AS fecha,
    fa.t_id AS transportista_id,
    tr.nombre::text AS transportista_nombre,
    COALESCE(pagos_agg.tot_ef, 0)::numeric AS total_efectivo,
    COALESCE(pagos_agg.tot_tr, 0)::numeric AS total_transferencia,
    COALESCE(pagos_agg.tot_ch, 0)::numeric AS total_cheque,
    COALESCE(pagos_agg.tot_cc, 0)::numeric AS total_cuenta_corriente,
    COALESCE(pagos_agg.tot_tj, 0)::numeric AS total_tarjeta,
    COALESCE(pagos_agg.tot_ot, 0)::numeric AS total_otros,
    COALESCE(pagos_agg.tot_gen, 0)::numeric AS total_general,
    COALESCE(entregas_agg.cant, 0)::bigint AS cantidad_pedidos,
    COALESCE(entregas_agg.tot_entregado, 0)::numeric AS total_entregado,
    COALESCE(gastos_agg.tot_g, 0)::numeric AS total_gastos,
    COALESCE(gastos_agg.cant_g, 0)::bigint AS cantidad_gastos,
    COALESCE(rc.estado, 'pendiente')::text AS estado,
    rc.observaciones,
    (rc.id IS NOT NULL AND COALESCE(rc.estado, 'pendiente') IN ('confirmada','resuelta')) AS controlada,
    rc.controlada_at,
    cp.nombre::text AS controlada_por_nombre,
    rc.resuelta_at,
    rp.nombre::text AS resuelta_por_nombre
  FROM fechas_activas fa
  JOIN perfiles tr ON tr.id = fa.t_id
  LEFT JOIN pagos_agg ON pagos_agg.t_id = fa.t_id AND pagos_agg.f = fa.f
  LEFT JOIN entregas_agg ON entregas_agg.t_id = fa.t_id AND entregas_agg.f = fa.f
  LEFT JOIN gastos_agg ON gastos_agg.t_id = fa.t_id AND gastos_agg.f = fa.f
  LEFT JOIN rendiciones_control rc
    ON rc.fecha = fa.f
   AND rc.transportista_id = fa.t_id
   AND rc.sucursal_id = v_sucursal_id
  LEFT JOIN perfiles cp ON cp.id = rc.controlada_por
  LEFT JOIN perfiles rp ON rp.id = rc.resuelta_por
  ORDER BY fa.f DESC, tr.nombre ASC;
END;
$$;

ALTER FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) OWNER TO postgres;
COMMENT ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) IS
  'Resumen de rendiciones por (fecha_pago, transportista). Suma pagos.monto por forma_pago, incluye total entregado del dia, gastos y estado de control.';

-- =========================================================================
-- 8. RPC: confirmar_rendicion (confirmada o disconformidad, con gastos)
-- =========================================================================

CREATE OR REPLACE FUNCTION public.confirmar_rendicion(
  p_fecha date,
  p_transportista_id uuid,
  p_estado text,
  p_observaciones text DEFAULT NULL,
  p_gastos jsonb DEFAULT '[]'::jsonb
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_id BIGINT;
  v_gasto jsonb;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_estado NOT IN ('confirmada','disconformidad') THEN
    RAISE EXCEPTION 'Estado inválido: %. Use "confirmada" o "disconformidad"', p_estado;
  END IF;

  INSERT INTO rendiciones_control (
    fecha, transportista_id, sucursal_id, estado, observaciones,
    controlada_at, controlada_por
  )
  VALUES (
    p_fecha, p_transportista_id, v_sucursal_id, p_estado, p_observaciones,
    now(), auth.uid()
  )
  ON CONFLICT (fecha, transportista_id, sucursal_id) DO UPDATE
    SET estado = EXCLUDED.estado,
        observaciones = EXCLUDED.observaciones,
        controlada_at = now(),
        controlada_por = auth.uid(),
        -- si se reabre desde 'resuelta' o 'disconformidad', limpiar campos de resolucion
        resuelta_at = NULL,
        resuelta_por = NULL
  RETURNING id INTO v_id;

  IF p_gastos IS NOT NULL AND jsonb_typeof(p_gastos) = 'array' AND jsonb_array_length(p_gastos) > 0 THEN
    FOR v_gasto IN SELECT * FROM jsonb_array_elements(p_gastos)
    LOOP
      IF (v_gasto->>'descripcion') IS NULL OR length(trim(v_gasto->>'descripcion')) = 0 THEN
        CONTINUE;
      END IF;

      INSERT INTO rendicion_gastos (
        fecha, transportista_id, sucursal_id, descripcion, monto, creado_por
      )
      VALUES (
        p_fecha,
        p_transportista_id,
        v_sucursal_id,
        trim(v_gasto->>'descripcion'),
        COALESCE((v_gasto->>'monto')::numeric, 0),
        auth.uid()
      );
    END LOOP;
  END IF;

  RETURN v_id;
END;
$$;

ALTER FUNCTION public.confirmar_rendicion(date, uuid, text, text, jsonb) OWNER TO postgres;
COMMENT ON FUNCTION public.confirmar_rendicion(date, uuid, text, text, jsonb) IS
  'Upsert de rendiciones_control con estado (confirmada|disconformidad), observaciones, y creacion en batch de rendicion_gastos.';

-- =========================================================================
-- 9. RPC: resolver_rendicion (disconformidad -> resuelta)
-- =========================================================================

CREATE OR REPLACE FUNCTION public.resolver_rendicion(
  p_fecha date,
  p_transportista_id uuid,
  p_observaciones text
) RETURNS bigint
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal_id BIGINT;
  v_id BIGINT;
  v_estado_actual TEXT;
  v_obs_previas TEXT;
  v_nombre_usuario TEXT;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT id, estado, observaciones
    INTO v_id, v_estado_actual, v_obs_previas
  FROM rendiciones_control
  WHERE fecha = p_fecha
    AND transportista_id = p_transportista_id
    AND sucursal_id = v_sucursal_id;

  IF v_id IS NULL THEN
    RAISE EXCEPTION 'No existe rendicion para (%, %)', p_fecha, p_transportista_id;
  END IF;

  IF v_estado_actual <> 'disconformidad' THEN
    RAISE EXCEPTION 'Solo se pueden resolver rendiciones en disconformidad (estado actual: %)', v_estado_actual;
  END IF;

  SELECT nombre INTO v_nombre_usuario FROM perfiles WHERE id = auth.uid();

  UPDATE rendiciones_control
     SET estado = 'resuelta',
         observaciones = COALESCE(v_obs_previas, '')
           || CASE WHEN v_obs_previas IS NOT NULL AND length(v_obs_previas) > 0 THEN E'\n\n' ELSE '' END
           || '[Resuelta por ' || COALESCE(v_nombre_usuario, 'usuario') || ' el '
           || to_char(now(), 'DD/MM/YYYY HH24:MI')
           || ']: ' || p_observaciones,
         resuelta_at = now(),
         resuelta_por = auth.uid()
   WHERE id = v_id;

  RETURN v_id;
END;
$$;

ALTER FUNCTION public.resolver_rendicion(date, uuid, text) OWNER TO postgres;
COMMENT ON FUNCTION public.resolver_rendicion(date, uuid, text) IS
  'Marca una rendicion en disconformidad como resuelta, preservando el historial de observaciones.';

-- =========================================================================
-- 10. Grants
-- =========================================================================

GRANT ALL ON FUNCTION public.marcar_pagos_masivo(bigint[], text, date) TO anon, authenticated, service_role;
GRANT ALL ON FUNCTION public.marcar_entregas_masivo(bigint[], uuid, date) TO anon, authenticated, service_role;
GRANT ALL ON FUNCTION public.obtener_resumen_rendiciones(date, date, uuid) TO anon, authenticated, service_role;
GRANT ALL ON FUNCTION public.confirmar_rendicion(date, uuid, text, text, jsonb) TO anon, authenticated, service_role;
GRANT ALL ON FUNCTION public.resolver_rendicion(date, uuid, text) TO anon, authenticated, service_role;

GRANT SELECT, INSERT ON public.rendicion_gastos TO authenticated;
GRANT UPDATE, DELETE ON public.rendicion_gastos TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.rendicion_gastos_id_seq TO authenticated;

COMMIT;
