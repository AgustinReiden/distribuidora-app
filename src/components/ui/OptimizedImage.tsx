/**
 * OptimizedImage - Componente de imagen optimizada con WebP y fallback
 *
 * Features:
 * - Deteccion automatica de soporte WebP
 * - Lazy loading nativo
 * - Fallback en caso de error
 * - Placeholder durante carga
 * - srcset responsivo
 */
import React, { useState, useEffect, memo, SyntheticEvent, ImgHTMLAttributes } from 'react'
import { supportsWebPSync, getOptimizedImageUrl, generateSrcSet } from '../../utils/imageOptimization'

// =============================================================================
// PROPS INTERFACES
// =============================================================================

export interface OptimizedImageProps extends Omit<ImgHTMLAttributes<HTMLImageElement>, 'onLoad' | 'onError'> {
  /** URL de la imagen */
  src: string;
  /** Texto alternativo (requerido para accesibilidad) */
  alt: string;
  /** URL de imagen de fallback */
  fallbackSrc?: string;
  /** URL de placeholder (blur, LQIP) */
  placeholderSrc?: string;
  /** Usar lazy loading */
  lazy?: boolean;
  /** Anchos para srcset responsivo */
  widths?: number[];
  /** Atributo sizes para srcset */
  sizes?: string;
  /** Clases CSS */
  className?: string;
  /** Callback cuando carga */
  onLoad?: (e: SyntheticEvent<HTMLImageElement>) => void;
  /** Callback en error */
  onError?: (e: SyntheticEvent<HTMLImageElement>) => void;
}

export interface OptimizedPictureProps extends Omit<ImgHTMLAttributes<HTMLImageElement>, 'onLoad' | 'onError'> {
  /** URL de la imagen */
  src: string;
  /** Texto alternativo (requerido para accesibilidad) */
  alt: string;
  /** URL de imagen de fallback */
  fallbackSrc?: string;
  /** Clases CSS del contenedor picture */
  className?: string;
  /** Clases CSS de la imagen */
  imgClassName?: string;
  /** Usar lazy loading */
  lazy?: boolean;
  /** Anchos para srcset responsivo */
  widths?: number[];
  /** Atributo sizes para srcset */
  sizes?: string;
}

// =============================================================================
// COMPONENTS
// =============================================================================

/**
 * Componente de imagen optimizada con WebP y fallback
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
}: OptimizedImageProps): React.ReactElement {
  const [currentSrc, setCurrentSrc] = useState<string>(placeholderSrc || src)
  const [isLoaded, setIsLoaded] = useState<boolean>(false)
  const [hasError, setHasError] = useState<boolean>(false)

  // Obtener URL optimizada
  const supportsWebp = supportsWebPSync()
  const optimizedSrc = getOptimizedImageUrl(src, { forceWebP: supportsWebp })

  // Generar srcset si se especifican widths
  const srcSet = widths ? generateSrcSet(src, widths) : undefined

  useEffect(() => {
    // Si hay placeholder, cargar la imagen real
    if (placeholderSrc && src) {
      const img = new Image()
      img.onload = (): void => {
        setCurrentSrc(optimizedSrc)
        setIsLoaded(true)
      }
      img.onerror = (): void => {
        setCurrentSrc(fallbackSrc)
        setHasError(true)
      }
      img.src = optimizedSrc
    }
  }, [src, optimizedSrc, placeholderSrc, fallbackSrc])

  const handleLoad = (e: SyntheticEvent<HTMLImageElement>): void => {
    setIsLoaded(true)
    onLoad?.(e)
  }

  const handleError = (e: SyntheticEvent<HTMLImageElement>): void => {
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
}: OptimizedPictureProps): React.ReactElement {
  const [hasError, setHasError] = useState<boolean>(false)

  // Generar URLs para diferentes formatos
  const webpSrc = getOptimizedImageUrl(src, { forceWebP: true })
  const originalSrc = src

  const handleError = (): void => {
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
