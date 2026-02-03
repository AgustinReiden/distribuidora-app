/**
 * Utilidades centralizadas para manejo de errores
 *
 * Proporciona funciones consistentes para:
 * - Extraer mensajes de error
 * - Notificar errores al usuario
 * - Ejecutar operaciones asíncronas con manejo de errores
 */

import type { NotifyService } from '../hooks/handlers/types';
import { logger } from './logger';

// ============================================
// TIPOS
// ============================================

export interface ErrorHandlingOptions {
  /** Mensaje a mostrar en caso de error */
  errorMessage?: string;
  /** Si debe notificar al usuario */
  notify?: boolean;
  /** Si debe hacer console.error */
  log?: boolean;
  /** Servicio de notificaciones */
  notifyService?: NotifyService;
}

export interface AsyncOperationOptions<T> extends ErrorHandlingOptions {
  /** Callback de éxito */
  onSuccess?: (result: T) => void;
  /** Callback de error */
  onError?: (error: Error) => void;
  /** Callback que siempre se ejecuta (finally) */
  onFinally?: () => void;
  /** Mensaje de éxito a mostrar */
  successMessage?: string;
}

// ============================================
// FUNCIONES DE EXTRACCIÓN DE ERRORES
// ============================================

/**
 * Extrae el mensaje de error de cualquier tipo de error
 */
export function getErrorMessage(error: unknown): string {
  if (error instanceof Error) {
    return error.message;
  }
  if (typeof error === 'string') {
    return error;
  }
  if (error && typeof error === 'object' && 'message' in error) {
    return String((error as { message: unknown }).message);
  }
  return 'Error desconocido';
}

/**
 * Crea un objeto Error a partir de cualquier tipo de error
 */
export function normalizeError(error: unknown): Error {
  if (error instanceof Error) {
    return error;
  }
  return new Error(getErrorMessage(error));
}

// ============================================
// FUNCIONES DE MANEJO DE ERRORES
// ============================================

/**
 * Maneja un error de forma centralizada
 */
export function handleError(
  error: unknown,
  options: ErrorHandlingOptions = {}
): Error {
  const {
    errorMessage,
    notify = true,
    log = true,
    notifyService
  } = options;

  const normalizedError = normalizeError(error);
  const message = errorMessage
    ? `${errorMessage}: ${normalizedError.message}`
    : normalizedError.message;

  if (log) {
    logger.error('[Error]', message, normalizedError);
  }

  if (notify && notifyService) {
    notifyService.error(message);
  }

  return normalizedError;
}

// ============================================
// FUNCIONES DE EJECUCIÓN SEGURA
// ============================================

/**
 * Ejecuta una función asíncrona con manejo de errores centralizado
 *
 * @example
 * const result = await withErrorHandling(
 *   () => api.saveItem(data),
 *   {
 *     notifyService: notify,
 *     successMessage: 'Guardado correctamente',
 *     errorMessage: 'Error al guardar'
 *   }
 * );
 */
export async function withErrorHandling<T>(
  fn: () => Promise<T>,
  options: AsyncOperationOptions<T> = {}
): Promise<T | null> {
  const {
    onSuccess,
    onError,
    onFinally,
    successMessage,
    notifyService,
    ...errorOptions
  } = options;

  try {
    const result = await fn();

    if (successMessage && notifyService) {
      notifyService.success(successMessage);
    }

    onSuccess?.(result);
    return result;
  } catch (error) {
    const normalizedError = handleError(error, { ...errorOptions, notifyService });
    onError?.(normalizedError);
    return null;
  } finally {
    onFinally?.();
  }
}

/**
 * Wrapper para operaciones CRUD con estados de loading
 *
 * @example
 * await withLoadingState(
 *   setGuardando,
 *   async () => {
 *     await api.saveItem(data);
 *     modal.close();
 *   },
 *   {
 *     notifyService: notify,
 *     successMessage: 'Guardado',
 *     errorMessage: 'Error al guardar'
 *   }
 * );
 */
export async function withLoadingState<T>(
  setLoading: (loading: boolean) => void,
  fn: () => Promise<T>,
  options: AsyncOperationOptions<T> = {}
): Promise<T | null> {
  setLoading(true);

  const result = await withErrorHandling(fn, {
    ...options,
    onFinally: () => {
      setLoading(false);
      options.onFinally?.();
    }
  });

  return result;
}

// ============================================
// FUNCIONES PARA CONFIRMACIÓN
// ============================================

export interface ConfirmDeleteOptions {
  titulo?: string;
  mensaje?: string;
  onConfirm: () => Promise<void>;
  onCancel?: () => void;
  setConfig: (config: {
    visible: boolean;
    titulo?: string;
    mensaje?: string;
    tipo?: string;
    onConfirm?: () => Promise<void>;
  }) => void;
}

/**
 * Muestra un diálogo de confirmación para eliminar
 */
export function showDeleteConfirmation(options: ConfirmDeleteOptions): void {
  const {
    titulo = 'Confirmar eliminación',
    mensaje = '¿Está seguro de que desea eliminar este elemento?',
    onConfirm,
    setConfig
  } = options;

  setConfig({
    visible: true,
    titulo,
    mensaje,
    tipo: 'danger',
    onConfirm: async () => {
      await onConfirm();
      setConfig({ visible: false });
    }
  });
}

// ============================================
// EXPORT DEFAULT
// ============================================

export default {
  getErrorMessage,
  normalizeError,
  handleError,
  withErrorHandling,
  withLoadingState,
  showDeleteConfirmation
};
