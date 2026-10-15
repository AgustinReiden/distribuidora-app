/**
 * Rechazos de negocio del servidor al crear un pedido.
 *
 * `crear_pedido_completo` no tira excepción cuando rechaza: devuelve
 * `{ success: false, errores: [...] }` (producto desactivado, compra mínima,
 * total que no coincide, stock insuficiente...). El cliente lo convierte en
 * `RechazoDeNegocioError`, que es lo que distingue "el servidor miró el pedido
 * y dijo que no" de un error de red o un 5xx, que sí merece reintento.
 *
 * El replay offline usa `rechazoEsTerminal` para decidir si reintentar sirve.
 */
import { pareceSesionVencida } from './pareceSesionVencida'

export class RechazoDeNegocioError extends Error {
  /** `codigo` del server, cuando el rechazo lo trae (#1153). */
  constructor(message: string, readonly codigo?: string) {
    super(message)
    this.name = 'RechazoDeNegocioError'
  }
}

/**
 * El rechazo de `crear_pedido_completo` porque un regalo no es legal (promo
 * apagada, vencida, de otra categoría, por encima del tope o excluyente). Es
 * el único con código: el replay offline ofrece "Sincronizar sin el regalo".
 */
export const CODIGO_REGALO_FUERA_DE_PROMO = 'regalo_fuera_de_promo'

/**
 * El rechazo porque un combo no es legal (#1191: llegó a su tope, se apagó o
 * su reparto no cierra). El replay offline ofrece "Sincronizar sin los combos".
 */
export const CODIGO_COMBO_FUERA_DE_REGLA = 'combo_fuera_de_regla'

export function esRechazoDeCombo(error: unknown): boolean {
  return esRechazoDeNegocio(error)
    && (error as RechazoDeNegocioError).codigo === CODIGO_COMBO_FUERA_DE_REGLA
}

export function esRechazoDeRegalo(error: unknown): boolean {
  return esRechazoDeNegocio(error)
    && (error as RechazoDeNegocioError).codigo === CODIGO_REGALO_FUERA_DE_PROMO
}

export function esRechazoDeNegocio(error: unknown): error is RechazoDeNegocioError {
  return error instanceof RechazoDeNegocioError
    || (error instanceof Error && error.name === 'RechazoDeNegocioError')
}

/** Falta de stock: puede dejar de ser cierto cuando entre mercadería. */
const PATRON_STOCK = /stock insuficiente|sin stock|stock disponible/i

/**
 * Si reintentar el pedido NO puede cambiar el resultado.
 *
 * - Un error que no es rechazo de negocio (red, 5xx, timeout): nunca terminal.
 * - Stock insuficiente: NO terminal. Es el único rechazo que el mundo puede
 *   revertir solo (entra mercadería, se cancela otro pedido), y el costo de un
 *   reintento de más es nulo; el de descartar un pedido legítimo, no.
 * - Sesión vencida / sucursal indeterminada: NO terminal; se arregla renovando.
 * - El resto (producto desactivado, compra mínima, total que no coincide,
 *   producto inexistente...) es determinista: reintentar sólo gasta la cola.
 */
export function rechazoEsTerminal(error: unknown): boolean {
  if (!esRechazoDeNegocio(error)) return false
  const mensaje = error.message
  if (PATRON_STOCK.test(mensaje)) return false
  if (pareceSesionVencida(mensaje)) return false
  return true
}
