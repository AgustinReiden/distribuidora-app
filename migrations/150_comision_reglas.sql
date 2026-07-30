-- =========================================================================
-- 150_comision_reglas.sql
--
-- Comisiones variables. Hoy el % es un `useState(2)` en VistaComisiones: se
-- tipea a mano, no se guarda, y no distingue una venta a precio de lista de
-- una con descuento por volumen —que es justamente lo que el dueño quiere
-- premiar distinto—.
--
-- Fase 1 usa sólo `preventista_id` + `origen_precio`: el "% base" es la regla
-- con origen_precio NULL y el "% reducido" la que tiene 'mayorista'. Las
-- columnas producto_id/categoria_id quedan listas para la fase 2 sin tocar el
-- schema — ahí se cobra el dividendo de haber normalizado categorías (mig 145).
--
-- Sigue el precedente de `metas_gerenciales` (mig 108): sucursal_id NULL = toda
-- la red, lectura por RLS admin, escritura sólo por RPC SECURITY DEFINER.
--
-- VIGENCIA POR FECHA: cambiar el % en septiembre no recalcula agosto. Se evalúa
-- contra `pedidos.fecha`, no contra now().
-- =========================================================================

CREATE TABLE IF NOT EXISTS public.comision_reglas (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sucursal_id    bigint REFERENCES sucursales(id),   -- NULL = toda la red
  preventista_id uuid   REFERENCES perfiles(id),     -- NULL = todos
  origen_precio  varchar(20),                        -- NULL = cualquiera
  producto_id    bigint REFERENCES productos(id),    -- NULL = cualquiera (fase 2)
  categoria_id   uuid   REFERENCES categorias(id),   -- NULL = cualquiera (fase 2)
  porcentaje     numeric(5,2) NOT NULL CHECK (porcentaje BETWEEN 0 AND 100),
  activo         boolean NOT NULL DEFAULT true,
  vigente_desde  date NOT NULL DEFAULT current_date,
  vigente_hasta  date,
  usuario_id     uuid,
  created_at     timestamptz DEFAULT now(),
  CONSTRAINT comision_reglas_origen_check CHECK (
    origen_precio IS NULL OR origen_precio IN (
      'lista', 'mayorista', 'desc_cliente', 'desc_categoria',
      'manual', 'bonificacion', 'desconocido'
    )
  ),
  CONSTRAINT comision_reglas_vigencia_check CHECK (
    vigente_hasta IS NULL OR vigente_hasta >= vigente_desde
  )
);

COMMENT ON TABLE public.comision_reglas IS
  'Reglas de comision por preventista/origen del precio (fase 2: producto/categoria). NULL en una dimension = "cualquiera". Mig 150.';

CREATE INDEX IF NOT EXISTS comision_reglas_lookup_idx
  ON public.comision_reglas (activo, vigente_desde, vigente_hasta);

ALTER TABLE public.comision_reglas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS comision_reglas_admin_select ON public.comision_reglas;
CREATE POLICY comision_reglas_admin_select ON public.comision_reglas
  FOR SELECT TO authenticated
  USING (EXISTS (SELECT 1 FROM perfiles WHERE id = auth.uid() AND rol = 'admin'));

-- -------------------------------------------------------------------------
-- Alta/edición y baja (admin-only)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.guardar_comision_regla(
  p_id             bigint,
  p_sucursal_id    bigint,
  p_preventista_id uuid,
  p_origen_precio  text,
  p_porcentaje     numeric,
  p_vigente_desde  date DEFAULT NULL,
  p_vigente_hasta  date DEFAULT NULL,
  p_producto_id    bigint DEFAULT NULL,
  p_categoria_id   uuid DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_id bigint;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede definir reglas de comision' USING ERRCODE = '42501';
  END IF;

  IF p_porcentaje IS NULL OR p_porcentaje < 0 OR p_porcentaje > 100 THEN
    RAISE EXCEPTION 'El porcentaje debe estar entre 0 y 100';
  END IF;

  IF p_id IS NULL THEN
    INSERT INTO comision_reglas (
      sucursal_id, preventista_id, origen_precio, producto_id, categoria_id,
      porcentaje, vigente_desde, vigente_hasta, usuario_id
    ) VALUES (
      p_sucursal_id, p_preventista_id, NULLIF(p_origen_precio, ''), p_producto_id, p_categoria_id,
      p_porcentaje, COALESCE(p_vigente_desde, current_date), p_vigente_hasta, auth.uid()
    )
    RETURNING id INTO v_id;
  ELSE
    UPDATE comision_reglas SET
      sucursal_id    = p_sucursal_id,
      preventista_id = p_preventista_id,
      origen_precio  = NULLIF(p_origen_precio, ''),
      producto_id    = p_producto_id,
      categoria_id   = p_categoria_id,
      porcentaje     = p_porcentaje,
      vigente_desde  = COALESCE(p_vigente_desde, vigente_desde),
      vigente_hasta  = p_vigente_hasta
    WHERE id = p_id
    RETURNING id INTO v_id;

    IF v_id IS NULL THEN
      RAISE EXCEPTION 'La regla % no existe', p_id USING ERRCODE = 'no_data_found';
    END IF;
  END IF;

  RETURN v_id;
END;
$fn$;

ALTER FUNCTION public.guardar_comision_regla(bigint, bigint, uuid, text, numeric, date, date, bigint, uuid) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.guardar_comision_regla(bigint, bigint, uuid, text, numeric, date, date, bigint, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.guardar_comision_regla(bigint, bigint, uuid, text, numeric, date, date, bigint, uuid) TO authenticated;

-- Baja lógica: una regla borrada de verdad reescribiría el pasado, porque el
-- cálculo se resuelve contra la fecha del pedido cada vez que se consulta.
CREATE OR REPLACE FUNCTION public.desactivar_comision_regla(p_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede dar de baja reglas de comision' USING ERRCODE = '42501';
  END IF;
  UPDATE comision_reglas SET activo = false WHERE id = p_id;
END;
$fn$;

ALTER FUNCTION public.desactivar_comision_regla(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.desactivar_comision_regla(bigint) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.desactivar_comision_regla(bigint) TO authenticated;

-- -------------------------------------------------------------------------
-- Cálculo
--
-- La base replica EXACTAMENTE la de `reporte_gerencial.base_comision`
-- (`estado <> 'cancelado' AND canal = 'app'`), que es el fin de COMIS-04: hoy
-- VistaComisiones usa `calcularReportePreventistas`, que no filtra canal, y las
-- dos fórmulas coinciden de casualidad. Se verificó contra prod que sumar
-- `pedido_items.subtotal` (sin bonificaciones) da el mismo peso que sumar
-- `pedidos.total`, así que bajar al ítem no cambia el total, sólo lo desglosa.
--
-- PRECEDENCIA: gana la regla más específica que matchea, por
--   preventista(8) + producto(4) + categoria(2) + origen_precio(1).
-- La sucursal NO entra en el score (así una regla de red para un preventista no
-- pierde contra una genérica de sucursal); se usa sólo como desempate, donde la
-- regla con sucursal explícita le gana a la de red. Después, `vigente_desde` más
-- reciente y por último id mayor.
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.calcular_comisiones(
  p_desde        date,
  p_hasta        date,
  p_sucursal_ids bigint[] DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  -- Sin regla que matchee se usa este %, que es el que la pantalla venía
  -- aplicando a mano. Así activar la feature no cambia ningún número.
  c_default    numeric := 2;
  v_sucursales bigint[];
  v_out        jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede ver el calculo de comisiones' USING ERRCODE = '42501';
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN
    RAISE EXCEPTION 'Rango de fechas invalido';
  END IF;

  -- Sin sucursales explícitas: las que el admin tiene asignadas.
  v_sucursales := COALESCE(
    p_sucursal_ids,
    ARRAY(SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = auth.uid())
  );
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    v_sucursales := ARRAY(SELECT id FROM sucursales);
  END IF;

  WITH ped AS (
    SELECT p.id, p.usuario_id, p.fecha, p.sucursal_id
    FROM pedidos p
    WHERE p.estado <> 'cancelado'
      AND p.canal = 'app'
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND p.sucursal_id = ANY(v_sucursales)
      AND p.usuario_id IN (SELECT id FROM perfiles)
  ),
  it AS (
    SELECT ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal,
           pi.producto_id,
           pi.origen_precio,
           prod.categoria_id
    FROM ped
    JOIN pedido_items pi ON pi.pedido_id = ped.id
    LEFT JOIN productos prod ON prod.id = pi.producto_id
    WHERE COALESCE(pi.es_bonificacion, false) = false
  ),
  con_pct AS (
    SELECT it.*,
      COALESCE((
        SELECT r.porcentaje FROM comision_reglas r
        WHERE r.activo
          AND (r.sucursal_id    IS NULL OR r.sucursal_id    = it.sucursal_id)
          AND (r.preventista_id IS NULL OR r.preventista_id = it.usuario_id)
          AND (r.origen_precio  IS NULL OR r.origen_precio  = it.origen_precio)
          AND (r.producto_id    IS NULL OR r.producto_id    = it.producto_id)
          AND (r.categoria_id   IS NULL OR r.categoria_id   = it.categoria_id)
          AND r.vigente_desde <= it.fecha
          AND (r.vigente_hasta IS NULL OR r.vigente_hasta >= it.fecha)
        ORDER BY
          (CASE WHEN r.preventista_id IS NOT NULL THEN 8 ELSE 0 END
         + CASE WHEN r.producto_id    IS NOT NULL THEN 4 ELSE 0 END
         + CASE WHEN r.categoria_id   IS NOT NULL THEN 2 ELSE 0 END
         + CASE WHEN r.origen_precio  IS NOT NULL THEN 1 ELSE 0 END) DESC,
          (r.sucursal_id IS NOT NULL) DESC,
          r.vigente_desde DESC,
          r.id DESC
        LIMIT 1
      ), c_default) AS pct
    FROM it
  ),
  por_origen AS (
    SELECT usuario_id,
           COALESCE(origen_precio, 'sin_dato') AS origen,
           SUM(subtotal)                 AS base,
           SUM(subtotal * pct / 100.0)   AS comision,
           COUNT(*)                      AS items
    FROM con_pct
    GROUP BY usuario_id, COALESCE(origen_precio, 'sin_dato')
  ),
  por_preventista AS (
    SELECT c.usuario_id,
           COALESCE(pf.nombre, 'Sin nombre')                                  AS nombre,
           pf.email,
           SUM(c.subtotal)                                                    AS base,
           SUM(c.subtotal * c.pct / 100.0)                                    AS comision,
           COUNT(*)                                                           AS items,
           COUNT(*) FILTER (WHERE c.origen_precio IS NULL)                    AS items_sin_desglose,
           COALESCE(SUM(c.subtotal) FILTER (WHERE c.origen_precio IS NULL),0) AS base_sin_desglose
    FROM con_pct c
    LEFT JOIN perfiles pf ON pf.id = c.usuario_id
    GROUP BY c.usuario_id, pf.nombre, pf.email
  )
  SELECT jsonb_build_object(
    'desde', p_desde,
    'hasta', p_hasta,
    'comision_default', c_default,
    'preventistas', COALESCE((
      SELECT jsonb_agg(x ORDER BY (x->>'base')::numeric DESC)
      FROM (
        SELECT jsonb_build_object(
          'id', pp.usuario_id,
          'nombre', pp.nombre,
          'email', pp.email,
          'base', ROUND(pp.base, 2),
          'comision', ROUND(pp.comision, 2),
          'items', pp.items,
          'items_sin_desglose', pp.items_sin_desglose,
          'base_sin_desglose', ROUND(pp.base_sin_desglose, 2),
          'por_origen', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
              'origen', po.origen,
              'base', ROUND(po.base, 2),
              'comision', ROUND(po.comision, 2),
              'items', po.items
            ) ORDER BY po.base DESC)
            FROM por_origen po WHERE po.usuario_id = pp.usuario_id
          ), '[]'::jsonb)
        ) AS x
        FROM por_preventista pp
      ) s
    ), '[]'::jsonb),
    'totales', (
      SELECT jsonb_build_object(
        'base', COALESCE(ROUND(SUM(base), 2), 0),
        'comision', COALESCE(ROUND(SUM(comision), 2), 0),
        'items', COALESCE(SUM(items), 0),
        'items_sin_desglose', COALESCE(SUM(items_sin_desglose), 0),
        'base_sin_desglose', COALESCE(ROUND(SUM(base_sin_desglose), 2), 0)
      ) FROM por_preventista
    )
  ) INTO v_out;

  RETURN v_out;
END;
$fn$;

ALTER FUNCTION public.calcular_comisiones(date, date, bigint[]) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.calcular_comisiones(date, date, bigint[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.calcular_comisiones(date, date, bigint[]) TO authenticated;

COMMENT ON FUNCTION public.calcular_comisiones(date, date, bigint[]) IS
  'Comision por preventista con desglose por origen del precio y conteo de items sin desglose. Misma base que reporte_gerencial.base_comision. Mig 150.';
