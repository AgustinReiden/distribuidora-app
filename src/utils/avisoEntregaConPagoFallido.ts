/**
 * El aviso fijo de una entrega cuyo cobro falló. Nombra el pedido (L5, #1603):
 * los avisos iguales se unen en uno (`NotificationContext`), y sin el número dos
 * cobros fallidos de pedidos distintos dejaban un solo aviso, como si faltara
 * registrar uno solo.
 */
export function avisoEntregaConPagoFallido(pedidoId: string | number, motivo: string): string {
  return `El pedido #${pedidoId} se entregó, pero falló el pago: ${motivo}. Registralo desde el menú de pago.`
}
