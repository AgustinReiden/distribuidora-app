-- =========================================================================
-- 154_actualizar_barridas_1a5.sql
--
-- El RPC filtraba `IN (1, 2, 3)` al parsear el jsonb, así que con los 5 grupos
-- de la mig 153 habría descartado EN SILENCIO las barridas 4 y 5: esas paradas
-- quedaban con barrida NULL y sin separador en la hoja de ruta, sin ningún
-- error visible. Se cambia por el rango 1..5.
-- =========================================================================

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
      AND (e ->> 'barrida')::smallint BETWEEN 1 AND 5
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
  'Marca la barrida (1..5) de cada parada del recorrido en curso. Admin/encargado. Mig 154.';
