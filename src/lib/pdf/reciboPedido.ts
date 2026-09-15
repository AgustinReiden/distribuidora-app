/**
 * Genera PDF de Recibo de Pedido
 * Soporta dos formatos: A4 profesional y Comanda (75mm ticket)
 * Branding: Crecer Distribuciones
 */
import { jsPDF } from 'jspdf'
import type { PedidoDB, PedidoItemDB } from '../../types/hooks'
import { A4, TICKET, COLORS, FORMAS_PAGO_LABELS } from './constants'
import {
  formatPrecio,
  formatFecha,
  formatFechaHora,
  generateFilename,
  drawDivider,
  setFillColor,
  setTextColor,
  setDrawColor,
  setHeaderStyle,
  setNormalStyle,
  setItalicStyle
} from './utils'
import { lineaItemImpresion } from './utils/lineaItem'
import { bloqueDeudaComanda } from '../../utils/deudaCliente'

// jsPDF expone `internal.getNumberOfPages` en runtime (alias de getNumberOfPages),
// pero el .d.ts de jspdf no lo declara en el tipo de `internal`.
type InternalConPaginas = jsPDF['internal'] & { getNumberOfPages: () => number }

// Colores de marca Crecer Distribuciones
const BRAND = {
  primary: [22, 101, 52],     // Verde oscuro
  primaryLight: [34, 197, 94], // Verde medio
  accent: [240, 253, 244],     // Verde muy claro (fondo)
  dark: [15, 23, 42],          // Casi negro (slate-900)
  warmGray: [245, 245, 244],   // Piedra claro
}

/**
 * Agrupa items de bonificacion repetidos por (producto, promocion, descripcion).
 *
 * El RPC `crear_pedido_completo` inserta UNA fila por bloque de promo aplicado:
 * si una promo regala 2 botellas y el cliente compra 3 promos, se generan 3
 * filas en `pedido_items` con cantidad=2 cada una (mismo producto y promo).
 *
 * Para impresion (comanda y recibo A4) queremos verlas sumadas: "6 botellas
 * (REGALO)" en una sola linea, no "3 x 2 botellas" en tres lineas.
 *
 * Los items NO bonificacion se mantienen sin cambios (el reducer del pedido
 * ya garantiza una fila por producto en pedidos cargados desde la app).
 */
function agruparItemsParaImpresion(items: PedidoItemDB[] | undefined): PedidoItemDB[] {
  if (!items || items.length === 0) return []
  const noBonif: PedidoItemDB[] = []
  const bonifMap = new Map<string, PedidoItemDB>()
  items.forEach(item => {
    if (!item.es_bonificacion) {
      noBonif.push(item)
      return
    }
    const key = [
      item.producto_id ?? item.producto?.id ?? 'null',
      item.promocion_id ?? 'null',
      (item.descripcion_regalo || '').trim()
    ].join('|')
    const existing = bonifMap.get(key)
    if (existing) {
      existing.cantidad = (existing.cantidad || 0) + (item.cantidad || 0)
      existing.subtotal = (existing.subtotal || 0) + (item.subtotal || 0)
    } else {
      // Copia superficial para no mutar el item original
      bonifMap.set(key, { ...item, cantidad: item.cantidad || 0, subtotal: item.subtotal || 0 })
    }
  })
  return [...noBonif, ...bonifMap.values()]
}

/**
 * Dibuja el pie de pagina del recibo A4 en la pagina actual del documento.
 * Se llama una vez por cada hoja (ver generarReciboA4): sin esto, un recibo
 * de varias paginas solo tenia pie en la ultima.
 */
function dibujarPieReciboA4(doc: jsPDF, pageWidth: number, margin: number, footerY: number): void {
  setDrawColor(doc, COLORS.gray[200])
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
}

/**
 * Genera recibo en formato A4 profesional
 */
function generarReciboA4(pedido: PedidoDB): void {
  const doc = new jsPDF({ orientation: 'portrait', unit: 'mm', format: 'a4' })
  const { width: pageWidth, margin, contentWidth } = A4
  const footerY = 270
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

  // Caja del cliente (alto dinamico si hay horarios)
  const boxHeight = pedido.cliente?.horarios_atencion ? 36 : 30
  setFillColor(doc, BRAND.warmGray)
  doc.roundedRect(margin, y - 2, contentWidth, boxHeight, 3, 3, 'F')
  // Borde izquierdo verde
  setFillColor(doc, BRAND.primary)
  doc.rect(margin, y - 2, 3, boxHeight, 'F')

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
  if (contacto) {
    doc.text(contacto, margin + 8, clienteY)
    clienteY += 5
  }
  if (pedido.cliente?.horarios_atencion) {
    const horarioTxt = `Horario: ${pedido.cliente.horarios_atencion}`
    const horLine = doc.splitTextToSize(horarioTxt, contentWidth - 16)[0] || horarioTxt
    doc.text(horLine, margin + 8, clienteY)
  }

  y += boxHeight + 8

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

  // Filas de productos (bonificaciones repetidas se agrupan en una sola linea)
  const items = agruparItemsParaImpresion(pedido.items)
  items.forEach((item, index) => {
    // Alternar color de fila
    if (index % 2 === 0) {
      setFillColor(doc, BRAND.accent)
      doc.rect(margin, y - 4, contentWidth, 9, 'F')
    }

    setTextColor(doc, BRAND.dark)
    doc.setFontSize(9)
    doc.setFont('helvetica', 'normal')

    // Nombre completo del producto (sin truncar, con wrap si necesario).
    // La linea la arma lineaItemImpresion (misma unidad que hojaRutaOptimizada
    // y ordenPreparacion): decide nombre, aclaracion de bulto y, para un
    // regalo de fraccion, la unidad en subunidades con el factor CONGELADO al
    // crear la linea (mig 212), no el vivo de la promo (#591/#592). La tabla
    // ya tiene columna CANT. propia, asi que se descarta el prefijo "Nx ".
    const nombreCompleto = lineaItemImpresion(item).replace(/^\d+x\s+/, '')
    const nombreLines = doc.splitTextToSize(nombreCompleto, 90)
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

  // Si el bloque que sigue (alto `needed`) no entra antes del pie, salta de
  // pagina. Sin esto, con 13-14 items el bloque de pago se pisaba con el pie
  // (fijo en footerY) y con 15 "Saldo pendiente" caia fuera de la hoja A4.
  const ensureSpace = (needed: number): void => {
    if (y + needed > footerY - 5) {
      doc.addPage()
      y = margin
    }
  }

  // Línea antes del total
  y += 3
  setDrawColor(doc, COLORS.gray[200])
  doc.setLineWidth(0.5)
  doc.line(margin + 80, y, margin + contentWidth, y)
  y += 8

  // === TOTAL ===
  ensureSpace(20)
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
  ensureSpace(30)
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

  const formaPagoLabel = FORMAS_PAGO_LABELS[pedido.forma_pago ?? ''] || pedido.forma_pago || 'Efectivo'
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
    ensureSpace(24)
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
    ensureSpace(8)
    doc.setFontSize(9)
    doc.setFont('helvetica', 'normal')
    setTextColor(doc, COLORS.gray[500])
    doc.text(`Entregado por: ${pedido.transportista.nombre}`, margin, y)
    y += 8
  }

  // === PIE DE PÁGINA (en cada hoja, no solo la ultima) ===
  const totalPaginas = (doc.internal as InternalConPaginas).getNumberOfPages()
  for (let pagina = 1; pagina <= totalPaginas; pagina++) {
    doc.setPage(pagina)
    dibujarPieReciboA4(doc, pageWidth, margin, footerY)
  }

  doc.save(generateFilename('recibo-pedido', pedido.id?.toString()))
}

/**
 * Calcula la altura dinamica de una comanda para un pedido
 */
function calcularAlturaComanda(pedido: PedidoDB): number {
  // Usamos la misma agrupacion de bonificaciones que dibujarComanda para que
  // el alto refleje las lineas reales (sino sobra papel en blanco).
  const items = agruparItemsParaImpresion(pedido.items)
  let height = 40 // header empresa + nro recibo + fecha
  height += 28 // cliente (nombre + direccion 2 lineas + telefono)
  // Reserva extra cuando el nombre puede partirse a 2 lineas (>30 chars
  // suele ser umbral para el ancho 75mm en font 12).
  if ((pedido.cliente?.nombre_fantasia || '').length > 30) height += 5
  if (pedido.cliente?.horarios_atencion) height += 8 // horario (hasta 2 lineas)
  height += 10 // divider + header tabla productos
  height += items.length * 12 // productos (nombre puede envolver + detalle precio unit)
  // El banner (y su alto) solo aplica si el detalle del cambio esta disponible:
  // sin el embed cambio:recorrido_cambios (ej. comanda individual desde
  // PedidoCard, que usa PEDIDO_SELECT sin ese join) canal='cambio' solo, sin
  // pedido.cambio, imprimia el cartel con 18mm de papel vacio.
  if (pedido.canal === 'cambio' && (Array.isArray(pedido.cambio) ? pedido.cambio[0] : pedido.cambio)) {
    height += 18
  }
  height += 32 // total + forma pago + estado
  if (pedido.estado_pago === 'parcial') height += 6
  // Deuda anterior: titulo + una linea por boleta. El alto del ticket ES el
  // formato de la pagina, asi que lo que no se cuente aca se dibuja fuera del
  // papel y no sale impreso nunca.
  const deuda = bloqueDeudaComanda(pedido.deuda_previa, pedido.deuda_previa_detalle)
  if (deuda) height += 12 + deuda.lineas.length * 4
  if (pedido.notas) height += 18
  height += 18 // pie
  return Math.max(height, 110)
}

/**
 * Dibuja el contenido de una comanda en el documento jsPDF actual
 */
function dibujarComanda(doc: jsPDF, pedido: PedidoDB): void {
  const { width: ticketWidth, margin, contentWidth } = TICKET
  let y = margin

  // === HEADER ===
  doc.setTextColor(0, 0, 0)
  setHeaderStyle(doc, 14)
  doc.text('CRECER', ticketWidth / 2, y + 5, { align: 'center' })
  y += 7
  doc.setFontSize(9)
  doc.setFont('helvetica', 'normal')
  doc.text('DISTRIBUCIONES', ticketWidth / 2, y + 2, { align: 'center' })
  y += 6

  // Número de recibo y fecha
  setHeaderStyle(doc, 11)
  doc.text(`Recibo #${pedido.id}`, ticketWidth / 2, y, { align: 'center' })
  y += 5
  setNormalStyle(doc, 9)
  // created_at primero: es timestamp real. pedido.fecha es date-only (columna
  // date), y formatFechaHora mostraba las 12:00 inventadas por parseDateSafe
  // en TODAS las comandas.
  doc.text(formatFechaHora(pedido.created_at || pedido.fecha || new Date()), ticketWidth / 2, y, { align: 'center' })
  y += 4

  drawDivider(doc, y, margin, ticketWidth - margin, 0.5)
  y += 5

  // === CLIENTE ===
  setHeaderStyle(doc, 12)
  const nombreLines = doc.splitTextToSize(pedido.cliente?.nombre_fantasia || 'Cliente', contentWidth)
  nombreLines.forEach((line: string) => {
    doc.text(line, margin, y)
    y += 5
  })
  setNormalStyle(doc, 9)
  if (pedido.cliente?.razon_social && pedido.cliente.razon_social !== pedido.cliente.nombre_fantasia) {
    const razonLines = doc.splitTextToSize(pedido.cliente.razon_social, contentWidth)
    razonLines.slice(0, 2).forEach((line: string) => {
      doc.text(line, margin, y)
      y += 4
    })
  }
  if (pedido.cliente?.direccion) {
    const dirLines = doc.splitTextToSize(pedido.cliente.direccion, contentWidth)
    dirLines.slice(0, 2).forEach((line: string) => {
      doc.text(line, margin, y)
      y += 4
    })
  }
  if (pedido.cliente?.telefono) {
    doc.text(`Tel: ${pedido.cliente.telefono}`, margin, y)
    y += 4
  }
  if (pedido.cliente?.horarios_atencion) {
    const horLines = doc.splitTextToSize(`Hor: ${pedido.cliente.horarios_atencion}`, contentWidth)
    horLines.slice(0, 2).forEach((line: string) => {
      doc.text(line, margin, y)
      y += 4
    })
  }
  y += 1

  drawDivider(doc, y, margin, ticketWidth - margin, 0.3)
  y += 4

  // === CAMBIO / DEVOLUCIÓN (parada canal='cambio'): banner + qué retirar/entregar ===
  // Sin el detalle (pedido.cambio) no hay nada que imprimir: ni el cartel ni el
  // alto que calcularAlturaComanda le reservó (ver ahí mismo el porqué).
  const cambioDetalle = Array.isArray(pedido.cambio) ? pedido.cambio[0] : pedido.cambio
  if (pedido.canal === 'cambio' && cambioDetalle) {
    setHeaderStyle(doc, 11)
    doc.text('CAMBIO / DEVOLUCION', ticketWidth / 2, y, { align: 'center' })
    y += 5
    setNormalStyle(doc, 9)
    doc.splitTextToSize(`Retirar: ${cambioDetalle.cantidad_devuelta ?? '?'}x ${cambioDetalle.producto_devuelto_nombre || 'producto'}`, contentWidth)
      .forEach((line: string) => { doc.text(line, margin, y); y += 4 })
    doc.splitTextToSize(`Entregar: ${cambioDetalle.cantidad_entregada ?? '?'}x ${cambioDetalle.producto_entregado_nombre || 'producto'}`, contentWidth)
      .forEach((line: string) => { doc.text(line, margin, y); y += 4 })
    y += 1
  }

  // === PRODUCTOS ===
  // Agrupamos bonificaciones repetidas: 3 filas de 2 unidades de la misma
  // promo -> una sola linea de 6 unidades.
  const items = agruparItemsParaImpresion(pedido.items)
  setHeaderStyle(doc, 9)
  doc.text('PRODUCTO', margin, y)
  doc.text('SUBT.', ticketWidth - margin, y, { align: 'right' })
  y += 4

  setNormalStyle(doc, 9)
  items.forEach(item => {
    const subtotal = item.subtotal || item.precio_unitario * item.cantidad
    const esBonif = !!item.es_bonificacion

    // La linea la arma lineaItemImpresion: mismo criterio que hojaRutaOptimizada
    // y ordenPreparacion, con el factor congelado al crear la linea (mig 212)
    // en vez del vivo de la promo (#591/#592).
    const lineaProducto = lineaItemImpresion(item)

    const nombreLines = doc.splitTextToSize(lineaProducto, contentWidth - 26)
    nombreLines.forEach((line: string, idx: number) => {
      doc.text(line, margin, y)
      if (idx === 0) {
        doc.text(formatPrecio(subtotal), ticketWidth - margin, y, { align: 'right' })
      }
      y += 4
    })
    // Detalle: para items comprados muestra "cantidad x precio_unit"; para regalos
    // se omite (no aporta info — precio es 0 y la cantidad ya esta en el header).
    if (!esBonif) {
      doc.setFontSize(7)
      doc.setTextColor(100, 100, 100)
      doc.text(`${item.cantidad} x ${formatPrecio(item.precio_unitario)}`, margin + 3, y)
      doc.setTextColor(0, 0, 0)
      doc.setFontSize(9)
      y += 3.5
    } else {
      y += 1
    }
  })

  y += 1
  drawDivider(doc, y, margin, ticketWidth - margin, 0.5)
  y += 5

  // === TOTAL ===
  setHeaderStyle(doc, 14)
  doc.text('TOTAL:', margin, y)
  doc.text(formatPrecio(pedido.total), ticketWidth - margin, y, { align: 'right' })
  y += 6

  // Estado de pago
  setNormalStyle(doc, 10)
  const formaPagoLabel = FORMAS_PAGO_LABELS[pedido.forma_pago ?? ''] || pedido.forma_pago || 'Efectivo'
  doc.text(`${formaPagoLabel}`, margin, y)

  const estadoPagoLabel = pedido.estado_pago === 'pagado' ? 'PAGADO' :
    pedido.estado_pago === 'parcial' ? 'PARCIAL' : 'PENDIENTE'
  setHeaderStyle(doc, 10)
  doc.text(estadoPagoLabel, ticketWidth - margin, y, { align: 'right' })
  y += 4

  if (pedido.estado_pago === 'parcial') {
    setNormalStyle(doc, 9)
    const montoPagado = pedido.monto_pagado || 0
    doc.text(`Pagado: ${formatPrecio(montoPagado)}`, margin, y)
    doc.text(`Saldo: ${formatPrecio(pedido.total - montoPagado)}`, ticketWidth - margin, y, { align: 'right' })
    y += 4
  }

  // === DEUDA ANTERIOR ===
  // Va despues del total del pedido y antes de las notas: primero lo que se
  // entrega, despues lo que ademas hay que cobrar. El transportista necesita el
  // detalle, no solo el total: con el numero suelto no puede imputar el cobro.
  // Sale en las DOS copias, la del cliente incluida (decision explicita).
  const deuda = bloqueDeudaComanda(pedido.deuda_previa, pedido.deuda_previa_detalle)
  if (deuda) {
    y += 2
    drawDivider(doc, y, margin, ticketWidth - margin, 0.5)
    y += 5
    setHeaderStyle(doc, 11)
    doc.text('DEUDA ANTERIOR:', margin, y)
    doc.text(formatPrecio(deuda.total), ticketWidth - margin, y, { align: 'right' })
    y += 5
    setNormalStyle(doc, 9)
    deuda.lineas.forEach(linea => {
      doc.text(linea.etiqueta, margin + 3, y)
      doc.text(formatPrecio(linea.monto), ticketWidth - margin, y, { align: 'right' })
      y += 4
    })
  }

  // === NOTAS ===
  if (pedido.notas) {
    y += 2
    drawDivider(doc, y, margin, ticketWidth - margin, 0.2)
    y += 3
    setItalicStyle(doc, 9)
    const notasLines = doc.splitTextToSize(pedido.notas, contentWidth)
    notasLines.slice(0, 3).forEach((line: string) => {
      doc.text(line, margin, y)
      y += 3.5
    })
  }

  // === PIE ===
  y += 3
  drawDivider(doc, y, margin, ticketWidth - margin, 0.3)
  y += 4
  setItalicStyle(doc, 7)
  doc.text('Crecer Distribuciones', ticketWidth / 2, y, { align: 'center' })
  y += 3
  doc.text('DOCUMENTO NO VALIDO COMO FACTURA', ticketWidth / 2, y, { align: 'center' })
}

/**
 * Genera recibo en formato Comanda (75mm ticket) - pedido individual
 */
function generarReciboComanda(pedido: PedidoDB): void {
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
 */
export function generarComandasMultiples(pedidos: PedidoDB[]): void {
  if (!pedidos || pedidos.length === 0) return

  const { width: ticketWidth } = TICKET
  let isFirstPage = true
  let doc: jsPDF | null = null

  for (const pedido of pedidos) {
    const height = calcularAlturaComanda(pedido)

    // Cada pedido se imprime 2 veces (duplicado)
    for (let copia = 0; copia < 2; copia++) {
      if (isFirstPage) {
        doc = new jsPDF({ orientation: 'portrait', unit: 'mm', format: [ticketWidth, height] })
        isFirstPage = false
      } else {
        doc!.addPage([ticketWidth, height])
      }
      dibujarComanda(doc!, pedido)
    }
  }

  if (doc) {
    doc.autoPrint()
    window.open(doc.output('bloburl'), '_blank')
  }
}

/**
 * Genera PDF de Recibo de Pedido
 * @param pedido - Datos del pedido completo (con items y cliente)
 * @param _empresa - (deprecated) No se usa, branding hardcodeado
 * @param options.formato - Formato de salida (default: 'a4')
 * @returns Descarga el PDF
 */
export function generarReciboPedido(pedido: PedidoDB, _empresa: unknown = {}, options: { formato?: 'a4' | 'comanda' } = {}): void {
  const formato = options.formato || 'a4'
  if (formato === 'comanda') {
    generarReciboComanda(pedido)
  } else {
    generarReciboA4(pedido)
  }
}
