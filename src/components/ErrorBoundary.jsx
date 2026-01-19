/**
 * Sistema de Error Boundaries con integración Sentry
 *
 * Incluye:
 * - ErrorBoundary: Boundary completo para la app
 * - CompactErrorBoundary: Boundary inline para modales y secciones
 * - withErrorBoundary: HOC para envolver componentes fácilmente
 */
import React from 'react';
import { AlertTriangle, RefreshCw, X } from 'lucide-react';
import { captureException, addBreadcrumb } from '../lib/sentry';

/**
 * Error Boundary completo (pantalla completa)
 * Usar en el nivel raíz de la aplicación
 */
class ErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { hasError: false, error: null, errorInfo: null };
  }

  static getDerivedStateFromError(error) {
    return { hasError: true };
  }

  componentDidCatch(error, errorInfo) {
    this.setState({ error, errorInfo });

    // Reportar a Sentry
    captureException(error, {
      tags: {
        component: this.props.componentName || 'unknown',
        boundary: 'full'
      },
      extra: {
        componentStack: errorInfo?.componentStack
      }
    });

    // Callback opcional
    this.props.onError?.(error, errorInfo);
  }

  handleReload = () => {
    window.location.reload();
  };

  handleRetry = () => {
    addBreadcrumb({
      category: 'error-boundary',
      message: 'User clicked retry',
      level: 'info'
    });
    this.setState({ hasError: false, error: null, errorInfo: null });
  };

  render() {
    if (this.state.hasError) {
      // Fallback personalizado
      if (this.props.fallback) {
        return this.props.fallback({
          error: this.state.error,
          errorInfo: this.state.errorInfo,
          onRetry: this.handleRetry,
          onReload: this.handleReload
        });
      }

      return (
        <div className="min-h-screen bg-gray-100 dark:bg-gray-900 flex items-center justify-center p-4">
          <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl max-w-md w-full p-6 text-center">
            <div className="flex items-center justify-center w-16 h-16 mx-auto mb-4 rounded-full bg-red-100 dark:bg-red-900/30">
              <AlertTriangle className="w-8 h-8 text-red-600 dark:text-red-400" />
            </div>

            <h1 className="text-xl font-bold text-gray-900 dark:text-white mb-2">
              ¡Ups! Algo salió mal
            </h1>

            <p className="text-gray-600 dark:text-gray-400 mb-6">
              Ha ocurrido un error inesperado. Por favor, intentá recargar la página.
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

            <div className="flex space-x-3 justify-center">
              <button
                onClick={this.handleRetry}
                className="px-4 py-2 bg-gray-200 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-lg hover:bg-gray-300 dark:hover:bg-gray-600 transition-colors"
              >
                Reintentar
              </button>
              <button
                onClick={this.handleReload}
                className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
              >
                <RefreshCw className="w-4 h-4" />
                <span>Recargar página</span>
              </button>
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
class CompactErrorBoundary extends React.Component {
  constructor(props) {
    super(props);
    this.state = { hasError: false, error: null };
  }

  static getDerivedStateFromError(error) {
    return { hasError: true, error };
  }

  componentDidCatch(error, errorInfo) {
    // Reportar a Sentry
    captureException(error, {
      tags: {
        component: this.props.componentName || 'unknown',
        boundary: 'compact'
      },
      extra: {
        componentStack: errorInfo?.componentStack
      }
    });

    // Callback opcional
    this.props.onError?.(error, errorInfo);
  }

  handleRetry = () => {
    addBreadcrumb({
      category: 'error-boundary',
      message: 'User clicked retry (compact)',
      level: 'info'
    });
    this.setState({ hasError: false, error: null });
  };

  handleClose = () => {
    this.props.onClose?.();
  };

  render() {
    if (this.state.hasError) {
      // Fallback personalizado
      if (this.props.fallback) {
        return this.props.fallback({
          error: this.state.error,
          onRetry: this.handleRetry,
          onClose: this.handleClose
        });
      }

      return (
        <div className="p-4 bg-red-50 dark:bg-red-900/20 rounded-lg border border-red-200 dark:border-red-800">
          <div className="flex items-start space-x-3">
            <div className="flex-shrink-0">
              <AlertTriangle className="w-5 h-5 text-red-500 dark:text-red-400" />
            </div>
            <div className="flex-1 min-w-0">
              <h3 className="text-sm font-medium text-red-800 dark:text-red-200">
                Error al cargar el componente
              </h3>
              <p className="mt-1 text-sm text-red-600 dark:text-red-300">
                {this.props.errorMessage || 'Ha ocurrido un error inesperado.'}
              </p>

              {import.meta.env.DEV && this.state.error && (
                <p className="mt-2 text-xs font-mono text-red-500 dark:text-red-400 truncate">
                  {this.state.error.message}
                </p>
              )}

              <div className="mt-3 flex space-x-2">
                <button
                  onClick={this.handleRetry}
                  className="inline-flex items-center px-3 py-1.5 text-xs font-medium text-red-700 dark:text-red-200 bg-red-100 dark:bg-red-900/40 rounded hover:bg-red-200 dark:hover:bg-red-900/60 transition-colors"
                >
                  <RefreshCw className="w-3 h-3 mr-1" />
                  Reintentar
                </button>
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

/**
 * HOC para envolver componentes con Error Boundary
 *
 * @param {React.Component} WrappedComponent - Componente a envolver
 * @param {object} options - Opciones de configuración
 * @param {string} options.componentName - Nombre del componente para logging
 * @param {boolean} options.compact - Usar boundary compacto
 * @param {string} options.errorMessage - Mensaje de error personalizado
 * @param {function} options.fallback - Componente de fallback personalizado
 * @param {function} options.onError - Callback cuando ocurre un error
 *
 * @example
 * // Uso básico
 * export default withErrorBoundary(MiComponente);
 *
 * // Con opciones
 * export default withErrorBoundary(MiModal, {
 *   componentName: 'MiModal',
 *   compact: true,
 *   errorMessage: 'Error al cargar el modal'
 * });
 */
function withErrorBoundary(WrappedComponent, options = {}) {
  const {
    componentName = WrappedComponent.displayName || WrappedComponent.name || 'Component',
    compact = false,
    errorMessage,
    fallback,
    onError
  } = options;

  const Boundary = compact ? CompactErrorBoundary : ErrorBoundary;

  function WithErrorBoundary(props) {
    return (
      <Boundary
        componentName={componentName}
        errorMessage={errorMessage}
        fallback={fallback}
        onError={onError}
        onClose={props.onClose}
      >
        <WrappedComponent {...props} />
      </Boundary>
    );
  }

  WithErrorBoundary.displayName = `withErrorBoundary(${componentName})`;

  return WithErrorBoundary;
}

/**
 * Hook para lanzar errores que serán capturados por el boundary más cercano
 * Útil para errores asíncronos que no se capturan automáticamente
 */
function useErrorHandler() {
  const [error, setError] = React.useState(null);

  if (error) {
    throw error;
  }

  const handleError = React.useCallback((err) => {
    setError(err);
  }, []);

  const resetError = React.useCallback(() => {
    setError(null);
  }, []);

  return { handleError, resetError };
}

export default ErrorBoundary;
export { ErrorBoundary, CompactErrorBoundary, withErrorBoundary, useErrorHandler };
