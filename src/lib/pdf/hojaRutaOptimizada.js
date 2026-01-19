/**
 * Genera PDF profesional de Hoja de Ruta Optimizada
 * Formato: Ticket comandera de 75mm de ancho - estilo plano
 */
import { jsPDF } from 'jspdf'
import { TICKET } from './constants'
import {
  formatPrecio,
  formatFecha,
  truncate,
  generateFilename,
  drawDivider,
  drawCheckbox,
  setHeaderStyle,
  setNormalStyle,
  setItalicStyle
} from './utils'

/**
 * Calcula la altura necesaria para el documento
 * @param {Array} pedidos - Lista de pedidos
 * @returns {number} Altura calculada en mm
 */
function calcularAltura(pedidos) {
  let totalHeight = 40 // Header + resumen
  pedidos.forEach(pedido => {
    totalHeight += 22 // Info básica del pedido
    const itemsCount = pedido.items?.length || 0
    totalHeight += Math.ceil(itemsCount * 4) // Productos con nombre completo
    if (pedido.notas) totalHeight += 5
  })
  totalHeight += 35 // Cierre de jornada
  return Math.max(totalHeight, 100)
}

/**
 * Genera PDF de Hoja de Ruta Optimizada
 * @param {Object} transportista - Datos del transportista
 * @param {Array} pedidos - Lista de pedidos ordenados por ruta optimizada
 * @param {Object} infoRuta - Información de la ruta (duración, distancia)
 * @returns {void} - Descarga el PDF
 */
export function generarHojaRutaOptimizada(transportista, pedidos, infoRuta = {}) {
  const { width: ticketWidth, margin, contentWidth } = TICKET

  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: [ticketWidth, calcularAltura(pedidos)]
  })

  let y = margin

  // === HEADER ===
  doc.setTextColor(0, 0, 0)
  setHeaderStyle(doc, 12)
  doc.text('HOJA DE RUTA', ticketWidth / 2, y + 4, { align: 'center' })
  y += 7

  doc.setFontSize(9)
  doc.text(transportista?.nombre || 'Transportista', ticketWidth / 2, y, { align: 'center' })
  y += 4

  setNormalStyle(doc, 7)
  doc.text(formatFecha(new Date()), ticketWidth / 2, y, { align: 'center' })
  y += 3

  // Métricas de ruta
  const metricasTexto = []
  if (infoRuta.duracion_formato) metricasTexto.push(infoRuta.duracion_formato)
  if (infoRuta.distancia_formato) metricasTexto.push(infoRuta.distancia_formato)
  metricasTexto.push(`${pedidos.length} entregas`)
  doc.setFontSize(6)
  doc.text(metricasTexto.join(' | '), ticketWidth / 2, y, { align: 'center' })
  y += 4

  // Línea divisora
  drawDivider(doc, y, margin, ticketWidth - margin, 0.3)
  y += 3

  // === RESUMEN DE COBRO ===
  const totalGeneral = pedidos.reduce((sum, p) => sum + (p.total || 0), 0)
  const totalPendiente = pedidos
    .filter(p => p.estado_pago !== 'pagado')
    .reduce((sum, p) => sum + (p.total || 0), 0)

  setHeaderStyle(doc, 7)
  doc.text('TOTAL:', margin, y + 3)
  doc.text(formatPrecio(totalGeneral), ticketWidth - margin, y + 3, { align: 'right' })
  y += 4

  setNormalStyle(doc, 6)
  doc.text(`Pendiente cobro: ${formatPrecio(totalPendiente)}`, margin, y + 2)
  y += 5

  drawDivider(doc, y, margin, ticketWidth - margin, 0.5)
  y += 4

  // === LISTA DE ENTREGAS ===
  pedidos.forEach((pedido, index) => {
    // Número de orden y cliente
    setHeaderStyle(doc, 8)
    doc.text(`${index + 1}.`, margin, y)

    // Nombre del cliente completo
    const clienteNombre = pedido.cliente?.nombre_fantasia || 'Sin cliente'
    doc.text(clienteNombre, margin + 6, y)
    y += 4

    // Dirección completa
    setNormalStyle(doc, 6)
    const direccion = pedido.cliente?.direccion || 'Sin direccion'
    const dirLines = doc.splitTextToSize(direccion, contentWidth - 2)
    dirLines.slice(0, 2).forEach(line => {
      doc.text(line, margin, y)
      y += 2.5
    })

    // Teléfono
    if (pedido.cliente?.telefono) {
      doc.text(`Tel: ${pedido.cliente.telefono}`, margin, y)
      y += 2.5
    }

    // Total y estado de pago
    setHeaderStyle(doc, 7)
    const estadoPago = pedido.estado_pago === 'pagado' ? 'PAGADO' :
                       pedido.estado_pago === 'parcial' ? 'PARCIAL' : 'PEND'
    doc.text(`${formatPrecio(pedido.total)} - ${estadoPago}`, margin, y)
    y += 3

    // Productos con nombre completo
    setNormalStyle(doc, 6)
    pedido.items?.forEach(item => {
      const productoNombre = item.producto?.nombre || 'Producto'
      doc.text(`  ${item.cantidad}x ${productoNombre}`, margin, y)
      y += 2.5
    })

    // Notas
    if (pedido.notas) {
      setItalicStyle(doc)
      doc.text(`* ${truncate(pedido.notas, 50)}`, margin, y)
      setNormalStyle(doc, 6)
      y += 2.5
    }

    // Checkbox entregado
    y += 1
    doc.setDrawColor(100, 100, 100)
    drawCheckbox(doc, margin, y - 2)
    doc.text('Entregado  Firma:__________', margin + 4, y)
    y += 4

    // Línea divisora entre pedidos
    doc.setDrawColor(150, 150, 150)
    doc.setLineWidth(0.2)
    doc.line(margin, y, ticketWidth - margin, y)
    y += 3
  })

  // === CIERRE DE JORNADA ===
  y += 2
  doc.setDrawColor(0, 0, 0)
  drawDivider(doc, y, margin, ticketWidth - margin, 0.5)
  y += 4

  setHeaderStyle(doc, 8)
  doc.text('CIERRE DE JORNADA', ticketWidth / 2, y, { align: 'center' })
  y += 5

  setNormalStyle(doc, 6)
  doc.text('Cobrado efectivo: ____________', margin, y)
  y += 4
  doc.text('Cobrado transf: _____________', margin, y)
  y += 4
  doc.text(`Entregas: _____ de ${pedidos.length}`, margin, y)
  y += 4
  doc.text('Firma: ___________________', margin, y)

  // Descargar PDF
  doc.save(generateFilename('ruta', transportista?.nombre))
}
