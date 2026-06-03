/**
 * ProductoToolbar
 *
 * Barra de acciones del panel /productos. Reemplaza los 6 botones inline
 * de colores variados que tenia VistaProductos.
 *
 * Estructura (admin):
 *   [ Catálogo ] [ Inventario ] [ Stock bajo (N) ] [ + Nuevo producto ]
 *
 * Filosofia: una sola accion saturada (verde primary). El resto neutral
 * con icono coloreado para mantener identidad sin saturar.
 */
import React from 'react';
import {
  Plus, ChevronDown, Tag, Package2, AlertTriangle,
  ArrowLeftRight, Percent, ClipboardCheck, TrendingDown, History,
  type LucideIcon,
} from 'lucide-react';
import {
  DropdownMenu, DropdownMenuTrigger, DropdownMenuContent,
  DropdownMenuItem, DropdownMenuLabel,
} from '../ui/DropdownMenu';
import { cn } from '../../lib/utils';

export interface ProductoToolbarProps {
  isAdmin: boolean;
  /**
   * Si el usuario puede controlar el stock (admin o encargado): habilita el
   * botón de stock bajo y la descarga del control de stock (Excel), sin
   * exponer el resto de acciones de catálogo/edición reservadas a admin.
   */
  puedeControlarStock?: boolean;
  productosStockBajoCount: number;
  onGestionarCategorias?: () => void;
  onCambioProducto?: () => void;
  onActualizacionMasivaPrecios?: () => void;
  onControlStock?: () => void;
  onVerAjustesStock?: () => void;
  onVerHistorialMermas?: () => void;
  onAbrirStockBajo?: () => void;
  onNuevoProducto?: () => void;
}

const BUTTON_BASE = cn(
  'inline-flex items-center gap-2.5 h-11 px-5 rounded-lg text-[14px] font-medium',
  'bg-white dark:bg-gray-800 text-stone-700 dark:text-gray-200',
  'border border-stone-200/80 dark:border-gray-700',
  'shadow-warm',
  'hover:bg-stone-50 dark:hover:bg-gray-700/50 hover:border-stone-300 dark:hover:border-gray-600 hover:-translate-y-px hover:shadow-warm-md',
  'active:translate-y-0 active:shadow-warm',
  'data-[state=open]:bg-stone-50 data-[state=open]:border-stone-300 data-[state=open]:shadow-warm-md dark:data-[state=open]:bg-gray-700/50',
  'transition-[transform,box-shadow,background-color,border-color] duration-150',
  'disabled:opacity-50 disabled:cursor-not-allowed disabled:hover:translate-y-0',
);

const TOOLBAR_ICON_SIZE = 'w-[18px] h-[18px]';

interface ToolbarDropdownProps {
  triggerIcon: LucideIcon;
  triggerIconClassName?: string;
  label: string;
  mobileLabel: string;
  children: React.ReactNode;
  menuClassName?: string;
}

function ToolbarDropdown({
  triggerIcon: TriggerIcon,
  triggerIconClassName = 'text-stone-500',
  label,
  mobileLabel,
  children,
  menuClassName = 'w-[min(18rem,calc(100vw-2rem))]',
}: ToolbarDropdownProps) {
  return (
    <DropdownMenu modal={false}>
      <DropdownMenuTrigger asChild>
        <button type="button" className={BUTTON_BASE}>
          <TriggerIcon className={cn(TOOLBAR_ICON_SIZE, 'flex-shrink-0', triggerIconClassName)} aria-hidden="true" />
          <span className="hidden sm:inline">{label}</span>
          <span className="sm:hidden">{mobileLabel}</span>
          <ChevronDown className="w-4 h-4 text-stone-400 dark:text-stone-500 flex-shrink-0 -mr-1" aria-hidden="true" />
        </button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className={menuClassName}>
        {children}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

function StockBajoButton({ count, onClick }: { count: number; onClick?: () => void }) {
  const hasItems = count > 0;
  return (
    <button
      type="button"
      onClick={hasItems ? onClick : undefined}
      disabled={!hasItems}
      className={cn(
        'inline-flex items-center gap-2 h-11 px-4 rounded-lg text-[14px] font-medium shadow-warm',
        'transition-[transform,box-shadow,background-color,border-color] duration-150',
        'hover:-translate-y-px hover:shadow-warm-md active:translate-y-0 active:shadow-warm',
        hasItems
          ? 'bg-amber-50 dark:bg-amber-900/15 text-amber-800 dark:text-amber-200 border border-amber-200/80 dark:border-amber-700/40 hover:bg-amber-100/80 dark:hover:bg-amber-900/25 hover:border-amber-300'
          : 'bg-white dark:bg-gray-800 text-stone-400 dark:text-stone-500 border border-stone-200/80 dark:border-gray-700 cursor-not-allowed hover:translate-y-0 hover:shadow-warm',
      )}
    >
      <AlertTriangle
        className={cn(TOOLBAR_ICON_SIZE, 'flex-shrink-0', hasItems ? 'text-amber-600' : 'text-stone-400')}
        aria-hidden="true"
      />
      <span className="hidden sm:inline">Stock bajo</span>
      <span className="sm:hidden">Stock</span>
      <span
        className={cn(
          'inline-flex items-center justify-center min-w-[1.5rem] h-5 px-1.5 rounded-full text-[11.5px] font-bold tabular-nums',
          hasItems
            ? 'bg-amber-200/70 dark:bg-amber-700/40 text-amber-800 dark:text-amber-200'
            : 'bg-stone-100 dark:bg-gray-700 text-stone-500',
        )}
      >
        {count}
      </span>
    </button>
  );
}

function PrimaryNewButton({ onClick, fullWidth = false }: { onClick: () => void; fullWidth?: boolean }) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        'group relative inline-flex items-center gap-2.5 h-11 px-6 rounded-lg text-[14px] font-semibold',
        'text-white',
        'bg-gradient-to-br from-green-500 to-green-600',
        'shadow-[0_2px_8px_-2px_rgb(34_197_94/0.45),inset_0_1px_0_rgb(255_255_255/0.12)]',
        'hover:from-green-500 hover:to-green-700 hover:-translate-y-px hover:shadow-[0_6px_16px_-4px_rgb(34_197_94/0.55),inset_0_1px_0_rgb(255_255_255/0.18)]',
        'active:translate-y-0 active:shadow-[0_2px_4px_-2px_rgb(34_197_94/0.4)]',
        'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-green-500/40 focus-visible:ring-offset-2 focus-visible:ring-offset-stone-50 dark:focus-visible:ring-offset-gray-900',
        'transition-[transform,box-shadow,background] duration-200',
        fullWidth && 'w-full justify-center',
      )}
    >
      <span
        className="absolute inset-0 rounded-lg bg-gradient-to-br from-white/10 to-transparent opacity-0 group-hover:opacity-100 transition-opacity duration-200 pointer-events-none"
        aria-hidden="true"
      />
      <Plus className={cn('relative', TOOLBAR_ICON_SIZE)} aria-hidden="true" />
      <span className="relative">Nuevo producto</span>
    </button>
  );
}

export default function ProductoToolbar({
  isAdmin,
  puedeControlarStock = false,
  productosStockBajoCount,
  onGestionarCategorias,
  onCambioProducto,
  onActualizacionMasivaPrecios,
  onControlStock,
  onVerAjustesStock,
  onVerHistorialMermas,
  onAbrirStockBajo,
  onNuevoProducto,
}: ProductoToolbarProps): React.ReactElement | null {
  const hayCatálogo = isAdmin && (
    Boolean(onGestionarCategorias) || Boolean(onCambioProducto) || Boolean(onActualizacionMasivaPrecios)
  );
  // Control de stock (Excel) lo ve admin y encargado; el historial de mermas
  // sigue siendo solo admin.
  const mostrarControlStock = puedeControlarStock && Boolean(onControlStock);
  const mostrarAjustesStock = puedeControlarStock && Boolean(onVerAjustesStock);
  const mostrarHistorialMermas = isAdmin && Boolean(onVerHistorialMermas);
  const hayInventario = mostrarControlStock || mostrarAjustesStock || mostrarHistorialMermas;
  const hayStockBajo = puedeControlarStock;
  const hayNuevo = isAdmin && Boolean(onNuevoProducto);

  if (!hayCatálogo && !hayInventario && !hayStockBajo && !hayNuevo) {
    return null;
  }

  // Dropdowns reusados en ambos layouts (mobile y desktop).
  const catalogoDropdown = hayCatálogo && (
    <ToolbarDropdown triggerIcon={Tag} label="Catálogo" mobileLabel="Catálogo">
      <DropdownMenuLabel>Catálogo</DropdownMenuLabel>
      {onGestionarCategorias && (
        <DropdownMenuItem onSelect={onGestionarCategorias}>
          <Tag className="w-4 h-4 text-purple-600" />
          <span>Categorías</span>
        </DropdownMenuItem>
      )}
      {onCambioProducto && (
        <DropdownMenuItem onSelect={onCambioProducto}>
          <ArrowLeftRight className="w-4 h-4 text-indigo-600" />
          <span>Cambio de productos</span>
        </DropdownMenuItem>
      )}
      {onActualizacionMasivaPrecios && (
        <DropdownMenuItem onSelect={onActualizacionMasivaPrecios}>
          <Percent className="w-4 h-4 text-indigo-600" />
          <span>Actualización masiva de precios</span>
        </DropdownMenuItem>
      )}
    </ToolbarDropdown>
  );

  const inventarioDropdown = hayInventario && (
    <ToolbarDropdown triggerIcon={Package2} label="Inventario" mobileLabel="Inventario">
      <DropdownMenuLabel>Inventario</DropdownMenuLabel>
      {mostrarControlStock && onControlStock && (
        <DropdownMenuItem onSelect={onControlStock}>
          <ClipboardCheck className="w-4 h-4 text-amber-600" />
          <div className="flex flex-col gap-0.5 min-w-0">
            <span className="font-medium">Control de stock</span>
            <span className="text-xs text-stone-500 dark:text-gray-400">
              Descargar o cargar planilla de inventario
            </span>
          </div>
        </DropdownMenuItem>
      )}
      {mostrarAjustesStock && onVerAjustesStock && (
        <DropdownMenuItem onSelect={onVerAjustesStock}>
          <History className="w-4 h-4 text-indigo-600" />
          <div className="flex flex-col gap-0.5 min-w-0">
            <span className="font-medium">Ajustes de stock</span>
            <span className="text-xs text-stone-500 dark:text-gray-400">
              Histórico de ajustes por planilla
            </span>
          </div>
        </DropdownMenuItem>
      )}
      {mostrarHistorialMermas && onVerHistorialMermas && (
        <DropdownMenuItem onSelect={onVerHistorialMermas}>
          <TrendingDown className="w-4 h-4 text-rose-600" />
          <span>Historial de mermas</span>
        </DropdownMenuItem>
      )}
    </ToolbarDropdown>
  );

  const stockBajoBtn = hayStockBajo && (
    <StockBajoButton count={productosStockBajoCount} onClick={onAbrirStockBajo} />
  );

  return (
    <>
      {/* ╔══ MOBILE (<sm): grid 3-col + primary full-width abajo ══╗ */}
      <div className="flex flex-col gap-2 sm:hidden">
        <div className="grid grid-cols-3 gap-1.5 [&>*]:w-full [&>*]:justify-center [&>*]:px-2">
          {catalogoDropdown}
          {inventarioDropdown}
          {stockBajoBtn}
        </div>
        {hayNuevo && onNuevoProducto && <PrimaryNewButton onClick={onNuevoProducto} fullWidth />}
      </div>

      {/* ╔══ DESKTOP (sm+): layout original ══╗ */}
      <div className="hidden sm:flex items-center gap-2 justify-end flex-wrap">
        {catalogoDropdown}
        {inventarioDropdown}
        {stockBajoBtn}
        {hayNuevo && onNuevoProducto && <PrimaryNewButton onClick={onNuevoProducto} />}
      </div>
    </>
  );
}
