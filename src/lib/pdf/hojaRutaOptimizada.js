/**
 * Genera PDF profesional de Hoja de Ruta Optimizada
 * Formato: A4 horizontal con 3 columnas estilo comandera
 * Facilita la lectura al chofer: una sola hoja grande con varios pedidos
 */
import { jsPDF } from 'jspdf'
import {
  formatPrecio,
  formatFecha,
  generateFilename,
  drawCheckbox
} from './utils'

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

/**
 * Dibuja el encabezado de la pagina.
 * @returns {number} Posicion Y donde comienzan las columnas
 */
function drawPageHeader(doc, transportista, pedidos, infoRuta, showSummary) {
  let y = PAGE_MARGIN

  doc.setTextColor(0, 0, 0)
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(16)
  doc.text('HOJA DE RUTA', PAGE_WIDTH / 2, y + 5, { align: 'center' })

  doc.setFont('helvetica', 'normal')
  doc.setFontSize(11)
  doc.text(transportista?.nombre || 'Transportista', PAGE_MARGIN, y + 5)

  doc.setFontSize(10)
  doc.text(formatFecha(new Date()), PAGE_WIDTH - PAGE_MARGIN, y + 5, { align: 'right' })

  y += 9

  // Linea de metricas + resumen
  const metricas = []
  metricas.push(`${pedidos.length} entregas`)
  if (infoRuta?.duracion_formato) metricas.push(infoRuta.duracion_formato)
  if (infoRuta?.distancia_formato) metricas.push(infoRuta.distancia_formato)

  doc.setFontSize(9)
  doc.text(metricas.join('  |  '), PAGE_MARGIN, y)

  if (showSummary) {
    const totalGeneral = pedidos.reduce((sum, p) => sum + (p.total || 0), 0)
    const totalPendiente = pedidos
      .filter((p) => p.estado_pago !== 'pagado')
      .reduce((sum, p) => sum + (p.total || 0), 0)
    doc.setFont('helvetica', 'bold')
    doc.text(
      `TOTAL: ${formatPrecio(totalGeneral)}   PENDIENTE: ${formatPrecio(totalPendiente)}`,
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

/**
 * Estructura las operaciones de layout de una card de pedido.
 * Produce lineas tipadas que tanto el dry-run (medir) como el draw aplican.
 */
function buildCardOps(doc, pedido, orderNumber) {
  const ops = []
  const estadoPagoLabel =
    pedido.estado_pago === 'pagado'
      ? 'PAGADO'
      : pedido.estado_pago === 'parcial'
        ? 'PARCIAL'
        : 'PEND'

  // Nombre cliente + numero
  const headerText = `${orderNumber}. ${pedido.cliente?.nombre_fantasia || 'Sin cliente'}`
  doc.setFont('helvetica', 'bold')
  doc.setFontSize(11)
  const headerLines = doc.splitTextToSize(headerText, CARD_CONTENT_WIDTH)
  headerLines.forEach((line) => {
    ops.push({ kind: 'text', text: line, fontSize: 11, bold: true, advance: 5 })
  })

  // Direccion
  if (pedido.cliente?.direccion) {
    doc.setFont('helvetica', 'normal')
    doc.setFontSize(9)
    const dirLines = doc.splitTextToSize(pedido.cliente.direccion, CARD_CONTENT_WIDTH)
    dirLines.slice(0, 2).forEach((line) => {
      ops.push({ kind: 'text', text: line, fontSize: 9, bold: false, advance: 4 })
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
    horLines.slice(0, 2).forEach((line) => {
      ops.push({ kind: 'text', text: line, fontSize: 9, bold: false, advance: 4 })
    })
  }

  // Total + estado
  ops.push({
    kind: 'text',
    text: `${formatPrecio(pedido.total)} - ${estadoPagoLabel}`,
    fontSize: 11,
    bold: true,
    advance: 5
  })

  // Productos
  doc.setFont('helvetica', 'normal')
  doc.setFontSize(9)
  const priceColWidth = 24
  const productWrapWidth = CARD_CONTENT_WIDTH - priceColWidth
  ;(pedido.items || []).forEach((item) => {
    const nombre = item.producto?.nombre || 'Producto'
    const subtotal = (item.precio_unitario || 0) * item.cantidad
    const itemLines = doc.splitTextToSize(`${item.cantidad}x ${nombre}`, productWrapWidth)
    itemLines.forEach((line, idx) => {
      ops.push({
        kind: 'product',
        text: line,
        subtotal: idx === 0 ? formatPrecio(subtotal) : null,
        fontSize: 9,
        advance: 4
      })
    })
  })

  // Total pedido
  ops.push({ kind: 'spacer', advance: 1 })
  ops.push({
    kind: 'total',
    label: 'Total pedido:',
    value: formatPrecio(pedido.total),
    fontSize: 10,
    advance: 4.5
  })

  // Notas
  if (pedido.notas) {
    doc.setFont('helvetica', 'italic')
    doc.setFontSize(9)
    const notasLines = doc.splitTextToSize(`* ${pedido.notas}`, CARD_CONTENT_WIDTH)
    notasLines.slice(0, 2).forEach((line) => {
      ops.push({ kind: 'italic', text: line, fontSize: 9, advance: 4 })
    })
  }

  // Entregado + firma
  ops.push({ kind: 'spacer', advance: 1 })
  ops.push({ kind: 'entregado', advance: 4.5 })

  // Divisor
  ops.push({ kind: 'divider', advance: CARD_BOTTOM_SPACING })

  return ops
}

function measureCardHeight(ops) {
  return ops.reduce((sum, op) => sum + (op.advance || 0), 0)
}

function drawCardOps(doc, ops, x, yStart) {
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
        doc.text('Entregado  Firma: _______________', innerX + 4.5, y + 2.5)
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

function buildCierreOps(pedidos) {
  const ops = []
  ops.push({ kind: 'cierre-title', text: 'CIERRE DE JORNADA', advance: 6 })
  ops.push({ kind: 'cierre-line', text: 'Cobrado efectivo: ________________________', advance: 5.5 })
  ops.push({ kind: 'cierre-line', text: 'Cobrado transferencia: __________________', advance: 5.5 })
  ops.push({ kind: 'cierre-line', text: `Entregas: _____ de ${pedidos.length}`, advance: 5.5 })
  ops.push({ kind: 'cierre-line', text: 'Firma: ____________________________________', advance: 5.5 })
  return ops
}

/**
 * Suma todas las cantidades por producto entre todos los pedidos y
 * produce operaciones de layout para el manifiesto de carga del camion.
 */
function buildManifiestoOps(pedidos) {
  const totales = {}
  pedidos.forEach((pedido) => {
    ;(pedido.items || []).forEach((item) => {
      const key = item.producto_id ?? item.producto?.id ?? item.producto?.nombre ?? 'sin-id'
      const nombre = item.producto?.nombre || 'Producto'
      if (!totales[key]) {
        totales[key] = { nombre, cantidad: 0 }
      }
      totales[key].cantidad += Number(item.cantidad) || 0
    })
  })

  const filas = Object.values(totales)
    .filter((t) => t.cantidad > 0)
    .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))

  const ops = []
  ops.push({ kind: 'manifiesto-title', text: 'MANIFIESTO DE CARGA', advance: 5.5 })
  ops.push({
    kind: 'manifiesto-subtitle',
    text: 'Total de productos a cargar en el vehiculo',
    advance: 5
  })
  filas.forEach((f) => {
    ops.push({
      kind: 'manifiesto-line',
      cantidad: `${f.cantidad}x`,
      nombre: f.nombre,
      advance: 4.5
    })
  })
  ops.push({ kind: 'spacer', advance: 2 })
  ops.push({ kind: 'manifiesto-firma', advance: 5.5 })
  return ops
}

function drawManifiestoOps(doc, ops, x, yStart) {
  const innerX = x + CARD_INNER_PADDING
  let y = yStart

  doc.setDrawColor(80, 80, 80)
  doc.setLineWidth(0.4)
  doc.line(x + 1, y - 1, x + COLUMN_WIDTH - 1, y - 1)

  ops.forEach((op) => {
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
      case 'manifiesto-line': {
        doc.setFont('helvetica', 'normal')
        doc.setFontSize(9)
        doc.setTextColor(0, 0, 0)
        const cantidadWidth = 12
        doc.setFont('helvetica', 'bold')
        doc.text(op.cantidad, innerX, y + 3)
        doc.setFont('helvetica', 'normal')
        const nombreLineas = doc.splitTextToSize(
          op.nombre,
          CARD_CONTENT_WIDTH - cantidadWidth
        )
        doc.text(nombreLineas[0] || '', innerX + cantidadWidth, y + 3)
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
    y += op.advance || 0
  })

  return y
}

function drawCierreOps(doc, ops, x, yStart) {
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

/**
 * Genera PDF de Hoja de Ruta en A4 horizontal con 3 columnas.
 * @param {Object} transportista - Datos del transportista
 * @param {Array} pedidos - Lista de pedidos
 * @param {Object} infoRuta - Informacion opcional de ruta (duracion, distancia)
 * @returns {void}
 */
export function generarHojaRutaOptimizada(transportista, pedidos, infoRuta = {}) {
  const doc = new jsPDF({
    orientation: 'landscape',
    unit: 'mm',
    format: 'a4'
  })

  // Normalizar infoRuta: si llega algo distinto a objeto, se ignora
  const info = infoRuta && typeof infoRuta === 'object' ? infoRuta : {}

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

  pedidos.forEach((pedido, idx) => {
    const ops = buildCardOps(doc, pedido, idx + 1)
    const height = measureCardHeight(ops)

    // Si no entra en la columna actual, pasa a la siguiente
    if (y + height > columnBottom && y > columnTop) {
      advanceColumn()
    }

    y = drawCardOps(doc, ops, columnX(), y)
  })

  // Cierre de jornada: intenta colocarlo al final de la columna actual
  const cierreOps = buildCierreOps(pedidos)
  const cierreHeight = cierreOps.reduce((s, o) => s + (o.advance || 0), 0) + 3

  if (y + cierreHeight > columnBottom) {
    advanceColumn()
  }

  y = drawCierreOps(doc, cierreOps, columnX(), y)

  // Manifiesto de carga: resumen consolidado de productos para el chofer
  const manifiestoOps = buildManifiestoOps(pedidos)
  const manifiestoHeight = manifiestoOps.reduce((s, o) => s + (o.advance || 0), 0) + 4

  if (y + manifiestoHeight > columnBottom) {
    advanceColumn()
  } else {
    y += 3
  }

  drawManifiestoOps(doc, manifiestoOps, columnX(), y)

  doc.save(generateFilename('ruta', transportista?.nombre))
}
