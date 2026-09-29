/**
 * Barra de filtros de /pedidos (WP-44, #769).
 *
 *    [ 🔍 Buscar...        ] [ Entrega: Hoy | Mañana | 📅 ] [ ⚙ Filtros (N) ]
 *    [ Estado: Pendientes × ] [ Pago: Impagos × ] [ Filtrado: … – … × ]
 *
 * La fila es el buscador, el control de entrega programada (Hoy / Mañana / fecha
 * suelta, sólo admin: es el filtro de un toque que se usa todos los días) y UN
 * trigger. En celular el control de entrega baja a su propia línea.
 *
 * Un solo trigger, "Filtros (N)", abre el MISMO panel (`PanelFiltrosPedidos`)
 * en el envoltorio que corresponde al ancho: bottom sheet en celular
 * (`ModalFiltrosPedidos`) y popover en escritorio. Sólo se monta el envoltorio
 * del ancho actual, así que nunca hay dos copias del formulario en el árbol —que
 * era lo que pasaba antes, con la fila inline de escritorio y el sheet
 * escondidos por CSS—.
 *
 * Debajo, un chip por cada filtro activo con su X (`ChipsFiltrosPedidos`): se
 * quitan sin abrir el panel. Qué cuenta como activo, para qué rol, y con qué
 * parche se quita cada uno vive en `src/utils/filtrosPedidos.ts`.
 */
import React, { memo, useId, useRef, useState, useSyncExternalStore } from 'react';
import { Search, SlidersHorizontal } from 'lucide-react';
import { Button } from '../ui/Button';
import Badge from '../ui/Badge';
import { Popover, PopoverContent, PopoverTrigger } from '../ui/Popover';
import { fechaLocalISO } from '../../utils/formatters';
import { cn } from '../../lib/utils';
import {
  chipsFiltrosActivos,
  contarFiltrosActivos,
  describirFiltrosActivos,
  type FiltrosPedidosUI,
  type ParcheFiltrosPedidos,
} from '../../utils/filtrosPedidos';
import ModalFiltrosPedidos from './ModalFiltrosPedidos';
import PanelFiltrosPedidos, { ControlEntregaProgramada, PieFiltrosPedidos } from './PanelFiltrosPedidos';
import ChipsFiltrosPedidos from './ChipsFiltrosPedidos';
import type { Usuario } from '../../types';

export interface PedidoFiltersProps {
  busqueda: string;
  filtros: FiltrosPedidosUI;
  transportistas?: Usuario[];
  usuarios?: Usuario[];
  isAdmin: boolean;
  onBusquedaChange: (value: string) => void;
  onFiltrosChange: (filtros: ParcheFiltrosPedidos) => void;
}

// =============================================================================
// ANCHO: ¿SHEET O POPOVER?
// =============================================================================

/** El mismo corte que el `sm:` de Tailwind: de acá para arriba es escritorio. */
const QUERY_ESCRITORIO = '(min-width: 640px)';

function hayMatchMedia(): boolean {
  return typeof window !== 'undefined' && typeof window.matchMedia === 'function';
}

function suscribirAncho(onCambio: () => void): () => void {
  if (!hayMatchMedia()) return () => {};
  const mql = window.matchMedia(QUERY_ESCRITORIO);
  mql.addEventListener?.('change', onCambio);
  return () => mql.removeEventListener?.('change', onCambio);
}

function esEscritorio(): boolean {
  return hayMatchMedia() && window.matchMedia(QUERY_ESCRITORIO).matches;
}

// Sin `window` (render en servidor) se asume celular, que es lo que usa casi todo el mundo.
const esEscritorioServidor = (): boolean => false;

// =============================================================================
// MAIN
// =============================================================================

function PedidoFilters({
  busqueda,
  filtros,
  transportistas = [],
  usuarios = [],
  isAdmin,
  onBusquedaChange,
  onFiltrosChange,
}: PedidoFiltersProps): React.ReactElement {
  const escritorio = useSyncExternalStore(suscribirAncho, esEscritorio, esEscritorioServidor);
  const [abierto, setAbierto] = useState(false);
  // Si la ventana cruza el breakpoint con el panel abierto (rotar una tablet),
  // el envoltorio cambia de sheet a popover o al revés: se cierra en vez de
  // reabrirse solo en el otro formato. Ajuste de estado en el render, el patrón
  // de React para derivar de un valor que cambia (sin efecto).
  const [escritorioPrevio, setEscritorioPrevio] = useState(escritorio);
  if (escritorioPrevio !== escritorio) {
    setEscritorioPrevio(escritorio);
    setAbierto(false);
  }
  const triggerRef = useRef<HTMLButtonElement>(null);
  const idTitulo = useId();
  const idDescripcion = useId();

  const activosCount = contarFiltrosActivos(filtros, { isAdmin });
  const chips = chipsFiltrosActivos(filtros, { isAdmin, transportistas, usuarios, hoy: fechaLocalISO() });

  const trigger = (
    <Button
      ref={triggerRef}
      type="button"
      variant="secondary"
      aria-label="Abrir filtros avanzados"
      aria-haspopup="dialog"
      aria-expanded={abierto}
      onClick={escritorio ? undefined : () => setAbierto(true)}
      className={cn(
        'flex-shrink-0 h-10 sm:h-9 px-3',
        activosCount > 0 && 'bg-blue-50 dark:bg-blue-900/20 border-blue-300 dark:border-blue-700 text-blue-700 dark:text-blue-200',
      )}
    >
      <SlidersHorizontal className="w-4 h-4" aria-hidden="true" />
      <span>Filtros</span>
      {activosCount > 0 && (
        <Badge tone="brand" fill="strong" className="min-w-[1.25rem] h-5 justify-center px-1 tabular-nums">
          {activosCount}
        </Badge>
      )}
    </Button>
  );

  return (
    <div className="flex flex-col gap-2.5">
      <div className="flex flex-wrap sm:flex-nowrap items-center gap-2">
        {/* Búsqueda: siempre a la vista, no es parte del panel. */}
        <div className="relative flex-1 min-w-[10rem]">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-4 h-4" aria-hidden="true" />
          <input
            type="text"
            value={busqueda}
            onChange={(e) => onBusquedaChange(e.target.value)}
            className={cn(
              'w-full h-10 sm:h-9 pl-9 pr-3 rounded-lg border text-sm',
              'bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200',
              'border-stone-200 dark:border-gray-700 placeholder:text-gray-400',
              'focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400',
            )}
            placeholder="Buscar por cliente, dirección o ID…"
            aria-label="Buscar pedidos por cliente, dirección o número de pedido"
          />
        </div>

        {/* Entrega programada (sólo admin): a la vista en escritorio, fuera del
            popover. En celular vive sólo en el sheet, como antes de WP-44: si
            también estuviera en la fila, el admin la vería dos veces. */}
        {isAdmin && (
          <div className="hidden sm:block">
            <ControlEntregaProgramada
              variante="fila"
              value={filtros.fechaEntregaProgramada ?? null}
              onFiltrosChange={onFiltrosChange}
            />
          </div>
        )}

        {escritorio ? (
          <Popover open={abierto} onOpenChange={setAbierto}>
            <PopoverTrigger asChild>{trigger}</PopoverTrigger>
            <PopoverContent aria-labelledby={idTitulo} aria-describedby={idDescripcion}>
              <div className="flex-shrink-0 px-4 pt-3 pb-2 border-b border-stone-200 dark:border-gray-700">
                <p id={idTitulo} className="text-sm font-semibold text-stone-900 dark:text-white">Filtros</p>
                <p id={idDescripcion} className="text-xs text-stone-500 dark:text-stone-400 mt-0.5">
                  {describirFiltrosActivos(activosCount)}
                </p>
              </div>
              <div className="flex-1 min-h-0 overflow-y-auto overscroll-contain px-4 py-3">
                <PanelFiltrosPedidos
                  filtros={filtros}
                  transportistas={transportistas}
                  usuarios={usuarios}
                  isAdmin={isAdmin}
                  mostrarEntrega={false}
                  onFiltrosChange={onFiltrosChange}
                />
              </div>
              <div className="flex-shrink-0 px-4 py-3 border-t border-stone-200 dark:border-gray-700">
                <PieFiltrosPedidos
                  activosCount={activosCount}
                  onFiltrosChange={onFiltrosChange}
                  onListo={() => setAbierto(false)}
                  tamanoListo="md"
                />
              </div>
            </PopoverContent>
          </Popover>
        ) : (
          <>
            {trigger}
            <ModalFiltrosPedidos
              open={abierto}
              filtros={filtros}
              transportistas={transportistas}
              usuarios={usuarios}
              isAdmin={isAdmin}
              activosCount={activosCount}
              onFiltrosChange={onFiltrosChange}
              onClose={() => setAbierto(false)}
            />
          </>
        )}
      </div>

      <ChipsFiltrosPedidos chips={chips} onFiltrosChange={onFiltrosChange} triggerRef={triggerRef} />
    </div>
  );
}

export default memo(PedidoFilters);
