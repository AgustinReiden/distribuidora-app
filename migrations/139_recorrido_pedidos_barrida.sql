-- =========================================================================
-- 139_recorrido_pedidos_barrida.sql
--
-- Guarda en qué barrida quedó cada parada, para:
--   1. mostrarla al chofer en la hoja de ruta y en la ruta activa;
--   2. medir rechazos POR BARRIDA, que es como se sabe si el cambio de ruteo
--      sirvió (hoy "CERRADO" es el motivo #1 de cancelación: 50 de 151 en
--      90 días).
--
-- Se agrega como RPC aparte en vez de sumar un parámetro a `aplicar_orden_ruta`
-- a propósito: esa función es el corazón del armado de rutas, se reescribió
-- varias veces (081→083→084→088) y tiene historial de cambios fuera de
-- migrations/. La barrida es un dato informativo: si este update fallara, la
-- ruta igual queda bien armada, solo sin las etiquetas. No justifica el riesgo
-- de reescribir el RPC central.
-- =========================================================================

ALTER TABLE public.recorrido_pedidos
  ADD COLUMN IF NOT EXISTS barrida smallint;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'recorrido_pedidos_barrida_check'
  ) THEN
    ALTER TABLE public.recorrido_pedidos
      ADD CONSTRAINT recorrido_pedidos_barrida_check
      CHECK (barrida IS NULL OR barrida IN (1, 2, 3));
  END IF;
END $$;

COMMENT ON COLUMN public.recorrido_pedidos.barrida IS
  'Bloque de reparto: 1 = cierra al mediodía, 2 = sin horario cargado, 3 = corrido o abre tarde. NULL = ruta armada sin barridas. Mig 139.';

CREATE OR REPLACE FUNCTION public.actualizar_barridas_recorrido(p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
DECLARE
  v_actualizados integer := 0;
BEGIN
  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo un admin o encargado puede actualizar las barridas'
      USING ERRCODE = '42501';
  END IF;

  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items debe ser un array JSON';
  END IF;

  WITH datos AS (
    SELECT (e ->> 'pedido_id')::bigint  AS pedido_id,
           (e ->> 'barrida')::smallint  AS barrida
    FROM jsonb_array_elements(p_items) e
    WHERE e ->> 'pedido_id' IS NOT NULL
      AND (e ->> 'barrida')::smallint IN (1, 2, 3)
  ),
  upd AS (
    UPDATE recorrido_pedidos rp
    SET barrida = d.barrida
    FROM datos d
    WHERE rp.pedido_id = d.pedido_id
      AND rp.recorrido_id IN (
        SELECT id FROM recorridos
        WHERE estado = 'en_curso' AND sucursal_id = current_sucursal_id()
      )
    RETURNING 1
  )
  SELECT count(*) INTO v_actualizados FROM upd;

  RETURN jsonb_build_object('success', true, 'actualizados', v_actualizados);
END;
$fn$;

ALTER FUNCTION public.actualizar_barridas_recorrido(jsonb) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.actualizar_barridas_recorrido(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.actualizar_barridas_recorrido(jsonb) TO authenticated;

COMMENT ON FUNCTION public.actualizar_barridas_recorrido(jsonb) IS
  'Marca la barrida de cada parada del recorrido en curso. Admin/encargado. Mig 139.';
