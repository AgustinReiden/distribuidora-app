/**
 * Genera los PDF de la ruta: la Hoja de Ruta Optimizada y, aparte, el Manifiesto de Carga.
 * Formato: A4 horizontal con 3 columnas estilo comandera
 * Facilita la lectura al chofer: una sola hoja grande con varios pedidos
 */
import { jsPDF } from 'jspdf'
import type { PedidoDB, PerfilDB } from '../../types/hooks'
import {
  formatPrecio,
  formatFecha,
  generateFilename,
  drawCheckbox
} from './utils'
import { formatAclaracionBulto } from './utils/formatBulto'
import { FORMAS_PAGO_LABELS, FORMAS_PAGO_SHORT } from './constants'
import { bloqueDeudaComanda, deudaSinBoletasDelLote } from '../../utils/deudaCliente'
import { esRegaloSustituido, lineaItemImpresion, nombreDeLaLinea, nombreSinConteo, unidadDelRegalo } from './utils/lineaItem'
import { esCantidadEnSubunidades, factorDeLaLinea } from '../../utils/unidadesRegalo'
import { barridasEfectivas, ETIQUETA_BARRIDA, type Barrida } from '../../utils/barridas'
import { horarioParaRutear } from '../../hooks/useOptimizarRuta'

/** Info opcional de ruta para el encabezado (fecha, duracion, distancia). */
export interface InfoRuta {
  fecha?: string | Date
  distancia_formato?: string
  duracion_formato?: string
}

// === Layout A4 horizontal ===
const PAGE_WIDTH = 297
const PAGE_HEIGHT = 210
const PAGE_MARGIN = 8
const COLUMN_COUNT = 3
const COLUMN_GAP = 5
const COLUMN_WIDTH =
  (PAGE_WIDTH - PAGE_MARGIN * 2 - COLUMN_GAP * (COLUMN_COUNT - 1)) / COLUMN_COUNT
const CARD_INNER_PADDING = 2
const CARD_CONTENT_WIDTH = COLUMN_WIDTH - CARD_INNER_PADDING * 2
const CARD_BOTTOM_SPACING = 3

type CardOp =
  | { kind: 'text'; text: string; fontSize: number; bold: boolean; advance: number }
  | { kind: 'product'; text: string; subtotal: string | null; fontSize: number; advance: number }
  | { kind: 'total'; label: string; value: string; fontSize: number; advance: number }
  | { kind: 'italic'; text: string; fontSize: number; advance: number }
  | { kind: 'entregado'; pago: string | null; advance: number }
  | { kind: 'deuda'; monto: string; advance: number }
  | { kind: 'deuda-pago'; advance: number }
  | { kind: 'divider'; advance: number }
  | { kind: 'spacer'; advance: number }

type ManifiestoOp =
  | { kind: 'manifiesto-title'; text: string; advance: number }
  | { kind: 'manifiesto-subtitle'; text: string; advance: number }
  | { kind: 'manifiesto-rubro'; text: string; advance: number }
  | { kind: 'manifiesto-subrubro'; text: string; advance: number }
  | { kind: 'manifiesto-line'; cantidad: string; nombre: string; advance: number }
  | { kind: 'manifiesto-firma'; advance: number }
  | { kind: 'spacer'; advance: number }

type CierreOp =
  | { kind: 'cierre-title'; text: string; advance: number }
  | { kind: 'cierre-line'; text: string; advance: number }

/** Contexto que drawManifiestoOps usa para fluir entre columnas/paginas. */
interface ManifiestoCtx {
  columnX: () => number
  advanceColumn: () => void
  readonly columnTop: number
  columnBottom: number
  startY: number
}

/**
 * Dibuja el encabezado de la pagina.
 * @returns Posicion Y donde comienzan las columnas
 */
function drawPageHeader(
  doc: jsPDF,
  transportista: PerfilDB | null | undefined,
  pedidos: PedidoDB[],
  infoRuta: InfoRuta,
  showSummary: boolean,
  titulo = 'HOJA DE RUTA'
): number {
  let y = PAGE_MARGIN

  doc.setTextColor(0, 0, 0)
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(16)
  doc.text(titulo, PAGE_WIDTH / 2, y + 5, { align: 'center' })

  doc.setFont('helvetica', 'normal')
  doc.setFontSize(11)
  doc.text(transportista?.nombre || 'Transportista', PAGE_MARGIN, y + 5)

  doc.setFontSize(10)
  doc.text(formatFecha(infoRuta?.fecha || new Date()), PAGE_WIDTH - PAGE_MARGIN, y + 5, { align: 'right' })

  y += 9

  // Linea de metricas + resumen
  const metricas = []
  metricas.push(`${pedidos.length} entregas`)
  if (infoRuta?.duracion_formato) metricas.push(infoRuta.duracion_formato)
  if (infoRuta?.distancia_formato) metricas.push(infoRuta.distancia_formato)

  doc.setFontSize(9)
  doc.text(metricas.join('  |  '), PAGE_MARGIN, y)

  if (showSummary) {
    // Solo el TOTAL de la ruta. Se quitó "PENDIENTE" (saldo deudor de clientes):
    // no corresponde al encabezado. La deuda anterior va por parada, en la tarjeta.
    const totalGeneral = pedidos.reduce((sum, p) => sum + (p.total || 0), 0)
    doc.setFont('helvetica', 'bold')
    doc.text(
      `TOTAL: ${formatPrecio(totalGeneral)}`,
      PAGE_WIDTH - PAGE_MARGIN,
      y,
      { align: 'right' }
    )
    doc.setFont('helvetica', 'normal')
  }

  y += 3
  doc.setDrawColor(80, 80, 80)
  doc.setLineWidth(0.5)
  doc.line(PAGE_MARGIN, y, PAGE_WIDTH - PAGE_MARGIN, y)

  return y + 3
}

/** Formas de pago que ofrece la línea de deuda para anotar cómo se cobra. */
const FORMAS_COBRO_DEUDA = ['efectivo', 'transferencia', 'cheque'] as const

const abreviarFormaPago = (forma: string): string =>
  FORMAS_PAGO_SHORT[forma] || FORMAS_PAGO_LABELS[forma] || forma

/**
 * Forma de pago de la parada, abreviada para la tarjeta. Mismo criterio que
 * `getFormaPagoDisplay` (la card del pedido): mandan los pagos registrados, y
 * sin pagos la forma con la que se cargó el pedido. Un pago dividido muestra
 * TODAS sus formas ("Efvo + Transf"), no "Combinado": el chofer tiene que saber
 * qué cobra. Vacío si no hay ninguna.
 */
export function formaPagoParada(pedido: Pick<PedidoDB, 'forma_pago' | 'pagos'>): string {
  const formas = Array.from(new Set((pedido.pagos || []).map((p) => p.forma_pago).filter(Boolean)))
  if (formas.length === 0 && pedido.forma_pago) formas.push(pedido.forma_pago)
  return formas.map(abreviarFormaPago).join(' + ')
}

/**
 * Estructura las operaciones de layout de una card de pedido.
 * Produce lineas tipadas que tanto el dry-run (medir) como el draw aplican.
 */
export function buildCardOps(doc: jsPDF, pedido: PedidoDB, orderNumber: number): CardOp[] {
  const ops: CardOp[] = []

  // Nombre cliente + numero
  const headerText = `${orderNumber}. ${pedido.cliente?.nombre_fantasia || 'Sin cliente'}`
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(11)
  const headerLines = doc.splitTextToSize(headerText, CARD_CONTENT_WIDTH)
  headerLines.forEach((line: string) => {
    ops.push({ kind: 'text', text: line, fontSize: 11, bold: true, advance: 5 })
  })

  // Parada de cambio/devolución (canal='cambio'): cartel prominente + qué
  // retirar/entregar (si el detalle está disponible en pedido.cambio).
  const esCambio = pedido.canal === 'cambio'
  if (esCambio) {
    ops.push({ kind: 'text', text: '** CAMBIO / DEVOLUCION **', fontSize: 10, bold: true, advance: 5 })
    // recorrido_cambios puede venir como objeto o array según el origen.
    const c = Array.isArray(pedido.cambio) ? pedido.cambio[0] : pedido.cambio
    if (c) {
      const retirar = `Retirar: ${c.cantidad_devuelta ?? '?'}x ${c.producto_devuelto_nombre || 'producto'}`
      const entregar = `Entregar: ${c.cantidad_entregada ?? '?'}x ${c.producto_entregado_nombre || 'producto'}`
      doc.setFont('helvetica', 'normal')
      doc.setFontSize(9)
      doc.splitTextToSize(retirar, CARD_CONTENT_WIDTH).forEach((line: string) => {
        ops.push({ kind: 'text', text: line, fontSize: 9, bold: false, advance: 4 })
      })
      doc.splitTextToSize(entregar, CARD_CONTENT_WIDTH).forEach((line: string) => {
        ops.push({ kind: 'text', text: line, fontSize: 9, bold: false, advance: 4 })
      })
      if (c.observaciones) {
        doc.splitTextToSize(`* ${c.observaciones}`, CARD_CONTENT_WIDTH).slice(0, 2).forEach((line: string) => {
          ops.push({ kind: 'italic', text: line, fontSize: 8, advance: 3.5 })
        })
      }
    }
  }

  // Razon social en linea aparte si existe y difiere del nombre de fantasia
  if (pedido.cliente?.razon_social && pedido.cliente.razon_social !== pedido.cliente.nombre_fantasia) {
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(9)
    const razonLines = doc.splitTextToSize(pedido.cliente.razon_social, CARD_CONTENT_WIDTH)
    razonLines.slice(0, 2).forEach((line: string) => {
      ops.push({ kind: 'text', text: line, fontSize: 9, bold: false, advance: 4 })
    })
  }

  // Direccion
  if (pedido.cliente?.direccion) {
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(9)
    const dirLines = doc.splitTextToSize(pedido.cliente.direccion, CARD_CONTENT_WIDTH)
    dirLines.slice(0, 2).forEach((line: string) => {
      ops.push({ kind: 'text', text: line, fontSize: 9, bold: false, advance: 4 })
    })
  }

  // Aclaracion de direccion (info extra para el repartidor: timbre, referencias)
  if (pedido.cliente?.aclaracion_direccion) {
    doc.setFont('helvetica', 'italic')
    doc.setFontSize(8)
    const aclLines = doc.splitTextToSize(pedido.cliente.aclaracion_direccion, CARD_CONTENT_WIDTH)
    aclLines.slice(0, 2).forEach((line: string) => {
      ops.push({ kind: 'italic', text: line, fontSize: 8, advance: 3.5 })
    })
  }

  // Telefono
  if (pedido.cliente?.telefono) {
    ops.push({
      kind: 'text',
      text: `Tel: ${pedido.cliente.telefono}`,
      fontSize: 9,
      bold: false,
      advance: 4
    })
  }

  // Horarios de atencion
  if (pedido.cliente?.horarios_atencion) {
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(9)
    const horLines = doc.splitTextToSize(
      `Horario: ${pedido.cliente.horarios_atencion}`,
      CARD_CONTENT_WIDTH
    )
    horLines.slice(0, 2).forEach((line: string) => {
      ops.push({ kind: 'text', text: line, fontSize: 9, bold: false, advance: 4 })
    })
  }

  // Horario de entrega pedido por el cliente (destacado para el chofer)
  if (pedido.cliente?.horario_entrega) {
    doc.setFont('helvetica', 'bold')
    doc.setFontSize(9)
    const entLines = doc.splitTextToSize(
      `ENTREGAR: ${pedido.cliente.horario_entrega}`,
      CARD_CONTENT_WIDTH
    )
    entLines.slice(0, 2).forEach((line: string) => {
      ops.push({ kind: 'text', text: line, fontSize: 9, bold: true, advance: 4 })
    })
  }

  // (Se quitó la línea "Total + estado de pago" por cliente a pedido del negocio.
  // El total del pedido sigue al pie como "Total pedido", y la deuda de boletas
  // ANTERIORES va abajo, en su propia línea.)

  // Productos: las bonificaciones van en una lista aparte abajo de los items
  // comprados, con la unidad bien aclarada (botellas/paquetes sueltos vs
  // fardos) para que el chofer no mezcle unidades al cargar/descargar.
  doc.setFont('helvetica', 'normal')
  doc.setFontSize(9)
  const priceColWidth = 24
  const productWrapWidth = CARD_CONTENT_WIDTH - priceColWidth
  const itemsComprados = (pedido.items || []).filter((i) => !i.es_bonificacion)
  const itemsBonificados = (pedido.items || []).filter((i) => i.es_bonificacion)

  itemsComprados.forEach((item) => {
    const nombre = item.producto?.nombre || 'Producto'
    const subtotal = (item.precio_unitario || 0) * item.cantidad
    const aclaracion = formatAclaracionBulto(
      item.cantidad,
      item.producto?.unidades_de_venta_por_fardo,
      item.producto?.etiqueta_bulto,
    )
    const linea = aclaracion
      ? `${item.cantidad}x ${nombre} ${aclaracion}`
      : `${item.cantidad}x ${nombre}`
    const itemLines = doc.splitTextToSize(linea, productWrapWidth)
    itemLines.forEach((line: string, idx: number) => {
      ops.push({
        kind: 'product',
        text: line,
        subtotal: idx === 0 ? formatPrecio(subtotal) : null,
        fontSize: 9,
        advance: 4
      })
    })
  })

  if (itemsBonificados.length > 0) {
    ops.push({ kind: 'spacer', advance: 0.5 })
    ops.push({
      kind: 'text',
      text: 'PRODUCTOS BONIFICADOS:',
      fontSize: 8.5,
      bold: true,
      advance: 4
    })
    itemsBonificados.forEach((item) => {
      // Regalo de tipo Fracción: cantidad en subunidades (botellas/paquetes).
      // Regalo de unidad entera: cantidad en unidades de venta, con la
      // aclaración de fardos si aplica. Cuál de los dos es lo decide la cascada
      // de unidadesRegalo (factor congelado primero), no el factor vivo de la
      // promo: con el vivo, subir el factor de 6 a 12 partía el manifiesto de
      // un pedido viejo en la mitad de los fardos que hay que cargar.
      // La lista ya va bajo "PRODUCTOS BONIFICADOS" y con "BONIF" en la columna
      // de precio, así que no se repite el sufijo (REGALO).
      const linea = lineaItemImpresion(item, { marcarRegalo: false })
      const itemLines = doc.splitTextToSize(linea, productWrapWidth)
      itemLines.forEach((line: string, idx: number) => {
        ops.push({
          kind: 'product',
          text: line,
          subtotal: idx === 0 ? 'BONIF' : null,
          fontSize: 9,
          advance: 4
        })
      })
    })
  }

  // Total pedido (no aplica a paradas de cambio: total 0, no es una venta)
  if (!esCambio) {
    ops.push({ kind: 'spacer', advance: 1 })
    ops.push({
      kind: 'total',
      label: 'Total pedido:',
      value: formatPrecio(pedido.total),
      fontSize: 10,
      advance: 4.5
    })
  }

  // Deuda anterior: boletas previas impagas (deuda_previa, sin contar este
  // pedido), calculada al momento de imprimir. Se cobra muchas veces con otra
  // forma que el pedido, así que la línea deja marcar con qué paga.
  const deuda = bloqueDeudaComanda(pedido.deuda_previa, pedido.deuda_previa_detalle)
  if (deuda) {
    ops.push({ kind: 'spacer', advance: 1 })
    ops.push({ kind: 'deuda', monto: formatPrecio(deuda.total), advance: 4.5 })
    ops.push({ kind: 'deuda-pago', advance: 5 })
  }

  // Notas
  if (pedido.notas) {
    doc.setFont('helvetica', 'italic')
    doc.setFontSize(9)
    const notasLines = doc.splitTextToSize(`* ${pedido.notas}`, CARD_CONTENT_WIDTH)
    notasLines.slice(0, 2).forEach((line: string) => {
      ops.push({ kind: 'italic', text: line, fontSize: 9, advance: 4 })
    })
  }

  // Entregado + forma de pago. La firma del cliente va en la comanda, no acá.
  // Una parada de cambio no cobra nada: sin forma de pago.
  ops.push({ kind: 'spacer', advance: 1 })
  ops.push({ kind: 'entregado', pago: esCambio ? null : formaPagoParada(pedido), advance: 4.5 })

  // Divisor
  ops.push({ kind: 'divider', advance: CARD_BOTTOM_SPACING })

  return ops
}

function measureCardHeight(ops: CardOp[]): number {
  return ops.reduce((sum, op) => sum + (op.advance || 0), 0)
}

function drawCardOps(doc: jsPDF, ops: CardOp[], x: number, yStart: number): number {
  const innerX = x + CARD_INNER_PADDING
  const right = x + COLUMN_WIDTH - CARD_INNER_PADDING
  let y = yStart

  ops.forEach((op) => {
    switch (op.kind) {
      case 'text': {
        doc.setFont('helvetica', op.bold ? 'bold' : 'normal')
        doc.setFontSize(op.fontSize)
        doc.setTextColor(0, 0, 0)
        doc.text(op.text, innerX, y + op.fontSize * 0.28)
        break
      }
      case 'product': {
        doc.setFont('helvetica', 'normal')
        doc.setFontSize(op.fontSize)
        doc.setTextColor(0, 0, 0)
        doc.text(op.text, innerX, y + op.fontSize * 0.28)
        if (op.subtotal) {
          doc.text(op.subtotal, right, y + op.fontSize * 0.28, { align: 'right' })
        }
        break
      }
      case 'total': {
        doc.setFont('helvetica', 'bold')
        doc.setFontSize(op.fontSize)
        doc.setTextColor(0, 0, 0)
        doc.text(op.label, innerX, y + op.fontSize * 0.28)
        doc.text(op.value, right, y + op.fontSize * 0.28, { align: 'right' })
        break
      }
      case 'italic': {
        doc.setFont('helvetica', 'italic')
        doc.setFontSize(op.fontSize)
        doc.setTextColor(60, 60, 60)
        doc.text(op.text, innerX, y + op.fontSize * 0.28)
        doc.setTextColor(0, 0, 0)
        break
      }
      case 'entregado': {
        doc.setFont('helvetica', 'normal')
        doc.setFontSize(9)
        doc.setTextColor(0, 0, 0)
        doc.setDrawColor(80, 80, 80)
        drawCheckbox(doc, innerX, y, 3)
        doc.text('Entregado', innerX + 4.5, y + 2.5)
        if (op.pago !== null) {
          // Sin forma cargada queda el espacio para anotarla.
          doc.text('Pago: ', innerX + 24, y + 2.5)
          doc.setFont('helvetica', 'bold')
          doc.text(op.pago || '______________', innerX + 24 + doc.getTextWidth('Pago: '), y + 2.5)
        }
        break
      }
      case 'deuda': {
        doc.setFont('helvetica', 'bold')
        doc.setFontSize(9)
        doc.setTextColor(0, 0, 0)
        doc.text('Deuda anterior:', innerX, y + 9 * 0.28)
        doc.text(op.monto, right, y + 9 * 0.28, { align: 'right' })
        break
      }
      case 'deuda-pago': {
        doc.setFont('helvetica', 'normal')
        doc.setFontSize(8.5)
        doc.setTextColor(0, 0, 0)
        doc.setDrawColor(80, 80, 80)
        doc.text('Paga con:', innerX, y + 2.5)
        let cx = innerX + 15
        FORMAS_COBRO_DEUDA.forEach((forma) => {
          drawCheckbox(doc, cx, y, 3)
          const etiqueta = abreviarFormaPago(forma)
          doc.text(etiqueta, cx + 4, y + 2.5)
          cx += 4 + doc.getTextWidth(etiqueta) + 5
        })
        break
      }
      case 'divider': {
        doc.setDrawColor(170, 170, 170)
        doc.setLineWidth(0.2)
        doc.line(x + 1, y + 1.5, x + COLUMN_WIDTH - 1, y + 1.5)
        break
      }
      case 'spacer':
      default:
        break
    }
    y += op.advance || 0
  })

  return y
}

function buildCierreOps(pedidos: PedidoDB[]): CierreOp[] {
  const ops: CierreOp[] = []
  ops.push({ kind: 'cierre-title', text: 'CIERRE DE JORNADA', advance: 6 })
  ops.push({ kind: 'cierre-line', text: 'Cobrado efectivo: ________________________', advance: 5.5 })
  ops.push({ kind: 'cierre-line', text: 'Cobrado transferencia: __________________', advance: 5.5 })
  ops.push({ kind: 'cierre-line', text: `Entregas: _____ de ${pedidos.length}`, advance: 5.5 })
  ops.push({ kind: 'cierre-line', text: 'Firma: ____________________________________', advance: 5.5 })
  return ops
}

/** Una fila acumulada del manifiesto (venta, bonif fardos/sueltas o cambio). */
interface FilaTotal {
  nombre: string
  cantidad: number
  grupo: GrupoManifiesto
  unidades_de_venta_por_fardo?: number | null
  etiqueta_bulto?: string | null
  preConvertidoAFardos?: boolean
  /** Producto de una fila de sueltas, para desambiguar descripciones iguales. */
  producto?: string
  /** Fila de sueltas cuyo nombre es el del producto pelado, sin unidad adelante. */
  sinUnidad?: boolean
}

/** Bonif de tipo Fracción acumulada en subunidades crudas, antes de partir. */
interface FilaFraccion {
  key: string
  nombre: string
  desc: string
  upb: number
  subunidades: number
  grupo: GrupoManifiesto
  sinUnidad: boolean
}

/** Rubro sin asignar: el manifiesto lo agrupa aparte y lo pone al final. */
export const SIN_RUBRO = 'Sin rubro'

/** Rubro → subrubro de un producto, como lo agrupa el manifiesto (mig 270). */
export interface GrupoManifiesto {
  rubro: string
  subrubro: string | null
}

/** Lo que el manifiesto necesita saber de un producto para agruparlo. */
export interface ProductoCatalogoManifiesto {
  id?: string | number
  categoria?: string | null
  subcategoria_id?: string | null
}

/**
 * Opciones del manifiesto. `nombresSubrubro` traduce `subcategoria_id` a nombre
 * (el embed de la query no lo trae: dos FKs de productos a categorias darian
 * PGRST201). `productos` es el catalogo vivo: resuelve el rubro de lo que no
 * trae producto embebido, como el producto que se ENTREGA en una parada de cambio.
 */
export interface OpcionesManifiesto {
  nombresSubrubro?: Record<string, string> | Map<string, string>
  productos?: ProductoCatalogoManifiesto[]
}

const nombreDeSubrubro = (id: string | null | undefined, nombres: OpcionesManifiesto['nombresSubrubro']): string | null => {
  if (!id || !nombres) return null
  const nombre = nombres instanceof Map ? nombres.get(String(id)) : nombres[String(id)]
  return nombre?.trim() || null
}

function grupoDeProducto(
  producto: ProductoCatalogoManifiesto | null | undefined,
  opciones: OpcionesManifiesto,
): GrupoManifiesto {
  const rubro = producto?.categoria?.trim()
  if (!rubro) return { rubro: SIN_RUBRO, subrubro: null }
  return { rubro, subrubro: nombreDeSubrubro(producto?.subcategoria_id, opciones.nombresSubrubro) }
}

/**
 * Rubros en orden alfabetico con "Sin rubro" al final; dentro de cada rubro, lo
 * que no tiene subrubro primero y despues los subrubros alfabeticos.
 */
function compararGrupos(a: GrupoManifiesto, b: GrupoManifiesto): number {
  if (a.rubro !== b.rubro) {
    if (a.rubro === SIN_RUBRO) return 1
    if (b.rubro === SIN_RUBRO) return -1
    return a.rubro.localeCompare(b.rubro, 'es')
  }
  if (a.subrubro === b.subrubro) return 0
  if (a.subrubro === null) return -1
  if (b.subrubro === null) return 1
  return a.subrubro.localeCompare(b.subrubro, 'es')
}

/**
 * Suma todas las cantidades por producto entre todos los pedidos y
 * produce operaciones de layout para el manifiesto de carga del camion.
 *
 * Para regalos de tipo Fracción (item.es_bonificacion + unidades_por_bloque):
 * convierte la cantidad en subunidades a "fardos completos + botellas sueltas".
 * Los fardos se suman al producto contenedor (mismo producto_id que el item).
 * Las botellas sueltas se listan en una fila aparte usando descripcion_regalo,
 * para que el chofer sepa que carga 1 fardo + N botellas individuales. Si el
 * regalo se sustituyó, la fila nombra al sustituto (nombreDeLaLinea), que es lo
 * que se carga.
 */
export function buildManifiestoOps(doc: jsPDF, pedidos: PedidoDB[], opciones: OpcionesManifiesto = {}): ManifiestoOp[] {
  const catalogoPorId = new Map<string, ProductoCatalogoManifiesto>()
  ;(opciones.productos ?? []).forEach((p) => { if (p.id != null) catalogoPorId.set(String(p.id), p) })

  const totalesCompras: Record<string, FilaTotal> = {} // por producto_id (items vendidos)
  const totalesCambios: Record<string, FilaTotal> = {} // entregados de paradas de cambio (canal='cambio'), sección aparte
  const totalesBonifFardos: Record<string, FilaTotal> = {} // por producto_id (bonifs en unidades de venta / fardos)
  const totalesBonifSueltas: Record<string, FilaTotal> = {} // por descripcion_regalo (botellas/paquetes sueltos)
  // Bonifs de tipo Fracción: se acumulan en subunidades CRUDAS por producto y se
  // parten a fardos+sueltas UNA sola vez sobre el total de la ruta (ver abajo),
  // así no quedan más sueltas que un fardo por sumar restos pedido por pedido.
  const totalesBonifFraccion: Record<string, FilaFraccion> = {} // `${id}|${desc}|${upb}` → { key, nombre, desc, upb, subunidades }

  const acumular = (mapa: Record<string, FilaTotal>, key: string, nombre: string, cantidad: number, grupo: GrupoManifiesto): FilaTotal => {
    if (!mapa[key]) mapa[key] = { nombre, cantidad: 0, grupo }
    mapa[key].cantidad += cantidad
    return mapa[key]
  }

  pedidos.forEach((pedido) => {
    ;(pedido.items || []).forEach((item) => {
      const cantidad = Number(item.cantidad) || 0
      if (cantidad <= 0) return

      const key = item.producto_id ?? item.producto?.id ?? item.producto?.nombre ?? 'sin-id'
      const nombreProducto = item.producto?.nombre || 'Producto'
      // Factor de ESTA línea: congelado al crear → vivo (sólo si la promo no
      // mueve stock) → 1. Con el vivo, subir el factor de una promo de 6 a 12
      // convertía 392 botellas ya vendidas en 32 fardos en vez de 65.
      const factor = factorDeLaLinea(item)
      // Sustituido: la descripción nombra el producto ORIGINAL; la fila lleva la
      // unidad de la promo con el nombre del sustituto, igual que la tarjeta.
      const sustituido = esRegaloSustituido(item)
      const desc = sustituido ? nombreDeLaLinea(item) : nombreSinConteo(item.descripcion_regalo)
      const grupo = grupoDeProducto(
        // El catalogo vivo manda: donde esta el producto hoy en el deposito.
        (catalogoPorId.get(String(item.producto_id ?? item.producto?.id)) ?? item.producto) as ProductoCatalogoManifiesto | undefined,
        opciones,
      )

      // Compras → lista principal, con aclaración (N FARDOS) si aplica.
      if (!item.es_bonificacion) {
        const fila = acumular(totalesCompras, key, nombreProducto, cantidad, grupo)
        if (fila.unidades_de_venta_por_fardo == null) {
          fila.unidades_de_venta_por_fardo = item.producto?.unidades_de_venta_por_fardo ?? null
        }
        if (fila.etiqueta_bulto == null) {
          fila.etiqueta_bulto = item.producto?.etiqueta_bulto ?? null
        }
        return
      }

      // Bonificación de tipo Fracción: acumular en subunidades crudas. El split
      // a fardos+sueltas se hace al final sobre el total consolidado de la ruta.
      if (esCantidadEnSubunidades(item)) {
        // El factor entra en la clave: dos líneas del mismo producto con
        // factores distintos (una promo que cambió) están en unidades distintas
        // y sumarlas crudas daría cualquier cosa.
        const fkey = `${key}|${desc}|${factor}`
        if (!totalesBonifFraccion[fkey]) {
          totalesBonifFraccion[fkey] = {
            key,
            nombre: nombreProducto,
            desc: desc || nombreProducto,
            upb: factor,
            subunidades: 0,
            grupo,
            // Sin unidad que pluralizar: un sustituto cuya promo no la nombra, o
            // un regalo sin descripción, que cae al nombre del producto (#938).
            sinUnidad: sustituido ? !unidadDelRegalo(item.descripcion_regalo) : !desc,
          }
        }
        totalesBonifFraccion[fkey].subunidades += cantidad
        return
      }

      // Bonificación de unidad entera: en unidades de venta del producto.
      const fila = acumular(totalesBonifFardos, key, nombreProducto, cantidad, grupo)
      if (fila.unidades_de_venta_por_fardo == null) {
        fila.unidades_de_venta_por_fardo = item.producto?.unidades_de_venta_por_fardo ?? null
      }
      if (fila.etiqueta_bulto == null) {
        fila.etiqueta_bulto = item.producto?.etiqueta_bulto ?? null
      }
    })
  })

  // Paradas de cambio/devolución (canal='cambio'): el producto que se ENTREGA al
  // cliente también hay que cargarlo, pero va en una sección APARTE del manifiesto
  // (no se mezcla con la venta del día). El detalle vive en recorrido_cambios
  // (cargado como pedido.cambio en la hoja de ruta).
  pedidos.forEach((pedido) => {
    if (pedido.canal !== 'cambio') return
    const c = Array.isArray(pedido.cambio) ? pedido.cambio[0] : pedido.cambio
    if (!c) return
    const cantidad = Number(c.cantidad_entregada) || 0
    if (cantidad <= 0) return
    const key = String(c.producto_entregado_id ?? c.producto_entregado_nombre ?? 'cambio-sin-id')
    acumular(
      totalesCambios,
      key,
      c.producto_entregado_nombre || 'Producto',
      cantidad,
      grupoDeProducto(catalogoPorId.get(String(c.producto_entregado_id)), opciones),
    )
  })

  // Partir las fracciones consolidadas UNA vez por producto: fardos completos +
  // el resto como sueltas (a lo sumo upb-1 sueltas por producto en toda la ruta).
  Object.values(totalesBonifFraccion).forEach((f) => {
    const fardos = Math.floor(f.subunidades / f.upb)
    const sueltas = f.subunidades % f.upb
    if (fardos > 0) {
      // Clave aparte: esta cantidad ya está en fardos completos del BLOQUE de la
      // promo, mientras que una bonificación de unidad entera del mismo producto
      // está en unidades de venta. Sumarlas en la misma fila imprimía "5x
      // producto (FARDOS COMPLETOS)" mezclando 2 fardos con 3 unidades sueltas.
      const fila = acumular(totalesBonifFardos, `${f.key}|fardos`, f.nombre, fardos, f.grupo)
      fila.preConvertidoAFardos = true
    }
    if (sueltas > 0) {
      // Clave por producto Y descripción: dos sabores de un regalo repartido
      // (#831) pueden llegar con la misma descripción de la promo, y sumarlos
      // en una fila hacía cargar N botellas sin decir de qué sabor.
      const fila = acumular(totalesBonifSueltas, `bonif:${f.key}|${f.desc}`, f.desc, sueltas, f.grupo)
      fila.producto = f.nombre
      fila.sinUnidad = f.sinUnidad
    }
  })
  // Si dos filas de sueltas quedaron con el mismo texto (misma descripción,
  // distinto producto), se desambiguan con el nombre del producto.
  const textosSueltas = new Map<string, number>()
  Object.values(totalesBonifSueltas).forEach((f) => {
    textosSueltas.set(f.nombre, (textosSueltas.get(f.nombre) ?? 0) + 1)
  })
  Object.values(totalesBonifSueltas).forEach((f) => {
    if ((textosSueltas.get(f.nombre) ?? 0) > 1 && f.producto) {
      f.nombre = `${f.nombre} - ${f.producto}`
    }
  })

  const ordenar = (mapa: Record<string, FilaTotal>): FilaTotal[] => Object.values(mapa)
    .filter((t) => t.cantidad > 0)
    .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))

  const filasCompras = ordenar(totalesCompras)
  const filasBonifFardos = ordenar(totalesBonifFardos)
  const filasBonifSueltas = ordenar(totalesBonifSueltas)
  const filasCambios = ordenar(totalesCambios)

  const lineaConAclaracion = (f: FilaTotal): string => {
    // preConvertidoAFardos: la cantidad ya está en fardos, la etiqueta va directa.
    if (f.preConvertidoAFardos) {
      return `${f.nombre} (${f.cantidad === 1 ? 'FARDO COMPLETO' : 'FARDOS COMPLETOS'})`
    }
    const aclaracion = formatAclaracionBulto(
      f.cantidad,
      f.unidades_de_venta_por_fardo,
      f.etiqueta_bulto,
    )
    return aclaracion ? `${f.nombre} ${aclaracion}` : f.nombre
  }

  const ops: ManifiestoOp[] = []
  // Ancho reservado para la cantidad (alineado con drawManifiestoOps). Los
  // nombres se pre-cortan acá a líneas físicas (con doc) para que el manifiesto
  // NO trunque nombres largos como "… (SUELTAS, NO FARDO)".
  const cantidadWidth = 12
  const pushLinea = (cantidad: string, nombre: string): void => {
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(9)
    const lineas = doc.splitTextToSize(nombre, CARD_CONTENT_WIDTH - cantidadWidth)
    lineas.forEach((ln: string, i: number) => {
      ops.push({
        kind: 'manifiesto-line',
        cantidad: i === 0 ? cantidad : '',
        nombre: ln,
        advance: i === 0 ? 4.5 : 4,
      })
    })
  }
  // Sueltos: "Nx botellas <producto>" — el conteo inicial del regalo ("1
  // Botella"/"2 Botellas") describe UN bloque, no la cantidad de la ruta, así
  // que siempre se descarta: dejarlo puesto imprimía "3x 2 Granadina" y el
  // chofer cargaba 6. Con dos tokens ("2 Granadina") no hay palabra de unidad
  // que pluralizar, sólo el nombre: se deja tal cual.
  const nombreSuelta = (desc: string, sinUnidad = false): string => {
    const nombre = nombreSinConteo(desc)
    if (!nombre) return '(SUELTAS, NO FARDO)'
    // Nombre de producto pelado (sustituto sin unidad en la promo, o regalo sin
    // descripción): la primera palabra es del producto, no una unidad.
    if (sinUnidad) return `${nombre} (SUELTAS, NO FARDO)`
    const m = /^(\S+)\s+(.+)$/.exec(nombre)
    if (!m) return `${nombre} (SUELTAS, NO FARDO)`
    const unidad = m[1].toLowerCase()
    const plural = unidad.endsWith('s') ? unidad : `${unidad}s`
    return `${plural} ${m[2]} (SUELTAS, NO FARDO)`
  }

  ops.push({
    kind: 'manifiesto-subtitle',
    text: 'Total de productos a cargar en el vehiculo',
    advance: 5
  })

  // Agrupado por rubro -> subrubro para que el deposito arme la carga por
  // gondola. Las bonificaciones y los cambios van DENTRO de cada grupo (no en un
  // bloque final): el que carga esa gondola levanta todo de una vez.
  const claveGrupo = (g: GrupoManifiesto): string => `${g.rubro}\u0000${g.subrubro ?? ''}`
  const grupos = new Map<string, GrupoManifiesto>()
  ;[filasCompras, filasBonifFardos, filasBonifSueltas, filasCambios].forEach((filas) => {
    filas.forEach((f) => { if (!grupos.has(claveGrupo(f.grupo))) grupos.set(claveGrupo(f.grupo), f.grupo) })
  })
  const delGrupo = (filas: FilaTotal[], g: GrupoManifiesto): FilaTotal[] =>
    filas.filter((f) => claveGrupo(f.grupo) === claveGrupo(g))

  let rubroActual: string | null = null
  Array.from(grupos.values()).sort(compararGrupos).forEach((g) => {
    if (g.rubro !== rubroActual) {
      rubroActual = g.rubro
      ops.push({ kind: 'spacer', advance: 1.5 })
      ops.push({ kind: 'manifiesto-rubro', text: g.rubro.toUpperCase(), advance: 6 })
    }
    if (g.subrubro) ops.push({ kind: 'manifiesto-subrubro', text: g.subrubro, advance: 5 })

    delGrupo(filasCompras, g).forEach((f) => pushLinea(`${f.cantidad}x`, lineaConAclaracion(f)))

    const bonifFardos = delGrupo(filasBonifFardos, g)
    const bonifSueltas = delGrupo(filasBonifSueltas, g)
    if (bonifFardos.length > 0 || bonifSueltas.length > 0) {
      ops.push({
        kind: 'manifiesto-subtitle',
        text: 'PRODUCTOS BONIFICADOS (cargar aparte)',
        advance: 4.5
      })
      bonifFardos.forEach((f) => pushLinea(`${f.cantidad}x`, lineaConAclaracion(f)))
      bonifSueltas.forEach((f) => pushLinea(`${f.cantidad}x`, nombreSuelta(f.nombre, f.sinUnidad)))
    }
    // Cambios/devoluciones: productos a entregar en las paradas de cambio, en su
    // propia seccion para que no se confundan con la venta del dia.
    const cambios = delGrupo(filasCambios, g)
    if (cambios.length > 0) {
      ops.push({
        kind: 'manifiesto-subtitle',
        text: 'CAMBIOS / DEVOLUCIONES (cargar aparte)',
        advance: 4.5
      })
      cambios.forEach((f) => pushLinea(`${f.cantidad}x`, f.nombre))
    }
  })
  ops.push({ kind: 'spacer', advance: 2 })
  ops.push({ kind: 'manifiesto-firma', advance: 5.5 })
  return ops
}

/**
 * Dibuja el manifiesto fluyendo a traves de columnas/paginas.
 * El ctx provee acceso dinamico a la columna actual y al limite inferior, mas
 * un advanceColumn() que salta a la siguiente columna (o agrega pagina nueva).
 * Cada fila chequea si entra antes de dibujarse, garantizando que la lista
 * completa quede visible aunque exceda una columna o una hoja.
 */
function drawManifiestoOps(doc: jsPDF, ops: ManifiestoOp[], ctx: ManifiestoCtx): number {
  let x = ctx.columnX()
  let innerX = x + CARD_INNER_PADDING
  let y = ctx.startY

  const drawSeparator = () => {
    doc.setDrawColor(80, 80, 80)
    doc.setLineWidth(0.4)
    doc.line(x + 1, y - 1, x + COLUMN_WIDTH - 1, y - 1)
  }

  const advanceForOverflow = () => {
    ctx.advanceColumn()
    x = ctx.columnX()
    innerX = x + CARD_INNER_PADDING
    y = ctx.columnTop
    drawSeparator()
  }

  drawSeparator()

  // Orphan-prevention: si el header (titulo + subtitulo + al menos 1 fila) no
  // entra en lo que queda de la columna, saltar antes de empezar a dibujar.
  const titleIdx = ops.findIndex(o => o.kind === 'manifiesto-title')
  if (titleIdx >= 0) {
    const headerHeight = (ops[titleIdx]?.advance || 0)
      + (ops[titleIdx + 1]?.advance || 0)
      + (ops[titleIdx + 2]?.advance || 0)
    if (y + headerHeight > ctx.columnBottom) {
      advanceForOverflow()
    }
  }

  for (const op of ops) {
    const advance = op.advance || 0

    // Un encabezado (rubro, subrubro o seccion) no puede quedar huerfano al pie
    // de la columna: tiene que entrar junto con la fila que le sigue.
    const esEncabezado = op.kind === 'manifiesto-rubro' || op.kind === 'manifiesto-subrubro' || op.kind === 'manifiesto-subtitle'
    const siguiente = esEncabezado
      ? ops.slice(ops.indexOf(op) + 1).find((o) => o.kind !== 'spacer' && o.kind !== 'manifiesto-subrubro')
      : undefined
    const necesita = advance + (siguiente?.advance || 0)

    // Si la op no entra en la columna actual, avanzar. El titulo se exime
    // porque ya lo manejo el bloque de orphan-prevention.
    if (op.kind !== 'manifiesto-title' && y + necesita > ctx.columnBottom) {
      advanceForOverflow()
    }

    switch (op.kind) {
      case 'manifiesto-title': {
        doc.setFont('helvetica', 'bold')
        doc.setFontSize(11)
        doc.setTextColor(0, 0, 0)
        doc.text(op.text, x + COLUMN_WIDTH / 2, y + 3, { align: 'center' })
        break
      }
      case 'manifiesto-subtitle': {
        doc.setFont('helvetica', 'italic')
        doc.setFontSize(8)
        doc.setTextColor(60, 60, 60)
        doc.text(op.text, x + COLUMN_WIDTH / 2, y + 3, { align: 'center' })
        doc.setTextColor(0, 0, 0)
        break
      }
      case 'manifiesto-rubro': {
        doc.setFillColor(225, 225, 225)
        doc.rect(x + 1, y, COLUMN_WIDTH - 2, advance - 1, 'F')
        doc.setFont('helvetica', 'bold')
        doc.setFontSize(10)
        doc.setTextColor(0, 0, 0)
        doc.text(op.text, innerX, y + 4)
        break
      }
      case 'manifiesto-subrubro': {
        doc.setFont('helvetica', 'bold')
        doc.setFontSize(9)
        doc.setTextColor(40, 40, 40)
        doc.text(op.text, innerX, y + 3.5)
        doc.setTextColor(0, 0, 0)
        doc.setDrawColor(150, 150, 150)
        doc.setLineWidth(0.2)
        doc.line(innerX, y + 4.3, x + COLUMN_WIDTH - CARD_INNER_PADDING, y + 4.3)
        break
      }
      case 'manifiesto-line': {
        doc.setFontSize(9)
        doc.setTextColor(0, 0, 0)
        const cantidadWidth = 12
        doc.setFont('helvetica', 'bold')
        doc.text(op.cantidad, innerX, y + 3)
        doc.setFont('helvetica', 'normal')
        // op.nombre ya viene pre-cortado a una línea física en buildManifiestoOps,
        // así que se dibuja completo (no se re-trunca a la primera línea).
        doc.text(op.nombre || '', innerX + cantidadWidth, y + 3)
        break
      }
      case 'manifiesto-firma': {
        doc.setFont('helvetica', 'normal')
        doc.setFontSize(9)
        doc.setTextColor(0, 0, 0)
        drawCheckbox(doc, innerX, y, 3)
        doc.text('Conforme de carga - Firma: __________', innerX + 4.5, y + 2.5)
        break
      }
      case 'spacer':
      default:
        break
    }
    y += advance
  }

  return y
}

function drawCierreOps(doc: jsPDF, ops: CierreOp[], x: number, yStart: number): number {
  const innerX = x + CARD_INNER_PADDING
  let y = yStart

  doc.setDrawColor(80, 80, 80)
  doc.setLineWidth(0.4)
  doc.line(x + 1, y - 1, x + COLUMN_WIDTH - 1, y - 1)

  ops.forEach((op) => {
    if (op.kind === 'cierre-title') {
      doc.setFont('helvetica', 'bold')
      doc.setFontSize(11)
      doc.setTextColor(0, 0, 0)
      doc.text(op.text, x + COLUMN_WIDTH / 2, y + 3, { align: 'center' })
    } else {
      doc.setFont('helvetica', 'normal')
      doc.setFontSize(10)
      doc.setTextColor(0, 0, 0)
      doc.text(op.text, innerX, y + 3)
    }
    y += op.advance || 0
  })

  return y
}

/** Alto que ocupa el separador de barrida, para el calculo de salto de columna. */
const SEPARADOR_BARRIDA_ALTO = 7

/** Titulo de tanda: linea + etiqueta ('Cierran al mediodia', etc.). */
function drawSeparadorBarrida(doc: jsPDF, barrida: Barrida, x: number, y: number): number {
  const ancho = COLUMN_WIDTH
  doc.setDrawColor(120, 120, 120)
  doc.setLineWidth(0.4)
  doc.line(x, y + 1.5, x + ancho, y + 1.5)
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(7.5)
  doc.setTextColor(90, 90, 90)
  doc.text(`BARRIDA ${barrida} - ${(ETIQUETA_BARRIDA[barrida] || '').toUpperCase()}`, x, y + 5.5)
  doc.setTextColor(0, 0, 0)
  return y + SEPARADOR_BARRIDA_ALTO
}

const nuevoDocA4 = (): jsPDF => new jsPDF({ orientation: 'landscape', unit: 'mm', format: 'a4' })

/** Si llega algo distinto a objeto, se ignora. */
const normalizarInfo = (infoRuta: InfoRuta): InfoRuta =>
  infoRuta && typeof infoRuta === 'object' ? infoRuta : {}

/**
 * Dibuja la hoja de ruta (tarjetas + cierre de jornada) en las 3 columnas,
 * empezando en la pagina actual del doc.
 */
function dibujarHojaRuta(doc: jsPDF, transportista: PerfilDB, pedidos: PedidoDB[], info: InfoRuta): void {
  let columnTop = drawPageHeader(doc, transportista, pedidos, info, true)
  const columnBottom = PAGE_HEIGHT - PAGE_MARGIN

  let currentColumn = 0
  let y = columnTop

  const advanceColumn = () => {
    currentColumn += 1
    if (currentColumn >= COLUMN_COUNT) {
      doc.addPage()
      columnTop = drawPageHeader(doc, transportista, pedidos, info, false)
      currentColumn = 0
    }
    y = columnTop
  }

  const columnX = () =>
    PAGE_MARGIN + currentColumn * (COLUMN_WIDTH + COLUMN_GAP)

  // Separador de barridas: la ruta viene ordenada por barrida (el optimizador
  // encadena las tres), asi que alcanza con marcar el corte cuando cambia. Sin
  // esto el chofer ve una lista corrida y no sabe que los primeros son los que
  // cierran al mediodia. Se recalcula del horario del cliente en vez de leer
  // recorrido_pedidos.barrida para que valga tambien al exportar antes de armar.
  // Es la barrida EFECTIVA, la misma que uso el optimizador: el vecino adelantado
  // a la barrida 1 va bajo el rotulo de la 1, no abre un "Barrida 5" en el medio.
  const efectivas = barridasEfectivas(pedidos, p => horarioParaRutear(p?.cliente))
  // Un pedido anterior del mismo cliente que viaja en esta ruta se cobra en su
  // propia parada: no va también como deuda anterior de otra (#936).
  const idsRuta = new Set(pedidos.map(p => String(p.id)))
  let barridaPrevia: Barrida | null = null
  pedidos.forEach((pedido, idx) => {
    const barrida: Barrida = efectivas.get(String(pedido.id)) ?? 4
    const ops = buildCardOps(doc, deudaSinBoletasDelLote(pedido, idsRuta), idx + 1)
    const height = measureCardHeight(ops)
    const cambiaBarrida = barrida !== barridaPrevia
    const altoSeparador = cambiaBarrida ? SEPARADOR_BARRIDA_ALTO : 0

    // Si no entra en la columna actual, pasa a la siguiente
    if (y + height + altoSeparador > columnBottom && y > columnTop) {
      advanceColumn()
    }

    if (cambiaBarrida) {
      y = drawSeparadorBarrida(doc, barrida, columnX(), y)
      barridaPrevia = barrida
    }

    y = drawCardOps(doc, ops, columnX(), y)
  })

  // Cierre de jornada: intenta colocarlo al final de la columna actual
  const cierreOps = buildCierreOps(pedidos)
  const cierreHeight = cierreOps.reduce((s, o) => s + (o.advance || 0), 0) + 3

  if (y + cierreHeight > columnBottom) {
    advanceColumn()
  }

  drawCierreOps(doc, cierreOps, columnX(), y)
}

/**
 * Dibuja el manifiesto de carga fluyendo en 3 columnas, empezando arriba de la
 * pagina actual del doc con su propio encabezado.
 */
function dibujarManifiesto(
  doc: jsPDF,
  transportista: PerfilDB,
  pedidos: PedidoDB[],
  info: InfoRuta,
  opciones: OpcionesManifiesto,
): void {
  const titulo = 'MANIFIESTO DE CARGA'

  let columnTop = drawPageHeader(doc, transportista, pedidos, info, false, titulo)
  const columnBottom = PAGE_HEIGHT - PAGE_MARGIN
  let currentColumn = 0

  const advanceColumn = () => {
    currentColumn += 1
    if (currentColumn >= COLUMN_COUNT) {
      doc.addPage()
      columnTop = drawPageHeader(doc, transportista, pedidos, info, false, titulo)
      currentColumn = 0
    }
  }

  const columnX = () =>
    PAGE_MARGIN + currentColumn * (COLUMN_WIDTH + COLUMN_GAP)

  drawManifiestoOps(doc, buildManifiestoOps(doc, pedidos, opciones), {
    columnX,
    advanceColumn,
    get columnTop() { return columnTop },
    columnBottom,
    startY: columnTop,
  })
}

/**
 * Genera PDF de Hoja de Ruta en A4 horizontal con 3 columnas.
 */
export function generarHojaRutaOptimizada(transportista: PerfilDB, pedidos: PedidoDB[], infoRuta: InfoRuta = {}): void {
  const doc = nuevoDocA4()
  const info = normalizarInfo(infoRuta)
  dibujarHojaRuta(doc, transportista, pedidos, info)
  doc.save(generateFilename('ruta', transportista?.nombre, info.fecha))
}

/**
 * Genera el PDF del Manifiesto de Carga (#829), aparte de la hoja de ruta: es lo
 * que arma el deposito, no lo que lleva el chofer en la mano. Mismo formato A4
 * horizontal en 3 columnas; los productos van agrupados por rubro -> subrubro.
 */
export function generarManifiestoCarga(
  transportista: PerfilDB,
  pedidos: PedidoDB[],
  infoRuta: InfoRuta = {},
  opciones: OpcionesManifiesto = {}
): void {
  const doc = nuevoDocA4()
  const info = normalizarInfo(infoRuta)
  dibujarManifiesto(doc, transportista, pedidos, info, opciones)
  doc.save(generateFilename('manifiesto-carga', transportista?.nombre, info.fecha))
}

/**
 * Hoja de ruta + manifiesto de carga en un solo PDF, para quien imprime todo de
 * una vez. Las dos piezas siguen existiendo por separado (#829); esta es la
 * tercera opcion. El manifiesto arranca en hoja nueva despues del cierre de
 * jornada, con su propio encabezado y su paginacion en columnas.
 */
export function generarHojaRutaYManifiesto(
  transportista: PerfilDB,
  pedidos: PedidoDB[],
  infoRuta: InfoRuta = {},
  opciones: OpcionesManifiesto = {}
): void {
  const doc = nuevoDocA4()
  const info = normalizarInfo(infoRuta)
  dibujarHojaRuta(doc, transportista, pedidos, info)
  doc.addPage()
  dibujarManifiesto(doc, transportista, pedidos, info, opciones)
  doc.save(generateFilename('ruta-manifiesto', transportista?.nombre, info.fecha))
}
