-- =========================================================================
-- 164_metas_periodo_editable.sql
--
-- Tres cosas que salieron de probar los objetivos en producción:
--
-- 1. PERÍODO EDITABLE. Las metas eran mensuales y punto (`periodo` = primer
--    día del mes). El mes sigue siendo el default, pero ahora se puede cargar
--    un objetivo para una quincena, una semana de acción o una campaña que
--    cruza meses. Se agrega `periodo_fin`; `periodo` pasa a ser el "desde".
--
-- 2. SEMÁFORO. Al día 4 de 31, con $0 sobre un objetivo de $1.000, el panel
--    decía "Atrasado". Es matemáticamente cierto contra el prorrateo (debía
--    llevar $129) pero es una lectura inútil: quedan 27 días y al principio
--    del período el prorrateo es ruido, no señal. Ahora sólo se marca en
--    riesgo cuando transcurrió al menos el 25% del período. Antes de eso, lo
--    peor que puede decir es "En progreso".
--
-- 3. El objetivo cuenta las ventas de TODO el período, no desde que se cargó.
--    Ya era así (el cálculo nunca miró `created_at`), pero queda dicho acá
--    porque fue una duda concreta: cargar hoy una meta del mes toma lo que ya
--    se vendió del 1 al día de hoy.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. Columna de fin de período
-- -------------------------------------------------------------------------
ALTER TABLE public.metas_preventista
  ADD COLUMN IF NOT EXISTS periodo_fin date;

-- Las metas que ya existían son mensuales: fin = último día de su mes.
UPDATE public.metas_preventista
SET periodo_fin = (date_trunc('month', periodo) + interval '1 month - 1 day')::date
WHERE periodo_fin IS NULL;

ALTER TABLE public.metas_preventista
  ALTER COLUMN periodo_fin SET NOT NULL;

ALTER TABLE public.metas_preventista
  DROP CONSTRAINT IF EXISTS metas_preventista_periodo_check;
ALTER TABLE public.metas_preventista
  ADD CONSTRAINT metas_preventista_periodo_check CHECK (periodo_fin >= periodo);

COMMENT ON COLUMN public.metas_preventista.periodo IS
  'Inicio del período del objetivo. Por defecto el primer día del mes. Mig 164.';
COMMENT ON COLUMN public.metas_preventista.periodo_fin IS
  'Fin del período (inclusive). Por defecto el último día del mes de `periodo`. Mig 164.';

-- El índice único tiene que incluir el fin: "agosto" y "primera quincena de
-- agosto" son dos objetivos distintos y ambos arrancan el 01/08.
DROP INDEX IF EXISTS public.metas_preventista_uidx;
CREATE UNIQUE INDEX metas_preventista_uidx
  ON public.metas_preventista (
    preventista_id, periodo, periodo_fin, tipo_meta,
    COALESCE(marca_id, '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(categoria_id, '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(producto_ids, '{}'::bigint[])
  );

-- -------------------------------------------------------------------------
-- 2. guardar_meta_preventista: p_periodo_hasta opcional.
--    NULL = mensual (comportamiento anterior, sigue siendo el default).
-- -------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint[]);

CREATE OR REPLACE FUNCTION public.guardar_meta_preventista(
  p_id             bigint,
  p_sucursal_id    bigint,
  p_preventista_id uuid,
  p_periodo        date,
  p_tipo_meta      text,
  p_valor_objetivo numeric,
  p_marca_id       uuid     DEFAULT NULL,
  p_categoria_id   uuid     DEFAULT NULL,
  p_producto_ids   bigint[] DEFAULT NULL,
  p_periodo_hasta  date     DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_id        bigint;
  v_desde     date;
  v_hasta     date;
  v_productos bigint[];
  v_ajenos    integer;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede definir objetivos' USING ERRCODE = '42501';
  END IF;

  -- Sin fecha de fin explícita el objetivo es del mes de p_periodo, que es el
  -- caso normal. Con fecha de fin, las dos fechas se respetan tal cual.
  IF p_periodo_hasta IS NULL THEN
    v_desde := date_trunc('month', COALESCE(p_periodo, current_date))::date;
    v_hasta := (v_desde + interval '1 month - 1 day')::date;
  ELSE
    v_desde := COALESCE(p_periodo, current_date);
    v_hasta := p_periodo_hasta;
  END IF;

  IF v_hasta < v_desde THEN
    RAISE EXCEPTION 'El fin del período no puede ser anterior al inicio';
  END IF;

  IF p_valor_objetivo IS NULL OR p_valor_objetivo <= 0 THEN
    RAISE EXCEPTION 'El objetivo debe ser mayor a 0';
  END IF;

  IF p_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Indicá la sucursal del objetivo';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales
    WHERE usuario_id = auth.uid() AND sucursal_id = p_sucursal_id
  ) THEN
    RAISE EXCEPTION 'No tenés acceso a esa sucursal' USING ERRCODE = '42501';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM usuario_sucursales us
    WHERE us.usuario_id = p_preventista_id AND us.sucursal_id = p_sucursal_id
  ) THEN
    RAISE EXCEPTION 'Ese usuario no trabaja en la sucursal elegida';
  END IF;

  IF p_producto_ids IS NOT NULL AND cardinality(p_producto_ids) > 0 THEN
    SELECT array_agg(DISTINCT x ORDER BY x) INTO v_productos
    FROM unnest(p_producto_ids) AS x;

    SELECT COUNT(*) INTO v_ajenos
    FROM unnest(v_productos) AS x
    WHERE NOT EXISTS (
      SELECT 1 FROM productos p WHERE p.id = x AND p.sucursal_id = p_sucursal_id
    );
    IF v_ajenos > 0 THEN
      RAISE EXCEPTION '% producto(s) no pertenecen a la sucursal elegida', v_ajenos;
    END IF;
  ELSE
    v_productos := NULL;
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO metas_preventista (
      sucursal_id, preventista_id, periodo, periodo_fin, tipo_meta,
      marca_id, categoria_id, producto_ids, valor_objetivo, usuario_id
    ) VALUES (
      p_sucursal_id, p_preventista_id, v_desde, v_hasta, p_tipo_meta,
      p_marca_id, p_categoria_id, v_productos, p_valor_objetivo, auth.uid()
    )
    ON CONFLICT (
      preventista_id, periodo, periodo_fin, tipo_meta,
      COALESCE(marca_id, '00000000-0000-0000-0000-000000000000'::uuid),
      COALESCE(categoria_id, '00000000-0000-0000-0000-000000000000'::uuid),
      COALESCE(producto_ids, '{}'::bigint[])
    ) DO UPDATE SET
      valor_objetivo = EXCLUDED.valor_objetivo,
      activo         = true,
      usuario_id     = EXCLUDED.usuario_id
    RETURNING id INTO v_id;
  ELSE
    UPDATE metas_preventista SET
      preventista_id = p_preventista_id,
      periodo        = v_desde,
      periodo_fin    = v_hasta,
      tipo_meta      = p_tipo_meta,
      marca_id       = p_marca_id,
      categoria_id   = p_categoria_id,
      producto_ids   = v_productos,
      valor_objetivo = p_valor_objetivo
    WHERE id = p_id
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'El objetivo % no existe', p_id USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  RETURN v_id;
END;
$fn$;

ALTER FUNCTION public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint[], date) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint[], date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint[], date) TO authenticated;

-- -------------------------------------------------------------------------
-- 3. avance_metas_preventista: cada meta se mide contra SU período.
--
--    Se devuelven las metas cuyo período se solapa con el mes consultado, así
--    el dashboard sigue mostrando "los objetivos de agosto" aunque alguno sea
--    quincenal o cruce de mes.
-- -------------------------------------------------------------------------
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
  v_mes_desde   date;
  v_mes_hasta   date;
  v_min         date;
  v_max         date;
  v_nombre      text;
  v_sucursales  bigint[];
  v_result      jsonb;
  v_sin_marca   integer := 0;
  v_hay_marca   boolean := false;
BEGIN
  v_target    := COALESCE(p_preventista_id, auth.uid());
  v_mes_desde := date_trunc('month', COALESCE(p_periodo, current_date))::date;
  v_mes_hasta := (v_mes_desde + interval '1 month - 1 day')::date;

  IF v_target IS NULL THEN
    RAISE EXCEPTION 'Sin usuario' USING ERRCODE = '42501';
  END IF;

  -- El muro: un preventista sólo puede pedir lo suyo.
  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND NOT es_admin() THEN
    RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
  END IF;

  SELECT nombre INTO v_nombre FROM perfiles WHERE id = v_target;

  SELECT array_agg(DISTINCT sucursal_id), min(periodo), max(periodo_fin)
    INTO v_sucursales, v_min, v_max
  FROM metas_preventista
  WHERE preventista_id = v_target AND activo
    AND periodo <= v_mes_hasta AND periodo_fin >= v_mes_desde;

  IF v_sucursales IS NULL THEN
    RETURN jsonb_build_object(
      'preventista_id', v_target,
      'nombre', v_nombre,
      'periodo', v_mes_desde,
      'dias_transcurridos', LEAST(EXTRACT(DAY FROM current_date)::int, EXTRACT(DAY FROM v_mes_hasta)::int),
      'dias_periodo', EXTRACT(DAY FROM v_mes_hasta)::int,
      'metas', '[]'::jsonb,
      'resumen', jsonb_build_object('total', 0, 'cumplidas', 0, 'en_riesgo', 0),
      'productos_sin_marca', 0
    );
  END IF;

  WITH
  metas AS (
    SELECT * FROM metas_preventista
    WHERE preventista_id = v_target AND activo
      AND periodo <= v_mes_hasta AND periodo_fin >= v_mes_desde
  ),
  -- Cubre la unión de los períodos; cada meta filtra después por el suyo.
  ped AS MATERIALIZED (
    SELECT id, cliente_id, sucursal_id, fecha
    FROM pedidos
    WHERE usuario_id = v_target
      AND estado = 'entregado'
      AND canal = 'app'
      AND fecha BETWEEN v_min AND v_max
      AND sucursal_id = ANY(v_sucursales)
  ),
  it AS MATERIALIZED (
    SELECT p.sucursal_id, p.fecha, pi.cantidad, pi.subtotal,
           pi.producto_id, prod.categoria_id, prod.marca_id
    FROM ped p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    JOIN productos prod  ON prod.id = pi.producto_id
    WHERE pi.es_bonificacion IS NOT TRUE
  ),
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
      (m.periodo_fin - m.periodo + 1) AS dias_periodo,
      GREATEST(0, LEAST(current_date - m.periodo + 1, m.periodo_fin - m.periodo + 1)) AS dias_trans,
      CASE m.tipo_meta
        WHEN 'facturacion' THEN (
          SELECT COALESCE(SUM(i.subtotal), 0) FROM it i
          WHERE i.sucursal_id = m.sucursal_id
            AND i.fecha BETWEEN m.periodo AND m.periodo_fin
            AND (m.marca_id     IS NULL OR i.marca_id     = m.marca_id)
            AND (m.categoria_id IS NULL OR i.categoria_id = m.categoria_id)
            AND (m.producto_ids IS NULL OR i.producto_id  = ANY(m.producto_ids))
        )
        WHEN 'unidades' THEN (
          SELECT COALESCE(SUM(i.cantidad), 0) FROM it i
          WHERE i.sucursal_id = m.sucursal_id
            AND i.fecha BETWEEN m.periodo AND m.periodo_fin
            AND (m.marca_id     IS NULL OR i.marca_id     = m.marca_id)
            AND (m.categoria_id IS NULL OR i.categoria_id = m.categoria_id)
            AND (m.producto_ids IS NULL OR i.producto_id  = ANY(m.producto_ids))
        )
        WHEN 'cobertura' THEN (
          SELECT COUNT(DISTINCT p.cliente_id) FROM ped p
          WHERE p.sucursal_id = m.sucursal_id
            AND p.fecha BETWEEN m.periodo AND m.periodo_fin
        )
        WHEN 'clientes_nuevos' THEN (
          SELECT COUNT(*) FROM primer_pedido pp
          WHERE pp.sucursal_id = m.sucursal_id
            AND pp.usuario_id = v_target
            AND pp.fecha BETWEEN m.periodo AND m.periodo_fin
        )
      END AS logrado
    FROM metas m
  ),
  calc AS (
    SELECT l.*,
      ROUND(l.valor_objetivo * l.dias_trans / NULLIF(l.dias_periodo, 0), 2) AS objetivo_prorrateado,
      ROUND(100 * l.logrado / NULLIF(l.valor_objetivo, 0), 1) AS pct,
      -- Cuánto del período ya pasó. Debajo del 25% el prorrateo es ruido: con
      -- 27 de 31 días por delante, "atrasado" no informa nada.
      (l.dias_trans::numeric / NULLIF(l.dias_periodo, 0)) AS avance_periodo
    FROM logrado l
  ),
  estados AS (
    SELECT c.*,
      CASE
        WHEN c.logrado >= c.valor_objetivo THEN 'cumplida'
        WHEN c.logrado >= COALESCE(c.objetivo_prorrateado, 0) THEN 'adelantado'
        WHEN c.avance_periodo < 0.25 THEN 'en_curso'
        WHEN c.logrado >= 0.8 * COALESCE(c.objetivo_prorrateado, 0) THEN 'en_curso'
        ELSE 'en_riesgo'
      END AS estado
    FROM calc c
  )
  SELECT jsonb_build_object(
    'preventista_id', v_target,
    'nombre', v_nombre,
    'periodo', v_mes_desde,
    'dias_transcurridos', LEAST(EXTRACT(DAY FROM current_date)::int, EXTRACT(DAY FROM v_mes_hasta)::int),
    'dias_periodo', EXTRACT(DAY FROM v_mes_hasta)::int,
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
          WHEN c.producto_ids IS NOT NULL THEN jsonb_build_object(
            'tipo', 'productos', 'id', NULL,
            'nombre', CASE WHEN cardinality(c.producto_ids) = 1
              THEN (SELECT nombre FROM productos WHERE id = c.producto_ids[1])
              ELSE cardinality(c.producto_ids) || ' productos' END,
            'productos', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre) ORDER BY p.nombre), '[]'::jsonb)
                          FROM productos p WHERE p.id = ANY(c.producto_ids)))
          ELSE jsonb_build_object('tipo', 'global', 'id', NULL, 'nombre', NULL)
        END,
        'desde', c.periodo,
        'hasta', c.periodo_fin,
        'dias_periodo', c.dias_periodo,
        'dias_transcurridos', c.dias_trans,
        -- true = el período no es un mes calendario completo; la UI lo aclara.
        'periodo_personalizado', (c.periodo <> date_trunc('month', c.periodo)::date
                                  OR c.periodo_fin <> (date_trunc('month', c.periodo) + interval '1 month - 1 day')::date),
        'objetivo', c.valor_objetivo,
        'logrado', c.logrado,
        'pct', COALESCE(c.pct, 0),
        'objetivo_prorrateado', COALESCE(c.objetivo_prorrateado, 0),
        'estado', c.estado
      ) ORDER BY c.tipo_meta, c.id), '[]'::jsonb),
    'resumen', jsonb_build_object(
      'total', COUNT(*),
      'cumplidas', COUNT(*) FILTER (WHERE c.estado = 'cumplida'),
      'en_riesgo', COUNT(*) FILTER (WHERE c.estado = 'en_riesgo')
    )
  ) INTO v_result
  FROM estados c;

  SELECT EXISTS (
    SELECT 1 FROM metas_preventista
    WHERE preventista_id = v_target AND activo
      AND periodo <= v_mes_hasta AND periodo_fin >= v_mes_desde
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

-- -------------------------------------------------------------------------
-- 4. rendimiento_preventistas: incluir a quien tiene objetivos aunque no haya
--    vendido nada.
--
--    Antes la lista salía de los pedidos entregados, así que un preventista
--    sin ventas en el mes no aparecía — y con él desaparecían sus objetivos.
--    Fue justo lo que pasó al cargar el primer objetivo de prueba: estaba en
--    la base y en el dashboard, pero la pantalla de /metas no lo mostraba.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.rendimiento_preventistas(
  p_sucursal_id bigint DEFAULT NULL,
  p_periodo     date   DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_periodo    date := date_trunc('month', COALESCE(p_periodo, current_date))::date;
  v_hasta      date;
  v_sucursales bigint[];
  v_asignadas  bigint[];
  v_es_servicio boolean := auth.uid() IS NULL;
  v_result     jsonb;
BEGIN
  v_hasta := (v_periodo + interval '1 month - 1 day')::date;

  IF NOT v_es_servicio AND NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede ver el rendimiento del equipo' USING ERRCODE = '42501';
  END IF;

  IF v_es_servicio THEN
    SELECT array_agg(id) INTO v_asignadas FROM sucursales;
  ELSE
    SELECT array_agg(sucursal_id) INTO v_asignadas
    FROM usuario_sucursales WHERE usuario_id = auth.uid();
  END IF;

  IF p_sucursal_id IS NULL THEN
    v_sucursales := v_asignadas;
  ELSE
    IF NOT v_es_servicio AND NOT (p_sucursal_id = ANY(v_asignadas)) THEN
      RAISE EXCEPTION 'Acceso denegado: la sucursal % no está asignada al usuario', p_sucursal_id
        USING ERRCODE = '42501';
    END IF;
    v_sucursales := ARRAY[p_sucursal_id];
  END IF;

  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    RAISE EXCEPTION 'Acceso denegado: sin sucursales disponibles' USING ERRCODE = '42501';
  END IF;

  WITH
  ped AS MATERIALIZED (
    SELECT id, cliente_id, usuario_id, sucursal_id, total
    FROM pedidos
    WHERE estado = 'entregado' AND canal = 'app'
      AND fecha BETWEEN v_periodo AND v_hasta
      AND sucursal_id = ANY(v_sucursales)
  ),
  it AS MATERIALIZED (
    SELECT p.usuario_id, pi.cantidad, pi.subtotal,
           pi.cantidad * COALESCE(pi.costo_unitario_al_crear, prod.costo_promedio, prod.costo_real,
             prod.costo_sin_iva * (1 + COALESCE(prod.impuestos_internos, 0) / 100)) AS costo,
           COALESCE(mar.nombre, '(sin marca)')          AS marca,
           COALESCE(NULLIF(prod.categoria, ''), '(sin categoría)') AS categoria
    FROM ped p
    JOIN pedido_items pi ON pi.pedido_id = p.id
    JOIN productos prod  ON prod.id = pi.producto_id
    LEFT JOIN marcas mar ON mar.id = prod.marca_id
    WHERE pi.es_bonificacion IS NOT TRUE
  ),
  primer_pedido AS (
    SELECT DISTINCT ON (p.cliente_id, p.sucursal_id)
           p.cliente_id, p.sucursal_id, p.usuario_id, p.fecha
    FROM pedidos p
    WHERE p.estado = 'entregado' AND p.canal = 'app'
      AND p.sucursal_id = ANY(v_sucursales)
    ORDER BY p.cliente_id, p.sucursal_id, p.fecha, p.id
  ),
  metas AS (
    SELECT preventista_id, COUNT(*) AS total FROM metas_preventista
    WHERE activo AND sucursal_id = ANY(v_sucursales)
      AND periodo <= v_hasta AND periodo_fin >= v_periodo
    GROUP BY preventista_id
  ),
  -- La lista es la UNIÓN de: quien vendió, quien tiene objetivos cargados, y
  -- TODOS los preventistas de la sucursal. El panel es de seguimiento del
  -- equipo: un preventista que no vendió nada en el mes es exactamente el que
  -- hay que ver, no el que hay que esconder.
  gente AS (
    SELECT usuario_id FROM ped WHERE usuario_id IS NOT NULL
    UNION
    SELECT preventista_id FROM metas
    UNION
    SELECT us.usuario_id
    FROM usuario_sucursales us
    JOIN perfiles pf ON pf.id = us.usuario_id
    WHERE us.sucursal_id = ANY(v_sucursales)
      AND pf.rol = 'preventista'
      AND COALESCE(pf.activo, true)
  ),
  base AS (
    SELECT g.usuario_id,
           COUNT(p.id)                     AS pedidos,
           COUNT(DISTINCT p.cliente_id)    AS cobertura
    FROM gente g LEFT JOIN ped p ON p.usuario_id = g.usuario_id
    GROUP BY g.usuario_id
  ),
  items AS (
    SELECT i.usuario_id,
           COALESCE(SUM(i.subtotal), 0) AS venta,
           COALESCE(SUM(i.cantidad), 0) AS unidades,
           COALESCE(SUM(i.subtotal - i.costo), 0) AS margen_comercial
    FROM it i GROUP BY i.usuario_id
  ),
  nuevos AS (
    SELECT pp.usuario_id, COUNT(*) AS clientes_nuevos
    FROM primer_pedido pp
    WHERE pp.fecha BETWEEN v_periodo AND v_hasta
    GROUP BY pp.usuario_id
  ),
  por_marca AS (
    SELECT t.usuario_id, jsonb_agg(jsonb_build_object(
             'marca', t.marca, 'venta', t.venta, 'unidades', t.unidades
           ) ORDER BY t.venta DESC) AS detalle
    FROM (SELECT usuario_id, marca, SUM(subtotal) AS venta, SUM(cantidad) AS unidades
          FROM it GROUP BY usuario_id, marca) t
    GROUP BY t.usuario_id
  ),
  por_categoria AS (
    SELECT t.usuario_id, jsonb_agg(jsonb_build_object(
             'categoria', t.categoria, 'venta', t.venta, 'unidades', t.unidades
           ) ORDER BY t.venta DESC) AS detalle
    FROM (SELECT usuario_id, categoria, SUM(subtotal) AS venta, SUM(cantidad) AS unidades
          FROM it GROUP BY usuario_id, categoria) t
    GROUP BY t.usuario_id
  )
  SELECT jsonb_build_object(
    'periodo', v_periodo,
    'preventistas', COALESCE(jsonb_agg(jsonb_build_object(
      'preventista_id', b.usuario_id,
      'nombre', COALESCE(pf.nombre, '(sin perfil)'),
      'rol', pf.rol,
      'pedidos', b.pedidos,
      'venta', COALESCE(i.venta, 0),
      'unidades', COALESCE(i.unidades, 0),
      'margen_comercial', COALESCE(i.margen_comercial, 0),
      'cobertura', b.cobertura,
      'clientes_nuevos', COALESCE(n.clientes_nuevos, 0),
      'ticket', ROUND(COALESCE(i.venta, 0) / NULLIF(b.pedidos, 0), 2),
      'metas_cargadas', COALESCE(mt.total, 0),
      -- El avance completo viene embebido: el panel muestra objetivo, a quién
      -- está asignado y progreso sin tener que expandir ni pedir otra query
      -- por preventista. Sale del MISMO RPC que ve el preventista en su
      -- dashboard, así que los números no pueden discrepar.
      'metas', COALESCE(av.detalle -> 'metas', '[]'::jsonb),
      'resumen_metas', COALESCE(av.detalle -> 'resumen',
                                jsonb_build_object('total', 0, 'cumplidas', 0, 'en_riesgo', 0)),
      'por_marca', COALESCE(pm.detalle, '[]'::jsonb),
      'por_categoria', COALESCE(pc.detalle, '[]'::jsonb)
    ) ORDER BY COALESCE(i.venta, 0) DESC), '[]'::jsonb)
  ) INTO v_result
  FROM base b
  LEFT JOIN perfiles pf     ON pf.id = b.usuario_id
  LEFT JOIN items i         ON i.usuario_id = b.usuario_id
  LEFT JOIN nuevos n        ON n.usuario_id = b.usuario_id
  LEFT JOIN por_marca pm    ON pm.usuario_id = b.usuario_id
  LEFT JOIN por_categoria pc ON pc.usuario_id = b.usuario_id
  LEFT JOIN metas mt        ON mt.preventista_id = b.usuario_id
  -- Sólo para quien tiene objetivos: evita N llamadas inútiles.
  LEFT JOIN LATERAL (
    SELECT avance_metas_preventista(b.usuario_id, v_periodo) AS detalle
    WHERE mt.total > 0
  ) av ON true;

  RETURN v_result;
END;
$fn$;

ALTER FUNCTION public.rendimiento_preventistas(bigint, date) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.rendimiento_preventistas(bigint, date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.rendimiento_preventistas(bigint, date) TO authenticated;
