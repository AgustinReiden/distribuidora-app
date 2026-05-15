/**
 * Header del panel de Clientes.
 *
 * Estructura visual (editorial cálido, gemela a PedidosViewHeader):
 *
 *   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
 *   CARTERA  ✦  MARTES 22 DE ABRIL  ✦  649 CLIENTES
 *
 *   Clientes con deuda                         [actions]
 *   ───
 *
 * El sufijo dinámico ("con deuda / al día / del rubro X / ...") refleja los
 * filtros activos y se anima al cambiar.
 */
import React from 'react';

export interface ClientesViewHeaderProps {
  totalClientes: number;
  loading: boolean;
  /** Sufijo descriptivo opcional (italic). Ej: "con deuda", "del rubro Almacén". */
  filtroDescriptivo?: string | null;
  /** Slot derecha (típicamente botones de acción). */
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

/** Rombito amber sutil entre items del crumb. */
function CrumbDot() {
  return (
    <span
      className="inline-block w-1 h-1 rounded-full bg-amber-500/70 align-middle mx-2.5"
      aria-hidden="true"
    />
  );
}

export default function ClientesViewHeader({
  totalClientes,
  loading,
  filtroDescriptivo,
  actions,
}: ClientesViewHeaderProps): React.ReactElement {
  const now = React.useMemo(() => new Date(), []);
  const diaLargo = formatDiaLargo(now);

  const resultadosLabel = loading
    ? 'ACTUALIZANDO…'
    : `${totalClientes.toLocaleString('es-AR')} ${totalClientes === 1 ? 'CLIENTE' : 'CLIENTES'}`;

  return (
    <header className="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4 pb-1">
      <div className="min-w-0 flex-1">
        <p className="text-[10.5px] sm:text-xs font-semibold tracking-[0.18em] text-stone-500 dark:text-stone-400 uppercase flex items-center flex-wrap">
          <span>Cartera</span>
          <CrumbDot />
          <span>{diaLargo}</span>
          <CrumbDot />
          <span className={loading ? 'animate-pulse' : ''}>{resultadosLabel}</span>
        </p>

        <h1
          className="mt-2 text-3xl sm:text-4xl text-stone-900 dark:text-white leading-[1.05]"
          style={{ fontWeight: 800, letterSpacing: '-0.035em' }}
        >
          <span className="bg-clip-text text-transparent bg-gradient-to-br from-stone-900 to-stone-700 dark:from-white dark:to-stone-300">
            Clientes
          </span>
          {filtroDescriptivo && (
            <>
              {' '}
              <em
                key={filtroDescriptivo}
                className="font-light italic text-stone-500 dark:text-stone-400 inline-block animate-[fadeSlideIn_300ms_ease-out]"
                style={{ letterSpacing: '-0.02em' }}
              >
                {filtroDescriptivo}
              </em>
            </>
          )}
        </h1>

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
