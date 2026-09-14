/**
 * Genera PDF de Orden de Preparación para el depósito
 * Formato: Ticket comandera de 75mm de ancho
 */
import { jsPDF } from 'jspdf'
import { TICKET } from './constants'
import { lineaItemImpresion } from './utils/lineaItem'
import {
  formatFecha,
  truncate,
  generateFilename,
  drawDivider,
  drawCheckbox,
  setHeaderStyle,
  setNormalStyle,
  setItalicStyle
} from './utils'

// Ancho util del ticket para los productos, en caracteres, a font 8. Se usa
// solo para ESTIMAR el alto: el corte real lo hace splitTextToSize al dibujar.
// Va corto a proposito (el ancho real entra ~44) para que la estimacion sobre y
// no se dibuje fuera del papel, que es alto de pagina y no se imprime nunca.
const CHARS_POR_LINEA = 38

/** Lineas de producto de un pedido, en el mismo orden en que se dibujan. */
function lineasProducto(pedido) {
  return (pedido.items || []).map(item => lineaItemImpresion(item))
}

/**
 * Calcula la altura necesaria para el documento
 * @param {Array} pedidos - Lista de pedidos
 * @returns {number} Altura calculada en mm
 */
function calcularAltura(pedidos) {
  let totalHeight = 25 // Encabezado inicial
  pedidos.forEach(pedido => {
    totalHeight += 18 // Cabecera del pedido (cliente + direccion + telefono)
    if (pedido.cliente?.horarios_atencion) totalHeight += 3 // Horario
    // Productos: un regalo de fraccion aclara la unidad y envuelve a 2-3 lineas.
    totalHeight += lineasProducto(pedido)
      .reduce((sum, linea) => sum + Math.max(Math.ceil(linea.length / CHARS_POR_LINEA), 1) * 4, 0)
    if (pedido.notas) totalHeight += 8
    totalHeight += 5 // Separador
  })
  totalHeight += 10 // Margen inferior
  return Math.max(totalHeight, 50)
}

/**
 * Genera PDF de Orden de Preparación
 * @param {Array} pedidos - Lista de pedidos a incluir
 * @returns {void} - Descarga el PDF
 */
export function generarOrdenPreparacion(pedidos) {
  const { width: ticketWidth, margin } = TICKET

  const doc = new jsPDF({
    orientation: 'portrait',
    unit: 'mm',
    format: [ticketWidth, calcularAltura(pedidos)]
  })

  let y = margin

  // Título principal
  setHeaderStyle(doc, 12)
  doc.text('ORDEN DE PREPARACION', ticketWidth / 2, y + 4, { align: 'center' })
  y += 7

  setNormalStyle(doc, 8)
  doc.text(formatFecha(new Date()), ticketWidth / 2, y, { align: 'center' })
  y += 4

  doc.setFontSize(7)
  doc.text(`Total: ${pedidos.length} pedido(s)`, ticketWidth / 2, y, { align: 'center' })
  y += 5

  // Línea divisora
  drawDivider(doc, y, margin, ticketWidth - margin, 0.3)
  y += 4

  // Iterar sobre cada pedido
  pedidos.forEach((pedido) => {
    // Cabecera del pedido
    doc.setFontSize(9)
    doc.setFont('helvetica', 'bold')
    doc.text(`#${pedido.id}`, margin, y)

    const clienteNombre = pedido.cliente?.nombre_fantasia || 'Sin cliente'
    doc.text(truncate(clienteNombre, 20), margin + 10, y)
    y += 4

    // Dirección
    setNormalStyle(doc, 7)
    const direccion = pedido.cliente?.direccion || 'Sin direccion'
    doc.text(truncate(direccion, 35), margin, y)
    y += 3

    // Teléfono
    if (pedido.cliente?.telefono) {
      doc.text(`Tel: ${pedido.cliente.telefono}`, margin, y)
      y += 3
    }

    // Horario de atencion
    if (pedido.cliente?.horarios_atencion) {
      doc.text(`Hor: ${truncate(pedido.cliente.horarios_atencion, 35)}`, margin, y)
      y += 3
    }

    // Notas
    if (pedido.notas) {
      setItalicStyle(doc, 6)
      doc.text(`* ${truncate(pedido.notas, 40)}`, margin, y)
      y += 3
    }

    y += 2

    // Lista de productos. La linea la arma lineaItemImpresion: marca el regalo,
    // usa la descripcion de la promo y aclara la unidad (fardos vs sueltas) con
    // el factor congelado del item. Sin eso el deposito prepara un regalo de
    // 392 botellas como 392 unidades de venta.
    setNormalStyle(doc, 8)
    lineasProducto(pedido).forEach((linea) => {
      drawCheckbox(doc, margin, y - 2.5)
      doc.splitTextToSize(linea, ticketWidth - margin * 2 - 4).forEach((line) => {
        doc.text(line, margin + 4, y)
        y += 4
      })
    })

    y += 2

    // Línea divisora entre pedidos
    doc.setLineWidth(0.2)
    doc.setDrawColor(150)
    doc.line(margin, y, ticketWidth - margin, y)
    doc.setDrawColor(0)
    y += 3
  })

  // Descargar PDF
  doc.save(generateFilename('orden-preparacion'))
}
