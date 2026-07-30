-- ============================================================================
-- 136 · CORRECCION del backfill de fecha_entrega (mig 133)
-- ============================================================================
-- QUE SALIO MAL EN LA 133:
--   El backfill priorizo `MIN(pagos.fecha)` como fecha de entrega. Eso alinea
--   por definicion la entrega con el dia del cobro, con lo cual TODA venta vieja
--   cobrada despues quedaba clasificada como "Entregas (cobro del dia)" (verde)
--   y desaparecia del cuadro "Ctas Ctes" (azul).
--
--   Caso que lo detecto (reportado por Taco Pozo): pedido #3892, vendido el
--   20/07, entregado realmente el 21/07 y cobrado el 22/07. La 133 le puso
--   fecha_entrega = 22/07 -> aparecia en verde. Corresponde azul (cta cte).
--
--   Alcance medido: 1.380 pedidos / ~$49,2M mal clasificados como verde.
--
-- FUENTE CORRECTA: `pedido_historial` guarda el instante real del cambio de
-- estado a 'entregado' (campo_modificado='estado', valor_nuevo='entregado').
-- Existe para el 100% de los pedidos entregados (3.527/3.527 verificado).
--
-- QUE CORRIGE ESTA MIGRACION (y que NO):
--   SI  · pedidos cuya fecha_entrega quedo igual al dia del 1er pago (grupo A,
--         1.380) o igual al dia de creacion (grupo B, 55) Y difiere del
--         historial. Son inequivocamente los que decidio la heuristica de 133.
--   NO  · los ~52 restantes que difieren del historial por otra causa: son
--         entregas masivas donde el encargado eligio una fecha contable
--         retroactiva a proposito (`marcar_entregas_masivo(p_fecha)`). Ahi la
--         fecha elegida es la correcta, no la del historial.
--
-- Se ancla a MEDIODIA AR a proposito: la RPC de rendiciones hace
-- `fecha_entrega::date`, que castea con el timezone de la sesion (UTC en
-- Supabase). Guardar el instante crudo haria que una entrega de las 22:00 AR
-- caiga al dia siguiente. Mediodia AR nunca cruza de dia.
-- ============================================================================

-- El trigger trg_pedidos_anular_control BORRA la fila de rendiciones_control
-- cuando cambia fecha_entrega. Sin deshabilitarlo, este UPDATE destruiria las
-- ~89 rendiciones ya cerradas y ademas bajaria el techo del guard de caja
-- (mig 134, ultima_fecha_caja_cerrada). Transaccional: si algo falla, el
-- rollback deja el trigger habilitado.
ALTER TABLE public.pedidos DISABLE TRIGGER trg_pedidos_anular_control;

WITH h AS (
  SELECT pedido_id, MAX(created_at) AS entregado_at
  FROM public.pedido_historial
  WHERE campo_modificado = 'estado' AND valor_nuevo = 'entregado'
  GROUP BY pedido_id
), pp AS (
  SELECT pedido_id, MIN(fecha) AS primer_pago
  FROM public.pagos WHERE pedido_id IS NOT NULL GROUP BY pedido_id
), objetivo AS (
  SELECT p.id,
         (h.entregado_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date AS fecha_real
  FROM public.pedidos p
  JOIN h ON h.pedido_id = p.id
  LEFT JOIN pp ON pp.pedido_id = p.id
  WHERE p.estado = 'entregado'
    AND p.fecha_entrega::date IS DISTINCT FROM (h.entregado_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
    AND (
      -- grupo A: la 133 lo alineo al dia del primer pago
      (pp.primer_pago IS NOT NULL AND p.fecha_entrega::date = pp.primer_pago)
      -- grupo B: la 133 cayo al fallback created_at
      OR p.fecha_entrega::date = (p.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
    )
)
UPDATE public.pedidos p
SET fecha_entrega = (o.fecha_real::text || ' 12:00:00 America/Argentina/Buenos_Aires')::timestamptz
FROM objetivo o
WHERE p.id = o.id;

ALTER TABLE public.pedidos ENABLE TRIGGER trg_pedidos_anular_control;
