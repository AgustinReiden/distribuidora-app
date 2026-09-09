-- Que boletas debe, no solo cuanto (para la comanda del transportista)
--
-- La mig 215 dejo `deuda_previa`: cuanto debia el cliente ANTES de este pedido.
-- Alcanza para un badge en pantalla, pero no para el papel que se lleva el
-- chofer: con el numero suelto no puede imputar el cobro. Necesita saber QUE
-- boletas reclamar. Esta funcion devuelve esas boletas, en orden cronologico.
--
-- Se imprime en la comanda (`dibujarComanda`, src/lib/pdf/reciboPedido.js), en
-- las dos copias -- la del cliente incluida.
--
-- CUADRA CON EL TOTAL, SALVO POR LOS PAGOS A CUENTA
-- `deuda_previa` resta ademas los pagos a cuenta (los de `pagos` con
-- `pedido_id IS NULL`), que no estan imputados a ninguna boleta y por eso no
-- aparecen aca. Hoy no hay uno solo en toda la base -- 5.401 pagos, todos
-- contra una boleta -- asi que el detalle suma exactamente el total; el bloque
-- DO de abajo lo verifica sobre todos los pedidos. Si algun dia aparece uno, el
-- ticket muestra la diferencia como linea "A cuenta" (ver
-- `bloqueDeudaComanda`) en vez de imprimir un desglose que no da.
--
-- Misma guarda y mismo ACL que la 215: SECURITY DEFINER porque la RLS de
-- `pedidos` le muestra al preventista solo SUS pedidos, y del caller solo se usa
-- `p.id` -- cliente, fecha y sucursal se releen de la tabla filtrando por
-- `current_sucursal_id()`, asi que una fila inventada por RPC devuelve [].
--
-- Revertir: `DROP FUNCTION public.deuda_previa_detalle(public.pedidos);`. La
-- comanda deja de imprimir el desglose; el total (215) sigue.
-- =========================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.deuda_previa_detalle(p public.pedidos)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  WITH ref AS (
    -- Misma guarda que deuda_previa (mig 215): del caller solo se usa `p.id`.
    SELECT pe.cliente_id, pe.created_at, pe.id, pe.sucursal_id
    FROM pedidos pe
    WHERE pe.id = p.id
      AND pe.sucursal_id = current_sucursal_id()
  ),
  boletas AS (
    SELECT p2.id,
           COALESCE(p2.fecha, p2.created_at::date) AS fecha,
           ROUND(p2.total - COALESCE(p2.monto_pagado, 0), 2) AS monto
    FROM pedidos p2, ref
    WHERE p2.cliente_id  = ref.cliente_id
      AND p2.sucursal_id = ref.sucursal_id
      AND p2.estado NOT IN ('cancelado', 'anulado')
      AND (p2.created_at, p2.id) < (ref.created_at, ref.id)
      AND p2.total - COALESCE(p2.monto_pagado, 0) >= 0.01
    ORDER BY p2.created_at, p2.id
  )
  SELECT COALESCE(
    jsonb_agg(jsonb_build_object('id', id, 'fecha', fecha, 'monto', monto)),
    '[]'::jsonb
  )
  FROM boletas;
$$;

COMMENT ON FUNCTION public.deuda_previa_detalle(public.pedidos) IS
  'Boletas impagas anteriores a este pedido, en orden cronologico (computed column de PostgREST). El total lo da deuda_previa (mig 215), que ademas resta los pagos a cuenta.';

REVOKE ALL ON FUNCTION public.deuda_previa_detalle(public.pedidos) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.deuda_previa_detalle(public.pedidos) TO authenticated;

DO $verif$
DECLARE
  v_abiertas text;
  v_definer  boolean;
  v_malos    int;
BEGIN
  SELECT array_to_string(array_agg(a::text), ' ') INTO v_abiertas
  FROM pg_proc p, unnest(p.proacl) a
  WHERE p.pronamespace = 'public'::regnamespace
    AND p.proname = 'deuda_previa_detalle'
    AND (a::text LIKE '=%' OR a::text LIKE 'anon=%');
  IF v_abiertas IS NOT NULL THEN
    RAISE EXCEPTION 'mig 218: el ACL quedo abierto (%).', v_abiertas;
  END IF;

  SELECT p.prosecdef INTO v_definer
  FROM pg_proc p
  WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'deuda_previa_detalle';
  IF NOT COALESCE(v_definer, false) THEN
    RAISE EXCEPTION 'mig 218: la funcion no quedo SECURITY DEFINER.';
  END IF;

  -- El detalle tiene que sumar lo mismo que el total de la 215.
  SELECT count(*) INTO v_malos
  FROM pedidos pe
  WHERE pe.estado NOT IN ('cancelado', 'anulado')
    AND COALESCE((
          SELECT SUM((b->>'monto')::numeric)
          FROM jsonb_array_elements(
            COALESCE((
              SELECT jsonb_agg(jsonb_build_object('monto', ROUND(p2.total - COALESCE(p2.monto_pagado,0), 2)))
              FROM pedidos p2
              WHERE p2.cliente_id  = pe.cliente_id
                AND p2.sucursal_id = pe.sucursal_id
                AND p2.estado NOT IN ('cancelado','anulado')
                AND (p2.created_at, p2.id) < (pe.created_at, pe.id)
                AND p2.total - COALESCE(p2.monto_pagado,0) >= 0.01
            ), '[]'::jsonb)
          ) b
        ), 0)
      <> COALESCE((
          SELECT SUM(GREATEST(0, p2.total - COALESCE(p2.monto_pagado, 0)))
          FROM pedidos p2
          WHERE p2.cliente_id  = pe.cliente_id
            AND p2.sucursal_id = pe.sucursal_id
            AND p2.estado NOT IN ('cancelado','anulado')
            AND (p2.created_at, p2.id) < (pe.created_at, pe.id)
        ), 0);
  IF v_malos > 0 THEN
    RAISE EXCEPTION 'mig 218: en % pedidos el detalle no suma lo mismo que el total.', v_malos;
  END IF;
END
$verif$;

COMMIT;
