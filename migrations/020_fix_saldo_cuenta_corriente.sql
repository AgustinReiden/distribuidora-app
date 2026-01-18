-- Migración: Corregir cálculo de saldo de cuenta corriente
-- Problema: El trigger solo monitoreaba cambios en 'total', no en 'monto_pagado'
-- Resultado: Marcar pedido como "pagado" no actualizaba el saldo del cliente

-- 1. Eliminar trigger existente
DROP TRIGGER IF EXISTS trigger_actualizar_saldo_pedido ON pedidos;

-- 2. Crear función mejorada que considera monto_pagado
CREATE OR REPLACE FUNCTION actualizar_saldo_pedido()
RETURNS TRIGGER AS $$
DECLARE
  saldo_anterior NUMERIC;
  saldo_nuevo NUMERIC;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- Pedido nuevo: saldo aumenta por (total - monto_pagado)
    -- Si el pedido ya viene pagado, no suma nada al saldo
    saldo_nuevo := NEW.total - COALESCE(NEW.monto_pagado, 0);
    UPDATE clientes
    SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + saldo_nuevo
    WHERE id = NEW.cliente_id;

  ELSIF TG_OP = 'DELETE' THEN
    -- Pedido eliminado: restar lo que quedaba pendiente
    saldo_anterior := OLD.total - COALESCE(OLD.monto_pagado, 0);
    UPDATE clientes
    SET saldo_cuenta = COALESCE(saldo_cuenta, 0) - saldo_anterior
    WHERE id = OLD.cliente_id;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Calcular cambio neto en el saldo
    saldo_anterior := OLD.total - COALESCE(OLD.monto_pagado, 0);
    saldo_nuevo := NEW.total - COALESCE(NEW.monto_pagado, 0);

    -- Solo actualizar si hay diferencia
    IF saldo_anterior != saldo_nuevo THEN
      UPDATE clientes
      SET saldo_cuenta = COALESCE(saldo_cuenta, 0) - saldo_anterior + saldo_nuevo
      WHERE id = NEW.cliente_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- 3. Crear trigger que monitorea total Y monto_pagado
CREATE TRIGGER trigger_actualizar_saldo_pedido
AFTER INSERT OR DELETE OR UPDATE OF total, monto_pagado ON pedidos
FOR EACH ROW EXECUTE FUNCTION actualizar_saldo_pedido();

-- 4. Recalcular saldos de TODOS los clientes (corrección retroactiva)
-- Fórmula: saldo = (suma de pendientes en pedidos) - (suma de pagos registrados)
UPDATE clientes c
SET saldo_cuenta = (
  -- Total pendiente de pedidos (total - monto_pagado)
  COALESCE((
    SELECT SUM(p.total - COALESCE(p.monto_pagado, 0))
    FROM pedidos p
    WHERE p.cliente_id = c.id
  ), 0)
  -
  -- Menos pagos registrados en tabla pagos
  COALESCE((
    SELECT SUM(pg.monto)
    FROM pagos pg
    WHERE pg.cliente_id = c.id
  ), 0)
);

-- 5. Log para verificación
DO $$
DECLARE
  clientes_actualizados INTEGER;
BEGIN
  SELECT COUNT(*) INTO clientes_actualizados FROM clientes WHERE saldo_cuenta != 0;
  RAISE NOTICE 'Saldos recalculados. Clientes con saldo != 0: %', clientes_actualizados;
END $$;
