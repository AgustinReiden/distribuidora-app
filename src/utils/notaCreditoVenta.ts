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
 * pedido (ni total, ni ítems, ni estado).
 *
 * B22 (decisiones del dueño del 17 y 18/11): según el motivo, la mercadería de la nota
 * reingresa al stock (al lote del que salió), queda como merma o no se mueve, y anular la
 * nota lo deshace. El server la mueve sólo si cada renglón lo pide (`"mercaderia": true`):
 * un PWA anterior, que no lo manda, hace una nota sólo de plata, como dice su pantalla. Y el
 * descuento comercial se carga por MONTO, sin unidades: sobre toda la boleta (el server lo
 * reparte en proporción a lo que le queda a cada línea, al centavo y sin pasar lo que le
 * queda a ninguna, con `_nc_venta_repartir`; acá, su espejo `repartirDescuentoNC`) o sobre
 * uno o más renglones.
 *
 * Decisiones del dueño del 16/11 y del 17/11 (B16 de #1603, en #1545): la nota se
 * imputa al día de su boleta (`fecha` es la de la boleta, la que cuenta para los
 * reportes y la posición fiscal; cuándo se emitió es `created_at`), y su crédito
 * es plata del día en que se emitió. Le descuenta al vendedor de la boleta sólo
 * según su MOTIVO (la lista es una, `nc_venta_motivos()` del server, con espejo
 * en `constants/motivosNCVenta.espejo.json`), y sin ir hacia atrás: la comisión
 * ya liquidada y la meta ya cumplida o fuera de su mes no se mueven. Eso lo
 * decide el server al crear la nota y queda en `resta_comision` (y, por meta, en
 * una tabla de server).
 *
 * Esto es la cuenta que ve la UI antes de confirmar. La que vale es la de la
 * RPC `crear_nota_credito_venta_impl`, que toma el precio del pedido y vuelve a
 * validar las cantidades; las dos siguen la misma regla:
 *   - sólo líneas cobradas (un regalo de promoción no se cobró, no se acredita);
 *   - por línea, hasta lo entregado (`pedido_items.cantidad`, que ya descuenta
 *     las salvedades) menos lo acreditado en NCs no anuladas;
 *   - total = Σ cantidad × precio_unitario del pedido, y tiene que ser > 0.
 */

import { diaArgentino, formatFecha, formatPrecio } from './formatters'
import { redondearSQL } from './calculations'

export const LEYENDA_NC_COMISION =
  'Se imputa al mes de la boleta. Según el motivo, le descuenta o no al vendedor'

type FechasNC = { fecha: string; created_at?: string | null }

/** El día argentino (YYYY-MM-DD) en que se emitió la nota; sin `created_at`, su `fecha`. */
export function diaEmisionNotaCreditoVenta(nc: FechasNC): string {
  return nc.created_at ? diaArgentino(nc.created_at) : nc.fecha
}

/**
 * Las fechas de una nota para mostrar (B16): `fecha` es la de imputación (la de
 * su boleta) y `created_at`, cuándo se emitió. Si caen el mismo día argentino,
 * una sola; si no, las dos.
 */
export function fechasNotaCreditoVenta(nc: FechasNC): string {
  const emitida = diaEmisionNotaCreditoVenta(nc)
  if (emitida === nc.fecha) return formatFecha(nc.fecha)
  return `Imputada al ${formatFecha(nc.fecha)} (día de la boleta) · emitida el ${formatFecha(emitida)}`
}

export type MotivoNCVenta =
  | 'cliente_rechaza'
  | 'error_pedido'
  | 'error_entrega'
  | 'producto_vencido'
  | 'producto_danado'
  | 'descuento_comercial'
  | 'otro'

export interface MotivoNCVentaInfo {
  value: MotivoNCVenta
  label: string
  /** Resta de la comisión y de las metas del vendedor de la boleta. */
  descuentaVendedor: boolean
  /** Además de la plata, resta unidades (metas de unidades, Rendimiento). */
  descuentaUnidades: boolean
  /** Qué pasa con la mercadería acreditada (B22): vuelve al stock, queda como merma o nada. */
  mercaderia: 'reingresa' | 'merma' | 'nada'
}

/**
 * Espejo de `nc_venta_motivos()` (B16 v3, decisión del dueño del 17/11). Lo vigila
 * `constants/motivosNCVenta.espejo.test.ts`: si cambia la lista del server, cambia ésta.
 */
export const MOTIVOS_NC_VENTA: ReadonlyArray<MotivoNCVentaInfo> = [
  { value: 'cliente_rechaza', label: 'El cliente lo devuelve o lo rechaza', descuentaVendedor: true, descuentaUnidades: true, mercaderia: 'reingresa' },
  { value: 'error_pedido', label: 'El pedido se tomó mal', descuentaVendedor: true, descuentaUnidades: true, mercaderia: 'reingresa' },
  { value: 'error_entrega', label: 'Se entregó mal (producto equivocado, error de armado o de reparto)', descuentaVendedor: false, descuentaUnidades: false, mercaderia: 'reingresa' },
  { value: 'producto_vencido', label: 'Producto vencido', descuentaVendedor: false, descuentaUnidades: false, mercaderia: 'merma' },
  { value: 'producto_danado', label: 'Producto dañado', descuentaVendedor: false, descuentaUnidades: false, mercaderia: 'merma' },
  { value: 'descuento_comercial', label: 'Descuento comercial acordado después', descuentaVendedor: true, descuentaUnidades: false, mercaderia: 'nada' },
  { value: 'otro', label: 'Otro', descuentaVendedor: false, descuentaUnidades: false, mercaderia: 'nada' },
]

export function motivoNCVentaLabel(motivo: string | null | undefined): string {
  return MOTIVOS_NC_VENTA.find(m => m.value === motivo)?.label ?? (motivo || '')
}

/**
 * La línea que el modal muestra al elegir el motivo: si la nota le descuenta al
 * vendedor, y qué. La regla de «nada hacia atrás» la aplica el server.
 */
export function leyendaMotivoNCVenta(motivo: string | null | undefined): string {
  const m = MOTIVOS_NC_VENTA.find(x => x.value === motivo)
  if (!m || !m.descuentaVendedor) return 'Este motivo no le descuenta nada al vendedor.'
  const que = m.descuentaUnidades ? 'la plata y las unidades' : 'la plata (no las unidades)'
  return `Este motivo le descuenta al vendedor ${que}: de su comisión, si todavía no se liquidó, y de sus metas del mes que todavía no cumplió.`
}

/**
 * Qué pasa con la mercadería de la nota según su motivo (B22), en una línea para el modal.
 * La regla la aplica el server (`nc_venta_motivos().mercaderia`).
 */
export function leyendaMercaderiaNCVenta(motivo: string | null | undefined): string {
  const m = MOTIVOS_NC_VENTA.find(x => x.value === motivo)
  if (m?.mercaderia === 'reingresa') return 'Las unidades vuelven al stock, al lote del que salieron.'
  if (m?.mercaderia === 'merma') return 'Las unidades vuelven pero no se pueden vender: quedan como merma.'
  return 'No se mueve mercadería.'
}

/** Si el motivo mueve mercadería (reingresa o merma): sus renglones piden moverla al server. */
export function motivoMueveMercaderia(motivo: string | null | undefined): boolean {
  const m = MOTIVOS_NC_VENTA.find(x => x.value === motivo)?.mercaderia
  return m === 'reingresa' || m === 'merma'
}

/**
 * Lo que la nota va a hacer con la mercadería, con las unidades elegidas, ANTES de guardar
 * (H1 de la revisión): «Vuelven al stock 2 u.», «Van a merma 2 u.» o «No mueve stock».
 */
export function resumenMercaderiaNC(motivo: string | null | undefined, unidades: number): string {
  const m = MOTIVOS_NC_VENTA.find(x => x.value === motivo)?.mercaderia
  if (!(unidades > 0) || !m || m === 'nada') return 'No mueve stock'
  return m === 'reingresa' ? `Vuelven al stock ${unidades} u.` : `Van a merma ${unidades} u.`
}

/** El descuento comercial se carga por monto, sin unidades (B22). Es el único motivo que va así. */
export function esMotivoPorMonto(motivo: string | null | undefined): boolean {
  return motivo === 'descuento_comercial'
}

/** Lo mínimo de un `pedido_items` que hace falta para acreditar. */
export interface ItemPedidoParaNC {
  id: string | number
  producto_id: string | number | null
  cantidad: number
  precio_unitario: number | string
  /** Sin él, cantidad × precio. */
  subtotal?: number | string | null
  es_bonificacion?: boolean | null
  producto?: { nombre?: string | null } | null
}

/** Lo mínimo de una NC ya emitida sobre el mismo pedido. */
export interface NCExistente {
  anulada?: boolean | null
  items?: ReadonlyArray<{
    pedido_item_id?: string | number | null
    cantidad: number
    /** La plata del renglón (un descuento por monto tiene cantidad 0). Sin ella, cantidad × precio. */
    subtotal?: number | string | null
  }> | null
}

export interface LineaAcreditable {
  pedidoItemId: string
  productoId: string
  nombre: string
  entregada: number
  precioUnitario: number
  yaAcreditada: number
  /** Las unidades que todavía se pueden acreditar de esta línea. */
  disponible: number
  /** La plata que le queda a la línea: su subtotal menos lo que ya acreditaron las notas vigentes. */
  montoDisponible: number
}

const centavos = (n: number): number => Math.round(n * 100) / 100

/**
 * Las líneas que se pueden acreditar de un pedido, con lo que queda disponible
 * en cada una. La clave es el `pedido_items.id` y no el producto: el mismo
 * producto puede venir en dos renglones (el bug que ya tuvo la NC de compras).
 */
export function lineasAcreditables(
  items: ReadonlyArray<ItemPedidoParaNC>,
  notasExistentes: ReadonlyArray<NCExistente> = [],
): LineaAcreditable[] {
  const precioDe = new Map(items.map(it => [String(it.id), Number(it.precio_unitario) || 0]))
  const acreditado = new Map<string, number>()
  const acreditadoMonto = new Map<string, number>()
  for (const nc of notasExistentes) {
    if (nc.anulada) continue
    for (const it of nc.items ?? []) {
      if (it.pedido_item_id == null) continue
      const key = String(it.pedido_item_id)
      const cant = Number(it.cantidad) || 0
      const monto = it.subtotal != null ? Number(it.subtotal) || 0 : cant * (precioDe.get(key) ?? 0)
      acreditado.set(key, (acreditado.get(key) ?? 0) + cant)
      acreditadoMonto.set(key, (acreditadoMonto.get(key) ?? 0) + monto)
    }
  }

  return items
    // Un regalo (o una línea a precio 0) no se cobró: no se acredita. Una línea sin producto
    // (borrado antes de la FK) tampoco: el server la rechaza por unidades y la saltea por monto.
    .filter(it => !it.es_bonificacion && (Number(it.precio_unitario) || 0) > 0 && it.producto_id != null)
    .map(it => {
      const key = String(it.id)
      const entregada = Number(it.cantidad) || 0
      const precioUnitario = Number(it.precio_unitario) || 0
      const subtotal = it.subtotal != null ? Number(it.subtotal) || 0 : entregada * precioUnitario
      const yaAcreditada = acreditado.get(key) ?? 0
      return {
        pedidoItemId: key,
        productoId: String(it.producto_id),
        nombre: it.producto?.nombre || 'Producto sin nombre',
        entregada,
        precioUnitario,
        yaAcreditada,
        disponible: Math.max(0, entregada - yaAcreditada),
        montoDisponible: Math.max(0, centavos(subtotal - (acreditadoMonto.get(key) ?? 0))),
      }
    })
}

/**
 * Lo que acreditan `cant` unidades de una línea. Espejo de `crear_nota_credito_venta_impl`:
 * sin descuento previo en la línea es cantidad × precio; si la línea ya tiene un descuento
 * por monto (B22), cada unidad acredita lo que le queda a la línea por unidad y la última, lo
 * que quede; nunca más que cantidad × precio (D7: con un descuento ya anulado, lo que le queda a
 * la línea por unidad puede pasar el precio, y el server topea en el precio).
 */
export function montoUnidadesNC(l: LineaAcreditable, cant: number): number {
  if (!(cant > 0)) return 0
  const tope = cant * l.precioUnitario
  if (l.disponible <= 0 || Math.abs(l.montoDisponible - l.disponible * l.precioUnitario) < 0.005) {
    return tope
  }
  const resto = cant >= l.disponible
    ? l.montoDisponible
    : Math.max(0, redondearSQL(cant * l.montoDisponible / l.disponible, 2))
  return Math.min(tope, resto)
}

export type CantidadesNC = Readonly<Record<string, number>>

/** Total de la NC con las cantidades elegidas, redondeado a centavos. */
export function totalNotaCreditoVenta(
  lineas: ReadonlyArray<LineaAcreditable>,
  cantidades: CantidadesNC,
): number {
  const total = lineas.reduce((sum, l) => sum + montoUnidadesNC(l, cantidades[l.pedidoItemId] ?? 0), 0)
  return centavos(total)
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
    // H4 y N2 de la revisión de B22, espejo de crear_nota_credito_venta_impl: no hay renglón de $ 0.
    // Si un descuento se llevó la plata de la línea (toda, o toda menos unos centavos que no alcanzan
    // para estas unidades), la mercadería se devuelve anulando primero ese descuento.
    if (montoUnidadesNC(l, cant) <= 0) {
      return `A «${l.nombre}» ya se le acreditó ${l.montoDisponible > 0 ? 'casi ' : ''}toda su plata con un descuento. ` +
        'Para devolver la mercadería, anulá primero ese descuento.'
    }
    alguna = true
  }
  if (!alguna) return 'Elegí al menos un producto y su cantidad'
  if (totalNotaCreditoVenta(lineas, cantidades) <= 0) return 'El total tiene que ser mayor a $0'
  return null
}

/**
 * Payload de `p_items` para la RPC: sólo las líneas con cantidad. Con un motivo que mueve
 * mercadería, cada renglón la pide (`mercaderia: true`): sin la marca, el server no la mueve.
 */
export function itemsNotaCreditoParaRPC(
  lineas: ReadonlyArray<LineaAcreditable>,
  cantidades: CantidadesNC,
  motivo: string | null | undefined,
): Array<{ pedido_item_id: number; cantidad: number; mercaderia?: true }> {
  const mueve = motivoMueveMercaderia(motivo)
  return lineas
    .filter(l => (cantidades[l.pedidoItemId] ?? 0) > 0)
    .map(l => ({
      pedido_item_id: Number(l.pedidoItemId),
      cantidad: cantidades[l.pedidoItemId],
      ...(mueve ? { mercaderia: true as const } : {}),
    }))
}

/** Las unidades elegidas, en total (las que cuenta el resumen de la mercadería). */
export function unidadesNotaCreditoVenta(cantidades: CantidadesNC): number {
  return Object.values(cantidades).reduce((s, c) => s + (c > 0 ? c : 0), 0)
}

// ---------------------------------------------------------------------------
// B22 · el descuento comercial por monto
// ---------------------------------------------------------------------------

/** Lo que le queda a la boleta para acreditar: la suma de lo que le queda a cada línea. */
export function montoDisponibleBoleta(lineas: ReadonlyArray<LineaAcreditable>): number {
  return centavos(lineas.reduce((s, l) => s + l.montoDisponible, 0))
}

/** Un porcentaje de lo que le queda a la boleta, en plata (la pantalla lo muestra antes de emitir). */
export function montoDePorcentaje(lineas: ReadonlyArray<LineaAcreditable>, pct: number): number {
  if (!Number.isFinite(pct) || pct <= 0) return 0
  return redondearSQL(montoDisponibleBoleta(lineas) * pct / 100, 2)
}

/**
 * El porcentaje con sus números, para que se vea sobre qué se calcula (D6 de la revisión):
 * «10 % de $ 700 que quedan por acreditar = $ 70».
 */
export function leyendaPorcentajeNC(lineas: ReadonlyArray<LineaAcreditable>, pct: number): string {
  const queda = montoDisponibleBoleta(lineas)
  const pctTexto = String(pct).replace('.', ',')
  return `${pctTexto} % de ${formatPrecio(queda)} que quedan por acreditar = ${formatPrecio(montoDePorcentaje(lineas, pct))}`
}

const aCent = (n: number): bigint => BigInt(Math.round(n * 100))
const porId = (a: string, b: string): number => {
  const x = BigInt(a)
  const y = BigInt(b)
  return x < y ? -1 : x > y ? 1 : 0
}

/**
 * Espejo de `_nc_venta_repartir` (B22, H2 de la revisión): reparte `monto` en proporción a lo
 * que le queda a cada renglón (`restos`, por id), al centavo, con restos mayores y CON TOPE:
 * ninguna parte pasa lo que le queda a su renglón, y todo lo que queda entra entero. Cada
 * renglón recibe el piso de su parte; los centavos que faltan van, de a uno, a los de mayor
 * resto (empate: el de más peso, después el de menor id). Las partes en 0 no aparecen; `null`
 * si el monto pasa lo que queda (el server lo rechaza). Va en enteros grandes, como el
 * `numeric` del server: con montos grandes un double ya perdería centavos. Lo vigilan
 * `repartoDescuentoNC.espejo.test.ts` y, del lado SQL, `scripts/espejo-reparto-descuento-nc.mjs`,
 * con los mismos casos.
 */
export function repartirDescuentoNC(
  monto: number,
  restos: Readonly<Record<string, number>>,
): Record<string, number> | null {
  if (!Number.isFinite(monto) || aCent(monto) <= 0n) return {}
  const t = aCent(monto)
  const l = Object.entries(restos)
    .map(([id, r]) => ({ id, w: Number.isFinite(r) ? aCent(r) : 0n }))
    .filter(x => x.w > 0n)
  const w = l.reduce((s, x) => s + x.w, 0n)
  if (w === 0n || t > w) return null
  const b = l.map(x => ({ ...x, piso: (t * x.w) / w, resto: (t * x.w) % w }))
  let faltan = t - b.reduce((s, x) => s + x.piso, 0n)
  const orden = [...b].sort((x, y) => {
    if (x.resto !== y.resto) return y.resto > x.resto ? 1 : -1
    if (x.w !== y.w) return y.w > x.w ? 1 : -1
    return porId(x.id, y.id)
  })
  const partes: Record<string, number> = {}
  for (const x of orden) {
    const c = x.piso + (faltan > 0n ? 1n : 0n)
    if (faltan > 0n) faltan -= 1n
    if (c > 0n) partes[x.id] = Number(c) / 100
  }
  return partes
}

/**
 * Cómo se reparte un descuento sobre toda la boleta (la cuenta del server, con su espejo
 * `repartirDescuentoNC`). Las partes en 0 no aparecen; si el monto pasa lo que queda, nada.
 */
export function repartoDescuentoNC(
  lineas: ReadonlyArray<LineaAcreditable>,
  monto: number,
): Array<{ pedidoItemId: string; nombre: string; monto: number }> {
  // N5 de la revisión: el reparto sale del monto ya al centavo, el mismo número que se manda
  // (itemsDescuentoParaRPC); el campo guarda al centavo lo tipeado con más decimales.
  const alCentavo = redondearSQL(monto, 2)
  if (!(alCentavo > 0)) return []
  const restos: Record<string, number> = {}
  for (const l of lineas) if (l.montoDisponible > 0) restos[l.pedidoItemId] = l.montoDisponible
  const partes = repartirDescuentoNC(alCentavo, restos) ?? {}
  return lineas
    .filter(l => (partes[l.pedidoItemId] ?? 0) > 0)
    .map(l => ({ pedidoItemId: l.pedidoItemId, nombre: l.nombre, monto: partes[l.pedidoItemId] }))
}

export type MontosNC = Readonly<Record<string, number>>

/**
 * `null` si el descuento se puede emitir; si no, el primer motivo en castellano. `montos` es
 * `null` para toda la boleta (va `monto`) o, en el avanzado, el monto de cada renglón.
 */
export function validarDescuentoNC(
  lineas: ReadonlyArray<LineaAcreditable>,
  monto: number,
  montos: MontosNC | null,
): string | null {
  const queda = montoDisponibleBoleta(lineas)
  if (montos == null) {
    if (!Number.isFinite(monto) || redondearSQL(monto, 2) <= 0) return 'Escribí el monto del descuento'
    if (redondearSQL(monto, 2) > queda + 0.005) {
      return `El descuento (${formatPrecio(monto)}) pasa lo que le queda a la boleta (${formatPrecio(queda)})`
    }
    return null
  }
  let alguno = false
  for (const l of lineas) {
    const m = montos[l.pedidoItemId] ?? 0
    if (m === 0) continue
    if (!Number.isFinite(m) || m < 0) return `Monto inválido para ${l.nombre}`
    if (redondearSQL(m, 2) > l.montoDisponible + 0.005) {
      return `${l.nombre}: le quedan ${formatPrecio(l.montoDisponible)} por acreditar`
    }
    alguno = true
  }
  if (!alguno) return 'Elegí al menos un producto y su monto'
  return null
}

/** Payload de `p_items` para un descuento: `[{monto}]` sobre toda la boleta, o un renglón por producto. */
export function itemsDescuentoParaRPC(
  lineas: ReadonlyArray<LineaAcreditable>,
  monto: number,
  montos: MontosNC | null,
): Array<{ monto: number } | { pedido_item_id: number; monto: number }> {
  if (montos == null) return [{ monto: redondearSQL(monto, 2) }]
  return lineas
    .filter(l => (montos[l.pedidoItemId] ?? 0) > 0)
    .map(l => ({ pedido_item_id: Number(l.pedidoItemId), monto: redondearSQL(montos[l.pedidoItemId], 2) }))
}

/** Total del descuento que se va a emitir. */
export function totalDescuentoNC(monto: number, montos: MontosNC | null): number {
  if (montos == null) return monto > 0 ? redondearSQL(monto, 2) : 0
  return centavos(Object.values(montos).reduce((s, m) => s + (m > 0 ? redondearSQL(m, 2) : 0), 0))
}

/**
 * Lo que la nota hizo con la mercadería, para la ficha: si algún renglón reingresó o quedó como
 * merma (el server lo anota en `lotes_devueltos` / `merma_id`). `null` si no movió nada.
 */
export function mercaderiaDeNotaNC(nc: {
  motivo?: string | null
  items?: ReadonlyArray<{ lotes_devueltos?: unknown; merma_id?: string | number | null }> | null
}): 'reingresa' | 'merma' | null {
  const movio = (nc.items ?? []).some(it => it.lotes_devueltos != null || it.merma_id != null)
  if (!movio) return null
  return MOTIVOS_NC_VENTA.find(m => m.value === nc.motivo)?.mercaderia === 'merma' ? 'merma' : 'reingresa'
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
