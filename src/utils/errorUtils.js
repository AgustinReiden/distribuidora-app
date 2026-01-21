/**
 * Utilidades de manejo de errores
 *
 * Proporciona clasificación y estrategias de recuperación para errores
 */

/**
 * Categorías de errores para recuperación inteligente
 */
export const ErrorCategory = {
  NETWORK: 'network',
  AUTH: 'auth',
  VALIDATION: 'validation',
  DATABASE: 'database',
  UNKNOWN: 'unknown'
}

/**
 * Clasifica un error en una categoría
 * @param {Error} error
 * @returns {string} Categoría del error
 */
export function categorizeError(error) {
  if (!error) return ErrorCategory.UNKNOWN

  const message = error.message?.toLowerCase() || ''
  const name = error.name?.toLowerCase() || ''

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
    error.status === 401 ||
    error.status === 403
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
 * @param {string} category
 * @returns {Object}
 */
export function getRecoveryInfo(category) {
  const info = {
    [ErrorCategory.NETWORK]: {
      title: 'Error de conexión',
      message: 'No se pudo conectar al servidor. Verificá tu conexión a internet.',
      canRetry: true,
      retryDelay: 2000,
      maxRetries: 3,
      iconName: 'WifiOff'
    },
    [ErrorCategory.AUTH]: {
      title: 'Error de autenticación',
      message: 'Tu sesión expiró o no tenés permisos. Por favor, volvé a iniciar sesión.',
      canRetry: false,
      action: 'relogin',
      iconName: 'Lock'
    },
    [ErrorCategory.VALIDATION]: {
      title: 'Datos inválidos',
      message: 'Algunos datos ingresados no son válidos. Por favor, revisalos.',
      canRetry: false,
      iconName: 'AlertTriangle'
    },
    [ErrorCategory.DATABASE]: {
      title: 'Error de base de datos',
      message: 'Hubo un problema al guardar o cargar los datos.',
      canRetry: true,
      retryDelay: 1000,
      maxRetries: 2,
      iconName: 'Database'
    },
    [ErrorCategory.UNKNOWN]: {
      title: 'Error inesperado',
      message: 'Ha ocurrido un error inesperado. Por favor, intentá nuevamente.',
      canRetry: true,
      retryDelay: 1000,
      maxRetries: 1,
      iconName: 'Bug'
    }
  }

  return info[category] || info[ErrorCategory.UNKNOWN]
}
