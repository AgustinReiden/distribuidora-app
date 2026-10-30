-- ============================================================================
-- 420 · Rutas 2: "Volver a pendiente" en una sola RPC (#1313, plan #1308 tarjeta 2)
-- ============================================================================
-- Va después de 419_rutas_1 (usa `_recorrido_contadores`) y del trigger de
-- transiciones de `pedidos.estado` de la tarjeta 4 (#1317). El número se elige
-- al aplicarla, contra el ledger de prod y origin/main. Aplicar desde el
-- contenido LF.
--
-- LOG-6 · "Volver a pendiente" eran tres llamadas sueltas desde el front: el
-- chofer por REST, el estado por REST y `quitar_pedido_de_recorridos_activos`.
-- Si la red se cortaba a mitad, el pedido quedaba pendiente con chofer, o
-- pendiente y todavía como parada de la ruta. Ahora es una RPC que hace las
-- tres cosas en una transacción.
--
-- Quién y desde dónde: admin o encargado (los que tienen el botón, en la fila y
-- en el panel de pedidos trabados), desde 'en_preparacion' o 'asignado'. Un
-- 'pendiente' es un no-op que igual lo saca de una ruta en curso si quedó ahí.
-- 'entregado' no: eso es "Revertir entrega", con su propio camino. 'cancelado'
-- y 'anulado' tampoco (mig 243: no se reabren).
-- Es SECURITY DEFINER: corre como su dueño y no pasa por el guard de REST de
-- `pedidos_proteger_columnas` (tarjeta 4), así que valida el rol acá adentro.
-- Sale de las rutas en curso como en `quitar_pedido_de_recorridos_activos`
-- (419_rutas_1): se borran todas sus paradas ahí, y la de un no entregado deja
-- antes su rastro en `pedido_historial`. Así destraba también las guardas de
-- edición, que miran "parada en una ruta en curso".
--
-- Locks: el pedido FOR UPDATE primero; después, por el UPDATE de pedidos, el
-- trigger `actualizar_recorrido_entrega` y este cuerpo bloquean las filas de
-- recorridos de ese pedido por id ascendente. No toca productos.
-- ============================================================================

BEGIN;

DO $premisas$
BEGIN
  IF to_regprocedure('public.volver_pedido_a_pendiente(bigint)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig 420 · volver_pedido_a_pendiente ya existe';
  END IF;
  IF to_regprocedure('public._recorrido_contadores(bigint)') IS NULL
     OR to_regprocedure('public._no_entregas_al_historial(bigint[])') IS NULL THEN
    RAISE EXCEPTION 'mig 420 · falta _recorrido_contadores: aplicar antes 419_rutas_1';
  END IF;
END
$premisas$;

CREATE FUNCTION public.volver_pedido_a_pendiente(p_pedido_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_estado   TEXT;
  v_paradas  BIGINT[];
  v_rutas    BIGINT[];
  v_rid      BIGINT;
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa' USING ERRCODE = '42501';
  END IF;

  IF NOT es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o un encargado puede volver un pedido a pendiente'
      USING ERRCODE = '42501';
  END IF;

  SELECT estado INTO v_estado
  FROM pedidos
  WHERE id = p_pedido_id AND sucursal_id = v_sucursal
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'El pedido #% no existe en esta sucursal', p_pedido_id
      USING ERRCODE = 'P0002';
  END IF;

  IF v_estado = 'entregado' THEN
    RAISE EXCEPTION 'El pedido #% ya está entregado: para deshacerlo usá "Revertir entrega"', p_pedido_id;
  END IF;
  IF v_estado NOT IN ('pendiente', 'en_preparacion', 'asignado') THEN
    RAISE EXCEPTION 'El pedido #% está % y no vuelve a pendiente', p_pedido_id, v_estado;
  END IF;

  -- Lo mismo que hacía el front por REST (chofer, estado, updated_at y
  -- fecha_entrega en NULL), en una sola sentencia.
  UPDATE pedidos
  SET estado           = 'pendiente',
      transportista_id = NULL,
      orden_entrega    = NULL,
      fecha_entrega    = NULL,
      updated_at       = now()
  WHERE id = p_pedido_id
    AND (estado <> 'pendiente' OR transportista_id IS NOT NULL OR orden_entrega IS NOT NULL);

  -- Sale de la(s) ruta(s) en curso, para que no quede como parada fantasma y
  -- reaparezca limpio en "Armar ruta". El no entregado deja su rastro antes.
  SELECT array_agg(rp.id), array_agg(DISTINCT rp.recorrido_id ORDER BY rp.recorrido_id)
    INTO v_paradas, v_rutas
  FROM recorrido_pedidos rp
  JOIN recorridos r ON r.id = rp.recorrido_id
  WHERE rp.pedido_id   = p_pedido_id
    AND rp.sucursal_id = v_sucursal
    AND r.estado       = 'en_curso';

  IF v_paradas IS NOT NULL THEN
    PERFORM public._no_entregas_al_historial(v_paradas);
    DELETE FROM recorrido_pedidos WHERE id = ANY(v_paradas);
  END IF;

  FOREACH v_rid IN ARRAY COALESCE(v_rutas, '{}') LOOP
    UPDATE recorridos r
    SET total_pedidos      = c.total_pedidos,
        total_facturado    = c.total_facturado,
        pedidos_entregados = c.pedidos_entregados,
        total_cobrado      = c.total_cobrado
    FROM public._recorrido_contadores(v_rid) c
    WHERE r.id = v_rid;
  END LOOP;

  RETURN jsonb_build_object(
    'success', true,
    'pedido_id', p_pedido_id,
    'paradas_eliminadas', COALESCE(cardinality(v_paradas), 0)
  );
END;
$function$;

ALTER FUNCTION public.volver_pedido_a_pendiente(bigint) OWNER TO postgres;
REVOKE ALL ON FUNCTION public.volver_pedido_a_pendiente(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.volver_pedido_a_pendiente(bigint) TO authenticated, service_role;
COMMENT ON FUNCTION public.volver_pedido_a_pendiente(bigint) IS
  '"Volver a pendiente" atómico (#1313): admin o encargado, desde en_preparacion o asignado. Suelta el chofer, deja el pedido pendiente y lo saca de las rutas en curso (el no entregado queda en pedido_historial).';

DO $cierre$
BEGIN
  IF has_function_privilege('anon', 'public.volver_pedido_a_pendiente(bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'mig 420 · volver_pedido_a_pendiente quedó ejecutable por anon';
  END IF;
END
$cierre$;

COMMIT;
