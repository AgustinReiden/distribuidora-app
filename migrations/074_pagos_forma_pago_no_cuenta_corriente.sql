-- Migración 074: cuenta_corriente deja de ser una forma de pago válida en `pagos`
--
-- Cta Cte no es una forma de pago: es una venta no cobrada. Registrar un pago con
-- forma_pago='cuenta_corriente' marcaba el pedido como PAGADO (vía el trigger
-- actualizar_estado_pago_pedido) aunque el cliente no pagó, e inflaba las
-- rendiciones. La UI ya no ofrece esa opción; este CHECK lo impide a nivel DB
-- para cualquier origen (UI, bot de Telegram, scripts).
--
-- Si el cliente no paga, el flujo correcto es "entregar a cuenta corriente (sin
-- cobrar)": el pedido queda entregado y el saldo pendiente, SIN registrar un pago.
--
-- NOT VALID: no valida las filas existentes (se conserva el pago histórico que ya
-- tiene 'cuenta_corriente' y el valor legacy 'combinado'); solo aplica a
-- INSERT/UPDATE nuevos. `IS DISTINCT FROM` tolera forma_pago NULL.
-- Forward-only y aditivo: no toca datos, saldos, stock ni pedidos.

ALTER TABLE public.pagos
  DROP CONSTRAINT IF EXISTS pagos_forma_pago_no_cuenta_corriente;

ALTER TABLE public.pagos
  ADD CONSTRAINT pagos_forma_pago_no_cuenta_corriente
  CHECK (forma_pago IS DISTINCT FROM 'cuenta_corriente') NOT VALID;
