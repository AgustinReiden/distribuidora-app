/**
 * Utilidades compartidas para generación de PDFs
 */

/**
 * Formatea un precio en formato de moneda argentina
 * @param {number} p - Precio a formatear
 * @returns {string} Precio formateado
 */
export const formatPrecio = (p) =>
  new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(p || 0)

/**
 * Formatea una fecha en formato DD/MM/YYYY
 * @param {Date|string} fecha - Fecha a formatear
 * @returns {string} Fecha formateada
 */
export const formatFecha = (fecha) =>
  new Date(fecha || new Date()).toLocaleDateString('es-AR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric'
  })

/**
 * Formatea fecha y hora
 * @param {Date|string} fecha - Fecha a formatear
 * @returns {string} Fecha y hora formateadas
 */
export const formatFechaHora = (fecha) =>
  new Date(fecha || new Date()).toLocaleString('es-AR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    hour: '2-digit',
    minute: '2-digit'
  })

/**
 * Trunca un texto a una longitud máxima
 * @param {string} text - Texto a truncar
 * @param {number} maxLength - Longitud máxima
 * @param {string} suffix - Sufijo para texto truncado
 * @returns {string} Texto truncado
 */
export const truncate = (text, maxLength, suffix = '..') => {
  if (!text) return ''
  return text.length > maxLength ? text.substring(0, maxLength - suffix.length) + suffix : text
}

/**
 * Genera un nombre de archivo seguro para el PDF
 * @param {string} prefix - Prefijo del archivo
 * @param {string} name - Nombre opcional
 * @returns {string} Nombre de archivo
 */
export const generateFilename = (prefix, name = '') => {
  const fecha = formatFecha(new Date()).replace(/\//g, '-')
  const safeName = name ? `-${name.replace(/\s+/g, '-').toLowerCase().substring(0, 20)}` : ''
  return `${prefix}${safeName}-${fecha}.pdf`
}

/**
 * Dibuja una línea divisora horizontal
 * @param {jsPDF} doc - Instancia de jsPDF
 * @param {number} y - Posición Y
 * @param {number} startX - Posición X inicial
 * @param {number} endX - Posición X final
 * @param {number} lineWidth - Grosor de línea
 */
export const drawDivider = (doc, y, startX, endX, lineWidth = 0.3) => {
  doc.setLineWidth(lineWidth)
  doc.line(startX, y, endX, y)
}

/**
 * Dibuja un checkbox vacío
 * @param {jsPDF} doc - Instancia de jsPDF
 * @param {number} x - Posición X
 * @param {number} y - Posición Y
 * @param {number} size - Tamaño del checkbox
 */
export const drawCheckbox = (doc, x, y, size = 2.5) => {
  doc.rect(x, y, size, size)
}

/**
 * Configura el estilo de texto para encabezados
 * @param {jsPDF} doc - Instancia de jsPDF
 * @param {number} size - Tamaño de fuente
 */
export const setHeaderStyle = (doc, size = 12) => {
  doc.setFontSize(size)
  doc.setFont('helvetica', 'bold')
  doc.setTextColor(0, 0, 0)
}

/**
 * Configura el estilo de texto normal
 * @param {jsPDF} doc - Instancia de jsPDF
 * @param {number} size - Tamaño de fuente
 */
export const setNormalStyle = (doc, size = 9) => {
  doc.setFontSize(size)
  doc.setFont('helvetica', 'normal')
  doc.setTextColor(0, 0, 0)
}

/**
 * Configura el estilo de texto itálico
 * @param {jsPDF} doc - Instancia de jsPDF
 * @param {number} size - Tamaño de fuente
 */
export const setItalicStyle = (doc, size = 7) => {
  doc.setFontSize(size)
  doc.setFont('helvetica', 'italic')
}

/**
 * Aplica color de relleno desde array RGB
 * @param {jsPDF} doc - Instancia de jsPDF
 * @param {number[]} color - Color RGB [r, g, b]
 */
export const setFillColor = (doc, color) => {
  doc.setFillColor(color[0], color[1], color[2])
}

/**
 * Aplica color de texto desde array RGB
 * @param {jsPDF} doc - Instancia de jsPDF
 * @param {number[]} color - Color RGB [r, g, b]
 */
export const setTextColor = (doc, color) => {
  doc.setTextColor(color[0], color[1], color[2])
}

/**
 * Aplica color de trazo desde array RGB
 * @param {jsPDF} doc - Instancia de jsPDF
 * @param {number[]} color - Color RGB [r, g, b]
 */
export const setDrawColor = (doc, color) => {
  doc.setDrawColor(color[0], color[1], color[2])
}
