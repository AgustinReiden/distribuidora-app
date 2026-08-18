/**
 * Tipos compartidos para todos los handlers
 * Centraliza interfaces comunes para evitar duplicación
 */

// =============================================================================
// TIPOS PARA MODALES
// =============================================================================

/**
 * Control básico de modal con estado open/close
 */
export interface ModalControl {
  open: boolean;
  setOpen: (open: boolean) => void;
}

/**
 * Configuración para modal de confirmación
 */
export interface ConfirmModalConfig {
  visible: boolean;
  titulo?: string;
  mensaje?: string;
  tipo?: 'success' | 'warning' | 'danger' | 'info';
  onConfirm?: () => Promise<void> | void;
}

/**
 * Interface para controlar modal de confirmación
 */
export interface ConfirmModal {
  setConfig: (config: ConfirmModalConfig) => void;
}

// =============================================================================
// TIPOS PARA NOTIFICACIONES
// =============================================================================

/**
 * Opciones para notificaciones
 */
export interface NotifyOptions {
  persist?: boolean;
}

/**
 * Servicio de notificaciones
 */
export interface NotifyService {
  success: (message: string, options?: NotifyOptions) => void;
  error: (message: string, duration?: number) => void;
  warning: (message: string) => void;
  info: (message: string) => void;
}

/**
 * Variante de `NotifyService` en la que `warning`/`info` también aceptan
 * opciones. Vivía en `useAppHandlers.ts`; se mudó acá al borrar esa capa
 * (era su único consumidor vivo, vía `useSyncManager`).
 */
export interface NotifyApi {
  success: (message: string, options?: NotifyOptions) => void;
  error: (message: string, duration?: number) => void;
  warning: (message: string, options?: NotifyOptions) => void;
  info: (message: string, options?: NotifyOptions) => void;
}
