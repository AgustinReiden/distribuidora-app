/**
 * ChipsFiltrosPedidos — un chip por cada filtro activo de /pedidos, con su X
 * para quitarlo sin abrir el panel (WP-44, #769).
 *
 * Qué chips hay y con qué parche se quita cada uno lo decide
 * `chipsFiltrosActivos` (src/utils/filtrosPedidos.ts); acá sólo se pintan. El
 * tono sale de `estadoTones` cuando el filtro es un estado (del pedido o de
 * pago), así el chip de "Entregados" se ve del mismo color que el badge de la
 * tarjeta.
 *
 * La fila entera es un `role="status"`: al poner o quitar un filtro, un lector
 * de pantalla anuncia cómo quedó.
 *
 * Foco: al quitar un chip, su botón se desmonta y el foco caería a `body`. Antes
 * de emitir se lo pasa al chip siguiente (o al anterior si era el último) y, si
 * no queda ninguno —la fila entera se va—, al trigger del panel (`triggerRef`).
 */
import React, { useRef, type RefObject } from 'react';
import { X } from 'lucide-react';
import Badge from '../ui/Badge';
import type { ChipFiltro, ParcheFiltrosPedidos } from '../../utils/filtrosPedidos';

export interface ChipsFiltrosPedidosProps {
  chips: readonly ChipFiltro[];
  onFiltrosChange: (parche: ParcheFiltrosPedidos) => void;
  /** A dónde va el foco cuando se quita el último chip (el trigger "Filtros"). */
  triggerRef?: RefObject<HTMLElement | null>;
}

export default function ChipsFiltrosPedidos({ chips, onFiltrosChange, triggerRef }: ChipsFiltrosPedidosProps): React.ReactElement | null {
  const botones = useRef(new Map<string, HTMLButtonElement>());

  if (chips.length === 0) return null;

  const quitar = (indice: number) => {
    const vecino = chips[indice + 1] ?? chips[indice - 1];
    const destino = vecino ? botones.current.get(vecino.id) : triggerRef?.current;
    destino?.focus();
    onFiltrosChange(chips[indice].quitar);
  };

  return (
    <div
      role="status"
      aria-live="polite"
      aria-label="Filtros activos"
      className="flex flex-wrap items-center gap-1.5"
    >
      {chips.map((c, i) => (
        <Badge key={c.id} tone={c.tone} className="h-7 gap-1.5 pl-2.5 pr-1 text-xs font-medium">
          <span>
            {c.etiqueta}: <span className="font-semibold tabular-nums">{c.valor}</span>
          </span>
          <button
            type="button"
            ref={(el) => {
              if (el) botones.current.set(c.id, el);
              else botones.current.delete(c.id);
            }}
            onClick={() => quitar(i)}
            aria-label={c.nombreQuitar}
            // 24 px: el mínimo táctil de WCAG 2.2 (2.5.8). Sin opacidad en reposo:
            // atenuada, la X perdía contraste en alto contraste y a 375 px.
            className="inline-flex items-center justify-center w-6 h-6 rounded-full hover:bg-black/10 dark:hover:bg-white/10 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500"
          >
            <X className="w-3.5 h-3.5" aria-hidden="true" />
          </button>
        </Badge>
      ))}
    </div>
  );
}
