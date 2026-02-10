/**
 * Barrel export para containers
 *
 * Cada container carga sus propios datos bajo demanda usando TanStack Query,
 * eliminando la necesidad de un "God Component" que cargue todo al inicio.
 */

export { default as DashboardContainer } from './DashboardContainer'
export { default as ProductosContainer } from './ProductosContainer'
export { default as ClientesContainer } from './ClientesContainer'
export { default as ComprasContainer } from './ComprasContainer'
export { default as ProveedoresContainer } from './ProveedoresContainer'
export { default as AnalyticsContainer } from './AnalyticsContainer'
