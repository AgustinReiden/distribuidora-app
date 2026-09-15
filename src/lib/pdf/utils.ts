/**
 * Utilidades compartidas para generación de PDFs
 */
import type { jsPDF } from 'jspdf'
import { parseDateSafe } from '../../utils/formatters'

const AR_TZ = 'America/Argentina/Buenos_Aires'

/**
 * Formatea un precio en formato de moneda argentina
 */
export const formatPrecio = (p: number | null | undefined): string =>
  new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(p || 0)

/**
 * Formatea una fecha en formato DD/MM/YYYY
 */
export const formatFecha = (fecha: Date | string | null | undefined): string =>
  parseDateSafe(fecha || new Date()).toLocaleDateString('es-AR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    timeZone: AR_TZ
  })

/**
 * Formatea fecha y hora
 */
export const formatFechaHora = (fecha: Date | string | null | undefined): string => {
  // Date-only ('YYYY-MM-DD', ej. pedidos.fecha) no tiene hora real que mostrar:
  // parseDateSafe le clava T12:00:00 para evitar el corrimiento de dia UTC, y
  // mostrar esa hora inventada como si fuera la hora real es el bug.
  const esDateOnly = typeof fecha === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(fecha)
  return parseDateSafe(fecha || new Date()).toLocaleString('es-AR', {
    day: '2-digit',
    month: '2-digit',
    year: 'numeric',
    timeZone: AR_TZ,
    ...(esDateOnly ? {} : { hour: '2-digit', minute: '2-digit' })
  })
}

/**
 * Trunca un texto a una longitud máxima
 */
export const truncate = (text: string | null | undefined, maxLength: number, suffix = '..'): string => {
  if (!text) return ''
  return text.length > maxLength ? text.substring(0, maxLength - suffix.length) + suffix : text
}

/**
 * Genera un nombre de archivo seguro para el PDF
 */
export const generateFilename = (prefix: string, name = '', fecha: Date | string = new Date()): string => {
  const fechaStr = formatFecha(fecha).replace(/\//g, '-')
  const safeName = name ? `-${name.replace(/\s+/g, '-').toLowerCase().substring(0, 20)}` : ''
  return `${prefix}${safeName}-${fechaStr}.pdf`
}

/**
 * Dibuja una línea divisora horizontal
 */
export const drawDivider = (doc: jsPDF, y: number, startX: number, endX: number, lineWidth = 0.3): void => {
  doc.setLineWidth(lineWidth)
  doc.line(startX, y, endX, y)
}

/**
 * Dibuja un checkbox vacío
 */
export const drawCheckbox = (doc: jsPDF, x: number, y: number, size = 2.5): void => {
  doc.rect(x, y, size, size)
}

/**
 * Configura el estilo de texto para encabezados
 */
export const setHeaderStyle = (doc: jsPDF, size = 12): void => {
  doc.setFontSize(size)
  doc.setFont('helvetica', 'bold')
  doc.setTextColor(0, 0, 0)
}

/**
 * Configura el estilo de texto normal
 */
export const setNormalStyle = (doc: jsPDF, size = 9): void => {
  doc.setFontSize(size)
  doc.setFont('helvetica', 'normal')
  doc.setTextColor(0, 0, 0)
}

/**
 * Configura el estilo de texto itálico
 */
export const setItalicStyle = (doc: jsPDF, size = 7): void => {
  doc.setFontSize(size)
  doc.setFont('helvetica', 'italic')
}

/**
 * Aplica color de relleno desde array RGB
 */
export const setFillColor = (doc: jsPDF, color: readonly number[]): void => {
  doc.setFillColor(color[0], color[1], color[2])
}

/**
 * Aplica color de texto desde array RGB
 */
export const setTextColor = (doc: jsPDF, color: readonly number[]): void => {
  doc.setTextColor(color[0], color[1], color[2])
}

/**
 * Aplica color de trazo desde array RGB
 */
export const setDrawColor = (doc: jsPDF, color: readonly number[]): void => {
  doc.setDrawColor(color[0], color[1], color[2])
}
