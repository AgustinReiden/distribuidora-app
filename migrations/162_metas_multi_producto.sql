-- =========================================================================
-- 162_metas_multi_producto.sql
--
-- "Estaría bueno poder crear un objetivo por producto y múltiples productos,
--  seleccionando los que se incluyen."
--
-- La mig 159 dejó `producto_id bigint` (un solo producto). En la práctica los
-- objetivos son sobre un conjunto: "las gaseosas de 3 litros" son varios
-- SKUs (sabores) y no siempre coinciden con una categoría entera.
--
-- `producto_id` se reemplaza por `producto_ids bigint[]`. La alternativa era
-- una tabla hija, pero rompe dos cosas que hoy funcionan: el índice único con
-- COALESCE (que es lo que habilita el upsert de guardar_meta_preventista) y
-- los CHECK de alcance único, que pasarían a depender de otra tabla. Con el
-- array, "sin productos" sigue siendo un valor comparable y el upsert vive.
--
-- Se pierde la FK: si alguien borra un producto, su id queda colgado en el
-- array. Es aceptable — un producto borrado simplemente deja de matchear y el
-- objetivo mide de menos; la UI muestra los que existen. A cambio, el RPC
-- valida al guardar que los productos sean de la sucursal de la meta.
--
-- El array se guarda ORDENADO y sin duplicados: sin eso {12,7} y {7,12} son
-- claves distintas para el índice único y se duplicaría el mismo objetivo.
--
-- La tabla está vacía en prod (0 filas), así que el cambio de columna no
-- migra datos.
--
-- NOTA sobre bonificaciones: no hace falta tocar nada. avance_metas_preventista
-- y rendimiento_preventistas ya filtran `es_bonificacion IS NOT TRUE`, así que
-- los regalos de promoción (2.775 unidades y $0 desde junio) nunca sumaron ni
-- en pesos ni en unidades.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1. Columna nueva y baja de la vieja
-- -------------------------------------------------------------------------
ALTER TABLE public.metas_preventista
  ADD COLUMN IF NOT EXISTS producto_ids bigint[];

-- Los CHECK y el índice viejos referencian producto_id: hay que soltarlos
-- antes de dropear la columna.
ALTER TABLE public.metas_preventista
  DROP CONSTRAINT IF EXISTS metas_preventista_alcance_unico,
  DROP CONSTRAINT IF EXISTS metas_preventista_alcance_valido,
  DROP CONSTRAINT IF EXISTS metas_preventista_unidades_check;

DROP INDEX IF EXISTS public.metas_preventista_uidx;

ALTER TABLE public.metas_preventista DROP COLUMN IF EXISTS producto_id;

COMMENT ON COLUMN public.metas_preventista.producto_ids IS
  'Productos incluidos en el objetivo. NULL = no acota por producto. Siempre ordenado y sin duplicados (lo normaliza guardar_meta_preventista) para que el índice único no vea {7,12} y {12,7} como distintos. Sin FK a propósito: ver mig 162.';

-- -------------------------------------------------------------------------
-- 2. CHECKs equivalentes, con el array en lugar de la columna
-- -------------------------------------------------------------------------
ALTER TABLE public.metas_preventista
  ADD CONSTRAINT metas_preventista_alcance_unico CHECK (
    (marca_id IS NOT NULL)::int
    + (categoria_id IS NOT NULL)::int
    + (producto_ids IS NOT NULL)::int <= 1
  ),
  -- Un array vacío es "acota por producto pero por ninguno": mide siempre 0.
  ADD CONSTRAINT metas_preventista_productos_no_vacio CHECK (
    producto_ids IS NULL OR cardinality(producto_ids) > 0
  ),
  ADD CONSTRAINT metas_preventista_alcance_valido CHECK (
    tipo_meta IN ('facturacion', 'unidades')
    OR (marca_id IS NULL AND categoria_id IS NULL AND producto_ids IS NULL)
  ),
  ADD CONSTRAINT metas_preventista_unidades_check CHECK (
    tipo_meta <> 'unidades'
    OR marca_id IS NOT NULL OR categoria_id IS NOT NULL OR producto_ids IS NOT NULL
  );

CREATE UNIQUE INDEX IF NOT EXISTS metas_preventista_uidx
  ON public.metas_preventista (
    preventista_id, periodo, tipo_meta,
    COALESCE(marca_id, '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(categoria_id, '00000000-0000-0000-0000-000000000000'::uuid),
    COALESCE(producto_ids, '{}'::bigint[])
  );

-- -------------------------------------------------------------------------
-- 3. guardar_meta_preventista: p_producto_ids en lugar de p_producto_id.
--    Cambia la firma, así que hay que dropear la vieja.
-- -------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint);

CREATE OR REPLACE FUNCTION public.guardar_meta_preventista(
  p_id             bigint,
  p_sucursal_id    bigint,
  p_preventista_id uuid,
  p_periodo        date,
  p_tipo_meta      text,
  p_valor_objetivo numeric,
  p_marca_id       uuid     DEFAULT NULL,
  p_categoria_id   uuid     DEFAULT NULL,
  p_producto_ids   bigint[] DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_id        bigint;
  v_periodo   date := date_trunc('month', COALESCE(p_periodo, current_date))::date;
  v_productos bigint[];
  v_ajenos    integer;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede definir objetivos' USING ERRCODE = '42501';
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

  -- Normalizar: ordenado, sin duplicados, NULL si viene vacío.
  IF p_producto_ids IS NOT NULL AND cardinality(p_producto_ids) > 0 THEN
    SELECT array_agg(DISTINCT x ORDER BY x) INTO v_productos
    FROM unnest(p_producto_ids) AS x;

    -- Un producto de otra sucursal no vende nunca acá: la meta mediría 0 y
    -- nadie entendería por qué.
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
      sucursal_id, preventista_id, periodo, tipo_meta,
      marca_id, categoria_id, producto_ids, valor_objetivo, usuario_id
    ) VALUES (
      p_sucursal_id, p_preventista_id, v_periodo, p_tipo_meta,
      p_marca_id, p_categoria_id, v_productos, p_valor_objetivo, auth.uid()
    )
    ON CONFLICT (
      preventista_id, periodo, tipo_meta,
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
      periodo        = v_periodo,
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

ALTER FUNCTION public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.guardar_meta_preventista(bigint, bigint, uuid, date, text, numeric, uuid, uuid, bigint[]) TO authenticated;

-- -------------------------------------------------------------------------
-- 4. avance_metas_preventista: matchear contra el array.
--    Sólo cambian el filtro de alcance y la etiqueta; el resto es la mig 160.
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

  -- El muro: un preventista sólo puede pedir lo suyo.
  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND NOT es_admin() THEN
    RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
  END IF;

  SELECT nombre INTO v_nombre FROM perfiles WHERE id = v_target;

  v_dias_total := EXTRACT(DAY FROM v_hasta)::integer;
  v_dias_trans := CASE
    WHEN current_date > v_hasta   THEN v_dias_total
    WHEN current_date < v_periodo THEN 0
    ELSE EXTRACT(DAY FROM current_date)::integer
  END;

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
  ped AS MATERIALIZED (
    SELECT id, cliente_id, sucursal_id
    FROM pedidos
    WHERE usuario_id = v_target
      AND estado = 'entregado'
      AND canal = 'app'
      AND fecha BETWEEN v_periodo AND v_hasta
      AND sucursal_id = ANY(v_sucursales)
  ),
  -- Los regalos de promoción quedan afuera acá: no suman ni unidades ni pesos.
  it AS MATERIALIZED (
    SELECT p.sucursal_id, pi.cantidad, pi.subtotal,
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
      CASE m.tipo_meta
        WHEN 'facturacion' THEN (
          SELECT COALESCE(SUM(i.subtotal), 0) FROM it i
          WHERE i.sucursal_id = m.sucursal_id
            AND (m.marca_id     IS NULL OR i.marca_id     = m.marca_id)
            AND (m.categoria_id IS NULL OR i.categoria_id = m.categoria_id)
            AND (m.producto_ids IS NULL OR i.producto_id  = ANY(m.producto_ids))
        )
        WHEN 'unidades' THEN (
          SELECT COALESCE(SUM(i.cantidad), 0) FROM it i
          WHERE i.sucursal_id = m.sucursal_id
            AND (m.marca_id     IS NULL OR i.marca_id     = m.marca_id)
            AND (m.categoria_id IS NULL OR i.categoria_id = m.categoria_id)
            AND (m.producto_ids IS NULL OR i.producto_id  = ANY(m.producto_ids))
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
          WHEN c.producto_ids IS NOT NULL THEN jsonb_build_object(
            'tipo', 'productos', 'id', NULL,
            -- Un solo producto: su nombre. Varios: el conteo, porque la lista
            -- entera no entra en una barra de progreso.
            'nombre', CASE WHEN cardinality(c.producto_ids) = 1
              THEN (SELECT nombre FROM productos WHERE id = c.producto_ids[1])
              ELSE cardinality(c.producto_ids) || ' productos' END,
            'productos', (SELECT COALESCE(jsonb_agg(jsonb_build_object('id', p.id, 'nombre', p.nombre) ORDER BY p.nombre), '[]'::jsonb)
                          FROM productos p WHERE p.id = ANY(c.producto_ids)))
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
