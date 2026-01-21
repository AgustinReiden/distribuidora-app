/**
 * OptimizedImage - Componente de imagen optimizada con WebP y fallback
 *
 * Features:
 * - Detección automática de soporte WebP
 * - Lazy loading nativo
 * - Fallback en caso de error
 * - Placeholder durante carga
 * - srcset responsivo
 */
import { useState, useEffect, memo } from 'react'
import { supportsWebPSync, getOptimizedImageUrl, generateSrcSet } from '../../utils/imageOptimization'

/**
 * @param {object} props
 * @param {string} props.src - URL de la imagen
 * @param {string} props.alt - Texto alternativo (requerido para accesibilidad)
 * @param {string} [props.fallbackSrc] - URL de imagen de fallback
 * @param {string} [props.placeholderSrc] - URL de placeholder (blur, LQIP)
 * @param {boolean} [props.lazy=true] - Usar lazy loading
 * @param {number[]} [props.widths] - Anchos para srcset responsivo
 * @param {string} [props.sizes] - Atributo sizes para srcset
 * @param {string} [props.className] - Clases CSS
 * @param {Function} [props.onLoad] - Callback cuando carga
 * @param {Function} [props.onError] - Callback en error
 */
export const OptimizedImage = memo(function OptimizedImage({
  src,
  alt,
  fallbackSrc = '/placeholder-image.png',
  placeholderSrc,
  lazy = true,
  widths,
  sizes = '(max-width: 640px) 100vw, (max-width: 1024px) 50vw, 33vw',
  className = '',
  onLoad,
  onError,
  ...props
}) {
  const [currentSrc, setCurrentSrc] = useState(placeholderSrc || src)
  const [isLoaded, setIsLoaded] = useState(false)
  const [hasError, setHasError] = useState(false)

  // Obtener URL optimizada
  const supportsWebp = supportsWebPSync()
  const optimizedSrc = getOptimizedImageUrl(src, { forceWebP: supportsWebp })

  // Generar srcset si se especifican widths
  const srcSet = widths ? generateSrcSet(src, widths) : undefined

  useEffect(() => {
    // Si hay placeholder, cargar la imagen real
    if (placeholderSrc && src) {
      const img = new Image()
      img.onload = () => {
        setCurrentSrc(optimizedSrc)
        setIsLoaded(true)
      }
      img.onerror = () => {
        setCurrentSrc(fallbackSrc)
        setHasError(true)
      }
      img.src = optimizedSrc
    }
  }, [src, optimizedSrc, placeholderSrc, fallbackSrc])

  const handleLoad = (e) => {
    setIsLoaded(true)
    onLoad?.(e)
  }

  const handleError = (e) => {
    if (!hasError) {
      setHasError(true)
      setCurrentSrc(fallbackSrc)
      onError?.(e)
    }
  }

  return (
    <img
      src={placeholderSrc ? currentSrc : optimizedSrc}
      alt={alt}
      loading={lazy ? 'lazy' : 'eager'}
      decoding="async"
      srcSet={!hasError ? srcSet : undefined}
      sizes={srcSet ? sizes : undefined}
      onLoad={handleLoad}
      onError={handleError}
      className={`
        ${className}
        ${!isLoaded && placeholderSrc ? 'blur-sm scale-105' : ''}
        transition-all duration-300
      `}
      {...props}
    />
  )
})

/**
 * Picture element con soporte WebP y fallback
 * Proporciona mejor compatibilidad con navegadores antiguos
 */
export const OptimizedPicture = memo(function OptimizedPicture({
  src,
  alt,
  fallbackSrc,
  className = '',
  imgClassName = '',
  lazy = true,
  widths,
  sizes = '(max-width: 640px) 100vw, (max-width: 1024px) 50vw, 33vw',
  ...props
}) {
  const [hasError, setHasError] = useState(false)

  // Generar URLs para diferentes formatos
  const webpSrc = getOptimizedImageUrl(src, { forceWebP: true })
  const originalSrc = src

  const handleError = () => {
    setHasError(true)
  }

  if (hasError && fallbackSrc) {
    return (
      <img
        src={fallbackSrc}
        alt={alt}
        loading={lazy ? 'lazy' : 'eager'}
        className={imgClassName}
        {...props}
      />
    )
  }

  return (
    <picture className={className}>
      {/* WebP source para navegadores modernos */}
      <source
        type="image/webp"
        srcSet={widths ? generateSrcSet(src, widths, { useWebP: true }) : webpSrc}
        sizes={sizes}
      />

      {/* Fallback para navegadores sin WebP */}
      <source
        type="image/jpeg"
        srcSet={widths ? generateSrcSet(src, widths, { useWebP: false }) : originalSrc}
        sizes={sizes}
      />

      {/* Imagen de fallback */}
      <img
        src={originalSrc}
        alt={alt}
        loading={lazy ? 'lazy' : 'eager'}
        decoding="async"
        onError={handleError}
        className={imgClassName}
        {...props}
      />
    </picture>
  )
})

export default OptimizedImage
