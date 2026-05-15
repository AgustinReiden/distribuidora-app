/**
 * Header del panel Dashboard.
 *
 * Estructura visual paralela a PedidosViewHeader / ProductosViewHeader:
 *
 *   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
 *   DASHBOARD  ✦  VIERNES 15 DE MAYO  ✦  ESTE MES
 *
 *   Resumen del mes                              [actions]
 *   ───
 *
 * El período se deriva con `labelPeriodoDashboard`.
 */
import React from 'react';
import { labelPeriodoDashboard, type FiltroPeriodoDashboard } from '../../utils/labelPeriodoDashboard';

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

const DIAS_SEMANA = [
  'DOMINGO', 'LUNES', 'MARTES', 'MIÉRCOLES', 'JUEVES', 'VIERNES', 'SÁBADO',
] as const;

const MESES = [
  'ENERO', 'FEBRERO', 'MARZO', 'ABRIL', 'MAYO', 'JUNIO',
  'JULIO', 'AGOSTO', 'SEPTIEMBRE', 'OCTUBRE', 'NOVIEMBRE', 'DICIEMBRE',
] as const;

function formatDiaLargo(now: Date): string {
  return `${DIAS_SEMANA[now.getDay()]} ${now.getDate()} DE ${MESES[now.getMonth()]}`;
}

function CrumbDot() {
  return (
    <span
      className="inline-block w-1 h-1 rounded-full bg-amber-500/70 align-middle mx-2.5"
      aria-hidden="true"
    />
  );
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
  const diaLargo = formatDiaLargo(now);
  const { verbo: verboFinal, periodo } = labelPeriodoDashboard(
    { filtroPeriodo, fechaDesde, fechaHasta },
    verbo,
  );

  const periodoCrumb = loading ? 'ACTUALIZANDO…' : periodoLabel.toUpperCase();

  return (
    <header className="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4 pb-1">
      <div className="min-w-0 flex-1">
        {/* Crumb editorial con separadores decorativos */}
        <p className="text-[10.5px] sm:text-xs font-semibold tracking-[0.18em] text-stone-500 dark:text-stone-400 uppercase flex items-center flex-wrap">
          <span>Dashboard</span>
          <CrumbDot />
          <span>{diaLargo}</span>
          <CrumbDot />
          <span className={loading ? 'animate-pulse' : ''}>{periodoCrumb}</span>
        </p>

        {/* Título editorial con período en cursiva */}
        <h1
          className="mt-2 text-3xl sm:text-4xl text-stone-900 dark:text-white leading-[1.05]"
          style={{ fontWeight: 800, letterSpacing: '-0.035em' }}
        >
          <span className="bg-clip-text text-transparent bg-gradient-to-br from-stone-900 to-stone-700 dark:from-white dark:to-stone-300">
            {verboFinal}
          </span>
          {periodo && (
            <>
              {' '}
              <em
                key={periodo}
                className="font-light italic text-stone-500 dark:text-stone-400 inline-block animate-[fadeSlideIn_300ms_ease-out]"
                style={{ letterSpacing: '-0.02em' }}
              >
                {periodo}
              </em>
            </>
          )}
        </h1>

        {/* Acento decorativo */}
        <div
          className="mt-3 h-[2px] w-12 rounded-full bg-gradient-to-r from-blue-600 via-blue-500 to-transparent dark:from-blue-400 dark:via-blue-500"
          aria-hidden="true"
        />
      </div>

      {actions && (
        <div className="flex-shrink-0 sm:max-w-[60%]">
          {actions}
        </div>
      )}
    </header>
  );
}
