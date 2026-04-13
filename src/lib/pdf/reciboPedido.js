/**
 * Genera PDF de Recibo de Pedido
 * Soporta dos formatos: A4 profesional y Comanda (75mm ticket)
 * Branding: Crecer Distribuciones
 */
import { jsPDF } from 'jspdf'
import { A4, TICKET, COLORS, FORMAS_PAGO_LABELS } from './constants'
import {
  formatPrecio,
  formatFecha,
  formatFechaHora,
  generateFilename,
  drawDivider,
  setFillColor,
  setTextColor,
  setHeaderStyle,
  setNormalStyle,
  setItalicStyle
} from './utils'

// Colores de marca Crecer Distribuciones
const BRAND = {
  primary: [22, 101, 52],     // Verde oscuro
  primaryLight: [34, 197, 94], // Verde medio
  accent: [240, 253, 244],     // Verde muy claro (fondo)
  dark: [15, 23, 42],          // Casi negro (slate-900)
  warmGray: [245, 245, 244],   // Piedra claro
}

/**
 * Genera recibo en formato A4 profesional
 */
function generarReciboA4(pedido) {
  const doc = new jsPDF({ orientation: 'portrait', unit: 'mm', format: 'a4' })
  const { width: pageWidth, margin, contentWidth } = A4
  let y = margin

  // === HEADER EMPRESA ===
  // Barra superior de color marca
  setFillColor(doc, BRAND.dark)
  doc.rect(0, 0, pageWidth, 42, 'F')

  // Acento verde en la barra
  setFillColor(doc, BRAND.primary)
  doc.rect(0, 38, pageWidth, 4, 'F')

  // Nombre de la empresa
  setTextColor(doc, COLORS.white)
  doc.setFontSize(24)
  doc.setFont('helvetica', 'bold')
  doc.text('CRECER DISTRIBUCIONES', margin, 20)

  // Subtítulo
  doc.setFontSize(9)
  doc.setFont('helvetica', 'normal')
  setTextColor(doc, [180, 200, 180])
  doc.text('Distribuidora mayorista', margin, 28)

  // Recibo info (derecha)
  setTextColor(doc, COLORS.white)
  doc.setFontSize(10)
  doc.setFont('helvetica', 'bold')
  doc.text('RECIBO DE PEDIDO', pageWidth - margin, 14, { align: 'right' })
  doc.setFontSize(18)
  doc.text(`#${pedido.id}`, pageWidth - margin, 24, { align: 'right' })
  doc.setFontSize(9)
  doc.setFont('helvetica', 'normal')
  doc.text(formatFecha(pedido.fecha || pedido.created_at || new Date()), pageWidth - margin, 32, { align: 'right' })

  y = 52

  // === BADGE DE ESTADO ===
  setTextColor(doc, COLORS.black)
  const estadoPagoLabel = pedido.estado_pago === 'pagado' ? 'PAGADO' :
    pedido.estado_pago === 'parcial' ? 'PARCIAL' : 'PENDIENTE'
  const badgeColor = pedido.estado_pago === 'pagado' ? BRAND.primary :
    pedido.estado_pago === 'parcial' ? COLORS.yellow[700] : COLORS.red[500]
  setFillColor(doc, badgeColor)
  const badgeWidth = doc.getTextWidth(estadoPagoLabel) + 14
  doc.roundedRect(pageWidth - margin - badgeWidth, y - 5, badgeWidth, 10, 2, 2, 'F')
  setTextColor(doc, COLORS.white)
  doc.setFontSize(9)
  doc.setFont('helvetica', 'bold')
  doc.text(estadoPagoLabel, pageWidth - margin - badgeWidth / 2, y + 1, { align: 'center' })

  // === DATOS DEL CLIENTE ===
  setTextColor(doc, BRAND.primary)
  doc.setFontSize(8)
  doc.setFont('helvetica', 'bold')
  doc.text('DATOS DEL CLIENTE', margin, y)
  y += 5

  // Caja del cliente
  setFillColor(doc, BRAND.warmGray)
  doc.roundedRect(margin, y - 2, contentWidth, 30, 3, 3, 'F')
  // Borde izquierdo verde
  setFillColor(doc, BRAND.primary)
  doc.rect(margin, y - 2, 3, 30, 'F')

  setTextColor(doc, BRAND.dark)
  doc.setFontSize(14)
  doc.setFont('helvetica', 'bold')
  doc.text(pedido.cliente?.nombre_fantasia || 'Cliente', margin + 8, y + 6)

  doc.setFontSize(9)
  doc.setFont('helvetica', 'normal')
  setTextColor(doc, COLORS.gray[600])

  let clienteY = y + 12
  if (pedido.cliente?.razon_social && pedido.cliente.razon_social !== pedido.cliente.nombre_fantasia) {
    doc.text(pedido.cliente.razon_social, margin + 8, clienteY)
    clienteY += 5
  }
  if (pedido.cliente?.direccion) {
    doc.text(pedido.cliente.direccion, margin + 8, clienteY)
    clienteY += 5
  }
  const contacto = [
    pedido.cliente?.telefono ? `Tel: ${pedido.cliente.telefono}` : null,
    pedido.cliente?.cuit ? `CUIT: ${pedido.cliente.cuit}` : null
  ].filter(Boolean).join('  |  ')
  if (contacto) doc.text(contacto, margin + 8, clienteY)

  y += 38

  // === TABLA DE PRODUCTOS ===
  setTextColor(doc, BRAND.primary)
  doc.setFontSize(8)
  doc.setFont('helvetica', 'bold')
  doc.text('DETALLE DE PRODUCTOS', margin, y)
  y += 5

  // Header de tabla
  setFillColor(doc, BRAND.dark)
  doc.roundedRect(margin, y, contentWidth, 9, 2, 2, 'F')
  setTextColor(doc, COLORS.white)
  doc.setFontSize(8)
  doc.setFont('helvetica', 'bold')
  y += 6
  doc.text('PRODUCTO', margin + 5, y)
  doc.text('CANT.', margin + 105, y, { align: 'center' })
  doc.text('P. UNIT.', margin + 130, y, { align: 'center' })
  doc.text('SUBTOTAL', contentWidth + margin - 5, y, { align: 'right' })
  y += 6

  // Filas de productos
  const items = pedido.items || []
  items.forEach((item, index) => {
    // Alternar color de fila
    if (index % 2 === 0) {
      setFillColor(doc, BRAND.accent)
      doc.rect(margin, y - 4, contentWidth, 9, 'F')
    }

    setTextColor(doc, BRAND.dark)
    doc.setFontSize(9)
    doc.setFont('helvetica', 'normal')

    // Nombre completo del producto (sin truncar, con wrap si necesario)
    const productoNombre = item.producto?.nombre || 'Producto'
    const nombreLines = doc.splitTextToSize(productoNombre, 90)
    doc.text(nombreLines[0], margin + 5, y)

    doc.text(String(item.cantidad), margin + 105, y, { align: 'center' })
    doc.text(formatPrecio(item.precio_unitario), margin + 130, y, { align: 'center' })

    doc.setFont('helvetica', 'bold')
    doc.text(
      formatPrecio(item.subtotal || item.precio_unitario * item.cantidad),
      contentWidth + margin - 5, y, { align: 'right' }
    )

    y += 9

    // Si el nombre tiene más de una línea
    if (nombreLines.length > 1) {
      doc.setFont('helvetica', 'normal')
      doc.setFontSize(8)
      setTextColor(doc, COLORS.gray[500])
      doc.text(nombreLines[1], margin + 5, y - 4)
      y += 4
    }

    // Paginación
    if (y > 255) {
      doc.addPage()
      y = margin
    }
  })

  // Línea antes del total
  y += 3
  doc.setDrawColor(...COLORS.gray[200])
  doc.setLineWidth(0.5)
  doc.line(margin + 80, y, margin + contentWidth, y)
  y += 8

  // === TOTAL ===
  setFillColor(doc, BRAND.dark)
  doc.roundedRect(margin + 90, y - 6, contentWidth - 90, 16, 3, 3, 'F')
  setTextColor(doc, COLORS.white)
  doc.setFontSize(11)
  doc.setFont('helvetica', 'bold')
  doc.text('TOTAL:', margin + 97, y + 4)
  doc.setFontSize(16)
  doc.text(formatPrecio(pedido.total), contentWidth + margin - 7, y + 4, { align: 'right' })
  setTextColor(doc, COLORS.black)

  y += 20

  // === INFORMACIÓN DE PAGO ===
  setFillColor(doc, BRAND.accent)
  doc.roundedRect(margin, y, contentWidth, 22, 3, 3, 'F')
  // Borde izquierdo verde
  setFillColor(doc, BRAND.primaryLight)
  doc.rect(margin, y, 3, 22, 'F')

  doc.setFontSize(8)
  doc.setFont('helvetica', 'bold')
  setTextColor(doc, BRAND.primary)
  doc.text('INFORMACION DE PAGO', margin + 8, y + 6)

  doc.setFont('helvetica', 'normal')
  setTextColor(doc, COLORS.gray[700])
  doc.setFontSize(9)

  const formaPagoLabel = FORMAS_PAGO_LABELS[pedido.forma_pago] || pedido.forma_pago || 'Efectivo'
  doc.text(`Forma de pago: ${formaPagoLabel}`, margin + 8, y + 13)

  const montoPagado = pedido.monto_pagado ?? (pedido.estado_pago === 'pagado' ? pedido.total : 0)
  doc.text(`Monto pagado: ${formatPrecio(montoPagado)}`, margin + 80, y + 13)

  if (pedido.estado_pago === 'parcial') {
    const saldo = pedido.total - montoPagado
    doc.setFont('helvetica', 'bold')
    setTextColor(doc, COLORS.red[700])
    doc.text(`Saldo pendiente: ${formatPrecio(saldo)}`, margin + 8, y + 19)
  }

  y += 30

  // === NOTAS ===
  if (pedido.notas) {
    setFillColor(doc, [255, 251, 235])
    doc.roundedRect(margin, y, contentWidth, 18, 3, 3, 'F')
    setFillColor(doc, COLORS.yellow[700])
    doc.rect(margin, y, 3, 18, 'F')

    doc.setFontSize(8)
    doc.setFont('helvetica', 'bold')
    setTextColor(doc, COLORS.yellow[700])
    doc.text('OBSERVACIONES', margin + 8, y + 6)
    doc.setFont('helvetica', 'normal')
    setTextColor(doc, COLORS.gray[600])
    doc.setFontSize(9)
    const notasLines = doc.splitTextToSize(pedido.notas, contentWidth - 15)
    doc.text(notasLines.slice(0, 2), margin + 8, y + 12)
    y += 24
  }

  // === TRANSPORTISTA ===
  if (pedido.transportista?.nombre) {
    doc.setFontSize(9)
    doc.setFont('helvetica', 'normal')
    setTextColor(doc, COLORS.gray[500])
    doc.text(`Entregado por: ${pedido.transportista.nombre}`, margin, y)
    y += 8
  }

  // === PIE DE PÁGINA ===
  const footerY = 270
  doc.setDrawColor(...COLORS.gray[200])
  doc.setLineWidth(0.3)
  doc.line(margin, footerY, pageWidth - margin, footerY)

  doc.setFontSize(8)
  doc.setFont('helvetica', 'normal')
  setTextColor(doc, COLORS.gray[400])
  doc.text('Crecer Distribuciones', margin, footerY + 5)
  doc.text('Este documento es comprobante valido de la operacion realizada.', pageWidth / 2, footerY + 5, { align: 'center' })

  doc.setFontSize(7)
  doc.setFont('helvetica', 'italic')
  doc.text(`Generado: ${formatFechaHora(new Date())}`, pageWidth - margin, footerY + 5, { align: 'right' })

  doc.save(generateFilename('recibo-pedido', pedido.id?.toString()))
}

/**
 * Calcula la altura dinamica de una comanda para un pedido
 */
function calcularAlturaComanda(pedido) {
  const items = pedido.items || []
  let height = 30 // header
  height += 20 // cliente
  height += 6 // divider + header tabla
  height += items.length * 9 // productos (nombre + detalle precio)
  height += 25 // total + pago
  if (pedido.notas) height += 12
  height += 20 // pie
  return Math.max(height, 80)
}

/**
 * Dibuja el contenido de una comanda en el documento jsPDF actual
 * @param {jsPDF} doc - Documento jsPDF
 * @param {Object} pedido - Datos del pedido
 * @returns {void}
 */
function dibujarComanda(doc, pedido) {
  const { width: ticketWidth, margin, contentWidth } = TICKET
  let y = margin

  // === HEADER ===
  doc.setTextColor(0, 0, 0)
  setHeaderStyle(doc, 11)
  doc.text('CRECER', ticketWidth / 2, y + 4, { align: 'center' })
  y += 5
  doc.setFontSize(7)
  doc.setFont('helvetica', 'normal')
  doc.text('DISTRIBUCIONES', ticketWidth / 2, y + 2, { align: 'center' })
  y += 5

  // Número de recibo y fecha
  setHeaderStyle(doc, 8)
  doc.text(`Recibo #${pedido.id}`, ticketWidth / 2, y, { align: 'center' })
  y += 3
  setNormalStyle(doc, 6)
  doc.text(formatFechaHora(pedido.fecha || pedido.created_at || new Date()), ticketWidth / 2, y, { align: 'center' })
  y += 3

  drawDivider(doc, y, margin, ticketWidth - margin, 0.5)
  y += 3

  // === CLIENTE ===
  setHeaderStyle(doc, 8)
  doc.text(pedido.cliente?.nombre_fantasia || 'Cliente', margin, y)
  y += 3
  setNormalStyle(doc, 6)
  if (pedido.cliente?.direccion) {
    const dirLines = doc.splitTextToSize(pedido.cliente.direccion, contentWidth)
    dirLines.slice(0, 2).forEach(line => {
      doc.text(line, margin, y)
      y += 2.5
    })
  }
  if (pedido.cliente?.telefono) {
    doc.text(`Tel: ${pedido.cliente.telefono}`, margin, y)
    y += 2.5
  }
  y += 1

  drawDivider(doc, y, margin, ticketWidth - margin, 0.3)
  y += 3

  // === PRODUCTOS ===
  const items = pedido.items || []
  setHeaderStyle(doc, 6)
  doc.text('PRODUCTO', margin, y)
  doc.text('SUBT.', ticketWidth - margin, y, { align: 'right' })
  y += 3

  setNormalStyle(doc, 6)
  items.forEach(item => {
    const productoNombre = item.producto?.nombre || 'Producto'
    const subtotal = item.subtotal || item.precio_unitario * item.cantidad

    const nombreLines = doc.splitTextToSize(`${item.cantidad}x ${productoNombre}`, contentWidth - 22)
    nombreLines.forEach((line, idx) => {
      doc.text(line, margin, y)
      if (idx === 0) {
        doc.text(formatPrecio(subtotal), ticketWidth - margin, y, { align: 'right' })
      }
      y += 2.8
    })
    // Detalle: cantidad x precio unitario
    doc.setFontSize(5)
    doc.setTextColor(100, 100, 100)
    doc.text(`${item.cantidad} x ${formatPrecio(item.precio_unitario)}`, margin + 2, y)
    doc.setTextColor(0, 0, 0)
    doc.setFontSize(6)
    y += 2.5
  })

  y += 1
  drawDivider(doc, y, margin, ticketWidth - margin, 0.5)
  y += 3

  // === TOTAL ===
  setHeaderStyle(doc, 10)
  doc.text('TOTAL:', margin, y)
  doc.text(formatPrecio(pedido.total), ticketWidth - margin, y, { align: 'right' })
  y += 4

  // Estado de pago
  setNormalStyle(doc, 7)
  const formaPagoLabel = FORMAS_PAGO_LABELS[pedido.forma_pago] || pedido.forma_pago || 'Efectivo'
  doc.text(`${formaPagoLabel}`, margin, y)

  const estadoPagoLabel = pedido.estado_pago === 'pagado' ? 'PAGADO' :
    pedido.estado_pago === 'parcial' ? 'PARCIAL' : 'PENDIENTE'
  setHeaderStyle(doc, 7)
  doc.text(estadoPagoLabel, ticketWidth - margin, y, { align: 'right' })
  y += 3

  if (pedido.estado_pago === 'parcial') {
    setNormalStyle(doc, 6)
    const montoPagado = pedido.monto_pagado || 0
    doc.text(`Pagado: ${formatPrecio(montoPagado)}`, margin, y)
    doc.text(`Saldo: ${formatPrecio(pedido.total - montoPagado)}`, ticketWidth - margin, y, { align: 'right' })
    y += 3
  }

  // === NOTAS ===
  if (pedido.notas) {
    y += 1
    drawDivider(doc, y, margin, ticketWidth - margin, 0.2)
    y += 2
    setItalicStyle(doc, 6)
    const notasLines = doc.splitTextToSize(pedido.notas, contentWidth)
    notasLines.slice(0, 3).forEach(line => {
      doc.text(line, margin, y)
      y += 2.5
    })
  }

  // === PIE ===
  y += 2
  drawDivider(doc, y, margin, ticketWidth - margin, 0.3)
  y += 3
  setItalicStyle(doc, 5)
  doc.text('Crecer Distribuciones', ticketWidth / 2, y, { align: 'center' })
  y += 2
  doc.text('Comprobante valido de operacion', ticketWidth / 2, y, { align: 'center' })
}

/**
 * Genera recibo en formato Comanda (75mm ticket) - pedido individual
 */
function generarReciboComanda(pedido) {
  const { width: ticketWidth } = TICKET
  const height = calcularAlturaComanda(pedido)

  const doc = new jsPDF({ orientation: 'portrait', unit: 'mm', format: [ticketWidth, height] })
  dibujarComanda(doc, pedido)
  doc.save(generateFilename('recibo-comanda', pedido.id?.toString()))
}

/**
 * Genera multiples comandas para impresion en comandera con corte automatico.
 * Cada pedido se imprime por duplicado, cada copia en pagina separada.
 * La impresora termica corta en cada salto de pagina.
 * @param {Array} pedidos - Array de pedidos con items y cliente
 */
export function generarComandasMultiples(pedidos) {
  if (!pedidos || pedidos.length === 0) return

  const { width: ticketWidth } = TICKET
  let isFirstPage = true
  let doc = null

  pedidos.forEach(pedido => {
    const height = calcularAlturaComanda(pedido)

    // Cada pedido se imprime 2 veces (duplicado)
    for (let copia = 0; copia < 2; copia++) {
      if (isFirstPage) {
        doc = new jsPDF({ orientation: 'portrait', unit: 'mm', format: [ticketWidth, height] })
        isFirstPage = false
      } else {
        doc.addPage([ticketWidth, height])
      }
      dibujarComanda(doc, pedido)
    }
  })

  if (doc) {
    doc.autoPrint()
    window.open(doc.output('bloburl'), '_blank')
  }
}

/**
 * Genera PDF de Recibo de Pedido
 * @param {Object} pedido - Datos del pedido completo (con items y cliente)
 * @param {Object} _empresa - (deprecated) No se usa, branding hardcodeado
 * @param {Object} options - Opciones de generación
 * @param {'a4'|'comanda'} options.formato - Formato de salida (default: 'a4')
 * @returns {void} - Descarga el PDF
 */
export function generarReciboPedido(pedido, _empresa = {}, options = {}) {
  const formato = options.formato || 'a4'
  if (formato === 'comanda') {
    generarReciboComanda(pedido)
  } else {
    generarReciboA4(pedido)
  }
}
