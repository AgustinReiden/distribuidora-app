-- =========================================================================
-- 183_cerrar_recorridos_terminados.sql
--
-- Nada cierra un recorrido. `completarRecorrido` existe en el front desde hace
-- meses (useRecorridos.ts) y NADIE la llama: el estado terminal se diseño y
-- nunca se cableo. Resultado al 2026-08-19: de 86 recorridos, 85 estan en
-- `en_curso` y son de dias pasados. El mas viejo es del 2026-06-15, y
-- `completado` tiene CERO filas en toda la tabla.
--
-- No es cosmetico: cualquier lectura del estado de la flota ("cuantas rutas hay
-- en curso") da 85 en vez de 1, y obliga a que la pantalla del chofer filtre por
-- fecha para no mostrar una ruta de junio.
--
-- QUE SE CIERRA Y QUE NO
-- -----------------------
-- Los numeros dicen que la enorme mayoria de esas rutas SI se hicieron: de 1917
-- paradas en recorridos vencidos, 1896 estan entregadas (98,9%) y ninguna
-- cancelada. O sea, el chofer repartio y nadie marco la ruta como cerrada.
--
-- Pero 21 paradas siguen en `asignado`, y estan concentradas en apenas 2
-- recorridos. Esas NO se tocan: cerrar una ruta con entregas pendientes seria
-- declarar terminado un reparto que no se hizo, y esconderia justamente los
-- pedidos que hay que rescatar. Son los mismos 21 pedidos trabados que el panel
-- de "pedidos frenados" pone a la vista para que alguien decida.
--
-- Por eso `cerrar_recorridos_vencidos` cierra SOLO lo que esta probadamente
-- terminado: recorridos de fecha pasada sin ninguna parada pendiente.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 1 · La funcion
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cerrar_recorridos_vencidos(
  p_sucursal_id BIGINT DEFAULT NULL
)
RETURNS TABLE (cerrados INT, con_pendientes INT)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_cerrados INT := 0;
  v_pendientes INT := 0;
BEGIN
  -- SECURITY DEFINER + GRANT a `authenticated` = cualquier usuario logueado
  -- puede invocarla. Cerrar rutas de toda la sucursal es de admin/encargado.
  -- `current_user <> 'authenticated'` exime a las corridas por consola y a
  -- otras RPCs, igual que hace `pedidos_proteger_columnas` (mig 181).
  IF current_user = 'authenticated' AND NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Solo un admin o encargado puede cerrar recorridos vencidos'
      USING ERRCODE = '42501';
  END IF;

  -- Un recorrido esta terminado cuando ninguna de sus paradas sigue esperando.
  -- `asignado` es el unico estado que significa "todavia hay que ir"; entregado,
  -- cancelado y anulado son desenlaces.
  WITH vencidos AS (
    SELECT r.id,
           EXISTS (
             SELECT 1
             FROM recorrido_pedidos rp
             JOIN pedidos p ON p.id = rp.pedido_id
             WHERE rp.recorrido_id = r.id
               AND p.estado = 'asignado'
           ) AS tiene_pendientes
    FROM recorridos r
    WHERE r.estado = 'en_curso'
      AND r.fecha < CURRENT_DATE
      AND (p_sucursal_id IS NULL OR r.sucursal_id = p_sucursal_id)
  ),
  cerrados_ahora AS (
    UPDATE recorridos r
       SET estado = 'completado',
           completed_at = COALESCE(r.completed_at, (r.fecha + TIME '23:59')::timestamptz)
      FROM vencidos v
     WHERE v.id = r.id
       AND NOT v.tiene_pendientes
    RETURNING r.id
  )
  SELECT
    (SELECT count(*) FROM cerrados_ahora),
    (SELECT count(*) FROM vencidos WHERE tiene_pendientes)
  INTO v_cerrados, v_pendientes;

  RETURN QUERY SELECT v_cerrados, v_pendientes;
END;
$$;

COMMENT ON FUNCTION public.cerrar_recorridos_vencidos(BIGINT) IS
  'Cierra los recorridos de fecha pasada que ya no tienen paradas pendientes. '
  'Los que SI tienen entregas sin resolver quedan abiertos a proposito: cerrarlos '
  'declararia terminado un reparto que no se hizo y esconderia los pedidos a '
  'rescatar. Devuelve (cerrados, con_pendientes). Ver mig 183.';

-- Solo admin/encargado: cierra rutas de toda la sucursal.
REVOKE ALL ON FUNCTION public.cerrar_recorridos_vencidos(BIGINT) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cerrar_recorridos_vencidos(BIGINT) TO authenticated;

-- -------------------------------------------------------------------------
-- 2 · Limpieza de lo acumulado
-- -------------------------------------------------------------------------
-- Se corre una vez para las ~83 rutas que quedaron abiertas desde junio. Las 2
-- que tienen paradas pendientes sobreviven y quedan visibles.
SELECT * FROM public.cerrar_recorridos_vencidos();
