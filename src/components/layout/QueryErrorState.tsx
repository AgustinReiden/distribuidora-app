import { AlertTriangle } from 'lucide-react';

export interface QueryErrorStateProps {
  /** Se llama al tocar "Reintentar". Normalmente el `refetch` de la query. */
  onRetry?: () => void;
  /** Por qué falló, si se sabe y le sirve al usuario (no un error crudo del server). */
  motivo?: string;
}

/**
 * Estado a mostrar cuando una query falló (isError) tras agotar los reintentos
 * de queryClient, en vez del empty state ("No hay X") — ese mensaje le hace
 * creer al usuario que la sucursal está vacía cuando en realidad no se pudo
 * cargar nada.
 */
export default function QueryErrorState({ onRetry, motivo }: QueryErrorStateProps) {
  return (
    <div className="text-center py-12 text-gray-500 dark:text-gray-400" role="alert">
      <AlertTriangle className="w-12 h-12 mx-auto mb-3 text-amber-500 opacity-80" />
      <p>No se pudo cargar.</p>
      {motivo && <p className="mt-1 text-sm max-w-md mx-auto">{motivo}</p>}
      {onRetry && (
        <button
          onClick={onRetry}
          className="mt-2 text-sm text-blue-600 dark:text-blue-400 hover:underline"
        >
          Reintentar
        </button>
      )}
    </div>
  );
}
