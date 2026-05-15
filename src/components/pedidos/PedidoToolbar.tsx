/**
 * PedidoToolbar
 *
 * Barra de acciones del panel /pedidos.
 *
 * Diseño (consensuado con usuario):
 *   Admin/Encargado:
 *     [ Acciones masivas ▾ ] [ Exportaciones ▾ ] [ Optimizar Ruta ] [ Nuevo pedido ]
 *
 *     Donde "Acciones masivas" agrupa: Asignar Transportista, Pagos Masivos,
 *     Entregas Masivas. Y "Exportaciones" agrupa: Excel, PDF. Cada opción
 *     dentro del dropdown mantiene su icono coloreado individual.
 *
 *   Preventista:
 *     [ Visitas del día ] [ Marcar visita ] [ Nuevo pedido ]
 *
 *     (Son sólo 2 acciones contextuales, no justifica agruparlas en dropdown.)
 *
 * "Nuevo pedido" es la única acción con fondo de color saturado (verde).
 * Todo lo demás es botón neutral con icono coloreado para mantener
 * identidad sin caer en el carnaval de fondos.
 */
import React from 'react';
import {
  Plus, Route, FileDown, PackageCheck, Banknote, ChevronDown, Truck,
  MapPin, History, Boxes, Download, type LucideIcon,
} from 'lucide-react';
import {
  DropdownMenu, DropdownMenuTrigger, DropdownMenuContent,
  DropdownMenuItem, DropdownMenuLabel,
} from '../ui/DropdownMenu';
import { cn } from '../../lib/utils';

// =============================================================================
// PROPS
// =============================================================================

export interface PedidoToolbarProps {
  isAdmin: boolean;
  isEncargado?: boolean;
  isPreventista: boolean;
  exportando: boolean;
  totalCount: number;
  onNuevoPedido: () => void;
  onOptimizarRuta: () => void;
  onExportarPDF: () => void;
  onExportarExcel: (modo: 'pagina' | 'filtro') => void;
  onEntregasMasivas?: () => void;
  onPagosMasivos?: () => void;
  onAsignarTransportistaMasivo?: () => void;
  onMarcarVisita?: () => void;
  onVerVisitasHoy?: () => void;
}

// =============================================================================
// HELPERS LOCALES
// =============================================================================

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

/** Tamaño de iconos en la toolbar: levemente más grandes que el default
 *  (18px en vez de 16px) para que respiren con los botones h-11. */
const TOOLBAR_ICON_SIZE = 'w-[18px] h-[18px]';

interface ToolbarButtonProps extends React.ButtonHTMLAttributes<HTMLButtonElement> {
  icon: LucideIcon;
  iconClassName?: string;
  /** Label corto para mobile (`<sm`). Si no se provee, se usa `children`. */
  mobileLabel?: string;
}

const ToolbarButton = React.forwardRef<HTMLButtonElement, ToolbarButtonProps>(
  ({ icon: Icon, iconClassName, mobileLabel, className, children, ...props }, ref) => (
    <button ref={ref} type="button" {...props} className={cn(BUTTON_BASE, className)}>
      <Icon className={cn(TOOLBAR_ICON_SIZE, 'flex-shrink-0', iconClassName)} aria-hidden="true" />
      {mobileLabel ? (
        <>
          <span className="hidden sm:inline">{children}</span>
          <span className="sm:hidden">{mobileLabel}</span>
        </>
      ) : (
        <span>{children}</span>
      )}
    </button>
  ),
);
ToolbarButton.displayName = 'ToolbarButton';

interface ToolbarDropdownProps {
  triggerIcon: LucideIcon;
  triggerIconClassName?: string;
  label: string;
  mobileLabel: string;
  children: React.ReactNode;
  /** Ancho del menú; default: w-60 */
  menuClassName?: string;
}

function ToolbarDropdown({
  triggerIcon: TriggerIcon,
  triggerIconClassName = 'text-stone-500',
  label,
  mobileLabel,
  children,
  menuClassName = 'w-[min(16rem,calc(100vw-2rem))]',
}: ToolbarDropdownProps) {
  return (
    // modal={false} evita que Radix bloquee el scroll del body al abrir,
    // lo que estaba causando un layout shift visible (~15px) en el header
    // y el resto del contenido cuando se desplegaba la lista. En una toolbar
    // dropdown no necesitamos focus trap completo; el cierre por outside-click
    // y Escape siguen funcionando.
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

/**
 * Botón primario verde para "Nuevo pedido". Único color de fondo saturado
 * en toda la toolbar.
 */
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
      <span className="relative">Nuevo pedido</span>
    </button>
  );
}

// =============================================================================
// MAIN
// =============================================================================

export default function PedidoToolbar({
  isAdmin,
  isEncargado,
  isPreventista,
  exportando,
  totalCount,
  onNuevoPedido,
  onOptimizarRuta,
  onExportarPDF,
  onExportarExcel,
  onEntregasMasivas,
  onPagosMasivos,
  onAsignarTransportistaMasivo,
  onMarcarVisita,
  onVerVisitasHoy,
}: PedidoToolbarProps): React.ReactElement {
  const canCreate = isAdmin || isEncargado || isPreventista;
  const showOpsGroups = isAdmin || isEncargado;
  const showPreventistaActions = isPreventista && !isAdmin && !isEncargado;

  // ¿Hay al menos una acción masiva habilitada? (para mostrar el dropdown)
  const hasMasivas = Boolean(
    onAsignarTransportistaMasivo || onPagosMasivos || onEntregasMasivas,
  );

  // Dropdowns "Acciones masivas" y "Exportaciones" — reusados en ambos layouts.
  const masivasDropdown = hasMasivas && (
    <ToolbarDropdown
      triggerIcon={Boxes}
      label="Acciones masivas"
      mobileLabel="Masivas"
    >
      <DropdownMenuLabel>Acciones masivas</DropdownMenuLabel>
      {onAsignarTransportistaMasivo && (
        <DropdownMenuItem onSelect={onAsignarTransportistaMasivo}>
          <Truck className="w-4 h-4 text-blue-600" />
          <span>Asignar Transportista</span>
        </DropdownMenuItem>
      )}
      {onPagosMasivos && (
        <DropdownMenuItem onSelect={onPagosMasivos}>
          <Banknote className="w-4 h-4 text-green-600" />
          <span>Pagos Masivos</span>
        </DropdownMenuItem>
      )}
      {onEntregasMasivas && (
        <DropdownMenuItem onSelect={onEntregasMasivas}>
          <PackageCheck className="w-4 h-4 text-teal-600" />
          <span>Entregas Masivas</span>
        </DropdownMenuItem>
      )}
    </ToolbarDropdown>
  );

  const exportarDropdown = (
    <ToolbarDropdown
      triggerIcon={Download}
      label="Exportaciones"
      mobileLabel="Exportar"
      menuClassName="w-[min(18rem,calc(100vw-2rem))]"
    >
      <DropdownMenuLabel>Exportaciones</DropdownMenuLabel>
      <DropdownMenuItem
        onSelect={() => onExportarExcel('pagina')}
        disabled={exportando}
      >
        <FileDown className="w-4 h-4 text-emerald-600" />
        <div className="flex flex-col gap-0.5 min-w-0">
          <span className="font-medium">Excel — Página actual</span>
          <span className="text-xs text-stone-500 dark:text-gray-400">
            Solo los pedidos visibles
          </span>
        </div>
      </DropdownMenuItem>
      <DropdownMenuItem
        onSelect={() => onExportarExcel('filtro')}
        disabled={exportando}
      >
        <FileDown className="w-4 h-4 text-emerald-600" />
        <div className="flex flex-col gap-0.5 min-w-0">
          <span className="font-medium">
            Excel — Filtro actual ({totalCount.toLocaleString('es-AR')})
          </span>
          <span className="text-xs text-stone-500 dark:text-gray-400">
            Todos los pedidos que coinciden
          </span>
        </div>
      </DropdownMenuItem>
      <DropdownMenuItem onSelect={onExportarPDF}>
        <FileDown className="w-4 h-4 text-rose-600" />
        <span>PDF</span>
      </DropdownMenuItem>
    </ToolbarDropdown>
  );

  return (
    <>
      {/* ╔══ MOBILE (<sm): grid 3-col arriba + primary full-width abajo ══╗ */}
      <div className="flex flex-col gap-2 sm:hidden">
        {showOpsGroups && (
          <div className="grid grid-cols-3 gap-1.5 [&>*]:w-full [&>*]:justify-center [&>*]:px-2">
            {masivasDropdown}
            {exportarDropdown}
            <ToolbarButton
              icon={Route}
              iconClassName="text-blue-600"
              mobileLabel="Ruta"
              onClick={onOptimizarRuta}
            >
              Optimizar Ruta
            </ToolbarButton>
          </div>
        )}

        {showPreventistaActions && (
          <div className="grid grid-cols-2 gap-1.5 [&>*]:w-full [&>*]:justify-center [&>*]:px-2">
            {onVerVisitasHoy && (
              <ToolbarButton
                icon={History}
                iconClassName="text-stone-500"
                mobileLabel="Visitas"
                onClick={onVerVisitasHoy}
                title="Ver clientes que visitaste hoy"
              >
                Visitas del día
              </ToolbarButton>
            )}
            {onMarcarVisita && (
              <ToolbarButton
                icon={MapPin}
                iconClassName="text-indigo-600"
                mobileLabel="Marcar"
                onClick={onMarcarVisita}
                title="Marcar visita a un cliente sin necesidad de cargar pedido"
              >
                Marcar visita
              </ToolbarButton>
            )}
          </div>
        )}

        {canCreate && <PrimaryNewButton onClick={onNuevoPedido} fullWidth />}
      </div>

      {/* ╔══ DESKTOP (sm+): layout original — fila a la derecha ══╗ */}
      <div className="hidden sm:flex items-center gap-2 justify-end flex-wrap">
        {showOpsGroups && (
          <>
            {masivasDropdown}
            {exportarDropdown}
            <ToolbarButton
              icon={Route}
              iconClassName="text-blue-600"
              mobileLabel="Ruta"
              onClick={onOptimizarRuta}
            >
              Optimizar Ruta
            </ToolbarButton>
          </>
        )}

        {showPreventistaActions && (
          <>
            {onVerVisitasHoy && (
              <ToolbarButton
                icon={History}
                iconClassName="text-stone-500"
                mobileLabel="Visitas"
                onClick={onVerVisitasHoy}
                title="Ver clientes que visitaste hoy"
              >
                Visitas del día
              </ToolbarButton>
            )}
            {onMarcarVisita && (
              <ToolbarButton
                icon={MapPin}
                iconClassName="text-indigo-600"
                mobileLabel="Marcar"
                onClick={onMarcarVisita}
                title="Marcar visita a un cliente sin necesidad de cargar pedido"
              >
                Marcar visita
              </ToolbarButton>
            )}
          </>
        )}

        {canCreate && <PrimaryNewButton onClick={onNuevoPedido} />}
      </div>
    </>
  );
}
