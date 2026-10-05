import React, { memo, CSSProperties } from 'react'
import Card from './Card'

// =============================================================================
// PROPS INTERFACES
// =============================================================================

export interface SkeletonProps {
  className?: string;
  width?: number | string;
  height?: number | string;
  rounded?: string;
  animate?: boolean;
}

export interface SkeletonTextProps {
  width?: number | string;
  className?: string;
}

export interface SkeletonTitleProps {
  width?: number | string;
  className?: string;
}

export interface SkeletonAvatarProps {
  size?: number;
  className?: string;
}

export interface SkeletonTableRowProps {
  columns?: number;
}

export interface SkeletonTableProps {
  rows?: number;
  columns?: number;
}

export interface SkeletonPedidosListProps {
  count?: number;
}

export interface SkeletonDashboardProps {
  /** Preventista puro: la grilla de métricas es la suya (2 columnas desde 375 px). */
  preventistaPuro?: boolean;
}

export interface SkeletonFormProps {
  fields?: number;
}

// =============================================================================
// COMPONENTS
// =============================================================================

/**
 * Componente Skeleton base para animaciones de carga
 */
export const Skeleton = memo(function Skeleton({
  className = '',
  width,
  height,
  rounded = 'rounded',
  animate = true
}: SkeletonProps): React.ReactElement {
  const style: CSSProperties = {}
  if (width) style.width = typeof width === 'number' ? `${width}px` : width
  if (height) style.height = typeof height === 'number' ? `${height}px` : height

  return (
    <div
      className={`bg-gray-200 dark:bg-gray-700 ${rounded} ${animate ? 'animate-pulse' : ''} ${className}`}
      style={style}
    />
  )
})

/**
 * Skeleton para texto de una linea
 */
export const SkeletonText = memo(function SkeletonText({
  width = '100%',
  className = ''
}: SkeletonTextProps): React.ReactElement {
  return <Skeleton width={width} height={16} rounded="rounded" className={className} />
})

/**
 * Skeleton para titulos
 */
export const SkeletonTitle = memo(function SkeletonTitle({
  width = '60%',
  className = ''
}: SkeletonTitleProps): React.ReactElement {
  return <Skeleton width={width} height={24} rounded="rounded" className={className} />
})

/**
 * Skeleton para avatares/imagenes circulares
 */
export const SkeletonAvatar = memo(function SkeletonAvatar({
  size = 40,
  className = ''
}: SkeletonAvatarProps): React.ReactElement {
  return <Skeleton width={size} height={size} rounded="rounded-full" className={className} />
})

/**
 * Skeleton para cards de producto
 */
export const SkeletonProductCard = memo(function SkeletonProductCard(): React.ReactElement {
  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 space-y-3">
      <Skeleton height={120} rounded="rounded-lg" />
      <SkeletonTitle width="80%" />
      <SkeletonText width="60%" />
      <div className="flex justify-between items-center pt-2">
        <Skeleton width={80} height={28} rounded="rounded" />
        <Skeleton width={60} height={32} rounded="rounded-lg" />
      </div>
    </div>
  )
})

/**
 * Skeleton para filas de tabla
 */
export const SkeletonTableRow = memo(function SkeletonTableRow({
  columns = 5
}: SkeletonTableRowProps): React.ReactElement {
  return (
    <tr className="border-b dark:border-gray-700">
      {Array.from({ length: columns }).map((_, i) => (
        <td key={i} className="px-4 py-3">
          <Skeleton
            width={i === 0 ? '70%' : i === columns - 1 ? 60 : '80%'}
            height={16}
            rounded="rounded"
          />
        </td>
      ))}
    </tr>
  )
})

/**
 * Skeleton para tabla completa
 */
export const SkeletonTable = memo(function SkeletonTable({
  rows = 5,
  columns = 5
}: SkeletonTableProps): React.ReactElement {
  return (
    <div className="overflow-hidden rounded-lg border dark:border-gray-700">
      <table className="w-full">
        <thead className="bg-gray-50 dark:bg-gray-800">
          <tr>
            {Array.from({ length: columns }).map((_, i) => (
              <th key={i} className="px-4 py-3 text-left">
                <Skeleton width={i === 0 ? 100 : 80} height={14} />
              </th>
            ))}
          </tr>
        </thead>
        <tbody className="bg-white dark:bg-gray-900">
          {Array.from({ length: rows }).map((_, i) => (
            <SkeletonTableRow key={i} columns={columns} />
          ))}
        </tbody>
      </table>
    </div>
  )
})

/**
 * Skeleton para cards de pedido.
 *
 * Replica la PedidoCard cerrada de /pedidos (WP-43, #768) clase por clase: la
 * misma `Card` (`padding="none"`, riel `accent`), el mismo contenedor
 * `flex-wrap px-4 py-3`, la misma columna de datos (`basis-48`, `space-y-1.5`)
 * con sus dos líneas, y la misma columna de acciones a la derecha (acción en
 * línea, menu ⋮ y chevron). Al envolver igual, a 375 px las acciones bajan a su
 * propia fila como en la tarjeta real, y a escritorio quedan centradas a la
 * derecha. Cada bloque mide lo que mide el elemento que reemplaza (badge 20,
 * línea de texto 20, Button `sm` 32, menu ⋮ 40, chevron 32), para que la lista no
 * cambie de alto al terminar de cargar. Si cambia la PedidoCard, cambia esto.
 *
 * Calibración: los anchos de los bloques son los medidos en la tarjeta real de un
 * pedido pendiente visto por admin (primer pedido de PEDIDOS_FIXTURE en la
 * galería, rol Admin, `npm run gallery`): badge de estado 88, de pago 118, total
 * 97, #id 51, badge FC/ZZ 32x20, dirección 294, vendedor 109, ítems 64 y acción en
 * línea 193x32 ("Marcar en preparación"). Con esos anchos el skeleton envuelve en
 * los mismos puntos que la tarjeta real y mide lo mismo (±4 px) a 343, 375, 500,
 * 640, 768, 1000 y 1232 px de ancho de tarjeta. Una tarjeta con otros datos (sin
 * badge FC/ZZ para el preventista, sin acción en línea, dirección corta) envuelve
 * en otros anchos: es una estimación, no un espejo dato a dato.
 */
export const SkeletonPedidoCard = memo(function SkeletonPedidoCard(): React.ReactElement {
  return (
    <Card padding="none" accent="neutral">
      <div className="flex flex-wrap items-start gap-x-3 gap-y-2 px-4 py-3">
        <div className="min-w-0 grow basis-48 space-y-1.5">
          {/* Línea 1: estado, cliente, estado de pago y total */}
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <Skeleton width={88} height={20} rounded="rounded-full" />
            <div className="flex h-5 min-w-0 grow basis-32 items-center">
              <SkeletonText width="70%" />
            </div>
            <div className="ml-auto flex min-w-0 max-w-full flex-wrap items-center justify-end gap-x-2 gap-y-1">
              <Skeleton width={118} height={20} rounded="rounded-full" />
              <div className="flex h-5 items-center">
                <Skeleton width={97} height={18} rounded="rounded" />
              </div>
            </div>
          </div>

          {/* Línea 2: #id, badge FC/ZZ, dirección, vendedor e ítems */}
          <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
            <div className="flex h-5 items-center">
              <SkeletonText width={51} />
            </div>
            <Skeleton width={32} height={20} rounded="rounded" />
            <div className="flex h-5 min-w-0 max-w-full items-center">
              <SkeletonText width={294} />
            </div>
            <div className="flex h-5 items-center">
              <SkeletonText width={109} />
            </div>
            <div className="flex h-5 items-center">
              <SkeletonText width={64} />
            </div>
          </div>
        </div>

        {/* Acciones: la visible (Button sm, "Marcar en preparación"), el menu ⋮ (icon) y el chevron (iconSm) */}
        <div className="ml-auto flex max-w-full flex-wrap items-center justify-end gap-1.5 sm:self-center">
          <Skeleton width={193} height={32} rounded="rounded-lg" />
          <Skeleton width={40} height={40} rounded="rounded-lg" />
          <Skeleton width={32} height={32} rounded="rounded-lg" />
        </div>
      </div>
    </Card>
  )
})

/**
 * Skeleton para lista de pedidos
 */
export const SkeletonPedidosList = memo(function SkeletonPedidosList({
  count = 5
}: SkeletonPedidosListProps): React.ReactElement {
  return (
    <div className="space-y-4">
      {Array.from({ length: count }).map((_, i) => (
        <SkeletonPedidoCard key={i} />
      ))}
    </div>
  )
})

/**
 * Skeleton para cards de estadisticas del dashboard
 */
export const SkeletonStatCard = memo(function SkeletonStatCard(): React.ReactElement {
  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
      <div className="flex items-center gap-3">
        <Skeleton width={48} height={48} rounded="rounded-lg" />
        <div className="flex-1 space-y-2">
          <SkeletonText width="60%" />
          <Skeleton width={100} height={28} rounded="rounded" />
        </div>
      </div>
    </div>
  )
})

/**
 * Skeleton para el dashboard.
 *
 * `preventistaPuro` reproduce la grilla de métricas de VistaDashboard para quien
 * no es admin ni encargado (WP-47, #772): dos columnas desde 375 px. El resto
 * usa la grilla de siempre (una columna, dos desde `sm`, cuatro desde `lg`). La
 * cantidad no cambia (4): la Tasa de entrega que el preventista no ve no es una
 * de las métricas de esa grilla sino el bloque de abajo del todo, que este
 * skeleton no dibuja.
 */
export const SkeletonDashboard = memo(function SkeletonDashboard({
  preventistaPuro = false
}: SkeletonDashboardProps): React.ReactElement {
  return (
    <div className="space-y-6">
      {/* Stats Grid: la misma de VistaDashboard */}
      <div className={preventistaPuro
        ? 'grid grid-cols-1 min-[375px]:grid-cols-2 lg:grid-cols-4 gap-3'
        : 'grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3'}>
        {Array.from({ length: 4 }).map((_, i) => (
          <SkeletonStatCard key={i} />
        ))}
      </div>

      {/* Charts placeholder */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
          <SkeletonTitle width={200} className="mb-4" />
          <Skeleton height={250} rounded="rounded-lg" />
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4">
          <SkeletonTitle width={200} className="mb-4" />
          <Skeleton height={250} rounded="rounded-lg" />
        </div>
      </div>
    </div>
  )
})

/**
 * Skeleton para formularios
 */
export const SkeletonForm = memo(function SkeletonForm({
  fields = 4
}: SkeletonFormProps): React.ReactElement {
  return (
    <div className="space-y-4">
      {Array.from({ length: fields }).map((_, i) => (
        <div key={i} className="space-y-1">
          <Skeleton width={100} height={14} rounded="rounded" />
          <Skeleton height={40} rounded="rounded-lg" />
        </div>
      ))}
      <div className="flex justify-end gap-2 pt-4">
        <Skeleton width={80} height={36} rounded="rounded-lg" />
        <Skeleton width={100} height={36} rounded="rounded-lg" />
      </div>
    </div>
  )
})

/**
 * Skeleton para lista de items
 */
export const SkeletonListItem = memo(function SkeletonListItem(): React.ReactElement {
  return (
    <div className="flex items-center gap-3 p-3 border-b dark:border-gray-700">
      <SkeletonAvatar size={40} />
      <div className="flex-1 space-y-2">
        <SkeletonText width="70%" />
        <SkeletonText width="40%" />
      </div>
      <Skeleton width={60} height={24} rounded="rounded" />
    </div>
  )
})

export default Skeleton
