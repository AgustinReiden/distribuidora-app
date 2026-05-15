/**
 * DashboardToolbar
 *
 * Barra de acciones del Dashboard. Mantiene exactamente las mismas
 * acciones que el original ("Actualizar" para todos, "Backup" para admin),
 * pero las refunde con la estética cálida (stone + warm shadow) que se
 * aplicó en /pedidos y /productos.
 *
 * Cantidad de botones es chica (1-2), así que no hay agrupación en
 * dropdowns — solo botones directos.
 */
import React from 'react';
import { RefreshCw, Download } from 'lucide-react';
import { cn } from '../../lib/utils';

export interface DashboardToolbarProps {
  loading: boolean;
  exportando: boolean;
  isAdmin: boolean;
  onRefetch: () => void;
  onDescargarBackup: (tipo: string) => void;
}

const BUTTON_BASE = cn(
  'inline-flex items-center gap-2.5 h-11 px-5 rounded-lg text-[14px] font-medium',
  'bg-white dark:bg-gray-800 text-stone-700 dark:text-gray-200',
  'border border-stone-200/80 dark:border-gray-700',
  'shadow-warm',
  'hover:bg-stone-50 dark:hover:bg-gray-700/50 hover:border-stone-300 dark:hover:border-gray-600 hover:-translate-y-px hover:shadow-warm-md',
  'active:translate-y-0 active:shadow-warm',
  'transition-[transform,box-shadow,background-color,border-color] duration-150',
  'disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:translate-y-0',
);

const TOOLBAR_ICON_SIZE = 'w-[18px] h-[18px]';

export default function DashboardToolbar({
  loading,
  exportando,
  isAdmin,
  onRefetch,
  onDescargarBackup,
}: DashboardToolbarProps): React.ReactElement {
  return (
    <div className="flex items-center gap-2 justify-end flex-wrap">
      <button
        type="button"
        onClick={onRefetch}
        disabled={loading}
        className={BUTTON_BASE}
        aria-label="Actualizar datos"
      >
        <RefreshCw
          className={cn(TOOLBAR_ICON_SIZE, 'flex-shrink-0 text-blue-600', loading && 'animate-spin')}
          aria-hidden="true"
        />
        <span>Actualizar</span>
      </button>

      {isAdmin && (
        <button
          type="button"
          onClick={() => onDescargarBackup('completo')}
          disabled={exportando}
          className={cn(
            'group relative inline-flex items-center gap-2.5 h-11 px-6 rounded-lg text-[14px] font-semibold text-white',
            'bg-gradient-to-br from-green-500 to-green-600',
            'shadow-[0_2px_8px_-2px_rgb(34_197_94/0.45),inset_0_1px_0_rgb(255_255_255/0.12)]',
            'hover:from-green-500 hover:to-green-700 hover:-translate-y-px hover:shadow-[0_6px_16px_-4px_rgb(34_197_94/0.55),inset_0_1px_0_rgb(255_255_255/0.18)]',
            'active:translate-y-0 active:shadow-[0_2px_4px_-2px_rgb(34_197_94/0.4)]',
            'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-500/40 focus-visible:ring-offset-2 focus-visible:ring-offset-stone-50 dark:focus-visible:ring-offset-gray-900',
            'transition-[transform,box-shadow,background] duration-200',
            'disabled:opacity-60 disabled:cursor-not-allowed',
          )}
          aria-label="Descargar backup"
        >
          <span
            className="absolute inset-0 rounded-lg bg-gradient-to-br from-white/10 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-200 pointer-events-none"
            aria-hidden="true"
          />
          <Download className={cn('relative', TOOLBAR_ICON_SIZE)} aria-hidden="true" />
          <span className="relative">
            <span className="hidden sm:inline">{exportando ? 'Generando…' : 'Backup'}</span>
            <span className="sm:hidden">{exportando ? '…' : 'Backup'}</span>
          </span>
        </button>
      )}
    </div>
  );
}
