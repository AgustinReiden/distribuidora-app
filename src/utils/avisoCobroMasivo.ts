/**
 * El aviso del cobro masivo (#1559, 1559-b12).
 *
 * `marcar_pagos_masivo` devuelve cuántas boletas cobró (desde la migración de la ola 2
 * del plan #1603; antes, cuántas no estaban canceladas ni eran vale blanco). Las que ya
 * estaban cobradas, dadas de baja o son vales blancos se saltean: el aviso cuenta lo
 * cobrado, no lo enviado, y dice cuántas quedaron sin cobrar.
 */

const plural = (n: number, uno: string, varios: string): string => (n === 1 ? uno : varios)

/** El aviso de éxito: cuántas boletas se cobraron. */
export function mensajeCobroMasivo(cobrados: number): string {
  if (cobrados <= 0) return 'No se cobró ningún pedido: todos ya estaban cobrados o dados de baja.'
  return `${cobrados} ${plural(cobrados, 'pedido marcado como pagado', 'pedidos marcados como pagados')}`
}

/** El aviso de lo salteado, o `null` si se cobraron todos los enviados. */
export function avisoNoCobrados(enviados: number, cobrados: number): string | null {
  const salteados = enviados - Math.max(cobrados, 0)
  if (salteados <= 0) return null
  return `${salteados} ${plural(salteados, 'pedido no se cobró', 'pedidos no se cobraron')}: ` +
    'ya estaban cobrados, dados de baja o son vales blancos. Revisá la lista.'
}
