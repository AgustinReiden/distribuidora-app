import React, { memo } from 'react'

/**
 * Componente Skeleton base para animaciones de carga
 */
export const Skeleton = memo(function Skeleton({
  className = '',
  width,
  height,
  rounded = 'rounded',
  animate = true
}) {
  const style = {}
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
 * Skeleton para texto de una línea
 */
export const SkeletonText = memo(function SkeletonText({
  width = '100%',
  className = ''
}) {
  return <Skeleton width={width} height={16} rounded="rounded" className={className} />
})

/**
 * Skeleton para títulos
 */
export const SkeletonTitle = memo(function SkeletonTitle({
  width = '60%',
  className = ''
}) {
  return <Skeleton width={width} height={24} rounded="rounded" className={className} />
})

/**
 * Skeleton para avatares/imágenes circulares
 */
export const SkeletonAvatar = memo(function SkeletonAvatar({
  size = 40,
  className = ''
}) {
  return <Skeleton width={size} height={size} rounded="rounded-full" className={className} />
})

/**
 * Skeleton para cards de producto
 */
export const SkeletonProductCard = memo(function SkeletonProductCard() {
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
}) {
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
}) {
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
 * Skeleton para cards de pedido
 */
export const SkeletonPedidoCard = memo(function SkeletonPedidoCard() {
  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg shadow p-4 space-y-3">
      <div className="flex justify-between items-start">
        <div className="space-y-2 flex-1">
          <div className="flex items-center gap-2">
            <Skeleton width={60} height={20} rounded="rounded" />
            <SkeletonTitle width={150} />
          </div>
          <SkeletonText width="70%" />
          <SkeletonText width="40%" />
        </div>
        <Skeleton width={80} height={24} rounded="rounded-full" />
      </div>
      <div className="flex justify-between items-center pt-2 border-t dark:border-gray-700">
        <div className="flex gap-2">
          <Skeleton width={70} height={28} rounded="rounded-lg" />
          <Skeleton width={70} height={28} rounded="rounded-lg" />
        </div>
        <Skeleton width={100} height={28} rounded="rounded" />
      </div>
    </div>
  )
})

/**
 * Skeleton para lista de pedidos
 */
export const SkeletonPedidosList = memo(function SkeletonPedidosList({
  count = 5
}) {
  return (
    <div className="space-y-4">
      {Array.from({ length: count }).map((_, i) => (
        <SkeletonPedidoCard key={i} />
      ))}
    </div>
  )
})

/**
 * Skeleton para cards de estadísticas del dashboard
 */
export const SkeletonStatCard = memo(function SkeletonStatCard() {
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
 * Skeleton para el dashboard
 */
export const SkeletonDashboard = memo(function SkeletonDashboard() {
  return (
    <div className="space-y-6">
      {/* Stats Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-4 gap-4">
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
}) {
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
export const SkeletonListItem = memo(function SkeletonListItem() {
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
