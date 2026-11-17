/**
 * Las dos listas que lee la deuda de un cliente por fuera de `['clientes']` y `['pedidos']` (#1544, 1544-b1):
 *
 *  - `['deudores-mora']` (`useDeudoresMoraQuery`): quién debe y cuánto, desde hace cuántos días.
 *    Cambia con todo lo que mueve la deuda de una boleta: cobrar, quitar un pago, cancelar, cambiar
 *    de cliente, crear o anular una nota de crédito.
 *  - `['notas_credito_venta']` (`useNotasCreditoVentaQuery`, `useImputarCreditoQuery`): las notas con
 *    su saldo por imputar. Cambia cuando una nota se crea o se anula, y también cuando su crédito se
 *    aplica a una boleta o se quita de ella (cancelación y cambio de cliente aplican el crédito que
 *    dejan, COB-2/#1512).
 *
 * Son prefijos: la mutation no conoce la sucursal ni los filtros de cada lista. Vive en un módulo
 * sin imports de datos para que cualquier mutation lo use sin arrastrar `lib/supabase`.
 */
import type { QueryClient } from '@tanstack/react-query'

/** La mora cambia; las notas de crédito no (un cobro, por ejemplo). */
export function invalidarMora(queryClient: Pick<QueryClient, 'invalidateQueries'>): void {
  queryClient.invalidateQueries({ queryKey: ['deudores-mora'] })
}

/** La mora y las notas de crédito cambian (se aplicó o se soltó un crédito, o se cambió una nota). */
export function invalidarNotasCreditoYMora(queryClient: Pick<QueryClient, 'invalidateQueries'>): void {
  queryClient.invalidateQueries({ queryKey: ['notas_credito_venta'] })
  invalidarMora(queryClient)
}
