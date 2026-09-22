/**
 * Header del panel de Productos: envoltorio fino de `PageHeader` (#709).
 *
 *   CATÁLOGO  ·  JUEVES 15 DE MAYO  ·  90 PRODUCTOS
 *   Productos de Manaos                         [actions]
 *
 * El sufijo del título se deriva con `labelCategoriaProductos` según los
 * filtros activos (categoría, búsqueda, stock bajo).
 */
import React from 'react';
import { labelCategoriaProductos } from '../../utils/labelCategoriaProductos';
import { formatDiaLargo } from '../../utils/periodo';
import PageHeader from '../layout/PageHeader';

export interface ProductosViewHeaderProps {
  busqueda: string;
  categoriaSeleccionada: string;
  mostrarSoloStockBajo: boolean;
  totalCount: number;
  loading: boolean;
  /** Slot derecha (típicamente ProductoToolbar). */
  actions?: React.ReactNode;
}

export default function ProductosViewHeader({
  busqueda,
  categoriaSeleccionada,
  mostrarSoloStockBajo,
  totalCount,
  loading,
  actions,
}: ProductosViewHeaderProps): React.ReactElement {
  const now = React.useMemo(() => new Date(), []);
  const { verbo, periodo } = labelCategoriaProductos({
    busqueda,
    categoriaSeleccionada,
    mostrarSoloStockBajo,
  });

  // Con `loading`, PageHeader reemplaza este último crumb por "ACTUALIZANDO…".
  const conteo = `${totalCount.toLocaleString('es-AR')} ${totalCount === 1 ? 'PRODUCTO' : 'PRODUCTOS'}`;

  return (
    <PageHeader
      titulo={verbo}
      periodo={periodo}
      crumbs={['Catálogo', formatDiaLargo(now), conteo]}
      acciones={actions}
      loading={loading}
    />
  );
}
