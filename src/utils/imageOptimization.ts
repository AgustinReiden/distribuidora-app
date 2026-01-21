/**
 * Image Optimization Utilities
 *
 * Proporciona soporte para WebP con fallback automático,
 * lazy loading y optimización de imágenes.
 */

/**
 * Cache del resultado de soporte WebP
 */
let webpSupportCache: boolean | null = null

/**
 * Detecta si el navegador soporta WebP
 */
export async function supportsWebP(): Promise<boolean> {
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
 */
export function supportsWebPSync(): boolean {
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

export interface OptimizeImageOptions {
  forceWebP?: boolean;
  fallbackFormat?: string | null;
}

/**
 * Reemplaza la extensión de un archivo
 */
function replaceExtension(url: string, newExtension: string): string {
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
 * Obtiene la URL optimizada de una imagen
 * Usa WebP si está soportado, de lo contrario usa la original
 */
export function getOptimizedImageUrl(originalUrl: string | null | undefined, options: OptimizeImageOptions = {}): string {
  if (!originalUrl) return originalUrl || ''

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

export interface SrcSetOptions {
  useWebP?: boolean;
}

/**
 * Obtiene la URL de una imagen redimensionada
 * (Asume un servicio de transformación de imágenes o CDN)
 */
export function getResizedImageUrl(baseUrl: string, width: number, useWebP = true): string {
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
 * Genera un srcset para imágenes responsivas
 */
export function generateSrcSet(baseUrl: string, widths: number[] = [320, 640, 1024, 1280], options: SrcSetOptions = {}): string {
  const { useWebP = supportsWebPSync() } = options

  return widths
    .map(width => {
      const url = getResizedImageUrl(baseUrl, width, useWebP)
      return `${url} ${width}w`
    })
    .join(', ')
}

/**
 * Precarga una imagen
 */
export function preloadImage(url: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve()
    img.onerror = reject
    img.src = url
  })
}

/**
 * Precarga múltiples imágenes
 */
export function preloadImages(urls: string[]): Promise<void[]> {
  return Promise.all(urls.map(preloadImage))
}

export interface OptimizedImageProps {
  src: string;
  alt: string;
  fallbackSrc?: string;
  className?: string;
  lazy?: boolean;
  widths?: number[];
  [key: string]: unknown;
}

export interface OptimizedImageResult {
  src: string;
  alt: string;
  loading: 'lazy' | 'eager';
  decoding: 'async' | 'sync' | 'auto';
  srcSet?: string;
  sizes?: string;
  onError?: (e: React.SyntheticEvent<HTMLImageElement>) => void;
  [key: string]: unknown;
}

/**
 * Props para imagen optimizada (para usar con componente React)
 */
export function getOptimizedImageProps(props: OptimizedImageProps): OptimizedImageResult {
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
    onError: fallbackSrc ? (e: React.SyntheticEvent<HTMLImageElement>) => { (e.target as HTMLImageElement).src = fallbackSrc } : undefined,
    ...rest
  }
}

export interface BackgroundStyleOptions {
  forceWebP?: boolean;
}

/**
 * Genera estilos CSS para background image optimizada
 */
export function getOptimizedBackgroundStyle(src: string, options: BackgroundStyleOptions = {}): React.CSSProperties {
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
export async function initImageOptimization(): Promise<void> {
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
