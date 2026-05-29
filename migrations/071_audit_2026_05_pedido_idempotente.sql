-- Migración 071: idempotencia de creación de pedidos (Auditoría 2026-05, P1-2)
-- Evita pedidos duplicados cuando el sync offline reintenta tras perder la respuesta
-- de un INSERT ya commiteado.
--
-- Enfoque SEGURO: no se toca crear_pedido_completo (RPC crítica). Se agrega:
--   1) columna pedidos.offline_id + índice UNIQUE parcial (aditivo, sin riesgo).
--   2) wrapper crear_pedido_idempotente que verifica offline_id y delega en
--      crear_pedido_completo. Llamadas con p_offline_id NULL = comportamiento idéntico.
-- El frontend pasa el offline_id (ya existente en la cola offline) al sincronizar.

-- 1) Columna + índice único parcial
ALTER TABLE public.pedidos ADD COLUMN IF NOT EXISTS offline_id text;
CREATE UNIQUE INDEX IF NOT EXISTS uq_pedidos_offline_id
  ON public.pedidos (offline_id) WHERE offline_id IS NOT NULL;

-- 2) Wrapper idempotente
CREATE OR REPLACE FUNCTION public.crear_pedido_idempotente(
  p_cliente_id bigint,
  p_total numeric,
  p_usuario_id uuid,
  p_items jsonb,
  p_notas text DEFAULT NULL::text,
  p_forma_pago text DEFAULT 'efectivo'::text,
  p_estado_pago text DEFAULT 'pendiente'::text,
  p_fecha date DEFAULT NULL::date,
  p_tipo_factura text DEFAULT 'ZZ'::text,
  p_total_neto numeric DEFAULT NULL::numeric,
  p_total_iva numeric DEFAULT 0,
  p_fecha_entrega_programada date DEFAULT NULL::date,
  p_preventista_id uuid DEFAULT NULL::uuid,
  p_offline_id text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_existing INT;
  v_result JSONB;
BEGIN
  -- Idempotencia: si ya existe un pedido con este offline_id, devolverlo sin recrear.
  IF p_offline_id IS NOT NULL THEN
    SELECT id INTO v_existing FROM pedidos WHERE offline_id = p_offline_id;
    IF v_existing IS NOT NULL THEN
      RETURN jsonb_build_object('success', true, 'pedido_id', v_existing, 'idempotente', true);
    END IF;
  END IF;

  -- Delegar en la RPC existente (sin cambios). auth.uid() se preserva.
  v_result := public.crear_pedido_completo(
    p_cliente_id, p_total, p_usuario_id, p_items, p_notas, p_forma_pago,
    p_estado_pago, p_fecha, p_tipo_factura, p_total_neto, p_total_iva,
    p_fecha_entrega_programada, p_preventista_id
  );

  -- Etiquetar el pedido recién creado con su offline_id (backstop: índice UNIQUE).
  IF COALESCE((v_result->>'success')::boolean, false) AND p_offline_id IS NOT NULL THEN
    UPDATE pedidos SET offline_id = p_offline_id
    WHERE id = (v_result->>'pedido_id')::int AND offline_id IS NULL;
  END IF;

  RETURN v_result;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.crear_pedido_idempotente(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid,text) TO authenticated, service_role;
