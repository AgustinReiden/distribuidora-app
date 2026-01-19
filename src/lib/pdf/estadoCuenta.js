/**
 * Genera PDF de Estado de Cuenta del Cliente
 * Formato: A4 para impresión profesional
 */
import { jsPDF } from 'jspdf'
import { A4, COLORS } from './constants'
import {
  formatPrecio,
  formatFecha,
  generateFilename,
  setHeaderStyle,
  setNormalStyle,
  setFillColor,
  setTextColor
} from './utils'

/**
 * Genera PDF de Estado de Cuenta
 * @param {Object} cliente - Datos del cliente
 * @param {Array} pedidos - Lista de pedidos del cliente
 * @param {Array} pagos - Lista de pagos del cliente
 * @param {Object} resumen - Resumen de cuenta
 * @returns {void} - Descarga el PDF
 */
export function generarEstadoCuenta(cliente, pedidos, pagos, resumen) {
  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: 'a4'
  })

  const { width: pageWidth, margin, contentWidth } = A4
  let y = margin

  // === HEADER ===
  doc.setFontSize(18)
  doc.setFont('helvetica', 'bold')
  doc.text('ESTADO DE CUENTA', pageWidth / 2, y, { align: 'center' })
  y += 10

  setNormalStyle(doc, 10)
  doc.text(`Fecha: ${formatFecha(new Date())}`, pageWidth - margin, y, { align: 'right' })
  y += 10

  // === DATOS DEL CLIENTE ===
  setFillColor(doc, COLORS.gray[100])
  doc.rect(margin, y, contentWidth, 25, 'F')
  y += 5

  setHeaderStyle(doc, 12)
  doc.text(cliente?.nombre_fantasia || cliente?.nombre || 'Cliente', margin + 5, y + 3)

  setNormalStyle(doc, 9)
  y += 7
  if (cliente?.direccion) doc.text(`Direccion: ${cliente.direccion}`, margin + 5, y + 3)
  y += 5
  if (cliente?.telefono) doc.text(`Telefono: ${cliente.telefono}`, margin + 5, y + 3)
  if (cliente?.zona) doc.text(`Zona: ${cliente.zona}`, margin + 100, y + 3)
  y += 15

  // === RESUMEN ===
  setHeaderStyle(doc, 11)
  doc.text('RESUMEN DE CUENTA', margin, y)
  y += 6

  setNormalStyle(doc, 9)

  // Grid de resumen
  const col1 = margin
  const col2 = margin + 60
  const col3 = margin + 120

  doc.text('Total Compras:', col1, y)
  doc.text(formatPrecio(resumen?.total_compras || 0), col1 + 35, y)

  doc.text('Total Pagos:', col2, y)
  doc.text(formatPrecio(resumen?.total_pagos || 0), col2 + 35, y)
  y += 5

  doc.text('Limite Credito:', col1, y)
  doc.text(formatPrecio(cliente?.limite_credito || 0), col1 + 35, y)

  doc.text('Dias Credito:', col2, y)
  doc.text(`${cliente?.dias_credito || 30} dias`, col2 + 35, y)
  y += 8

  // Saldo destacado
  const saldoPositivo = (resumen?.saldo_actual || 0) > 0
  setFillColor(doc, saldoPositivo ? [255, 240, 240] : COLORS.green[50])
  doc.rect(col3 - 5, y - 12, 65, 18, 'F')

  doc.setFontSize(10)
  doc.setFont('helvetica', 'bold')
  doc.text('SALDO ACTUAL:', col3, y - 5)
  doc.setFontSize(14)
  setTextColor(doc, saldoPositivo ? [200, 0, 0] : [0, 150, 0])
  doc.text(formatPrecio(resumen?.saldo_actual || 0), col3, y + 2)
  setTextColor(doc, COLORS.black)
  y += 15

  // === MOVIMIENTOS ===
  setHeaderStyle(doc, 11)
  doc.text('ULTIMOS MOVIMIENTOS', margin, y)
  y += 6

  // Combinar y ordenar pedidos y pagos
  const movimientos = [
    ...(pedidos || []).map(p => ({
      fecha: p.created_at,
      tipo: 'PEDIDO',
      detalle: `Pedido #${p.id}`,
      debe: p.total,
      haber: 0,
      estado: p.estado_pago
    })),
    ...(pagos || []).map(p => ({
      fecha: p.created_at,
      tipo: 'PAGO',
      detalle: `${p.forma_pago}${p.referencia ? ` - ${p.referencia}` : ''}`,
      debe: 0,
      haber: p.monto
    }))
  ].sort((a, b) => new Date(b.fecha) - new Date(a.fecha)).slice(0, 20)

  // Encabezados de tabla
  doc.setFontSize(8)
  doc.setFont('helvetica', 'bold')
  setFillColor(doc, COLORS.gray[800])
  doc.rect(margin, y, contentWidth, 6, 'F')
  setTextColor(doc, COLORS.white)
  y += 4
  doc.text('FECHA', margin + 2, y)
  doc.text('TIPO', margin + 25, y)
  doc.text('DETALLE', margin + 50, y)
  doc.text('DEBE', margin + 120, y)
  doc.text('HABER', margin + 145, y)
  doc.text('ESTADO', margin + 170, y)
  y += 5
  setTextColor(doc, COLORS.black)

  // Filas
  setNormalStyle(doc, 7)

  movimientos.reverse().forEach((mov, index) => {
    if (y > 270) {
      doc.addPage()
      y = margin
    }

    // Alternar color de fila
    if (index % 2 === 0) {
      setFillColor(doc, COLORS.gray[50])
      doc.rect(margin, y - 3, contentWidth, 5, 'F')
    }

    doc.text(formatFecha(mov.fecha), margin + 2, y)
    doc.text(mov.tipo, margin + 25, y)
    doc.text(mov.detalle.substring(0, 30), margin + 50, y)
    doc.text(mov.debe > 0 ? formatPrecio(mov.debe) : '-', margin + 120, y)
    doc.text(mov.haber > 0 ? formatPrecio(mov.haber) : '-', margin + 145, y)
    doc.text(mov.estado || '-', margin + 170, y)
    y += 5
  })

  // Descargar PDF
  doc.save(generateFilename('estado-cuenta', cliente?.nombre_fantasia))
}
