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
const DEFAULT_CONFIG: DOMPurify.Config = {
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
const TEXT_ONLY_CONFIG: DOMPurify.Config = {
  ALLOWED_TAGS: [],
  ALLOWED_ATTR: [],
  RETURN_DOM: false,
  RETURN_DOM_FRAGMENT: false
}

// Configuración para contenido rico (más etiquetas permitidas)
const RICH_CONFIG: DOMPurify.Config = {
  ALLOWED_TAGS: [
    'b', 'i', 'em', 'strong', 'u', 'br', 'p', 'span',
    'ul', 'ol', 'li', 'a', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
    'blockquote', 'code', 'pre'
  ],
  ALLOWED_ATTR: ['class', 'style', 'href', 'target', 'rel'],
  ADD_ATTR: ['target'], // Permitir target en links
  ALLOW_DATA_ATTR: false,
  RETURN_DOM: false,
  RETURN_DOM_FRAGMENT: false
}

// Helper to sanitize with explicit string return
const sanitizeToString = (dirty: string, config: DOMPurify.Config): string => {
  // DOMPurify.sanitize returns string when RETURN_DOM and RETURN_DOM_FRAGMENT are both false
  // Using type assertion to work around DOMPurify overload complexity
  const result = (DOMPurify as { sanitize: (dirty: string, config: DOMPurify.Config) => string }).sanitize(dirty, { ...config, RETURN_DOM: false, RETURN_DOM_FRAGMENT: false })
  return result
}

/**
 * Sanitiza HTML permitiendo solo etiquetas básicas
 */
export function sanitizeHTML(dirty: string | null | undefined): string {
  if (dirty == null) return ''
  return sanitizeToString(String(dirty), DEFAULT_CONFIG)
}

/**
 * Sanitiza texto removiendo todo HTML
 */
export function sanitizeText(dirty: string | null | undefined): string {
  if (dirty == null) return ''
  return sanitizeToString(String(dirty), TEXT_ONLY_CONFIG)
}

/**
 * Sanitiza contenido rico (para editores WYSIWYG)
 */
export function sanitizeRichContent(dirty: string | null | undefined): string {
  if (dirty == null) return ''
  return sanitizeToString(String(dirty), RICH_CONFIG)
}

/**
 * Sanitiza un valor para uso seguro en URLs
 */
export function sanitizeURLParam(value: string | null | undefined): string {
  if (value == null) return ''
  // Primero limpiar cualquier HTML, luego codificar
  const cleaned = sanitizeText(String(value))
  return encodeURIComponent(cleaned)
}

/**
 * Valida y sanitiza una URL completa
 */
export function sanitizeURL(url: string | null | undefined, allowedProtocols = ['http:', 'https:', 'mailto:']): string | null {
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

type SanitizedValue = string | number | boolean | null | undefined | SanitizedObject | SanitizedArray;
interface SanitizedObject { [key: string]: SanitizedValue }
type SanitizedArray = SanitizedValue[];

/**
 * Sanitiza un objeto, limpiando todos los valores string
 */
export function sanitizeObject<T extends Record<string, unknown>>(obj: T | null | undefined, excludeKeys: string[] = []): T {
  if (obj == null || typeof obj !== 'object') return obj as unknown as T

  const sanitized: Record<string, unknown> = Array.isArray(obj) ? ([] as unknown as Record<string, unknown>) : {}

  for (const [key, value] of Object.entries(obj)) {
    if (excludeKeys.includes(key)) {
      sanitized[key] = value
    } else if (typeof value === 'string') {
      sanitized[key] = sanitizeText(value)
    } else if (typeof value === 'object' && value !== null) {
      sanitized[key] = sanitizeObject(value as Record<string, unknown>, excludeKeys)
    } else {
      sanitized[key] = value
    }
  }

  return sanitized as T
}

export interface SanitizeFormDataOptions {
  htmlFields?: string[];
  richFields?: string[];
  skipFields?: string[];
}

/**
 * Sanitiza datos de formulario antes de enviar
 */
export function sanitizeFormData<T extends Record<string, unknown>>(formData: T | null | undefined, options: SanitizeFormDataOptions = {}): T {
  const { htmlFields = [], richFields = [], skipFields = [] } = options

  if (formData == null || typeof formData !== 'object') return formData as unknown as T

  const sanitized: Record<string, unknown> = {}

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

  return sanitized as T
}

/**
 * Hook para crear una versión sanitizada de un valor
 */
export function useSanitizedValue(value: string | null | undefined, type: 'text' | 'html' | 'rich' = 'text'): string {
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
 * Escapa caracteres especiales de PostgREST para uso seguro en filtros .or() / .ilike()
 *
 * Previene inyección PostgREST eliminando caracteres que forman parte de la
 * sintaxis de filtros (, . () []) y wildcards manuales (%).
 * Limita longitud a 100 caracteres para prevenir abuso.
 *
 * @example
 * // Input malicioso: "%a%,razon_social.ilike.%"
 * escapePostgrestFilter("%a%,razon_social.ilike.%") // "arazon_socialilike"
 */
export function escapePostgrestFilter(input: string | null | undefined): string {
  if (input == null || !input) return ''
  return String(input)
    .replace(/[,.()[\]]/g, '') // Eliminar sintaxis PostgREST
    .replace(/%/g, '')          // Eliminar wildcards manuales (ya agregamos % en el filtro)
    .trim()
    .slice(0, 100)              // Limitar longitud
}

/**
 * Escapa caracteres especiales para regex
 */
export function escapeRegex(string: string | null | undefined): string {
  if (string == null) return ''
  return String(string).replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
}

/**
 * Trunca texto de forma segura (sin cortar entidades HTML)
 */
export function truncateText(text: string | null | undefined, maxLength: number, suffix = '...'): string {
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
  escapePostgrestFilter,
  escapeRegex,
  truncateText
}
