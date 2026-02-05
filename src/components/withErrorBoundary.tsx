/**
 * HOC para envolver componentes con Error Boundary
 *
 * @param WrappedComponent - Componente a envolver
 * @param options - Opciones de configuracion
 * @param options.componentName - Nombre del componente para logging
 * @param options.compact - Usar boundary compacto
 * @param options.errorMessage - Mensaje de error personalizado
 * @param options.fallback - Componente de fallback personalizado
 * @param options.onError - Callback cuando ocurre un error
 *
 * @example
 * // Uso basico
 * export default withErrorBoundary(MiComponente);
 *
 * // Con opciones
 * export default withErrorBoundary(MiModal, {
 *   componentName: 'MiModal',
 *   compact: true,
 *   errorMessage: 'Error al cargar el modal'
 * });
 */
import { ComponentType, ReactElement } from 'react';
import { ErrorBoundary, CompactErrorBoundary } from './ErrorBoundary';

interface ErrorInfo {
  componentStack: string;
}

interface ErrorBoundaryOptions {
  componentName?: string;
  compact?: boolean;
  errorMessage?: string;
  fallback?: ReactElement;
  onError?: (error: Error, errorInfo: ErrorInfo) => void;
}

interface WithOnCloseProps {
  onClose?: () => void;
}

export function withErrorBoundary<P extends WithOnCloseProps>(
  WrappedComponent: ComponentType<P>,
  options: ErrorBoundaryOptions = {}
): ComponentType<P> {
  const {
    componentName = WrappedComponent.displayName || WrappedComponent.name || 'Component',
    compact = false,
    errorMessage,
    fallback,
    onError
  } = options;

  const Boundary = compact ? CompactErrorBoundary : ErrorBoundary;

  function WithErrorBoundary(props: P): ReactElement {
    return (
      <Boundary
        componentName={componentName}
        errorMessage={errorMessage}
        fallback={fallback as unknown as undefined}
        onError={onError as any}
        onClose={props.onClose}
      >
        <WrappedComponent {...props} />
      </Boundary>
    );
  }

  WithErrorBoundary.displayName = `withErrorBoundary(${componentName})`;

  return WithErrorBoundary;
}

export default withErrorBoundary;
