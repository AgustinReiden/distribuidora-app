/**
 * Genera PDF de Hoja de Ruta para el transportista
 * Formato: Ticket comandera de 75mm de ancho
 */
import { jsPDF } from 'jspdf'
import { TICKET, FORMAS_PAGO_SHORT, ESTADOS_PAGO } from './constants'
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
  let totalHeight = 35 // Encabezado y resumen
  pedidos.forEach(pedido => {
    totalHeight += 30 // Info básica del pedido
    const itemsCount = pedido.items?.length || 0
    totalHeight += Math.ceil(itemsCount * 4) // Productos resumidos
    if (pedido.notas) totalHeight += 6
  })
  totalHeight += 25 // Pie de página
  return Math.max(totalHeight, 80)
}

/**
 * Genera PDF de Hoja de Ruta
 * @param {Object} transportista - Datos del transportista
 * @param {Array} pedidos - Lista de pedidos asignados
 * @returns {void} - Descarga el PDF
 */
export function generarHojaRuta(transportista, pedidos) {
  const { width: ticketWidth, margin } = TICKET

  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: [ticketWidth, calcularAltura(pedidos)]
  })

  let y = margin

  // Calcular totales
  const totalPedidos = pedidos.length
  const totalACobrar = pedidos.reduce((sum, p) => sum + (p.total || 0), 0)
  const totalPendienteCobro = pedidos
    .filter(p => p.estado_pago !== 'pagado')
    .reduce((sum, p) => sum + (p.total || 0), 0)

  // Título principal
  setHeaderStyle(doc, 12)
  doc.text('HOJA DE RUTA', ticketWidth / 2, y + 4, { align: 'center' })
  y += 7

  // Nombre del transportista
  doc.setFontSize(9)
  doc.text(transportista?.nombre || 'Transportista', ticketWidth / 2, y, { align: 'center' })
  y += 4

  setNormalStyle(doc, 7)
  doc.text(formatFecha(new Date()), ticketWidth / 2, y, { align: 'center' })
  y += 5

  // Resumen
  drawDivider(doc, y, margin, ticketWidth - margin, 0.3)
  y += 3

  doc.setFontSize(7)
  doc.text(`Entregas: ${totalPedidos}`, margin, y)
  doc.text(`Total: ${formatPrecio(totalACobrar)}`, ticketWidth - margin, y, { align: 'right' })
  y += 3
  doc.text(`Pend. cobro: ${formatPrecio(totalPendienteCobro)}`, margin, y)
  y += 4

  doc.line(margin, y, ticketWidth - margin, y)
  y += 4

  // Iterar sobre cada pedido/entrega
  pedidos.forEach((pedido, index) => {
    // Número de entrega
    setHeaderStyle(doc, 10)
    doc.text(`${index + 1}.`, margin, y)

    // Nombre del cliente
    const clienteNombre = pedido.cliente?.nombre_fantasia || 'Sin cliente'
    doc.text(truncate(clienteNombre, 18), margin + 6, y)

    // Total con estado de pago
    setNormalStyle(doc, 8)
    const estadoPago = ESTADOS_PAGO[pedido.estado_pago] || ESTADOS_PAGO.pendiente
    doc.text(`${estadoPago.symbol} ${formatPrecio(pedido.total)}`, ticketWidth - margin, y, { align: 'right' })
    y += 4

    // Dirección
    doc.setFontSize(7)
    doc.text(truncate(pedido.cliente?.direccion || 'Sin direccion', 40), margin, y)
    y += 3

    // Teléfono
    if (pedido.cliente?.telefono) {
      doc.text(`Tel: ${pedido.cliente.telefono}`, margin, y)
      y += 3
    }

    // Forma de pago
    const formaPagoTexto = FORMAS_PAGO_SHORT[pedido.forma_pago] || pedido.forma_pago || 'Efvo'
    doc.text(`${formaPagoTexto} | ${estadoPago.label}`, margin, y)
    y += 3

    // Productos (formato compacto)
    doc.setFontSize(6)
    const productosTexto = pedido.items?.map(i =>
      `${i.cantidad}x${truncate(i.producto?.nombre || '?', 12)}`
    ).join(', ') || ''
    const prodLines = doc.splitTextToSize(productosTexto, ticketWidth - (margin * 2))
    prodLines.slice(0, 2).forEach(line => {
      doc.text(line, margin, y)
      y += 3
    })

    // Notas
    if (pedido.notas) {
      setItalicStyle(doc)
      doc.text(`* ${truncate(pedido.notas, 35)}`, margin, y)
      y += 3
      setNormalStyle(doc, 7)
    }

    // Área de confirmación compacta
    y += 1
    doc.setFontSize(7)
    drawCheckbox(doc, margin, y - 2)
    doc.text('Entregado', margin + 4, y)
    doc.text('Firma:______________', ticketWidth / 2, y)
    y += 4

    // Línea divisora
    doc.setLineWidth(0.2)
    doc.setDrawColor(150)
    doc.line(margin, y, ticketWidth - margin, y)
    doc.setDrawColor(0)
    y += 3
  })

  // Pie de página con resumen
  y += 2
  drawDivider(doc, y, margin, ticketWidth - margin, 0.5)
  y += 4

  setHeaderStyle(doc, 8)
  doc.text('RESUMEN COBRANZA', ticketWidth / 2, y, { align: 'center' })
  y += 4

  setNormalStyle(doc, 7)
  doc.text('Cobrado: ____________', margin, y)
  y += 4
  doc.text('Efectivo: ____________', margin, y)
  y += 4
  doc.text('Transf: ____________', margin, y)
  y += 4
  doc.text('Firma: ______________', margin, y)

  // Descargar PDF
  doc.save(generateFilename('hoja-ruta', transportista?.nombre))
}
