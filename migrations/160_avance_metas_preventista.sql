-- =========================================================================
-- 160_avance_metas_preventista.sql
--
-- Avance en vivo de los objetivos de un preventista. Lo consume el dashboard
-- del propio preventista (sin argumentos) y el admin mirando a cualquiera.
--
-- BASE DE CÁLCULO — una sola, fijada acá y no se negocia:
--   venta = pedidos con estado='entregado' y canal='app'
--   ítems con es_bonificacion = false
-- Es la misma de reporte_gerencial (mig 130), así que el % de avance cierra
-- peso a peso contra la columna "venta" del reporte gerencial.
-- OJO: calcular_comisiones (mig 150) usa estado <> 'cancelado' A PROPÓSITO
-- (la comisión se devenga al vender, no al entregar). No mezclar las dos.
--
-- SEGURIDAD: la función es SECURITY DEFINER, o sea que BYPASEA la RLS de
-- metas_preventista y de pedidos, y `p_preventista_id` viene del cliente. El
-- IF de las primeras líneas es lo único que separa a un preventista de las
-- ventas y los objetivos de sus compañeros.
--
-- El prorrateo se calcula ACÁ, no en el front: metas_gerenciales lo hace en el
-- front y por eso su semáforo puede discrepar del de esta pantalla.
-- =========================================================================

CREATE OR REPLACE FUNCTION public.avance_metas_preventista(
  p_preventista_id uuid DEFAULT NULL,
  p_periodo        date DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_target      uuid;
  v_periodo     date;
  v_hasta       date;
  v_dias_total  integer;
  v_dias_trans  integer;
  v_nombre      text;
  v_sucursales  bigint[];
  v_result      jsonb;
  v_sin_marca   integer := 0;
  v_hay_marca   boolean := false;
BEGIN
  v_target  := COALESCE(p_preventista_id, auth.uid());
  v_periodo := date_trunc('month', COALESCE(p_periodo, current_date))::date;
  v_hasta   := (v_periodo + interval '1 month' - interval '1 day')::date;

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  -- El muro. Un preventista sólo puede pedir lo suyo.
  -- auth.uid() NULL = service_role / SQL editor: exento, igual que reporte_gerencial.
  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND NOT es_admin() THEN
    RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
  END IF;

  SELECT nombre INTO v_nombre FROM perfiles WHERE id = v_target;

  v_dias_total := EXTRACT(DAY FROM v_hasta)::integer;
  -- Mes en curso: días ya transcurridos. Mes cerrado: el mes completo.
  v_dias_trans := CASE
    WHEN current_date > v_hasta  THEN v_dias_total
    WHEN current_date < v_periodo THEN 0
    ELSE EXTRACT(DAY FROM current_date)::integer
  END;

  -- Las sucursales relevantes son las de las metas cargadas, no todas las del
  -- usuario: si tiene metas sólo en Tucumán, lo vendido en Taco Pozo no cuenta.
  SELECT array_agg(DISTINCT sucursal_id) INTO v_sucursales
  FROM metas_preventista
  WHERE preventista_id = v_target AND periodo = v_periodo AND activo;

  IF v_sucursales IS NULL THEN
    RETURN jsonb_build_object(
      'preventista_id', v_target,
      'nombre', v_nombre,
      'periodo', v_periodo,
      'dias_transcurridos', v_dias_trans,
      'dias_periodo', v_dias_total,
      'metas', '[]'::jsonb,
      'resumen', jsonb_build_object('total', 0, 'cumplidas', 0, 'en_riesgo', 0),
      'productos_sin_marca', 0
    );
  END IF;

  WITH
  metas AS (
    SELECT * FROM metas_preventista
    WHERE preventista_id = v_target AND periodo = v_periodo AND activo
  ),
  -- Pedidos entregados del preventista en el mes. MATERIALIZED para que no se
  -- re-evalúe una vez por meta.
  ped AS MATERIALIZED (
    SELECT id, cliente_id, sucursal_id
    FROM pedidos
    WHERE usuario_id = v_target
      AND estado = 'entregado'
      AND canal = 'app'
      AND fecha BETWEEN v_periodo AND v_hasta
      AND sucursal_id = ANY(v_sucursales)
  ),
  it AS MATERIALIZED (
    SELECT p.sucursal_id, pi.cantidad, pi.subtotal, pi.es_bonificacion,
           pi.producto_id, prod.categoria_id, prod.marca_id
    FROM ped p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    JOIN productos prod  ON prod.id = pi.producto_id
    WHERE pi.es_bonificacion IS NOT TRUE
  ),
  -- Cliente nuevo = su PRIMER pedido entregado de la sucursal cae en el mes.
  -- El usuario_id se toma de ese primer pedido, no del filtro del MIN: si no,
  -- dos preventistas se atribuyen el mismo cliente.
  primer_pedido AS (
    SELECT DISTINCT ON (p.cliente_id, p.sucursal_id)
           p.cliente_id, p.sucursal_id, p.usuario_id, p.fecha
    FROM pedidos p
    WHERE p.estado = 'entregado' AND p.canal = 'app'
      AND p.sucursal_id = ANY(v_sucursales)
    ORDER BY p.cliente_id, p.sucursal_id, p.fecha, p.id
  ),
  logrado AS (
    SELECT m.*,
      CASE m.tipo_meta
        WHEN 'facturacion' THEN (
          SELECT COALESCE(SUM(i.subtotal), 0) FROM it i
          WHERE i.sucursal_id = m.sucursal_id
            AND (m.marca_id     IS NULL OR i.marca_id     = m.marca_id)
            AND (m.categoria_id IS NULL OR i.categoria_id = m.categoria_id)
            AND (m.producto_id  IS NULL OR i.producto_id  = m.producto_id)
        )
        WHEN 'unidades' THEN (
          SELECT COALESCE(SUM(i.cantidad), 0) FROM it i
          WHERE i.sucursal_id = m.sucursal_id
            AND (m.marca_id     IS NULL OR i.marca_id     = m.marca_id)
            AND (m.categoria_id IS NULL OR i.categoria_id = m.categoria_id)
            AND (m.producto_id  IS NULL OR i.producto_id  = m.producto_id)
        )
        WHEN 'cobertura' THEN (
          SELECT COUNT(DISTINCT p.cliente_id) FROM ped p
          WHERE p.sucursal_id = m.sucursal_id
        )
        WHEN 'clientes_nuevos' THEN (
          SELECT COUNT(*) FROM primer_pedido pp
          WHERE pp.sucursal_id = m.sucursal_id
            AND pp.usuario_id = v_target
            AND pp.fecha BETWEEN v_periodo AND v_hasta
        )
      END AS logrado
    FROM metas m
  ),
  calc AS (
    SELECT l.*,
      ROUND(l.valor_objetivo * v_dias_trans / NULLIF(v_dias_total, 0), 2) AS objetivo_prorrateado,
      ROUND(100 * l.logrado / NULLIF(l.valor_objetivo, 0), 1) AS pct
    FROM logrado l
  )
  SELECT jsonb_build_object(
    'preventista_id', v_target,
    'nombre', v_nombre,
    'periodo', v_periodo,
    'dias_transcurridos', v_dias_trans,
    'dias_periodo', v_dias_total,
    'metas', COALESCE(jsonb_agg(jsonb_build_object(
        'id', c.id,
        'tipo_meta', c.tipo_meta,
        'unidad', CASE c.tipo_meta
                    WHEN 'facturacion' THEN '$'
                    WHEN 'unidades'    THEN 'u'
                    ELSE 'clientes' END,
        'alcance', CASE
          WHEN c.marca_id IS NOT NULL THEN jsonb_build_object(
            'tipo', 'marca', 'id', c.marca_id,
            'nombre', (SELECT nombre FROM marcas WHERE id = c.marca_id))
          WHEN c.categoria_id IS NOT NULL THEN jsonb_build_object(
            'tipo', 'categoria', 'id', c.categoria_id,
            'nombre', (SELECT nombre FROM categorias WHERE id = c.categoria_id))
          WHEN c.producto_id IS NOT NULL THEN jsonb_build_object(
            'tipo', 'producto', 'id', c.producto_id,
            'nombre', (SELECT nombre FROM productos WHERE id = c.producto_id))
          ELSE jsonb_build_object('tipo', 'global', 'id', NULL, 'nombre', NULL)
        END,
        'objetivo', c.valor_objetivo,
        'logrado', c.logrado,
        'pct', COALESCE(c.pct, 0),
        'objetivo_prorrateado', COALESCE(c.objetivo_prorrateado, 0),
        'estado', CASE
          WHEN c.logrado >= c.valor_objetivo THEN 'cumplida'
          WHEN c.logrado >= COALESCE(c.objetivo_prorrateado, 0) THEN 'adelantado'
          WHEN c.logrado >= 0.8 * COALESCE(c.objetivo_prorrateado, 0) THEN 'en_curso'
          ELSE 'en_riesgo'
        END
      ) ORDER BY c.tipo_meta, c.id), '[]'::jsonb),
    'resumen', jsonb_build_object(
      'total', COUNT(*),
      'cumplidas', COUNT(*) FILTER (WHERE c.logrado >= c.valor_objetivo),
      'en_riesgo', COUNT(*) FILTER (
        WHERE c.logrado < 0.8 * COALESCE(c.objetivo_prorrateado, 0)
          AND c.logrado < c.valor_objetivo)
    )
  ) INTO v_result
  FROM calc c;

  -- Cobertura del dato: una meta por marca sobre un catálogo a medio marcar
  -- mide de menos y el error es invisible. Mismo criterio que el banner
  -- items_sin_desglose de VistaComisiones.
  SELECT EXISTS (
    SELECT 1 FROM metas_preventista
    WHERE preventista_id = v_target AND periodo = v_periodo AND activo
      AND marca_id IS NOT NULL
  ) INTO v_hay_marca;

  IF v_hay_marca THEN
    SELECT COUNT(*) INTO v_sin_marca
    FROM productos WHERE marca_id IS NULL AND sucursal_id = ANY(v_sucursales);
  END IF;

  RETURN v_result || jsonb_build_object('productos_sin_marca', v_sin_marca);
END;
$fn$;

ALTER FUNCTION public.avance_metas_preventista(uuid, date) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.avance_metas_preventista(uuid, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.avance_metas_preventista(uuid, date) TO authenticated;

COMMENT ON FUNCTION public.avance_metas_preventista(uuid, date) IS
  'Avance de los objetivos mensuales de un preventista. Sin argumentos devuelve los del usuario logueado; con p_preventista_id requiere admin. Base: pedidos entregados canal app, sin bonificaciones. Mig 160.';
