/**
 * Sistema de Error Boundaries con integración Sentry
 *
 * Incluye:
 * - ErrorBoundary: Boundary completo para la app
 * - CompactErrorBoundary: Boundary inline para modales y secciones
 * - withErrorBoundary: HOC para envolver componentes fácilmente
 * - useErrorHandler: Hook para manejar errores asíncronos
 */
import React, { ReactNode, ErrorInfo } from 'react';
import { AlertTriangle, RefreshCw, X, WifiOff, Lock, Database, Bug, LucideIcon } from 'lucide-react';
import { captureException, addBreadcrumb } from '../lib/sentry';
import { categorizeError, getRecoveryInfo } from '../utils/errorUtils';
import type { ErrorCategory } from '../types';

// =============================================================================
// TYPES
// =============================================================================

export type IconName = 'WifiOff' | 'Lock' | 'AlertTriangle' | 'Database' | 'Bug';

/** Props for ErrorBoundary fallback render function */
export interface ErrorFallbackProps {
  error: Error | null;
  errorInfo: ErrorInfo | null;
  errorCategory: ErrorCategory | null;
  onRetry: () => Promise<void>;
  onReload: () => void;
  onReset: () => void;
  isRetrying: boolean;
  retryCount: number;
}

/** Props for CompactErrorBoundary fallback render function */
export interface CompactErrorFallbackProps {
  error: Error | null;
  errorCategory: ErrorCategory | null;
  onRetry: () => Promise<void>;
  onClose: () => void;
  isRetrying: boolean;
}

/** Props for the main ErrorBoundary component */
export interface ErrorBoundaryProps {
  children: ReactNode;
  componentName?: string;
  fallback?: (props: ErrorFallbackProps) => ReactNode;
  onError?: (error: Error, errorInfo: ErrorInfo, category: ErrorCategory) => void;
}

/** State for the main ErrorBoundary component */
export interface ErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
  errorInfo: ErrorInfo | null;
  errorCategory: ErrorCategory | null;
  retryCount: number;
  isRetrying: boolean;
}

/** Props for CompactErrorBoundary component */
export interface CompactErrorBoundaryProps {
  children: ReactNode;
  componentName?: string;
  errorMessage?: string;
  fallback?: (props: CompactErrorFallbackProps) => ReactNode;
  onError?: (error: Error, errorInfo: ErrorInfo, category: ErrorCategory) => void;
  onClose?: () => void;
}

/** State for CompactErrorBoundary component */
export interface CompactErrorBoundaryState {
  hasError: boolean;
  error: Error | null;
  errorCategory: ErrorCategory | null;
  retryCount: number;
  isRetrying: boolean;
}

// Mapa de iconos por nombre
const iconMap: Record<IconName, LucideIcon> = {
  WifiOff,
  Lock,
  AlertTriangle,
  Database,
  Bug
};

/**
 * Obtiene el componente de icono basado en el nombre
 */
function getIconComponent(iconName: string | undefined): LucideIcon {
  return iconMap[iconName as IconName] || Bug;
}

/**
 * Error Boundary completo (pantalla completa)
 * Usar en el nivel raíz de la aplicación
 */
class ErrorBoundary extends React.Component<ErrorBoundaryProps, ErrorBoundaryState> {
  constructor(props: ErrorBoundaryProps) {
    super(props);
    this.state = {
      hasError: false,
      error: null,
      errorInfo: null,
      errorCategory: null,
      retryCount: 0,
      isRetrying: false
    };
  }

  static getDerivedStateFromError(error: Error): Partial<ErrorBoundaryState> {
    return {
      hasError: true,
      errorCategory: categorizeError(error)
    };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo): void {
    const category = categorizeError(error);

    this.setState({ error, errorInfo, errorCategory: category });

    // Reportar a Sentry
    captureException(error, {
      tags: {
        component: this.props.componentName || 'unknown',
        boundary: 'full',
        errorCategory: category
      },
      extra: {
        componentStack: errorInfo?.componentStack,
        retryCount: this.state.retryCount
      }
    });

    // Callback opcional
    this.props.onError?.(error, errorInfo, category);
  }

  handleReload = (): void => {
    window.location.reload();
  };

  handleRelogin = (): void => {
    // Limpiar sesión y redirigir al login
    localStorage.removeItem('supabase.auth.token');
    window.location.href = '/login';
  };

  handleRetry = async (): Promise<void> => {
    const { errorCategory, retryCount } = this.state;
    if (!errorCategory) return;
    const recoveryInfo = getRecoveryInfo(errorCategory);

    if (!recoveryInfo.canRetry) {
      return;
    }

    if (recoveryInfo.maxRetries && retryCount >= recoveryInfo.maxRetries) {
      return;
    }

    addBreadcrumb({
      category: 'error-boundary',
      message: `User clicked retry (attempt ${retryCount + 1})`,
      level: 'info'
    });

    this.setState({ isRetrying: true });

    // Esperar antes de reintentar (backoff exponencial)
    const delay = (recoveryInfo.retryDelay ?? 1000) * Math.pow(2, retryCount);
    await new Promise(resolve => setTimeout(resolve, delay));

    this.setState({
      hasError: false,
      error: null,
      errorInfo: null,
      errorCategory: null,
      retryCount: retryCount + 1,
      isRetrying: false
    });
  };

  resetError = (): void => {
    this.setState({
      hasError: false,
      error: null,
      errorInfo: null,
      errorCategory: null,
      retryCount: 0,
      isRetrying: false
    });
  };

  render(): ReactNode {
    if (this.state.hasError) {
      // Fallback personalizado
      if (this.props.fallback) {
        return this.props.fallback({
          error: this.state.error,
          errorInfo: this.state.errorInfo,
          errorCategory: this.state.errorCategory,
          onRetry: this.handleRetry,
          onReload: this.handleReload,
          onReset: this.resetError,
          isRetrying: this.state.isRetrying,
          retryCount: this.state.retryCount
        });
      }

      const recoveryInfo = getRecoveryInfo(this.state.errorCategory ?? 'UNKNOWN');
      const IconComponent = getIconComponent(recoveryInfo.iconName);
      const canRetryNow = recoveryInfo.canRetry &&
        (!recoveryInfo.maxRetries || this.state.retryCount < recoveryInfo.maxRetries);

      return (
        <div className="min-h-screen bg-gray-100 dark:bg-gray-900 flex items-center justify-center p-4">
          <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl max-w-md w-full p-6 text-center">
            <div className="flex items-center justify-center w-16 h-16 mx-auto mb-4 rounded-full bg-red-100 dark:bg-red-900/30">
              <IconComponent className="w-8 h-8 text-red-600 dark:text-red-400" />
            </div>

            <h1 className="text-xl font-bold text-gray-900 dark:text-white mb-2">
              {recoveryInfo.title}
            </h1>

            <p className="text-gray-600 dark:text-gray-400 mb-6">
              {recoveryInfo.message}
            </p>

            {import.meta.env.DEV && this.state.error && (
              <div className="mb-6 p-3 bg-gray-100 dark:bg-gray-700 rounded-lg text-left overflow-auto max-h-40">
                <p className="text-sm font-mono text-red-600 dark:text-red-400">
                  {this.state.error.toString()}
                </p>
                {this.state.errorInfo && (
                  <pre className="text-xs text-gray-500 dark:text-gray-400 mt-2 whitespace-pre-wrap">
                    {this.state.errorInfo.componentStack}
                  </pre>
                )}
              </div>
            )}

            {this.state.retryCount > 0 && (
              <p className="text-sm text-gray-500 dark:text-gray-400 mb-4">
                Intento {this.state.retryCount} de {recoveryInfo.maxRetries || '∞'}
              </p>
            )}

            <div className="flex space-x-3 justify-center">
              {canRetryNow && (
                <button
                  onClick={this.handleRetry}
                  disabled={this.state.isRetrying}
                  className="flex items-center space-x-2 px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-lg hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors disabled:opacity-50"
                >
                  <RefreshCw className={`w-4 h-4 ${this.state.isRetrying ? 'animate-spin' : ''}`} />
                  <span>{this.state.isRetrying ? 'Reintentando...' : 'Reintentar'}</span>
                </button>
              )}

              {recoveryInfo.action === 'relogin' ? (
                <button
                  onClick={this.handleRelogin}
                  className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
                >
                  <Lock className="w-4 h-4" />
                  <span>Iniciar sesión</span>
                </button>
              ) : (
                <button
                  onClick={this.handleReload}
                  className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
                >
                  <RefreshCw className="w-4 h-4" />
                  <span>Recargar página</span>
                </button>
              )}
            </div>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}

/**
 * Error Boundary compacto (inline)
 * Usar en modales, cards, y secciones
 */
class CompactErrorBoundary extends React.Component<CompactErrorBoundaryProps, CompactErrorBoundaryState> {
  constructor(props: CompactErrorBoundaryProps) {
    super(props);
    this.state = {
      hasError: false,
      error: null,
      errorCategory: null,
      retryCount: 0,
      isRetrying: false
    };
  }

  static getDerivedStateFromError(error: Error): Partial<CompactErrorBoundaryState> {
    return {
      hasError: true,
      errorCategory: categorizeError(error)
    };
  }

  componentDidCatch(error: Error, errorInfo: ErrorInfo): void {
    const category = categorizeError(error);

    this.setState({ error, errorCategory: category });

    // Reportar a Sentry
    captureException(error, {
      tags: {
        component: this.props.componentName || 'unknown',
        boundary: 'compact',
        errorCategory: category
      },
      extra: {
        componentStack: errorInfo?.componentStack
      }
    });

    // Callback opcional
    this.props.onError?.(error, errorInfo, category);
  }

  handleRetry = async (): Promise<void> => {
    const { errorCategory, retryCount } = this.state;
    if (!errorCategory) return;
    const recoveryInfo = getRecoveryInfo(errorCategory);

    if (!recoveryInfo.canRetry) {
      return;
    }

    addBreadcrumb({
      category: 'error-boundary',
      message: 'User clicked retry (compact)',
      level: 'info'
    });

    this.setState({ isRetrying: true });

    const delay = (recoveryInfo.retryDelay ?? 1000) * Math.pow(2, retryCount);
    await new Promise(resolve => setTimeout(resolve, Math.min(delay, 5000)));

    this.setState({
      hasError: false,
      error: null,
      errorCategory: null,
      retryCount: retryCount + 1,
      isRetrying: false
    });
  };

  handleClose = (): void => {
    this.props.onClose?.();
  };

  render(): ReactNode {
    if (this.state.hasError) {
      // Fallback personalizado
      if (this.props.fallback) {
        return this.props.fallback({
          error: this.state.error,
          errorCategory: this.state.errorCategory,
          onRetry: this.handleRetry,
          onClose: this.handleClose,
          isRetrying: this.state.isRetrying
        });
      }

      const recoveryInfo = getRecoveryInfo(this.state.errorCategory ?? 'UNKNOWN');
      const IconComponent = getIconComponent(recoveryInfo.iconName);

      return (
        <div className="p-4 bg-red-50 dark:bg-red-900/20 rounded-lg border border-red-200 dark:border-red-800">
          <div className="flex items-start space-x-3">
            <div className="flex-shrink-0">
              <IconComponent className="w-5 h-5 text-red-500 dark:text-red-400" />
            </div>
            <div className="flex-1 min-w-0">
              <h3 className="text-sm font-medium text-red-800 dark:text-red-200">
                {recoveryInfo.title}
              </h3>
              <p className="mt-1 text-sm text-red-600 dark:text-red-300">
                {this.props.errorMessage || recoveryInfo.message}
              </p>

              {import.meta.env.DEV && this.state.error && (
                <p className="mt-2 text-xs font-mono text-red-500 dark:text-red-400 truncate">
                  {this.state.error.message}
                </p>
              )}

              <div className="mt-3 flex space-x-2">
                {recoveryInfo.canRetry && (
                  <button
                    onClick={this.handleRetry}
                    disabled={this.state.isRetrying}
                    className="inline-flex items-center px-3 py-1.5 text-xs font-medium text-red-700 dark:text-red-200 bg-red-100 dark:bg-red-900/40 rounded hover:bg-red-200 dark:hover:bg-red-900/60 transition-colors disabled:opacity-50"
                  >
                    <RefreshCw className={`w-3 h-3 mr-1 ${this.state.isRetrying ? 'animate-spin' : ''}`} />
                    {this.state.isRetrying ? 'Reintentando...' : 'Reintentar'}
                  </button>
                )}
                {this.props.onClose && (
                  <button
                    onClick={this.handleClose}
                    className="inline-flex items-center px-3 py-1.5 text-xs font-medium text-gray-700 dark:text-gray-200 bg-gray-100 dark:bg-gray-700 rounded hover:bg-gray-200 dark:hover:bg-gray-600 transition-colors"
                  >
                    <X className="w-3 h-3 mr-1" />
                    Cerrar
                  </button>
                )}
              </div>
            </div>
          </div>
        </div>
      );
    }

    return this.props.children;
  }
}

export default ErrorBoundary;
export { ErrorBoundary, CompactErrorBoundary };

// withErrorBoundary HOC está disponible en './withErrorBoundary'
