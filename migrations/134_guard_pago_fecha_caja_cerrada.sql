-- ============================================================================
-- 134 · Guard de "caja cerrada": no registrar pagos con fecha <= ultimo cierre
-- ============================================================================
-- CONTEXTO (Taco Pozo, doc "Mejoras app Crecer"):
--   Se podian registrar cobranzas con fecha anterior a la actual, rompiendo el
--   control de caja. El primitivo previo `rendicion_dia_cerrada` (mig 039) solo
--   frenaba al rol 'encargado' y solo en las RPC (los INSERT directos de pagos
--   lo salteaban); admin quedaba exento.
--
-- Decision (usuario): bloquear cualquier pago con fecha <= al ULTIMO cierre de
-- caja de la sucursal (rendicion confirmada/resuelta), para TODOS los roles.
--
-- Implementacion autoritativa: un trigger BEFORE INSERT/UPDATE en `pagos` que
-- corre para cualquier camino (RPC FIFO/masivas, INSERT directo del front, admin
-- o encargado). No toca DELETE (para permitir anular/corregir, p.ej. el saldo a
-- favor erroneo). El trigger solo mira fecha/monto: transferencias de pagos que
-- cambian pedido_id/cliente_id (cambiar_cliente_pedido) o forma_pago
-- (actualizar_forma_pago_pago) NO lo disparan.
-- ============================================================================

-- Fecha del ultimo cierre de caja de una sucursal (NULL si nunca cerro ninguna).
-- SECURITY DEFINER para ver todas las rendiciones_control sin depender del RLS
-- del que inserta el pago. Mismo criterio que rendicion_dia_cerrada (039):
-- 'confirmada'/'resuelta' = cerrada; 'disconformidad' = aun pendiente.
CREATE OR REPLACE FUNCTION public.ultima_fecha_caja_cerrada(p_sucursal_id bigint)
RETURNS date
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $$
  SELECT MAX(fecha)
  FROM rendiciones_control
  WHERE sucursal_id = p_sucursal_id
    AND estado IN ('confirmada','resuelta');
$$;

GRANT EXECUTE ON FUNCTION public.ultima_fecha_caja_cerrada(bigint) TO authenticated;

CREATE OR REPLACE FUNCTION public.guard_pago_fecha_cerrada()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_limite date;
BEGIN
  IF NEW.sucursal_id IS NULL OR NEW.fecha IS NULL THEN
    RETURN NEW;
  END IF;

  v_limite := public.ultima_fecha_caja_cerrada(NEW.sucursal_id);

  IF v_limite IS NOT NULL AND NEW.fecha <= v_limite THEN
    RAISE EXCEPTION 'La caja de la sucursal esta cerrada hasta el % (rendicion controlada). No se puede registrar/editar un pago con fecha %. Reabri la rendicion de ese dia para hacer cambios.',
      to_char(v_limite, 'DD/MM/YYYY'), to_char(NEW.fecha, 'DD/MM/YYYY')
      USING ERRCODE = '42501';
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_pagos_guard_fecha_cerrada ON public.pagos;
CREATE TRIGGER trg_pagos_guard_fecha_cerrada
  BEFORE INSERT OR UPDATE OF fecha, monto ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.guard_pago_fecha_cerrada();
