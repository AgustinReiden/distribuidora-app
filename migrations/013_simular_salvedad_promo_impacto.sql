-- Migration 013: helper dry-run para detectar promos afectadas por una salvedad
--
-- Permite al front mostrar una alerta ANTES de confirmar la salvedad cuando
-- el item afectado rompe una bonificación (la promo ya no cumple la condición
-- de compra). La lógica espejea exactamente el recalculo que hace
-- `registrar_salvedad` (migración 010) pero sin modificar nada.

CREATE OR REPLACE FUNCTION public.simular_salvedad_promo_impacto(
  p_pedido_id bigint,
  p_pedido_item_id bigint,
  p_cantidad_afectada integer
) RETURNS TABLE (
  promocion_id BIGINT,
  promo_nombre TEXT,
  bonif_actual INT,
  bonif_esperada INT,
  delta INT,
  descripcion_regalo TEXT,
  sera_eliminada BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_item RECORD;
BEGIN
  IF v_sucursal IS NULL OR p_cantidad_afectada IS NULL OR p_cantidad_afectada <= 0 THEN
    RETURN;
  END IF;

  SELECT pi.id, pi.producto_id, pi.cantidad, COALESCE(pi.es_bonificacion, FALSE) AS es_bonificacion
    INTO v_item
    FROM pedido_items pi
   WHERE pi.id = p_pedido_item_id
     AND pi.pedido_id = p_pedido_id
     AND pi.sucursal_id = v_sucursal;

  IF v_item IS NULL OR v_item.es_bonificacion THEN
    RETURN;
  END IF;

  RETURN QUERY
  WITH bonifs AS (
    SELECT pi.id, pi.producto_id, pi.cantidad, pi.promocion_id
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id
       AND pi.sucursal_id = v_sucursal
       AND COALESCE(pi.es_bonificacion, FALSE) = TRUE
       AND pi.promocion_id IS NOT NULL
  ),
  promo_info AS (
    SELECT
      b.id AS bonif_id,
      b.cantidad AS bonif_qty,
      b.promocion_id,
      p.nombre AS promo_nombre,
      p.descripcion_regalo,
      MAX(CASE WHEN pr.clave = 'cantidad_compra'       THEN pr.valor END)::INT AS cant_compra,
      MAX(CASE WHEN pr.clave = 'cantidad_bonificacion' THEN pr.valor END)::INT AS cant_bonif
    FROM bonifs b
    JOIN promociones p ON p.id = b.promocion_id AND p.sucursal_id = v_sucursal
    LEFT JOIN promocion_reglas pr ON pr.promocion_id = p.id
    GROUP BY b.id, b.cantidad, b.promocion_id, p.nombre, p.descripcion_regalo
  ),
  totales AS (
    -- Total de items disparadores de la promo (no-bonif) DESPUÉS de la salvedad
    SELECT
      pi.pedido_id, pp.promocion_id,
      SUM(
        CASE
          WHEN pi.id = p_pedido_item_id THEN GREATEST(pi.cantidad - p_cantidad_afectada, 0)
          ELSE pi.cantidad
        END
      )::INT AS total_qty_post
    FROM pedido_items pi
    JOIN promocion_productos pp ON pp.producto_id = pi.producto_id
    WHERE pi.pedido_id = p_pedido_id
      AND pi.sucursal_id = v_sucursal
      AND COALESCE(pi.es_bonificacion, FALSE) = FALSE
    GROUP BY pi.pedido_id, pp.promocion_id
  )
  SELECT
    pi.promocion_id,
    pi.promo_nombre::TEXT,
    pi.bonif_qty AS bonif_actual,
    (COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif AS bonif_esperada,
    pi.bonif_qty - ((COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif) AS delta,
    pi.descripcion_regalo,
    ((COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif) = 0 AS sera_eliminada
  FROM promo_info pi
  LEFT JOIN totales t ON t.promocion_id = pi.promocion_id
  WHERE pi.cant_compra IS NOT NULL AND pi.cant_compra > 0
    AND pi.cant_bonif  IS NOT NULL AND pi.cant_bonif  > 0
    AND pi.bonif_qty > ((COALESCE(t.total_qty_post, 0) / NULLIF(pi.cant_compra, 0)) * pi.cant_bonif);
END;
$$;

REVOKE ALL ON FUNCTION public.simular_salvedad_promo_impacto(bigint, bigint, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.simular_salvedad_promo_impacto(bigint, bigint, integer) TO authenticated;
