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
import { Button } from '../ui/Button';

export interface DashboardToolbarProps {
  loading: boolean;
  exportando: boolean;
  isAdmin: boolean;
  onRefetch: () => void;
  onDescargarBackup: (tipo: string) => Promise<void>;
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
        <Button
          type="button"
          variant="hero"
          size="lg"
          onClick={() => onDescargarBackup('completo')}
          disabled={exportando}
          className="group relative gap-2.5 active:translate-y-0"
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
        </Button>
      )}
    </div>
  );
}
