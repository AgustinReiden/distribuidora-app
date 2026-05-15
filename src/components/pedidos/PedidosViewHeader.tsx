/**
 * Header del panel de Pedidos.
 *
 * Estructura visual (editorial cálido):
 *
 *   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
 *   OPERACIONES  ✦  MARTES 22 DE ABRIL  ✦  649 RESULTADOS
 *
 *   Pedidos del día                         [actions]
 *   ───
 *
 * El sufijo dinámico ("del día / del mes / para entregar hoy / ...") se
 * deriva de los filtros activos (ver labelPeriodoPedidos).
 *
 * El verbo "Pedidos" usa peso 800 con kerning negativo para sentirse
 * editorial y compacto; el período usa cursiva italic real con un color
 * cálido (stone-500) para diferenciarse sin gritar.
 */
import React from 'react';
import type { FiltrosPedidosState } from '../../types';
import { labelPeriodoPedidos } from '../../utils/labelPeriodoPedidos';

export interface PedidosViewHeaderProps {
  filtros: FiltrosPedidosState;
  totalCount: number;
  loading: boolean;
  /** Slot derecha (típicamente PedidoToolbar). */
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

/** Separador decorativo del crumb: un pequeño rombo en amber sutil que
 *  rompe la monotonía sin gritar. */
function CrumbDot() {
  return (
    <span
      className="inline-block w-1 h-1 rounded-full bg-amber-500/70 align-middle mx-2.5"
      aria-hidden="true"
    />
  );
}

export default function PedidosViewHeader({
  filtros,
  totalCount,
  loading,
  actions,
}: PedidosViewHeaderProps): React.ReactElement {
  const now = React.useMemo(() => new Date(), []);
  const diaLargo = formatDiaLargo(now);
  const { verbo, periodo } = labelPeriodoPedidos(
    {
      fechaDesde: filtros.fechaDesde ?? null,
      fechaHasta: filtros.fechaHasta ?? null,
      fechaEntregaProgramada: filtros.fechaEntregaProgramada ?? null,
    },
    undefined,
    now,
  );

  const resultadosLabel = loading
    ? 'ACTUALIZANDO…'
    : `${totalCount.toLocaleString('es-AR')} ${totalCount === 1 ? 'RESULTADO' : 'RESULTADOS'}`;

  return (
    <header className="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4 pb-1">
      <div className="min-w-0 flex-1">
        {/* Crumb editorial con separadores decorativos */}
        <p className="text-[10.5px] sm:text-xs font-semibold tracking-[0.18em] text-stone-500 dark:text-stone-400 uppercase flex items-center flex-wrap">
          <span>Operaciones</span>
          <CrumbDot />
          <span>{diaLargo}</span>
          <CrumbDot />
          <span className={loading ? 'animate-pulse' : ''}>{resultadosLabel}</span>
        </p>

        {/* Título editorial con período en cursiva */}
        <h1
          className="mt-2 text-3xl sm:text-4xl text-stone-900 dark:text-white leading-[1.05]"
          style={{ fontWeight: 800, letterSpacing: '-0.035em' }}
        >
          <span className="bg-clip-text text-transparent bg-gradient-to-br from-stone-900 to-stone-700 dark:from-white dark:to-stone-300">
            {verbo}
          </span>
          {periodo && (
            <>
              {' '}
              <em
                key={periodo /* trigger re-mount → fade animation cuando cambia */}
                className="font-light italic text-stone-500 dark:text-stone-400 inline-block animate-[fadeSlideIn_300ms_ease-out]"
                style={{ letterSpacing: '-0.02em' }}
              >
                {periodo}
              </em>
            </>
          )}
        </h1>

        {/* Acento decorativo: línea pequeña debajo del título.
            Gradiente sutil de azul a transparente, evoca un subrayado editorial. */}
        <div
          className="mt-3 h-[2px] w-12 rounded-full bg-gradient-to-r from-blue-600 via-blue-500 to-transparent dark:from-blue-400 dark:via-blue-500"
          aria-hidden="true"
        />
      </div>

      {actions && (
        <div className="flex-shrink-0 sm:max-w-[62%]">
          {actions}
        </div>
      )}
    </header>
  );
}
