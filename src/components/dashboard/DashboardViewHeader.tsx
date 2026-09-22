/**
 * Header del panel Dashboard: envoltorio fino de `PageHeader` (#709).
 *
 *   DASHBOARD  ·  VIERNES 15 DE MAYO  ·  ESTE MES
 *   Resumen del mes                              [actions]
 *
 * El título se deriva con `labelPeriodoDashboard`; el tercer crumb no es un
 * conteo sino la etiqueta del período elegido (`periodoLabel`), en mayúsculas.
 */
import React from 'react';
import { labelPeriodoDashboard, type FiltroPeriodoDashboard } from '../../utils/labelPeriodoDashboard';
import { formatDiaLargo } from '../../utils/periodo';
import PageHeader from '../layout/PageHeader';

export interface DashboardViewHeaderProps {
  filtroPeriodo: FiltroPeriodoDashboard;
  fechaDesde?: string | null;
  fechaHasta?: string | null;
  /** 'Resumen' (admin) o 'Mis métricas' (preventista) */
  verbo?: string;
  /** Texto del crumb superior derecho ("Este mes", "Hoy", etc.) */
  periodoLabel: string;
  loading: boolean;
  actions?: React.ReactNode;
}

export default function DashboardViewHeader({
  filtroPeriodo,
  fechaDesde,
  fechaHasta,
  verbo = 'Resumen',
  periodoLabel,
  loading,
  actions,
}: DashboardViewHeaderProps): React.ReactElement {
  const now = React.useMemo(() => new Date(), []);
  const { verbo: verboFinal, periodo } = labelPeriodoDashboard(
    { filtroPeriodo, fechaDesde, fechaHasta },
    verbo,
  );

  return (
    <PageHeader
      titulo={verboFinal}
      periodo={periodo}
      // Con `loading`, PageHeader reemplaza este último crumb por "ACTUALIZANDO…".
      crumbs={['Dashboard', formatDiaLargo(now), periodoLabel.toUpperCase()]}
      acciones={actions}
      loading={loading}
    />
  );
}
