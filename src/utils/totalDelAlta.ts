import { montoCobroAlta } from './saldoAFavor'
import { formatPrecio } from './formatters'

/**
 * Si el total que guardó el server para un alta es el que mandó el front, con la tolerancia
 * de un centavo del alta (`crear_pedido_completo` acepta `p_total` a un centavo de la suma
 * de las líneas y, desde 1559-b1, guarda la suma). Se compara en centavos enteros: en coma
 * flotante `Math.abs(99.99 - 100)` da 0.010000000000005116 y un `< 0.01` lo dejaba afuera.
 */
export function mismoTotalDelAlta(guardado: number, enviado: number): boolean {
  return Math.abs(Math.round(guardado * 100) - Math.round(enviado * 100)) <= 1
}

/**
 * Lo que dice el aviso cuando un pedido propio ya estaba cargado (entró en un intento anterior) y
 * después alguien lo cambió. Una sola frase para el replay de la cola y para el alta directa (decisión 5 del
 * dueño: no se registra ningún cobro; se dice el total que quedó y que hay que cobrar desde el pedido).
 */
export function mensajePedidoQueYaHabiaEntrado(id?: string | number | null, total?: number | null): string {
  const numero = id != null ? ` #${id}` : ''
  const queQuedo = typeof total === 'number' && Number.isFinite(total) ? `: ahora su total es ${formatPrecio(total)}` : ''
  return `El pedido${numero} ya estaba cargado (entró en un intento anterior) y después alguien lo cambió, por ejemplo ` +
    `porque se editó o se canceló${queQuedo}. No se cargó otro pedido y el cobro NO se registró. ` +
    'Cobralo desde el pedido, viendo el total real.'
}

/** Lo que el alta directa le pregunta a la respuesta del server (`crearPedido`). */
interface RespuestaDelAlta {
  id?: string | number | null
  idempotente?: boolean
  clienteId?: string | number | null
  total?: number | null
  cargoEnvio?: number | null
}

/**
 * El alta directa se reintenta con la misma clave (D56). Si el server contesta el pedido que ya tenía
 * (`idempotente`) y ese pedido es del mismo cliente pero con otro total, es el PROPIO cambiado después
 * (editado, cancelado, con una salvedad): no se creó nada, y decir «Pedido creado» miente. Devuelve el
 * aviso, o null si no aplica: no fue la rama idempotente, no hay total, es de otro cliente
 * (acá no puede pasar con una clave por intención) o está igual. Un vale blanco no tiene total
 * comparable (lo precia el server a costo) y no entra.
 */
export function avisoAltaQueYaHabiaEntrado(
  respuesta: RespuestaDelAlta | null | undefined,
  enviado: { clienteId: string | number | null | undefined; total: number; tipoFactura?: string | null },
): string | null {
  if (!respuesta || respuesta.idempotente !== true || enviado.tipoFactura === 'VB') return null
  if (typeof respuesta.total !== 'number') return null
  // Sin cliente es la fila que no se pudo leer (lo más probable con la señal floja que provocó el reintento):
  // la RPC sólo le contesta a quien cargó el pedido (mig 519) y la clave es por intención, así que es el propio
  // y decide el total de la RPC. Con cliente, tiene que ser el mismo.
  if (respuesta.clienteId != null && String(respuesta.clienteId) !== String(enviado.clienteId)) return null
  if (mismoTotalDelAlta(respuesta.total - (respuesta.cargoEnvio ?? 0), enviado.total)) return null
  return mensajePedidoQueYaHabiaEntrado(respuesta.id, respuesta.total)
}

/**
 * Lo que se cobra al crear el pedido (decisión 5 del dueño). Si el server contestó un pedido que ya existía y
 * NO es el que se mandó (`volvioDistinto`: lo editaron, lo cancelaron, le sumaron un renglón; ver
 * `avisoAltaQueYaHabiaEntrado`), NO se registra ningún cobro: se avisa y se cobra desde el pedido, viendo el
 * total real. Con el mismo total, o en un alta nueva, es la cuenta de siempre (`montoCobroAlta`).
 */
export function montoCobroDelAlta(args: {
  estadoPago: string
  montoDeclarado: number
  totalConEnvio: number
  totalGuardado: number
  saldoAplicado: number
  saldoMostrado?: number
  volvioDistinto: boolean
}): number {
  const { volvioDistinto, ...cuenta } = args
  if (volvioDistinto) return 0
  return montoCobroAlta(cuenta)
}
