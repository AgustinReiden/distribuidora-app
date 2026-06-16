-- ============================================================================
-- 086 — Saldo a favor reduce clientes.saldo_cuenta (modelo de saldo neto)
-- ============================================================================
-- Hasta ahora, un pago sin pedido (pedido_id NULL) — el "saldo a favor" que
-- deja FIFO al sobrar — NO afectaba `clientes.saldo_cuenta` (el trigger
-- `actualizar_saldo_cliente` estaba neutralizado). El crédito quedaba invisible:
-- el cliente había pagado de más pero el saldo seguía mostrando lo que "debía".
--
-- Este cambio reactiva ese trigger para que los pagos SIN pedido resten el
-- saldo (quedan como saldo negativo = crédito a favor). Así el crédito se netea
-- solo contra próximos pedidos: al crear un pedido, `actualizar_saldo_pedido`
-- sube el saldo, y el crédito ya está restado.
--
-- Invariante resultante:
--   saldo_cuenta = Σ(pedidos no cancelados: total - monto_pagado)   [trigger pedidos]
--                - Σ(pagos con pedido_id NULL: monto)                [este trigger]
--   ≡ compras_no_canceladas - pagos_totales
--
-- Sin doble conteo: los pagos CON pedido los maneja la cascada de pedidos
-- (recalcular_monto_pagado_pedido → actualizar_saldo_pedido); este trigger solo
-- toca los pagos SIN pedido. Las transiciones (imputar un crédito a un pedido =
-- UPDATE pedido_id NULL→valor) se compensan exactamente entre ambos triggers.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.actualizar_saldo_cliente()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  -- Contribución de un pago al saldo: solo los pagos SIN pedido (créditos a
  -- favor) afectan saldo_cuenta acá, y lo RESTAN (contrib negativa). Los pagos
  -- CON pedido contribuyen 0 (los maneja la cascada de pedidos).
  contrib_old numeric;
  contrib_new numeric;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.pedido_id IS NULL THEN
      UPDATE clientes SET saldo_cuenta = COALESCE(saldo_cuenta, 0) - NEW.monto
       WHERE id = NEW.cliente_id;
    END IF;
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.pedido_id IS NULL THEN
      UPDATE clientes SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + OLD.monto
       WHERE id = OLD.cliente_id;
    END IF;
    RETURN OLD;

  ELSIF TG_OP = 'UPDATE' THEN
    contrib_old := CASE WHEN OLD.pedido_id IS NULL THEN -OLD.monto ELSE 0 END;
    contrib_new := CASE WHEN NEW.pedido_id IS NULL THEN -NEW.monto ELSE 0 END;

    IF OLD.cliente_id IS DISTINCT FROM NEW.cliente_id THEN
      -- Cambió de cliente: revertir en el viejo, aplicar en el nuevo
      IF contrib_old <> 0 THEN
        UPDATE clientes SET saldo_cuenta = COALESCE(saldo_cuenta, 0) - contrib_old
         WHERE id = OLD.cliente_id;
      END IF;
      IF contrib_new <> 0 THEN
        UPDATE clientes SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + contrib_new
         WHERE id = NEW.cliente_id;
      END IF;
    ELSIF contrib_new <> contrib_old THEN
      UPDATE clientes SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + (contrib_new - contrib_old)
       WHERE id = NEW.cliente_id;
    END IF;
    RETURN NEW;
  END IF;

  RETURN NULL;
END;
$function$;

-- Recrear el trigger incluyendo UPDATE (antes era solo INSERT/DELETE) para
-- captar transiciones de pedido_id/monto/cliente_id (p.ej. imputar un crédito).
-- UPDATE OF acotado a esas columnas: un cambio de forma_pago no dispara nada.
DROP TRIGGER IF EXISTS trigger_actualizar_saldo_pago ON public.pagos;
CREATE TRIGGER trigger_actualizar_saldo_pago
  AFTER INSERT OR DELETE OR UPDATE OF monto, pedido_id, cliente_id
  ON public.pagos
  FOR EACH ROW
  EXECUTE FUNCTION public.actualizar_saldo_cliente();

-- Recalc one-time (idempotente): reflejar en saldo_cuenta los créditos (pagos
-- sin pedido) ya existentes. Se recomputa desde cero con la misma invariante,
-- acotado a los clientes que tienen pagos sin pedido para no tocar otros saldos.
UPDATE clientes c
SET saldo_cuenta =
      COALESCE((SELECT SUM(pe.total - COALESCE(pe.monto_pagado, 0))
                  FROM pedidos pe
                 WHERE pe.cliente_id = c.id
                   AND pe.estado NOT IN ('cancelado', 'anulado')), 0)
    - COALESCE((SELECT SUM(pa.monto)
                  FROM pagos pa
                 WHERE pa.cliente_id = c.id
                   AND pa.pedido_id IS NULL), 0)
WHERE c.id IN (SELECT DISTINCT cliente_id FROM pagos WHERE pedido_id IS NULL);

COMMIT;
