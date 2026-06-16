-- Migración 088: unificar asignación + edición in-place de la ruta del día
--
-- Contexto: "Asignar transportista" y "Armar ruta del día" eran redundantes y se
-- podían crear rutas duplicadas. Ahora todo se hace al armar la ruta.
--
-- Cambios sobre 084 (aplicar_orden_ruta):
-- 1) ASIGNA el transportista y marca los pedidos como 'asignado' (en camino),
--    además de setear orden_entrega. Antes esto se hacía aparte (Asignar
--    Transportista) y el RPC solo tocaba orden_entrega.
-- 2) Edición IN-PLACE: si ya existe un recorrido 'en_curso' para
--    (transportista, fecha, sucursal) se ACTUALIZA ese mismo recorrido (no se
--    cancela ni se crea otro). Las paradas quitadas vuelven a estar disponibles
--    (estado 'en_preparacion', sin transportista) salvo que ya estén entregadas.
-- 3) Índice único parcial: a lo sumo un recorrido 'en_curso' por
--    (transportista, fecha, sucursal).
--
-- Aplicada en prod el 2026-06-16 vía MCP (apply_migration: aplicar_orden_ruta_unifica)
-- y verificada: índice uq_recorrido_vigente creado, RPC asigna 'asignado' + upsert
-- de paradas. La definición viva previa coincidía con 084 y no había duplicados en_curso.

DROP FUNCTION IF EXISTS public.aplicar_orden_ruta(uuid, jsonb, numeric, integer, jsonb, date);

CREATE OR REPLACE FUNCTION public.aplicar_orden_ruta(
  p_transportista_id uuid,
  p_pedidos jsonb,
  p_distancia numeric DEFAULT NULL,
  p_duracion integer DEFAULT NULL,
  p_polylines jsonb DEFAULT NULL,
  p_fecha date DEFAULT NULL
) RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_fecha date := COALESCE(p_fecha, CURRENT_DATE);
  v_item jsonb;
  v_recorrido_id BIGINT;
  v_nuevos BIGINT[];
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'No autorizado para aplicar orden de ruta' USING ERRCODE = '42501';
  END IF;

  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Sucursal no resuelta para el usuario actual';
  END IF;

  IF p_pedidos IS NULL OR jsonb_array_length(p_pedidos) = 0 THEN
    RAISE EXCEPTION 'No hay pedidos para aplicar orden';
  END IF;

  -- IDs de los pedidos de la nueva ruta
  SELECT array_agg((value->>'pedido_id')::BIGINT)
    INTO v_nuevos
  FROM jsonb_array_elements(p_pedidos);

  -- Recorrido vigente de ESA fecha (si lo hay): se edita in-place
  SELECT id INTO v_recorrido_id
  FROM recorridos
  WHERE transportista_id = p_transportista_id
    AND fecha = v_fecha
    AND estado = 'en_curso'
    AND sucursal_id = v_sucursal
  ORDER BY created_at DESC
  LIMIT 1;

  -- 1. Paradas quitadas (estaban en el recorrido y ya no vienen):
  --    - Si seguían 'asignado': vuelven a disponible (en_preparacion, sin transportista).
  --    - Se sacan de la ruta salvo que ya estén entregadas (se conservan como histórico).
  IF v_recorrido_id IS NOT NULL THEN
    UPDATE pedidos p
    SET estado = 'en_preparacion',
        transportista_id = NULL,
        orden_entrega = NULL
    FROM recorrido_pedidos rp
    WHERE rp.recorrido_id = v_recorrido_id
      AND rp.pedido_id = p.id
      AND p.sucursal_id = v_sucursal
      AND p.estado = 'asignado'
      AND NOT (rp.pedido_id = ANY(v_nuevos));

    DELETE FROM recorrido_pedidos rp
    USING pedidos p
    WHERE rp.recorrido_id = v_recorrido_id
      AND rp.pedido_id = p.id
      AND p.estado <> 'entregado'
      AND NOT (rp.pedido_id = ANY(v_nuevos));
  END IF;

  -- 2. Asignar transportista + marcar en camino + setear orden de entrega
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_pedidos) LOOP
    UPDATE pedidos
    SET transportista_id = p_transportista_id,
        estado = 'asignado',
        orden_entrega = (v_item->>'orden_entrega')::INTEGER
    WHERE id = (v_item->>'pedido_id')::BIGINT
      AND sucursal_id = v_sucursal;
  END LOOP;

  -- 3. Upsert del recorrido (mismo id si ya existía; sin duplicar)
  IF v_recorrido_id IS NULL THEN
    INSERT INTO recorridos
      (transportista_id, fecha, distancia_total, duracion_total, total_pedidos,
       total_facturado, estado, sucursal_id, polylines)
    VALUES
      (p_transportista_id, v_fecha, p_distancia, p_duracion,
       jsonb_array_length(p_pedidos), 0, 'en_curso', v_sucursal, p_polylines)
    RETURNING id INTO v_recorrido_id;
  ELSE
    UPDATE recorridos
    SET distancia_total = p_distancia,
        duracion_total = p_duracion,
        polylines = p_polylines,
        estado = 'en_curso'
    WHERE id = v_recorrido_id;
  END IF;

  -- 4. Upsert de paradas (preserva estado_entrega/hora_entrega de las que siguen)
  INSERT INTO recorrido_pedidos (recorrido_id, pedido_id, orden_entrega, sucursal_id)
  SELECT v_recorrido_id,
         (value->>'pedido_id')::BIGINT,
         (value->>'orden_entrega')::INTEGER,
         v_sucursal
  FROM jsonb_array_elements(p_pedidos)
  ON CONFLICT (recorrido_id, pedido_id)
  DO UPDATE SET orden_entrega = EXCLUDED.orden_entrega;

  -- 5. Recalcular totales desde las paradas finales (cubre el caso de paradas
  --    entregadas que se conservan aunque no vengan en p_pedidos).
  UPDATE recorridos r
  SET total_pedidos = sub.cnt,
      total_facturado = sub.fact
  FROM (
    SELECT COUNT(*) AS cnt, COALESCE(SUM(p.total), 0) AS fact
    FROM recorrido_pedidos rp
    JOIN pedidos p ON p.id = rp.pedido_id
    WHERE rp.recorrido_id = v_recorrido_id
  ) sub
  WHERE r.id = v_recorrido_id;

  RETURN v_recorrido_id;
END;
$$;

REVOKE ALL ON FUNCTION public.aplicar_orden_ruta(uuid, jsonb, numeric, integer, jsonb, date) FROM anon;
GRANT EXECUTE ON FUNCTION public.aplicar_orden_ruta(uuid, jsonb, numeric, integer, jsonb, date) TO authenticated;

-- Defensa en profundidad: a lo sumo un recorrido 'en_curso' por
-- (transportista, fecha, sucursal). Primero cancelar duplicados preexistentes
-- (quedándose con el más reciente), luego crear el índice único parcial.
WITH ranked AS (
  SELECT id, row_number() OVER (
    PARTITION BY transportista_id, fecha, sucursal_id
    ORDER BY created_at DESC
  ) AS rn
  FROM recorridos
  WHERE estado = 'en_curso'
)
UPDATE recorridos r
SET estado = 'cancelado'
FROM ranked
WHERE r.id = ranked.id AND ranked.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS uq_recorrido_vigente
  ON recorridos (transportista_id, fecha, sucursal_id)
  WHERE estado = 'en_curso';
