-- Migración 072: el trigger de saldo trata pedidos cancelados/anulados como contribución 0 (P1-6, parte 2)
--
-- Problema (foot-gun verificado en vivo): actualizar_saldo_pedido mantiene clientes.saldo_cuenta
-- por DELTAS y NO excluye cancelados. Si un pedido se cancela sin zerolear (o se zerolea/edita
-- estando cancelado), el saldo driftea. La verdad contable (mig 052) es Σ(total - monto_pagado)
-- SOLO de no-cancelados.
--
-- Fix FORWARD-ONLY: la contribución de un pedido al saldo es 0 si está cancelado/anulado.
-- IMPORTANTE: esto es CREATE OR REPLACE de la función del trigger → NO re-dispara sobre filas
-- existentes; NO modifica ningún saldo/stock/ítem actual. Solo cambia el cálculo de cambios futuros.
-- (Comportamiento idéntico al actual para el flujo normal no-cancelado.)

CREATE OR REPLACE FUNCTION public.actualizar_saldo_pedido()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'public'
AS $function$
DECLARE
  contrib_old NUMERIC;
  contrib_new NUMERIC;
BEGIN
  IF TG_OP = 'INSERT' THEN
    contrib_new := CASE WHEN NEW.estado IN ('cancelado','anulado') THEN 0
                        ELSE NEW.total - COALESCE(NEW.monto_pagado, 0) END;
    IF contrib_new <> 0 THEN
      UPDATE clientes SET saldo_cuenta = COALESCE(saldo_cuenta, 0) + contrib_new
      WHERE id = NEW.cliente_id;
    END IF;
    RETURN NEW;

  ELSIF TG_OP = 'DELETE' THEN
    contrib_old := CASE WHEN OLD.estado IN ('cancelado','anulado') THEN 0
                        ELSE OLD.total - COALESCE(OLD.monto_pagado, 0) END;
    IF contrib_old <> 0 THEN
      UPDATE clientes SET saldo_cuenta = COALESCE(saldo_cuenta, 0) - contrib_old
      WHERE id = OLD.cliente_id;
    END IF;
    RETURN OLD;

  ELSIF TG_OP = 'UPDATE' THEN
    contrib_old := CASE WHEN OLD.estado IN ('cancelado','anulado') THEN 0
                        ELSE OLD.total - COALESCE(OLD.monto_pagado, 0) END;
    contrib_new := CASE WHEN NEW.estado IN ('cancelado','anulado') THEN 0
                        ELSE NEW.total - COALESCE(NEW.monto_pagado, 0) END;
    IF contrib_old IS DISTINCT FROM contrib_new THEN
      UPDATE clientes SET saldo_cuenta = COALESCE(saldo_cuenta, 0) - contrib_old + contrib_new
      WHERE id = NEW.cliente_id;
    END IF;
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$function$;
