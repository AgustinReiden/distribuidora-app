/**
 * Utilidades de manejo de errores
 *
 * Proporciona clasificación y estrategias de recuperación para errores
 */

import type { ErrorCategory as ErrorCategoryType } from '@/types';

/**
 * Categorías de errores para recuperación inteligente
 */
export const ErrorCategory = {
  NETWORK: 'NETWORK',
  AUTH: 'AUTH',
  VALIDATION: 'VALIDATION',
  DATABASE: 'DATABASE',
  UNKNOWN: 'UNKNOWN'
} as const;

export interface RecoveryInfo {
  title: string;
  message: string;
  canRetry: boolean;
  retryDelay?: number;
  maxRetries?: number;
  action?: string;
  iconName: string;
}

interface ErrorWithStatus extends Error {
  status?: number;
}

/**
 * Clasifica un error en una categoría
 */
export function categorizeError(error: Error | ErrorWithStatus | null | undefined): ErrorCategoryType {
  if (!error) return ErrorCategory.UNKNOWN

  const message = error.message?.toLowerCase() || ''
  const name = error.name?.toLowerCase() || ''
  const status = (error as ErrorWithStatus).status

  // Errores de red
  if (
    message.includes('network') ||
    message.includes('fetch') ||
    message.includes('timeout') ||
    message.includes('connection') ||
    message.includes('offline') ||
    (name === 'typeerror' && message.includes('failed to fetch'))
  ) {
    return ErrorCategory.NETWORK
  }

  // Errores de autenticación
  if (
    message.includes('auth') ||
    message.includes('unauthorized') ||
    message.includes('forbidden') ||
    message.includes('session') ||
    message.includes('token') ||
    status === 401 ||
    status === 403
  ) {
    return ErrorCategory.AUTH
  }

  // Errores de validación
  if (
    message.includes('validation') ||
    message.includes('invalid') ||
    message.includes('required') ||
    name === 'validationerror' ||
    name === 'zoderror'
  ) {
    return ErrorCategory.VALIDATION
  }

  // Errores de base de datos
  if (
    message.includes('database') ||
    message.includes('supabase') ||
    message.includes('postgres') ||
    message.includes('constraint') ||
    message.includes('duplicate')
  ) {
    return ErrorCategory.DATABASE
  }

  return ErrorCategory.UNKNOWN
}

/**
 * Obtiene información de recuperación según la categoría
 */
export function getRecoveryInfo(category: ErrorCategoryType): RecoveryInfo {
  const info: Record<ErrorCategoryType, RecoveryInfo> = {
    NETWORK: {
      title: 'Error de conexión',
      message: 'No se pudo conectar al servidor. Verificá tu conexión a internet.',
      canRetry: true,
      retryDelay: 2000,
      maxRetries: 3,
      iconName: 'WifiOff'
    },
    AUTH: {
      title: 'Error de autenticación',
      message: 'Tu sesión expiró o no tenés permisos. Por favor, volvé a iniciar sesión.',
      canRetry: false,
      action: 'relogin',
      iconName: 'Lock'
    },
    VALIDATION: {
      title: 'Datos inválidos',
      message: 'Algunos datos ingresados no son válidos. Por favor, revisalos.',
      canRetry: false,
      iconName: 'AlertTriangle'
    },
    DATABASE: {
      title: 'Error de base de datos',
      message: 'Hubo un problema al guardar o cargar los datos.',
      canRetry: true,
      retryDelay: 1000,
      maxRetries: 2,
      iconName: 'Database'
    },
    UNKNOWN: {
      title: 'Error inesperado',
      message: 'Ha ocurrido un error inesperado. Por favor, intentá nuevamente.',
      canRetry: true,
      retryDelay: 1000,
      maxRetries: 1,
      iconName: 'Bug'
    }
  }

  return info[category] || info.UNKNOWN
}
