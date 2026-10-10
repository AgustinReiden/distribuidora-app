/**
 * Pedidos dados de baja: `cancelado` y `anulado` (#1080).
 *
 * `pedidos_estado_check` (mig 297) tiene seis estados y dos son terminales.
 * En la base, todas las funciones de `public` tratan `anulado` exactamente
 * igual que `cancelado`: stock ya devuelto, total 0, fuera de la deuda
 * (`actualizar_saldo_pedido`, `deuda_previa`), no editable
 * (`pedido_items_guard_estado`, `actualizar_pedido_items`), no se entrega ni se
 * cobra (`marcar_entregas_masivo`, `marcar_pagos_masivo_impl`,
 * `registrar_pago_cliente_fifo_impl`), no recibe crédito
 * (`imputar_credito_a_pedido_impl`) y no entra en rutas (`aplicar_orden_ruta`).
 * El front miraba sólo `cancelado` en varios lugares y un anulado se veía como
 * un pedido activo. Este es el predicado único del lado del front.
 *
 * Las consultas por PostgREST no pueden llamar a esta función: excluyen con
 * `.neq(col, 'cancelado').neq(col, 'anulado')` (PostgREST hace AND de los
 * filtros repetidos sobre la misma columna). El test de este archivo verifica
 * que ningún `.neq(..., 'cancelado')` del código quede sin su par.
 */
export const ESTADOS_DE_BAJA = ['cancelado', 'anulado'] as const

export type EstadoDeBaja = (typeof ESTADOS_DE_BAJA)[number]

/** ¿El pedido está dado de baja (cancelado o anulado)? */
export function esPedidoDeBaja(estado: string | null | undefined): boolean {
  return estado === 'cancelado' || estado === 'anulado'
}
