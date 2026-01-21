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
import { ErrorBoundary, CompactErrorBoundary } from './ErrorBoundary';

export function withErrorBoundary(WrappedComponent, options = {}) {
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

export default withErrorBoundary;
