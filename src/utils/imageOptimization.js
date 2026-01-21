/**
 * Image Optimization Utilities
 *
 * Proporciona soporte para WebP con fallback automático,
 * lazy loading y optimización de imágenes.
 */

/**
 * Cache del resultado de soporte WebP
 * @type {boolean|null}
 */
let webpSupportCache = null

/**
 * Detecta si el navegador soporta WebP
 * @returns {Promise<boolean>}
 */
export async function supportsWebP() {
  if (webpSupportCache !== null) {
    return webpSupportCache
  }

  // Método rápido usando canvas
  if (typeof document !== 'undefined') {
    const canvas = document.createElement('canvas')
    if (canvas.getContext && canvas.getContext('2d')) {
      // WebP lossy support
      const result = canvas.toDataURL('image/webp').indexOf('data:image/webp') === 0
      webpSupportCache = result
      return result
    }
  }

  // Fallback: asumir que no soporta
  webpSupportCache = false
  return false
}

/**
 * Detecta soporte WebP de forma síncrona (puede no ser preciso en primer llamado)
 * @returns {boolean}
 */
export function supportsWebPSync() {
  if (webpSupportCache !== null) {
    return webpSupportCache
  }

  // Intentar detección rápida
  if (typeof document !== 'undefined') {
    const canvas = document.createElement('canvas')
    if (canvas.getContext && canvas.getContext('2d')) {
      webpSupportCache = canvas.toDataURL('image/webp').indexOf('data:image/webp') === 0
      return webpSupportCache
    }
  }

  return false
}

/**
 * Obtiene la URL optimizada de una imagen
 * Usa WebP si está soportado, de lo contrario usa la original
 *
 * @param {string} originalUrl - URL de la imagen original
 * @param {object} options - Opciones de optimización
 * @param {boolean} options.forceWebP - Forzar WebP si está disponible
 * @param {string} options.fallbackFormat - Formato de fallback ('jpg', 'png')
 * @returns {string} URL optimizada
 */
export function getOptimizedImageUrl(originalUrl, options = {}) {
  if (!originalUrl) return originalUrl

  const { forceWebP = true, fallbackFormat = null } = options

  // Si no queremos WebP o el navegador no lo soporta
  if (!forceWebP || !supportsWebPSync()) {
    // Devolver URL con formato de fallback si se especifica
    if (fallbackFormat && !originalUrl.endsWith(`.${fallbackFormat}`)) {
      return replaceExtension(originalUrl, fallbackFormat)
    }
    return originalUrl
  }

  // Convertir a WebP si es posible
  const webpUrl = replaceExtension(originalUrl, 'webp')
  return webpUrl
}

/**
 * Reemplaza la extensión de un archivo
 * @param {string} url - URL original
 * @param {string} newExtension - Nueva extensión
 * @returns {string}
 */
function replaceExtension(url, newExtension) {
  const lastDot = url.lastIndexOf('.')
  const queryStart = url.indexOf('?')

  if (lastDot === -1) {
    // No tiene extensión, agregar
    if (queryStart === -1) {
      return `${url}.${newExtension}`
    }
    return `${url.slice(0, queryStart)}.${newExtension}${url.slice(queryStart)}`
  }

  const extensionEnd = queryStart === -1 ? url.length : queryStart
  return `${url.slice(0, lastDot)}.${newExtension}${url.slice(extensionEnd)}`
}

/**
 * Genera un srcset para imágenes responsivas
 * @param {string} baseUrl - URL base de la imagen
 * @param {number[]} widths - Anchos deseados
 * @param {object} options - Opciones
 * @returns {string} srcset string
 */
export function generateSrcSet(baseUrl, widths = [320, 640, 1024, 1280], options = {}) {
  const { useWebP = supportsWebPSync() } = options

  return widths
    .map(width => {
      const url = getResizedImageUrl(baseUrl, width, useWebP)
      return `${url} ${width}w`
    })
    .join(', ')
}

/**
 * Obtiene la URL de una imagen redimensionada
 * (Asume un servicio de transformación de imágenes o CDN)
 *
 * @param {string} baseUrl - URL base
 * @param {number} width - Ancho deseado
 * @param {boolean} useWebP - Usar WebP
 * @returns {string}
 */
export function getResizedImageUrl(baseUrl, width, useWebP = true) {
  // Para Supabase Storage
  if (baseUrl.includes('supabase.co/storage')) {
    const separator = baseUrl.includes('?') ? '&' : '?'
    const format = useWebP ? 'webp' : 'origin'
    return `${baseUrl}${separator}width=${width}&format=${format}`
  }

  // Para URLs genéricas, solo aplicar formato
  if (useWebP) {
    return getOptimizedImageUrl(baseUrl, { forceWebP: true })
  }

  return baseUrl
}

/**
 * Precarga una imagen
 * @param {string} url - URL de la imagen
 * @returns {Promise<void>}
 */
export function preloadImage(url) {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve()
    img.onerror = reject
    img.src = url
  })
}

/**
 * Precarga múltiples imágenes
 * @param {string[]} urls - URLs de las imágenes
 * @returns {Promise<void[]>}
 */
export function preloadImages(urls) {
  return Promise.all(urls.map(preloadImage))
}

/**
 * Componente de imagen con lazy loading y WebP fallback
 * Uso: importar y usar como <OptimizedImage src="..." alt="..." />
 *
 * @typedef {object} OptimizedImageProps
 * @property {string} src - URL de la imagen
 * @property {string} alt - Texto alternativo
 * @property {string} [fallbackSrc] - URL de fallback si falla la carga
 * @property {string} [className] - Clases CSS
 * @property {boolean} [lazy] - Usar lazy loading (default: true)
 * @property {number[]} [widths] - Anchos para srcset
 */

/**
 * Props para imagen optimizada (para usar con componente React)
 * @param {OptimizedImageProps} props
 * @returns {object} Props para elemento img
 */
export function getOptimizedImageProps(props) {
  const {
    src,
    alt,
    fallbackSrc,
    lazy = true,
    widths = [320, 640, 1024],
    ...rest
  } = props

  const supportsWebp = supportsWebPSync()
  const optimizedSrc = getOptimizedImageUrl(src, { forceWebP: supportsWebp })

  return {
    src: optimizedSrc,
    alt,
    loading: lazy ? 'lazy' : 'eager',
    decoding: 'async',
    srcSet: widths ? generateSrcSet(src, widths) : undefined,
    sizes: widths ? '(max-width: 640px) 100vw, (max-width: 1024px) 50vw, 33vw' : undefined,
    onError: fallbackSrc ? (e) => { e.target.src = fallbackSrc } : undefined,
    ...rest
  }
}

/**
 * Genera estilos CSS para background image optimizada
 * @param {string} src - URL de la imagen
 * @param {object} options - Opciones
 * @returns {object} Objeto de estilos CSS
 */
export function getOptimizedBackgroundStyle(src, options = {}) {
  const { forceWebP = true } = options
  const supportsWebp = supportsWebPSync()

  const optimizedSrc = supportsWebp && forceWebP
    ? getOptimizedImageUrl(src, { forceWebP: true })
    : src

  return {
    backgroundImage: `url(${optimizedSrc})`,
    backgroundSize: 'cover',
    backgroundPosition: 'center'
  }
}

/**
 * Inicializa la detección de WebP de forma asíncrona
 * Llamar al inicio de la aplicación para precargar el resultado
 */
export async function initImageOptimization() {
  await supportsWebP()
  console.log(`[ImageOptimization] WebP support: ${webpSupportCache}`)
}

export default {
  supportsWebP,
  supportsWebPSync,
  getOptimizedImageUrl,
  generateSrcSet,
  preloadImage,
  preloadImages,
  getOptimizedImageProps,
  getOptimizedBackgroundStyle,
  initImageOptimization
}
