/**
 * Componente de estado vacío reutilizable
 *
 * Muestra mensajes consistentes cuando no hay datos para mostrar,
 * diferenciando entre estados "sin datos" y "sin resultados de búsqueda".
 */
import React, { memo } from 'react';
import { LucideIcon, Search, Inbox, AlertCircle, FileQuestion } from 'lucide-react';

// ============================================
// TIPOS
// ============================================

export interface EmptyStateProps {
  /** Icono a mostrar */
  icon?: LucideIcon;
  /** Título del mensaje */
  title?: string;
  /** Descripción adicional */
  description?: string;
  /** Indica si es resultado de una búsqueda/filtro sin resultados */
  isFiltered?: boolean;
  /** Término de búsqueda actual (para personalizar mensaje) */
  searchTerm?: string;
  /** Nombre de la entidad (ej: "clientes", "pedidos") */
  entityName?: string;
  /** Acción principal (botón) */
  action?: React.ReactNode;
  /** Clases CSS adicionales */
  className?: string;
  /** Tamaño del componente */
  size?: 'sm' | 'md' | 'lg';
}

// ============================================
// COMPONENTE
// ============================================

function EmptyState({
  icon: CustomIcon,
  title,
  description,
  isFiltered = false,
  searchTerm,
  entityName = 'elementos',
  action,
  className = '',
  size = 'md'
}: EmptyStateProps): React.ReactElement {
  // Determinar icono según contexto
  const Icon = CustomIcon || (isFiltered ? Search : Inbox);

  // Generar título y descripción según contexto
  const displayTitle = title || (isFiltered
    ? `No se encontraron ${entityName}`
    : `No hay ${entityName}`);

  const displayDescription = description || (isFiltered
    ? searchTerm
      ? `No hay ${entityName} que coincidan con "${searchTerm}". Intenta con otros términos de búsqueda.`
      : `No hay ${entityName} que coincidan con los filtros aplicados. Prueba modificando los criterios de búsqueda.`
    : `Aún no hay ${entityName} registrados. Puedes crear uno nuevo para comenzar.`);

  // Clases según tamaño
  const sizeClasses = {
    sm: {
      container: 'py-6',
      icon: 'w-8 h-8',
      title: 'text-base',
      description: 'text-sm'
    },
    md: {
      container: 'py-12',
      icon: 'w-12 h-12',
      title: 'text-lg',
      description: 'text-sm'
    },
    lg: {
      container: 'py-16',
      icon: 'w-16 h-16',
      title: 'text-xl',
      description: 'text-base'
    }
  };

  const classes = sizeClasses[size];

  return (
    <div
      className={`text-center ${classes.container} ${className}`}
      role="status"
      aria-live="polite"
    >
      <Icon
        className={`${classes.icon} mx-auto mb-3 text-gray-400 dark:text-gray-500 opacity-50`}
        aria-hidden="true"
      />
      <h3 className={`${classes.title} font-medium text-gray-600 dark:text-gray-300 mb-1`}>
        {displayTitle}
      </h3>
      <p className={`${classes.description} text-gray-500 dark:text-gray-400 max-w-md mx-auto`}>
        {displayDescription}
      </p>
      {action && (
        <div className="mt-4">
          {action}
        </div>
      )}
    </div>
  );
}

// ============================================
// VARIANTES PRE-CONFIGURADAS
// ============================================

export interface EmptyStateVariantProps {
  action?: React.ReactNode;
  searchTerm?: string;
  className?: string;
}

/** Estado vacío para listas de clientes */
export function EmptyClientes({ action, searchTerm, className }: EmptyStateVariantProps): React.ReactElement {
  return (
    <EmptyState
      entityName="clientes"
      isFiltered={Boolean(searchTerm)}
      searchTerm={searchTerm}
      action={action}
      className={className}
    />
  );
}

/** Estado vacío para listas de pedidos */
export function EmptyPedidos({ action, searchTerm, className }: EmptyStateVariantProps): React.ReactElement {
  return (
    <EmptyState
      entityName="pedidos"
      isFiltered={Boolean(searchTerm)}
      searchTerm={searchTerm}
      action={action}
      className={className}
    />
  );
}

/** Estado vacío para listas de productos */
export function EmptyProductos({ action, searchTerm, className }: EmptyStateVariantProps): React.ReactElement {
  return (
    <EmptyState
      entityName="productos"
      isFiltered={Boolean(searchTerm)}
      searchTerm={searchTerm}
      action={action}
      className={className}
    />
  );
}

/** Estado vacío para resultados de búsqueda */
export function EmptySearchResults({ searchTerm, entityName = 'resultados' }: { searchTerm?: string; entityName?: string }): React.ReactElement {
  return (
    <EmptyState
      icon={Search}
      title="Sin resultados"
      description={searchTerm
        ? `No se encontraron ${entityName} para "${searchTerm}"`
        : `No se encontraron ${entityName} con los filtros aplicados`}
      isFiltered={true}
      size="sm"
    />
  );
}

/** Estado de error */
export function ErrorState({
  title = 'Error al cargar datos',
  description = 'Ocurrió un error al cargar la información. Por favor, intenta de nuevo.',
  action
}: {
  title?: string;
  description?: string;
  action?: React.ReactNode;
}): React.ReactElement {
  return (
    <EmptyState
      icon={AlertCircle}
      title={title}
      description={description}
      action={action}
      className="text-red-600"
    />
  );
}

/** Estado "no encontrado" */
export function NotFoundState({
  title = 'No encontrado',
  description = 'El elemento que buscas no existe o fue eliminado.'
}: {
  title?: string;
  description?: string;
}): React.ReactElement {
  return (
    <EmptyState
      icon={FileQuestion}
      title={title}
      description={description}
    />
  );
}

// ============================================
// EXPORTS
// ============================================

export default memo(EmptyState);
