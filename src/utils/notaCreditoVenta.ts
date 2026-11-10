/**
 * Nota de crédito de VENTA (#833, mig 276). No confundir con `notaCredito.ts`,
 * que es la de compras (proveedor).
 *
 * El caso: el cliente aceptó el pedido (quedó entregado) y después reclamó
 * vencidos. No se le devuelve plata: se le reconoce un crédito en su cuenta
 * corriente. Desde la mig 479 (COB-1, #1512) ese crédito baja primero su propia
 * boleta, si sigue impaga, y lo que sobra va FIFO a las otras boletas abiertas del
 * cliente, de la más vieja a la más nueva; sólo queda de saldo a favor lo que no
 * alcanza a ninguna. Anular la NC (COB-3) quita todo su crédito, suelto y ya
 * aplicado: las boletas que pagaba vuelven a deber eso. La NC es un documento aparte: NO toca el
 * pedido (ni total, ni ítems, ni estado), así que no afecta la venta por
 * vendedor ni la comisión, y no mueve stock.
 *
 * Esto es la cuenta que ve la UI antes de confirmar. La que vale es la de la
 * RPC `crear_nota_credito_venta_impl`, que toma el precio del pedido y vuelve a
 * validar las cantidades; las dos siguen la misma regla:
 *   - sólo líneas cobradas (un regalo de promoción no se cobró, no se acredita);
 *   - por línea, hasta lo entregado (`pedido_items.cantidad`, que ya descuenta
 *     las salvedades) menos lo acreditado en NCs no anuladas;
 *   - total = Σ cantidad × precio_unitario del pedido, y tiene que ser > 0.
 */

import { formatPrecio } from './formatters'

export const LEYENDA_NC_NO_AFECTA_COMISION = 'No afecta la comisión del vendedor'

export type MotivoNCVenta = 'producto_vencido' | 'producto_danado' | 'otro'

export const MOTIVOS_NC_VENTA: ReadonlyArray<{ value: MotivoNCVenta; label: string }> = [
  { value: 'producto_vencido', label: 'Producto vencido' },
  { value: 'producto_danado', label: 'Producto dañado' },
  { value: 'otro', label: 'Otro' },
]

export function motivoNCVentaLabel(motivo: string | null | undefined): string {
  return MOTIVOS_NC_VENTA.find(m => m.value === motivo)?.label ?? (motivo || '')
}

/** Lo mínimo de un `pedido_items` que hace falta para acreditar. */
export interface ItemPedidoParaNC {
  id: string | number
  producto_id: string | number
  cantidad: number
  precio_unitario: number | string
  es_bonificacion?: boolean | null
  producto?: { nombre?: string | null } | null
}

/** Lo mínimo de una NC ya emitida sobre el mismo pedido. */
export interface NCExistente {
  anulada?: boolean | null
  items?: ReadonlyArray<{ pedido_item_id?: string | number | null; cantidad: number }> | null
}

export interface LineaAcreditable {
  pedidoItemId: string
  productoId: string
  nombre: string
  entregada: number
  precioUnitario: number
  yaAcreditada: number
  /** Lo que todavía se puede acreditar de esta línea. */
  disponible: number
}

/**
 * Las líneas que se pueden acreditar de un pedido, con lo que queda disponible
 * en cada una. La clave es el `pedido_items.id` y no el producto: el mismo
 * producto puede venir en dos renglones (el bug que ya tuvo la NC de compras).
 */
export function lineasAcreditables(
  items: ReadonlyArray<ItemPedidoParaNC>,
  notasExistentes: ReadonlyArray<NCExistente> = [],
): LineaAcreditable[] {
  const acreditado = new Map<string, number>()
  for (const nc of notasExistentes) {
    if (nc.anulada) continue
    for (const it of nc.items ?? []) {
      if (it.pedido_item_id == null) continue
      const key = String(it.pedido_item_id)
      acreditado.set(key, (acreditado.get(key) ?? 0) + (Number(it.cantidad) || 0))
    }
  }

  return items
    .filter(it => !it.es_bonificacion && (Number(it.precio_unitario) || 0) > 0)
    .map(it => {
      const key = String(it.id)
      const entregada = Number(it.cantidad) || 0
      const yaAcreditada = acreditado.get(key) ?? 0
      return {
        pedidoItemId: key,
        productoId: String(it.producto_id),
        nombre: it.producto?.nombre || `Producto #${it.producto_id}`,
        entregada,
        precioUnitario: Number(it.precio_unitario) || 0,
        yaAcreditada,
        disponible: Math.max(0, entregada - yaAcreditada),
      }
    })
}

export type CantidadesNC = Readonly<Record<string, number>>

/** Total de la NC con las cantidades elegidas, redondeado a centavos. */
export function totalNotaCreditoVenta(
  lineas: ReadonlyArray<LineaAcreditable>,
  cantidades: CantidadesNC,
): number {
  const total = lineas.reduce((sum, l) => {
    const cant = cantidades[l.pedidoItemId] ?? 0
    return cant > 0 ? sum + cant * l.precioUnitario : sum
  }, 0)
  return Math.round(total * 100) / 100
}

/** `null` si se puede emitir; si no, el primer motivo en castellano. */
export function validarNotaCreditoVenta(
  lineas: ReadonlyArray<LineaAcreditable>,
  cantidades: CantidadesNC,
): string | null {
  let alguna = false
  for (const l of lineas) {
    const cant = cantidades[l.pedidoItemId] ?? 0
    if (cant === 0) continue
    if (!Number.isInteger(cant) || cant < 0) {
      return `Cantidad inválida para ${l.nombre}`
    }
    if (cant > l.disponible) {
      return `${l.nombre}: se pueden acreditar hasta ${l.disponible} (entregadas ${l.entregada}, ya acreditadas ${l.yaAcreditada})`
    }
    alguna = true
  }
  if (!alguna) return 'Elegí al menos un producto y su cantidad'
  if (totalNotaCreditoVenta(lineas, cantidades) <= 0) return 'El total tiene que ser mayor a $0'
  return null
}

/** Payload de `p_items` para la RPC: sólo las líneas con cantidad. */
export function itemsNotaCreditoParaRPC(
  lineas: ReadonlyArray<LineaAcreditable>,
  cantidades: CantidadesNC,
): Array<{ pedido_item_id: number; cantidad: number }> {
  return lineas
    .filter(l => (cantidades[l.pedidoItemId] ?? 0) > 0)
    .map(l => ({ pedido_item_id: Number(l.pedidoItemId), cantidad: cantidades[l.pedidoItemId] }))
}

/** Suma de las NCs vigentes (no anuladas) de una lista. */
export function totalNotasCreditoVigentes(
  notas: ReadonlyArray<{ total: number | string; anulada?: boolean | null }>,
): number {
  return notas.reduce((sum, n) => (n.anulada ? sum : sum + (Number(n.total) || 0)), 0)
}

/**
 * Adónde fue el crédito de una NC al emitirla (mig 479, COB-1). El server lo
 * contesta en `crear_nota_credito_venta`; si falta (un PWA viejo contra un server
 * nuevo, o al revés) cada parte cuenta como 0, y sin `credito_disponible` el
 * saldo suelto es lo que no se aplicó: con un server viejo, todo el total.
 */
export interface CreditoNCEmitida {
  total?: number | string | null
  credito_aplicado_pedido?: number | string | null
  credito_aplicado_otras?: number | string | null
  credito_disponible?: number | string | null
}

export interface ReparticionCreditoNC {
  /** Lo que bajó la boleta de origen. */
  aplicadoPedido: number
  /** Lo que fue FIFO a otras boletas abiertas del cliente. */
  aplicadoOtras: number
  /** Lo que quedó suelto, de saldo a favor. */
  disponible: number
}

const aCentavos = (n: unknown): number => {
  const v = Number(n)
  return Number.isFinite(v) ? Math.round(v * 100) / 100 : 0
}

export function reparticionCreditoNC(r: CreditoNCEmitida): ReparticionCreditoNC {
  const aplicadoPedido = aCentavos(r.credito_aplicado_pedido)
  const aplicadoOtras = aCentavos(r.credito_aplicado_otras)
  const disponible = r.credito_disponible == null
    ? Math.max(0, aCentavos(aCentavos(r.total) - aplicadoPedido - aplicadoOtras))
    : Math.max(0, aCentavos(r.credito_disponible))
  return { aplicadoPedido, aplicadoOtras, disponible }
}

/** Las líneas que cuentan adónde fue el crédito; sólo las que no son 0. */
export function lineasReparticionCreditoNC(rep: ReparticionCreditoNC): string[] {
  const lineas: string[] = []
  if (rep.aplicadoPedido > 0.005) lineas.push(`Se aplicaron ${formatPrecio(rep.aplicadoPedido)} a este pedido`)
  if (rep.aplicadoOtras > 0.005) lineas.push(`${formatPrecio(rep.aplicadoOtras)} a otras boletas del cliente`)
  if (rep.disponible > 0.005) lineas.push(`Quedan ${formatPrecio(rep.disponible)} de saldo a favor`)
  return lineas
}
