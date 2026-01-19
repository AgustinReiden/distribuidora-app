/**
 * Genera PDF de Recibo de Pago
 * Formato: Ticket comandera de 75mm de ancho
 */
import { jsPDF } from 'jspdf'
import { TICKET, FORMAS_PAGO_LABELS } from './constants'
import {
  formatPrecio,
  formatFechaHora,
  generateFilename,
  drawDivider,
  setHeaderStyle,
  setNormalStyle,
  setItalicStyle
} from './utils'

/**
 * Genera PDF de Recibo de Pago
 * @param {Object} pago - Datos del pago registrado
 * @param {Object} cliente - Datos del cliente
 * @param {Object} empresa - Datos de la empresa (opcional)
 * @returns {void} - Descarga el PDF
 */
export function generarReciboPago(pago, cliente, empresa = {}) {
  const { width: ticketWidth, margin, contentWidth } = TICKET

  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: [ticketWidth, 120] // Altura fija para recibo
  })

  let y = margin

  // === HEADER ===
  doc.setTextColor(0, 0, 0)
  setHeaderStyle(doc, 12)
  doc.text('RECIBO DE PAGO', ticketWidth / 2, y + 4, { align: 'center' })
  y += 8

  // Nombre empresa (opcional)
  if (empresa.nombre) {
    setNormalStyle(doc, 8)
    doc.text(empresa.nombre, ticketWidth / 2, y, { align: 'center' })
    y += 4
  }

  // Número de recibo
  setHeaderStyle(doc, 9)
  doc.text(`N° ${pago.id || '---'}`, ticketWidth / 2, y, { align: 'center' })
  y += 5

  // Fecha y hora
  setNormalStyle(doc, 7)
  doc.text(formatFechaHora(pago.created_at), ticketWidth / 2, y, { align: 'center' })
  y += 5

  // Línea divisora
  drawDivider(doc, y, margin, ticketWidth - margin, 0.3)
  y += 5

  // === DATOS DEL CLIENTE ===
  doc.setFontSize(7)
  doc.text('RECIBIDO DE:', margin, y)
  y += 3

  setHeaderStyle(doc, 9)
  doc.text(cliente?.nombre_fantasia || cliente?.nombre || 'Cliente', margin, y)
  y += 4

  setNormalStyle(doc, 7)
  if (cliente?.direccion) {
    doc.text(cliente.direccion, margin, y)
    y += 3
  }
  if (cliente?.telefono) {
    doc.text(`Tel: ${cliente.telefono}`, margin, y)
    y += 3
  }
  y += 2

  // Línea divisora
  drawDivider(doc, y, margin, ticketWidth - margin, 0.2)
  y += 5

  // === DETALLE DEL PAGO ===
  doc.setFontSize(7)
  doc.text('LA SUMA DE:', margin, y)
  y += 5

  // Monto grande
  doc.setFontSize(16)
  doc.setFont('helvetica', 'bold')
  doc.text(formatPrecio(pago.monto), ticketWidth / 2, y, { align: 'center' })
  y += 7

  // Forma de pago
  setNormalStyle(doc, 8)
  const formaPagoLabel = FORMAS_PAGO_LABELS[pago.forma_pago] || pago.forma_pago || 'EFECTIVO'
  doc.text(`Forma de pago: ${formaPagoLabel}`, margin, y)
  y += 4

  // Referencia si existe
  if (pago.referencia) {
    doc.text(`Referencia: ${pago.referencia}`, margin, y)
    y += 4
  }

  // Pedido asociado si existe
  if (pago.pedido_id) {
    doc.text(`Aplicado a Pedido #${pago.pedido_id}`, margin, y)
    y += 4
  }

  // Concepto/Notas
  y += 2
  doc.text('CONCEPTO:', margin, y)
  y += 3
  doc.setFontSize(7)
  const concepto = pago.notas || 'Pago a cuenta'
  const conceptoLines = doc.splitTextToSize(concepto, contentWidth)
  conceptoLines.slice(0, 2).forEach(line => {
    doc.text(line, margin, y)
    y += 3
  })
  y += 3

  // Línea divisora
  drawDivider(doc, y, margin, ticketWidth - margin, 0.3)
  y += 5

  // === FIRMA ===
  setNormalStyle(doc, 7)
  doc.text('Recibido por: ________________', margin, y)
  y += 6
  doc.text('Firma: ______________________', margin, y)
  y += 8

  // === PIE ===
  setItalicStyle(doc, 6)
  doc.text('Este recibo es comprobante de pago valido', ticketWidth / 2, y, { align: 'center' })
  y += 3
  doc.text('Conserve este documento', ticketWidth / 2, y, { align: 'center' })

  // Descargar PDF
  doc.save(generateFilename('recibo', pago.id?.toString()))
}
