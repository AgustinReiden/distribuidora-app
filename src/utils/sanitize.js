/**
 * Utilidades de sanitización para prevención de XSS
 *
 * Usa DOMPurify para sanitizar contenido HTML y texto de usuario.
 * React ya escapa automáticamente los valores en JSX, pero estas
 * utilidades son útiles para:
 * - Contenido que se renderiza con dangerouslySetInnerHTML
 * - Valores que se usan en URLs o atributos
 * - Datos antes de guardarlos en la base de datos
 */
import DOMPurify from 'dompurify'

// Configuración por defecto de DOMPurify
const DEFAULT_CONFIG = {
  // Permitir solo etiquetas de texto básicas
  ALLOWED_TAGS: ['b', 'i', 'em', 'strong', 'u', 'br', 'p', 'span'],
  // Permitir solo atributos de estilo básicos
  ALLOWED_ATTR: ['class', 'style'],
  // No permitir URLs en atributos
  ALLOW_DATA_ATTR: false,
  // Retornar string vacío si el input es null/undefined
  RETURN_DOM: false,
  RETURN_DOM_FRAGMENT: false
}

// Configuración para texto plano (sin HTML)
const TEXT_ONLY_CONFIG = {
  ALLOWED_TAGS: [],
  ALLOWED_ATTR: []
}

// Configuración para contenido rico (más etiquetas permitidas)
const RICH_CONFIG = {
  ALLOWED_TAGS: [
    'b', 'i', 'em', 'strong', 'u', 'br', 'p', 'span',
    'ul', 'ol', 'li', 'a', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'blockquote', 'code', 'pre'
  ],
  ALLOWED_ATTR: ['class', 'style', 'href', 'target', 'rel'],
  ADD_ATTR: ['target'], // Permitir target en links
  ALLOW_DATA_ATTR: false
}

/**
 * Sanitiza HTML permitiendo solo etiquetas básicas
 * @param {string} dirty - HTML potencialmente peligroso
 * @returns {string} HTML sanitizado
 */
export function sanitizeHTML(dirty) {
  if (dirty == null) return ''
  return DOMPurify.sanitize(String(dirty), DEFAULT_CONFIG)
}

/**
 * Sanitiza texto removiendo todo HTML
 * @param {string} dirty - Texto con posible HTML
 * @returns {string} Texto plano sin HTML
 */
export function sanitizeText(dirty) {
  if (dirty == null) return ''
  return DOMPurify.sanitize(String(dirty), TEXT_ONLY_CONFIG)
}

/**
 * Sanitiza contenido rico (para editores WYSIWYG)
 * @param {string} dirty - HTML rico potencialmente peligroso
 * @returns {string} HTML sanitizado con etiquetas permitidas
 */
export function sanitizeRichContent(dirty) {
  if (dirty == null) return ''
  return DOMPurify.sanitize(String(dirty), RICH_CONFIG)
}

/**
 * Sanitiza un valor para uso seguro en URLs
 * @param {string} value - Valor a usar en URL
 * @returns {string} Valor codificado para URL
 */
export function sanitizeURLParam(value) {
  if (value == null) return ''
  // Primero limpiar cualquier HTML, luego codificar
  const cleaned = sanitizeText(String(value))
  return encodeURIComponent(cleaned)
}

/**
 * Valida y sanitiza una URL completa
 * @param {string} url - URL a validar
 * @param {string[]} allowedProtocols - Protocolos permitidos
 * @returns {string|null} URL sanitizada o null si es inválida
 */
export function sanitizeURL(url, allowedProtocols = ['http:', 'https:', 'mailto:']) {
  if (url == null || url === '') return null

  try {
    const parsed = new URL(String(url))
    if (!allowedProtocols.includes(parsed.protocol)) {
      return null
    }
    return parsed.href
  } catch {
    // Si no es una URL válida, podría ser una ruta relativa
    const cleaned = sanitizeText(String(url))
    // Solo permitir rutas relativas que empiecen con /
    if (cleaned.startsWith('/') && !cleaned.includes('//')) {
      return cleaned
    }
    return null
  }
}

/**
 * Sanitiza un objeto, limpiando todos los valores string
 * @param {object} obj - Objeto a sanitizar
 * @param {string[]} excludeKeys - Keys a excluir de la sanitización
 * @returns {object} Objeto con valores sanitizados
 */
export function sanitizeObject(obj, excludeKeys = []) {
  if (obj == null || typeof obj !== 'object') return obj

  const sanitized = Array.isArray(obj) ? [] : {}

  for (const [key, value] of Object.entries(obj)) {
    if (excludeKeys.includes(key)) {
      sanitized[key] = value
    } else if (typeof value === 'string') {
      sanitized[key] = sanitizeText(value)
    } else if (typeof value === 'object' && value !== null) {
      sanitized[key] = sanitizeObject(value, excludeKeys)
    } else {
      sanitized[key] = value
    }
  }

  return sanitized
}

/**
 * Sanitiza datos de formulario antes de enviar
 * @param {object} formData - Datos del formulario
 * @param {object} options - Opciones de sanitización
 * @param {string[]} options.htmlFields - Campos que permiten HTML básico
 * @param {string[]} options.richFields - Campos que permiten HTML rico
 * @param {string[]} options.skipFields - Campos a no sanitizar (ej: passwords)
 * @returns {object} Datos sanitizados
 */
export function sanitizeFormData(formData, options = {}) {
  const { htmlFields = [], richFields = [], skipFields = [] } = options

  if (formData == null || typeof formData !== 'object') return formData

  const sanitized = {}

  for (const [key, value] of Object.entries(formData)) {
    if (skipFields.includes(key)) {
      // No sanitizar campos como passwords
      sanitized[key] = value
    } else if (typeof value !== 'string') {
      // Valores no-string pasan sin cambios
      sanitized[key] = value
    } else if (richFields.includes(key)) {
      sanitized[key] = sanitizeRichContent(value)
    } else if (htmlFields.includes(key)) {
      sanitized[key] = sanitizeHTML(value)
    } else {
      // Por defecto, texto plano
      sanitized[key] = sanitizeText(value)
    }
  }

  return sanitized
}

/**
 * Hook para crear una versión sanitizada de un valor
 * @param {string} value - Valor a sanitizar
 * @param {'text'|'html'|'rich'} type - Tipo de sanitización
 * @returns {string} Valor sanitizado
 */
export function useSanitizedValue(value, type = 'text') {
  switch (type) {
    case 'html':
      return sanitizeHTML(value)
    case 'rich':
      return sanitizeRichContent(value)
    default:
      return sanitizeText(value)
  }
}

/**
 * Escapa caracteres especiales para regex
 * @param {string} string - String a escapar
 * @returns {string} String con caracteres regex escapados
 */
export function escapeRegex(string) {
  if (string == null) return ''
  return String(string).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * Trunca texto de forma segura (sin cortar entidades HTML)
 * @param {string} text - Texto a truncar
 * @param {number} maxLength - Longitud máxima
 * @param {string} suffix - Sufijo a agregar si se trunca
 * @returns {string} Texto truncado
 */
export function truncateText(text, maxLength, suffix = '...') {
  if (text == null) return ''
  const cleaned = sanitizeText(String(text))
  if (cleaned.length <= maxLength) return cleaned
  return cleaned.slice(0, maxLength - suffix.length) + suffix
}

export default {
  sanitizeHTML,
  sanitizeText,
  sanitizeRichContent,
  sanitizeURL,
  sanitizeURLParam,
  sanitizeObject,
  sanitizeFormData,
  escapeRegex,
  truncateText
}
