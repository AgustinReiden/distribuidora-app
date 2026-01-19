/**
 * Genera PDF de Recibo de Pedido Pagado
 * Formato: A4 profesional con detalle completo de productos
 */
import { jsPDF } from 'jspdf'
import { A4, COLORS, FORMAS_PAGO_LABELS } from './constants'
import {
  formatPrecio,
  formatFecha,
  formatFechaHora,
  truncate,
  generateFilename,
  setFillColor,
  setTextColor
} from './utils'

/**
 * Genera PDF de Recibo de Pedido
 * @param {Object} pedido - Datos del pedido completo (con items y cliente)
 * @param {Object} empresa - Datos de la empresa (opcional)
 * @returns {void} - Descarga el PDF
 */
export function generarReciboPedido(pedido, empresa = {}) {
  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: 'a4'
  })

  const { width: pageWidth, margin, contentWidth } = A4
  let y = margin

  // === HEADER DE LA EMPRESA ===
  setFillColor(doc, COLORS.gray[900])
  doc.rect(0, 0, pageWidth, 40, 'F')

  setTextColor(doc, COLORS.white)
  doc.setFontSize(22)
  doc.setFont('helvetica', 'bold')
  doc.text(empresa.nombre || 'DISTRIBUIDORA', margin, 18)

  if (empresa.direccion || empresa.telefono || empresa.email) {
    doc.setFontSize(9)
    doc.setFont('helvetica', 'normal')
    let infoY = 25
    if (empresa.direccion) {
      doc.text(empresa.direccion, margin, infoY)
      infoY += 4
    }
    const contactoTexto = [empresa.telefono, empresa.email].filter(Boolean).join(' | ')
    if (contactoTexto) doc.text(contactoTexto, margin, infoY)
  }

  // Número de recibo y fecha (derecha)
  doc.setFontSize(11)
  doc.setFont('helvetica', 'bold')
  doc.text('RECIBO', pageWidth - margin, 15, { align: 'right' })
  doc.setFontSize(16)
  doc.text(`#${pedido.id}`, pageWidth - margin, 23, { align: 'right' })
  doc.setFontSize(9)
  doc.setFont('helvetica', 'normal')
  doc.text(formatFecha(pedido.created_at || new Date()), pageWidth - margin, 30, { align: 'right' })

  y = 50
  setTextColor(doc, COLORS.black)

  // === ESTADO PAGADO - Badge destacado ===
  setFillColor(doc, COLORS.green[500])
  doc.roundedRect(pageWidth - margin - 35, y - 5, 35, 10, 2, 2, 'F')
  setTextColor(doc, COLORS.white)
  doc.setFontSize(9)
  doc.setFont('helvetica', 'bold')
  doc.text('PAGADO', pageWidth - margin - 17.5, y + 1, { align: 'center' })
  setTextColor(doc, COLORS.black)

  // === DATOS DEL CLIENTE ===
  doc.setFontSize(10)
  doc.setFont('helvetica', 'bold')
  setTextColor(doc, COLORS.gray[500])
  doc.text('CLIENTE', margin, y)
  y += 6

  setFillColor(doc, COLORS.gray[50])
  doc.roundedRect(margin, y - 3, contentWidth, 28, 2, 2, 'F')

  setTextColor(doc, COLORS.black)
  doc.setFontSize(13)
  doc.setFont('helvetica', 'bold')
  doc.text(pedido.cliente?.nombre_fantasia || 'Cliente', margin + 5, y + 4)

  doc.setFontSize(9)
  doc.setFont('helvetica', 'normal')
  setTextColor(doc, COLORS.gray[600])

  if (pedido.cliente?.razon_social) {
    doc.text(pedido.cliente.razon_social, margin + 5, y + 10)
  }
  if (pedido.cliente?.cuit) {
    doc.text(`CUIT: ${pedido.cliente.cuit}`, margin + 5, y + 15)
  }
  if (pedido.cliente?.direccion) {
    doc.text(pedido.cliente.direccion, margin + 5, y + 20)
  }
  if (pedido.cliente?.telefono) {
    doc.text(`Tel: ${pedido.cliente.telefono}`, margin + 100, y + 15)
  }

  y += 35

  // === TABLA DE PRODUCTOS ===
  setTextColor(doc, COLORS.gray[500])
  doc.setFontSize(10)
  doc.setFont('helvetica', 'bold')
  doc.text('DETALLE DE PRODUCTOS', margin, y)
  y += 5

  // Encabezados de tabla
  setFillColor(doc, COLORS.gray[900])
  doc.rect(margin, y, contentWidth, 8, 'F')
  setTextColor(doc, COLORS.white)
  doc.setFontSize(8)
  doc.setFont('helvetica', 'bold')
  y += 5.5
  doc.text('PRODUCTO', margin + 3, y)
  doc.text('CANTIDAD', margin + 100, y, { align: 'center' })
  doc.text('P. UNIT.', margin + 125, y, { align: 'center' })
  doc.text('SUBTOTAL', margin + 165, y, { align: 'right' })
  y += 5

  // Filas de productos
  setTextColor(doc, COLORS.black)
  doc.setFont('helvetica', 'normal')
  doc.setFontSize(9)

  const items = pedido.items || []
  items.forEach((item, index) => {
    // Alternar color de fila
    if (index % 2 === 0) {
      setFillColor(doc, COLORS.gray[50])
      doc.rect(margin, y - 4, contentWidth, 8, 'F')
    }

    const productoNombre = item.producto?.nombre || 'Producto'
    doc.text(truncate(productoNombre, 45), margin + 3, y)
    doc.text(String(item.cantidad), margin + 100, y, { align: 'center' })
    doc.text(formatPrecio(item.precio_unitario), margin + 125, y, { align: 'center' })
    doc.text(formatPrecio(item.subtotal || item.precio_unitario * item.cantidad), margin + 165, y, { align: 'right' })
    y += 8

    // Verificar si necesita nueva página
    if (y > 250) {
      doc.addPage()
      y = margin
    }
  })

  // Línea divisora
  y += 2
  doc.setDrawColor(200, 200, 200)
  doc.setLineWidth(0.5)
  doc.line(margin + 80, y, margin + contentWidth, y)
  y += 8

  // === TOTALES ===
  setFillColor(doc, COLORS.gray[900])
  doc.roundedRect(margin + 100, y - 5, 80, 14, 2, 2, 'F')
  setTextColor(doc, COLORS.white)
  doc.setFontSize(10)
  doc.setFont('helvetica', 'bold')
  doc.text('TOTAL:', margin + 105, y + 3)
  doc.setFontSize(14)
  doc.text(formatPrecio(pedido.total), margin + 175, y + 3, { align: 'right' })
  setTextColor(doc, COLORS.black)

  y += 20

  // === INFORMACIÓN DE PAGO ===
  setFillColor(doc, COLORS.green[50])
  doc.roundedRect(margin, y, contentWidth, 20, 2, 2, 'F')

  doc.setFontSize(9)
  doc.setFont('helvetica', 'bold')
  setTextColor(doc, COLORS.green[500])
  doc.text('INFORMACION DE PAGO', margin + 5, y + 6)

  doc.setFont('helvetica', 'normal')
  setTextColor(doc, COLORS.gray[700])
  doc.setFontSize(9)

  const formaPagoLabel = FORMAS_PAGO_LABELS[pedido.forma_pago] || pedido.forma_pago || 'Efectivo'
  doc.text(`Forma de pago: ${formaPagoLabel}`, margin + 5, y + 13)
  doc.text(`Monto pagado: ${formatPrecio(pedido.monto_pagado || pedido.total)}`, margin + 80, y + 13)

  if (pedido.fecha_entrega) {
    doc.text(`Fecha entrega: ${formatFecha(pedido.fecha_entrega)}`, margin + 140, y + 13)
  }

  y += 30

  // === NOTAS DEL PEDIDO ===
  if (pedido.notas) {
    setFillColor(doc, COLORS.yellow[50])
    doc.roundedRect(margin, y, contentWidth, 18, 2, 2, 'F')
    doc.setFontSize(8)
    doc.setFont('helvetica', 'bold')
    setTextColor(doc, COLORS.yellow[700])
    doc.text('NOTAS:', margin + 5, y + 6)
    doc.setFont('helvetica', 'normal')
    setTextColor(doc, COLORS.gray[600])
    const notasLines = doc.splitTextToSize(pedido.notas, contentWidth - 10)
    doc.text(notasLines.slice(0, 2), margin + 5, y + 12)
    y += 25
  }

  // === TRANSPORTISTA ===
  if (pedido.transportista?.nombre) {
    doc.setFontSize(8)
    doc.setFont('helvetica', 'normal')
    setTextColor(doc, COLORS.gray[500])
    doc.text(`Entregado por: ${pedido.transportista.nombre}`, margin, y)
    y += 8
  }

  // === PIE DE PÁGINA ===
  y = 265
  doc.setDrawColor(200, 200, 200)
  doc.setLineWidth(0.3)
  doc.line(margin, y, pageWidth - margin, y)
  y += 5

  doc.setFontSize(8)
  doc.setFont('helvetica', 'italic')
  setTextColor(doc, COLORS.gray[400])
  doc.text('Este documento es comprobante valido de la operacion realizada.', pageWidth / 2, y, { align: 'center' })
  y += 4
  doc.text('Conserve este recibo para cualquier reclamo o consulta.', pageWidth / 2, y, { align: 'center' })

  // Fecha de generación
  y += 6
  doc.setFontSize(7)
  doc.text(`Generado: ${formatFechaHora(new Date())}`, pageWidth / 2, y, { align: 'center' })

  // Descargar PDF
  doc.save(generateFilename('recibo-pedido', pedido.id?.toString()))
}
