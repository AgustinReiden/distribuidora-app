/**
 * Header del panel de Productos.
 *
 * Estructura visual paralela a PedidosViewHeader (editorial cálido):
 *
 *   ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
 *   CATÁLOGO  ✦  JUEVES 15 DE MAYO  ✦  90 PRODUCTOS
 *
 *   Productos de Manaos                         [actions]
 *   ───
 *
 * El período se deriva con `labelCategoriaProductos` según los filtros activos
 * (categoría, búsqueda, stock bajo).
 */
import React from 'react';
import { labelCategoriaProductos } from '../../utils/labelCategoriaProductos';

export interface ProductosViewHeaderProps {
  busqueda: string;
  categoriaSeleccionada: string;
  mostrarSoloStockBajo: boolean;
  totalCount: number;
  loading: boolean;
  /** Slot derecha (típicamente ProductoToolbar). */
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

export default function ProductosViewHeader({
  busqueda,
  categoriaSeleccionada,
  mostrarSoloStockBajo,
  totalCount,
  loading,
  actions,
}: ProductosViewHeaderProps): React.ReactElement {
  const now = React.useMemo(() => new Date(), []);
  const diaLargo = formatDiaLargo(now);
  const { verbo, periodo } = labelCategoriaProductos({
    busqueda,
    categoriaSeleccionada,
    mostrarSoloStockBajo,
  });

  const resultadosLabel = loading
    ? 'ACTUALIZANDO…'
    : `${totalCount.toLocaleString('es-AR')} ${totalCount === 1 ? 'PRODUCTO' : 'PRODUCTOS'}`;

  return (
    <header className="flex flex-col sm:flex-row sm:items-end sm:justify-between gap-4 pb-1">
      <div className="min-w-0 flex-1">
        {/* Crumb editorial con separadores decorativos */}
        <p className="text-[10.5px] sm:text-xs font-semibold tracking-[0.18em] text-stone-500 dark:text-stone-400 uppercase flex items-center flex-wrap">
          <span>Catálogo</span>
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
                key={periodo}
                className="font-light italic text-stone-500 dark:text-stone-400 inline-block animate-[fadeSlideIn_300ms_ease-out]"
                style={{ letterSpacing: '-0.02em' }}
              >
                {periodo}
              </em>
            </>
          )}
        </h1>

        {/* Acento decorativo: línea pequeña debajo del título */}
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
