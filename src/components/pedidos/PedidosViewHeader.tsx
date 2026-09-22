/**
 * Header del panel de Pedidos: envoltorio fino de `PageHeader` (#709).
 *
 *   OPERACIONES  ·  MARTES 22 DE ABRIL  ·  649 RESULTADOS
 *   Pedidos del día                         [actions]
 *
 * Lo único propio de Pedidos es cómo se arma el título: el sufijo ("del día /
 * del mes / para entregar hoy / …") sale de los filtros activos vía
 * `labelPeriodoPedidos`. El resto (crumb, cursiva del período con su
 * animación, "ACTUALIZANDO…" mientras carga) lo resuelve `PageHeader`.
 */
import React from 'react';
import type { FiltrosPedidosState } from '../../types';
import { labelPeriodoPedidos } from '../../utils/labelPeriodoPedidos';
import { formatDiaLargo } from '../../utils/periodo';
import PageHeader from '../layout/PageHeader';

export interface PedidosViewHeaderProps {
  filtros: FiltrosPedidosState;
  totalCount: number;
  loading: boolean;
  /** Slot derecha (típicamente PedidoToolbar). */
  actions?: React.ReactNode;
}

export default function PedidosViewHeader({
  filtros,
  totalCount,
  loading,
  actions,
}: PedidosViewHeaderProps): React.ReactElement {
  const now = React.useMemo(() => new Date(), []);
  const { verbo, periodo } = labelPeriodoPedidos(
    {
      fechaDesde: filtros.fechaDesde ?? null,
      fechaHasta: filtros.fechaHasta ?? null,
      fechaEntregaProgramada: filtros.fechaEntregaProgramada ?? null,
    },
    undefined,
    now,
  );

  // Con `loading`, PageHeader reemplaza este último crumb por "ACTUALIZANDO…".
  const resultados = `${totalCount.toLocaleString('es-AR')} ${totalCount === 1 ? 'RESULTADO' : 'RESULTADOS'}`;

  return (
    <PageHeader
      titulo={verbo}
      periodo={periodo}
      crumbs={['Operaciones', formatDiaLargo(now), resultados]}
      acciones={actions}
      loading={loading}
    />
  );
}
