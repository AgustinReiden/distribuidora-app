-- ============================================================================
-- 035 — recalcular pedidos.monto_pagado al insertar/anular pagos
-- ============================================================================
-- Bug historico: al registrar pagos en el modal "Registrar Pago — Pedido #N"
-- (ModalPagoPedido), las filas se insertan en `pagos` pero `pedidos.monto_pagado`
-- nunca se actualiza, por lo que el trigger BEFORE en `pedidos`
-- (`actualizar_estado_pago_pedido`) jamas recalcula `estado_pago`. Resultado:
-- la card sigue mostrando "Pago Pendiente" aunque el pedido este pagado.
--
-- Causa: el unico trigger AFTER INSERT/DELETE en `pagos`
-- (`trigger_actualizar_saldo_pago`) apunta a `actualizar_saldo_cliente()`, que
-- esta neutralizada en 000_baseline.sql (solo devuelve OLD/NEW; ver comentario
-- "NEUTRALIZED: saldo_cuenta is managed exclusively by actualizar_saldo_pedido").
-- Cuando se neutralizo, nadie cubrio el gap de actualizar `pedidos.monto_pagado`.
--
-- Fix: nuevo trigger AFTER en `pagos` que recalcula `pedidos.monto_pagado` como
-- SUM(pagos.monto WHERE pedido_id = X). El trigger BEFORE existente en
-- `pedidos` se encarga de recalcular `estado_pago` en cascada.
--
-- Incluye backfill para los pedidos rotos en produccion (ej: #1540 con
-- monto_pagado=0 y dos pagos sumando $24.700).
-- ============================================================================

CREATE OR REPLACE FUNCTION public.recalcular_monto_pagado_pedido()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
BEGIN
  -- Se recalcula para el(los) pedido(s) afectado(s) por la operacion.
  -- Skip cuando pedido_id IS NULL (caso "pago a cuenta general del cliente").

  IF TG_OP = 'INSERT' THEN
    IF NEW.pedido_id IS NOT NULL THEN
      UPDATE pedidos
         SET monto_pagado = COALESCE((
           SELECT SUM(monto) FROM pagos WHERE pedido_id = NEW.pedido_id
         ), 0)
       WHERE id = NEW.pedido_id;
    END IF;
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    IF OLD.pedido_id IS NOT NULL THEN
      UPDATE pedidos
         SET monto_pagado = COALESCE((
           SELECT SUM(monto) FROM pagos WHERE pedido_id = OLD.pedido_id
         ), 0)
       WHERE id = OLD.pedido_id;
    END IF;
    RETURN OLD;

  ELSIF TG_OP = 'UPDATE' THEN
    -- Si cambio el pedido_id, hay que recalcular tanto el anterior como el nuevo.
    IF OLD.pedido_id IS DISTINCT FROM NEW.pedido_id THEN
      IF OLD.pedido_id IS NOT NULL THEN
        UPDATE pedidos
           SET monto_pagado = COALESCE((
             SELECT SUM(monto) FROM pagos WHERE pedido_id = OLD.pedido_id
           ), 0)
         WHERE id = OLD.pedido_id;
      END IF;
      IF NEW.pedido_id IS NOT NULL THEN
        UPDATE pedidos
           SET monto_pagado = COALESCE((
             SELECT SUM(monto) FROM pagos WHERE pedido_id = NEW.pedido_id
           ), 0)
         WHERE id = NEW.pedido_id;
      END IF;
    ELSIF NEW.pedido_id IS NOT NULL THEN
      -- Mismo pedido pero cambio el monto.
      UPDATE pedidos
         SET monto_pagado = COALESCE((
           SELECT SUM(monto) FROM pagos WHERE pedido_id = NEW.pedido_id
         ), 0)
       WHERE id = NEW.pedido_id;
    END IF;
    RETURN NEW;
  END IF;

  RETURN NULL;
END;
$$;

ALTER FUNCTION public.recalcular_monto_pagado_pedido() OWNER TO postgres;

GRANT ALL ON FUNCTION public.recalcular_monto_pagado_pedido() TO anon;
GRANT ALL ON FUNCTION public.recalcular_monto_pagado_pedido() TO authenticated;
GRANT ALL ON FUNCTION public.recalcular_monto_pagado_pedido() TO service_role;

-- Trigger AFTER: necesita ver la fila ya insertada/borrada al hacer el SUM.
-- Se incluye UPDATE OF monto, pedido_id por completitud (la app no edita pagos
-- in-place hoy, pero deja la red de seguridad si en el futuro se hace).
CREATE OR REPLACE TRIGGER trigger_recalcular_monto_pagado_pedido
  AFTER INSERT OR UPDATE OF monto, pedido_id OR DELETE
  ON public.pagos
  FOR EACH ROW
  EXECUTE FUNCTION public.recalcular_monto_pagado_pedido();

-- ============================================================================
-- Backfill: corregir pedidos donde monto_pagado quedo desincronizado.
-- El trigger BEFORE en pedidos (trigger_actualizar_estado_pago) recalcula
-- estado_pago automaticamente cuando se updatea monto_pagado.
-- ============================================================================

UPDATE pedidos p
   SET monto_pagado = sub.suma
  FROM (
    SELECT pedido_id, SUM(monto) AS suma
      FROM pagos
     WHERE pedido_id IS NOT NULL
     GROUP BY pedido_id
  ) sub
 WHERE p.id = sub.pedido_id
   AND COALESCE(p.monto_pagado, 0) <> sub.suma;
