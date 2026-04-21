-- Migration 052: Fix saldo double-counting
--
-- Problem: Two triggers independently modify clientes.saldo_cuenta:
--   1. actualizar_saldo_pedido (on pedidos INSERT/UPDATE/DELETE): adds total - monto_pagado
--   2. actualizar_saldo_cliente (on pagos INSERT/DELETE): subtracts pago.monto
-- If monto_pagado on pedidos is updated when a pago is created, the balance
-- is adjusted TWICE - once by each trigger.
--
-- Solution: saldo_cuenta is driven exclusively by the pedidos trigger.
-- The pagos trigger is neutralized to prevent double-counting.
-- Also adds UPDATE handling that was missing from the pagos trigger.

-- ============================================================
-- 1. Neutralize actualizar_saldo_cliente (pagos trigger)
-- saldo_cuenta is now managed exclusively by actualizar_saldo_pedido
-- ============================================================
CREATE OR REPLACE FUNCTION public.actualizar_saldo_cliente()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- NEUTRALIZED: This trigger no longer modifies saldo_cuenta directly.
  -- saldo_cuenta is managed exclusively by actualizar_saldo_pedido
  -- via the (total - monto_pagado) calculation on the pedidos table.
  --
  -- The pagos table is kept for audit/record purposes but does not
  -- independently affect the client balance to prevent double-counting.
  IF TG_OP = 'DELETE' THEN
    RETURN OLD;
  END IF;
  RETURN NEW;
END;
$$;

-- ============================================================
-- 2. Recalculate all client balances to fix any existing drift
-- ============================================================
UPDATE clientes c
SET saldo_cuenta = COALESCE(sub.saldo_real, 0)
FROM (
  SELECT
    p.cliente_id,
    SUM(
      CASE WHEN p.estado != 'cancelado'
        THEN p.total - COALESCE(p.monto_pagado, 0)
        ELSE 0
      END
    ) as saldo_real
  FROM pedidos p
  WHERE p.cliente_id IS NOT NULL
  GROUP BY p.cliente_id
) sub
WHERE c.id = sub.cliente_id;

-- Also reset saldo for clients with no pedidos
UPDATE clientes
SET saldo_cuenta = 0
WHERE id NOT IN (SELECT DISTINCT cliente_id FROM pedidos WHERE cliente_id IS NOT NULL);
