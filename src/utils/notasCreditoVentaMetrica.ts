/**
 * La nota de crédito de venta en las cifras del Dashboard y de la ficha del cliente (REP-1,
 * tanda 6 de #1603; decisión del dueño del 24/11).
 *
 * La venta de los rankings es NETA de notas de crédito de venta (CLAUDE.md, «La venta de los
 * rankings es neta»): el gerencial, Ventas por cliente, por zona y por preventista y el tablero
 * ya le restan `_ventas_nc`. El Dashboard («Venta entregada», clientes más activos) y el «Total
 * comprado» de la ficha sumaban las boletas enteras: con 1.050 vendidos y 350 en notas, los
 * reportes decían 700 y el Dashboard 1.050.
 *
 * Qué resta, igual que `_ventas_nc`: la nota VIGENTE (no anulada) cuya boleta es venta
 * (entregada, canal distinto de 'cambio', tipo_factura distinto de 'VB'), por la fecha de la
 * nota (la de su boleta, B16), al cliente de la nota y al vendedor de la boleta. Resta plata y
 * toda nota, sea cual sea su motivo: es la venta de la empresa. No resta pedidos ni clientes.
 * La plata es `total` de la nota (nunca cantidad × precio, B22) y nunca incluye el envío.
 *
 * Quién la lee por REST: `mt_notas_credito_venta_select` es de admin y encargado de la sucursal
 * (`es_encargado_o_admin()`). Para un preventista la consulta vuelve vacía, sin error, y sus
 * cifras quedan brutas como hasta hoy (ver el informe de la tarjeta).
 */
import { esTipoVB } from './valeBlanco'

/**
 * Las columnas que se leen, con la boleta embebida por su FK (la única entre las dos tablas,
 * pero compuesta: el hint va por nombre de constraint, como `salvedades_items_pedido_id_fkey`).
 * No se embebe `perfiles`: la tabla tiene dos FKs a perfiles y un embed sin hint da PGRST201.
 */
export const NOTAS_VENTA_METRICA_SELECT =
  'id, fecha, cliente_id, total, anulada, pedido:pedidos!notas_credito_venta_pedido_id_fkey(estado, canal, tipo_factura, usuario_id)'

export interface NotaCreditoVentaMetricaRow {
  fecha?: string | null
  cliente_id: string | number
  total: number | string | null
  anulada?: boolean | null
  /** La boleta de la nota. Sin ella no se sabe si es venta: la nota no resta. */
  pedido?: {
    estado?: string | null
    canal?: string | null
    tipo_factura?: string | null
    usuario_id?: string | null
  } | null
}

export const montoDeNota = (n: { total: number | string | null }): number => {
  const v = Number(n.total)
  return Number.isFinite(v) ? v : 0
}

/** ¿Esta nota le resta a la venta? Vigente, de una boleta que es venta y con plata. */
export function notaRestaDeLaVenta(n: NotaCreditoVentaMetricaRow): boolean {
  if (n.anulada) return false
  const p = n.pedido
  if (!p) return false
  return p.estado === 'entregado'
    && p.canal !== 'cambio'
    && !esTipoVB(p.tipo_factura)
    && montoDeNota(n) > 0
}

/** Las notas que restan, de a una: la plata que le sacan a la venta. */
export function notasQueRestan(notas: readonly NotaCreditoVentaMetricaRow[]): NotaCreditoVentaMetricaRow[] {
  return notas.filter(notaRestaDeLaVenta)
}

/** Lo que las notas que restan le sacan a la venta, en total. */
export function totalNotasQueRestan(notas: readonly NotaCreditoVentaMetricaRow[]): number {
  return notasQueRestan(notas).reduce((s, n) => s + montoDeNota(n), 0)
}

/** Las notas de un día o de un rango `[desde, hasta]` inclusive ('YYYY-MM-DD'); null = sin tope. */
export function notasEnVentana(
  notas: readonly NotaCreditoVentaMetricaRow[],
  desde: string | null,
  hasta: string | null,
): NotaCreditoVentaMetricaRow[] {
  return notas.filter(n => {
    if (!n.fecha) return false
    if (desde && n.fecha < desde) return false
    if (hasta && n.fecha > hasta) return false
    return true
  })
}

/** Las notas de las boletas de un vendedor (el filtro del Dashboard de un preventista). */
export function notasDelVendedor(
  notas: readonly NotaCreditoVentaMetricaRow[],
  usuarioId: string,
): NotaCreditoVentaMetricaRow[] {
  return notas.filter(n => n.pedido?.usuario_id === usuarioId)
}
