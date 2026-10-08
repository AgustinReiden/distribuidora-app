-- ============================================================================
-- 309 — el vale blanco no comisiona
-- ============================================================================
-- El vale blanco es consumo interno entre empresas propias (Comercial TP, los
-- Refugio, Crecer Tucumán, "pérdidas y otros"): no es una venta que alguien
-- haya salido a hacer, y no comisiona para nadie. `calcular_comisiones` no lo
-- miraba, así que a quien cargaba esos pedidos se le sumaban a la base — en
-- septiembre de 2026, 224.530 a un preventista y ~3,9 M a encargado/admin.
--
-- Cómo se reconoce: por el PAGO, no por `pedidos.forma_pago`. El pedido nace
-- con la forma que pone el preventista (casi siempre 'efectivo') y el vale se
-- registra al cobrar: de los 195 pedidos con vale blanco que había al escribir
-- esto, 175 decían 'efectivo' en el pedido. Se miran las dos señales igual.
--
-- Se excluye el pedido entero. Hoy no hay ninguno pagado en parte con vale y en
-- parte con otra cosa; si apareciera, es el cliente interno el que lo define,
-- no la proporción.
--
-- Sólo cambia el CTE `ped`; el resto es copia literal de la versión vigente.
-- Esto toca la COMISIÓN, no la definición de "venta por vendedor" (mig 241):
-- los reportes de venta siguen viendo estos pedidos.
-- ============================================================================

CREATE OR REPLACE FUNCTION public.calcular_comisiones(p_desde date, p_hasta date, p_sucursal_ids bigint[] DEFAULT NULL::bigint[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursales bigint[];
  v_pct_prev   numeric;
  v_pct_otros  numeric;
  v_out        jsonb;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede ver el calculo de comisiones' USING ERRCODE = '42501';
  END IF;

  IF p_desde IS NULL OR p_hasta IS NULL OR p_hasta < p_desde THEN
    RAISE EXCEPTION 'Rango de fechas invalido';
  END IF;

  v_sucursales := COALESCE(
    p_sucursal_ids,
    ARRAY(SELECT sucursal_id FROM usuario_sucursales WHERE usuario_id = auth.uid())
  );
  IF v_sucursales IS NULL OR array_length(v_sucursales, 1) IS NULL THEN
    v_sucursales := ARRAY(SELECT id FROM sucursales);
  END IF;

  SELECT COALESCE(MAX(pc.comision_pct_preventista), 2),
         COALESCE(MAX(pc.comision_pct_otros), 0)
    INTO v_pct_prev, v_pct_otros
    FROM politicas_comerciales pc
   WHERE pc.sucursal_id = ANY(v_sucursales);
  v_pct_prev  := COALESCE(v_pct_prev, 2);
  v_pct_otros := COALESCE(v_pct_otros, 0);

  WITH ped AS (
    SELECT p.id, p.usuario_id, p.fecha, p.sucursal_id
    FROM pedidos p
    WHERE p.estado = 'entregado'
      AND p.canal <> 'cambio'
      AND p.fecha BETWEEN p_desde AND p_hasta
      AND p.sucursal_id = ANY(v_sucursales)
      AND p.usuario_id IN (SELECT id FROM perfiles)
      -- Vale blanco: consumo interno, no comisiona (mig 309).
      AND COALESCE(p.forma_pago, '') <> 'vale_blanco'
      AND NOT EXISTS (
        SELECT 1 FROM pagos g
        WHERE g.pedido_id = p.id AND g.forma_pago = 'vale_blanco'
      )
  ),
  it AS (
    SELECT ped.usuario_id, ped.fecha, ped.sucursal_id,
           pi.subtotal,
           pi.producto_id,
           pi.origen_precio,
           prod.categoria_id,
           perf.rol AS rol_vendedor
    FROM ped
    JOIN pedido_items pi ON pi.pedido_id = ped.id
    LEFT JOIN productos prod ON prod.id = pi.producto_id
    LEFT JOIN perfiles perf ON perf.id = ped.usuario_id
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
      ),
      CASE WHEN it.rol_vendedor = 'preventista'
           THEN COALESCE(pc.comision_pct_preventista, 2)
           ELSE COALESCE(pc.comision_pct_otros, 0)
      END) AS pct
    FROM it
    LEFT JOIN politicas_comerciales pc ON pc.sucursal_id = it.sucursal_id
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
    'comision_default', v_pct_prev,
    'comision_pct_preventista', v_pct_prev,
    'comision_pct_otros', v_pct_otros,
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
$function$;
