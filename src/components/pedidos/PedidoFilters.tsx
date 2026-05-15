/**
 * Componente de filtros para la vista de pedidos
 *
 * Diseño: dropdowns con un único estilo de pill (border sutil, fondo blanco).
 * Cuando un filtro tiene valor distinto al "todos" por default, su pill
 * adquiere acento azul para señalar que está activo, en lugar de usar un
 * color distinto por tipo de filtro (eso causaba el "carnaval" en mobile).
 */
import React, { memo, ChangeEvent } from 'react';
import { Search, Calendar, X, Truck, User } from 'lucide-react';
import { fechaLocalISO } from '../../utils/formatters';
import { cn } from '../../lib/utils';
import type { Usuario } from '../../types';

interface FiltrosPedido {
  estado: string;
  estadoPago?: string;
  transportistaId?: string;
  usuarioId?: string;
  fechaDesde?: string | null;
  fechaHasta?: string | null;
  conSalvedad?: 'todos' | 'con_salvedad' | 'sin_salvedad';
  verCancelados?: boolean;
  fechaEntregaProgramada?: string | null;
}

interface FiltrosChange {
  estado?: string;
  estadoPago?: string;
  transportistaId?: string;
  usuarioId?: string;
  fechaDesde?: string | null;
  fechaHasta?: string | null;
  conSalvedad?: 'todos' | 'con_salvedad' | 'sin_salvedad';
  verCancelados?: boolean;
  fechaEntregaProgramada?: string | null;
}

export interface PedidoFiltersProps {
  busqueda: string;
  filtros: FiltrosPedido;
  transportistas?: Usuario[];
  usuarios?: Usuario[];
  isAdmin: boolean;
  onBusquedaChange: (value: string) => void;
  onFiltrosChange: (filtros: FiltrosChange) => void;
  onModalFiltroFecha: () => void;
}

// =============================================================================
// HELPERS LOCALES
// =============================================================================

const SELECT_BASE = cn(
  'h-9 pl-3 pr-8 rounded-lg border text-sm appearance-none',
  'bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200',
  'border-stone-200 dark:border-gray-700',
  'focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400',
  'transition-colors',
);

const SELECT_ACTIVE = 'bg-blue-50 dark:bg-blue-900/20 border-blue-300 dark:border-blue-700 text-blue-700 dark:text-blue-200';

function selectClass(activo: boolean): string {
  return cn(SELECT_BASE, activo && SELECT_ACTIVE);
}

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
  onModalFiltroFecha
}: PedidoFiltersProps): React.ReactElement {
  const fechaActiva = Boolean(filtros.fechaDesde || filtros.fechaHasta);

  return (
    <div className="flex flex-col gap-3">
      {/* ─── Primera fila: Busqueda + filtros principales ─── */}
      <div className="flex flex-col sm:flex-row gap-2">
        <div className="relative flex-1 min-w-0">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-4 h-4" aria-hidden="true" />
          <input
            type="text"
            value={busqueda}
            onChange={(e: ChangeEvent<HTMLInputElement>) => onBusquedaChange(e.target.value)}
            className={cn(
              'w-full h-9 pl-9 pr-3 rounded-lg border text-sm',
              'bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200',
              'border-stone-200 dark:border-gray-700 placeholder:text-gray-400',
              'focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400',
            )}
            placeholder="Buscar por cliente, dirección o ID…"
            aria-label="Buscar pedidos por cliente, dirección o número de pedido"
          />
        </div>
        <label htmlFor="filtro-estado" className="sr-only">Filtrar por estado del pedido</label>
        <select
          id="filtro-estado"
          value={filtros.estado}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ estado: e.target.value })}
          className={selectClass(filtros.estado !== 'todos')}
        >
          <option value="todos">Todos los estados</option>
          <option value="pendiente">Pendientes</option>
          <option value="en_preparacion">En preparación</option>
          <option value="asignado">En camino</option>
          <option value="entregado">Entregados</option>
          <option value="cancelado">Cancelados</option>
        </select>
        <label className="inline-flex items-center gap-2 h-9 px-3 rounded-lg border border-stone-200 dark:border-gray-700 bg-white dark:bg-gray-800 cursor-pointer select-none hover:bg-gray-50 dark:hover:bg-gray-700/50">
          <input
            type="checkbox"
            checked={filtros.verCancelados || false}
            onChange={(e: ChangeEvent<HTMLInputElement>) => onFiltrosChange({ verCancelados: e.target.checked })}
            className="w-4 h-4 rounded text-blue-600 focus:ring-blue-500"
          />
          <span className="text-sm text-gray-700 dark:text-gray-300 whitespace-nowrap">Ver cancelados</span>
        </label>
        <button
          type="button"
          onClick={onModalFiltroFecha}
          aria-label="Filtrar pedidos por rango de fechas"
          className={cn(
            'inline-flex items-center gap-2 h-9 px-3 rounded-lg border text-sm transition-colors',
            fechaActiva
              ? 'bg-blue-50 dark:bg-blue-900/20 border-blue-300 dark:border-blue-700 text-blue-700 dark:text-blue-200'
              : 'bg-white dark:bg-gray-800 border-stone-200 dark:border-gray-700 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700/50',
          )}
        >
          <Calendar className="w-4 h-4" aria-hidden="true" />
          <span>Fechas</span>
        </button>
      </div>

      {/* ─── Segunda fila: Filtros adicionales para admin ─── */}
      {isAdmin && (
        <div className="flex flex-wrap items-center gap-2">
          <label htmlFor="filtro-pago" className="sr-only">Filtrar por estado de pago</label>
          <select
            id="filtro-pago"
            value={filtros.estadoPago || 'todos'}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ estadoPago: e.target.value })}
            className={selectClass(Boolean(filtros.estadoPago) && filtros.estadoPago !== 'todos')}
          >
            <option value="todos">Todos los pagos</option>
            <option value="pendiente">Pago pendiente</option>
            <option value="parcial">Pago parcial</option>
            <option value="pagado">Pagado</option>
          </select>

          <label htmlFor="filtro-transportista" className="sr-only">Filtrar por transportista</label>
          <select
            id="filtro-transportista"
            value={filtros.transportistaId || 'todos'}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ transportistaId: e.target.value })}
            className={selectClass(Boolean(filtros.transportistaId) && filtros.transportistaId !== 'todos')}
          >
            <option value="todos">Todos los transportistas</option>
            <option value="sin_asignar">Sin asignar</option>
            {transportistas.map(t => (
              <option key={t.id} value={t.id}>{t.nombre}</option>
            ))}
          </select>

          <div className="inline-flex items-center gap-1.5">
            <User className="w-4 h-4 text-gray-500 dark:text-gray-400" aria-hidden="true" />
            <label htmlFor="filtro-usuario" className="sr-only">Filtrar por usuario que cargó el pedido</label>
            <select
              id="filtro-usuario"
              value={filtros.usuarioId || 'todos'}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ usuarioId: e.target.value })}
              className={selectClass(Boolean(filtros.usuarioId) && filtros.usuarioId !== 'todos')}
            >
              <option value="todos">Todos los usuarios</option>
              {usuarios.map(u => (
                <option key={u.id} value={u.id}>{u.nombre}</option>
              ))}
            </select>
          </div>

          <label htmlFor="filtro-salvedad" className="sr-only">Filtrar por salvedades en entrega</label>
          <select
            id="filtro-salvedad"
            value={filtros.conSalvedad || 'todos'}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ conSalvedad: e.target.value as 'todos' | 'con_salvedad' | 'sin_salvedad' })}
            className={selectClass(Boolean(filtros.conSalvedad) && filtros.conSalvedad !== 'todos')}
          >
            <option value="todos">Todas las entregas</option>
            <option value="con_salvedad">Con salvedad</option>
            <option value="sin_salvedad">Sin salvedad</option>
          </select>

          {/* Quick filters de fecha entrega: segmented control */}
          <EntregaSegmentedControl
            value={filtros.fechaEntregaProgramada ?? null}
            onChange={value => onFiltrosChange({ fechaEntregaProgramada: value })}
          />
        </div>
      )}

      {/* ─── Chip de filtro de fechas activo ─── */}
      {fechaActiva && (
        <div
          className="inline-flex items-center gap-2 self-start px-3 py-1.5 rounded-full bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 text-sm text-blue-700 dark:text-blue-200"
          role="status"
          aria-live="polite"
        >
          <Calendar className="w-4 h-4" aria-hidden="true" />
          <span>
            Filtrado: <span className="font-medium tabular-nums">{filtros.fechaDesde || '…'}</span> – <span className="font-medium tabular-nums">{filtros.fechaHasta || '…'}</span>
          </span>
          <button
            type="button"
            onClick={() => onFiltrosChange({ fechaDesde: null, fechaHasta: null })}
            className="text-blue-700/60 dark:text-blue-200/60 hover:text-red-600 dark:hover:text-red-400 transition-colors"
            aria-label="Limpiar filtro de fechas"
          >
            <X className="w-4 h-4" aria-hidden="true" />
          </button>
        </div>
      )}
    </div>
  );
}

// =============================================================================
// SEGMENTED CONTROL DE ENTREGA (Hoy / Mañana + date input)
// =============================================================================

interface EntregaSegmentedControlProps {
  value: string | null;
  onChange: (value: string | null) => void;
}

function EntregaSegmentedControl({ value, onChange }: EntregaSegmentedControlProps) {
  const hoy = fechaLocalISO();
  const manana = (() => {
    const d = new Date(hoy + 'T12:00:00');
    d.setDate(d.getDate() + 1);
    return fechaLocalISO(d);
  })();
  const esHoy = value === hoy;
  const esManana = value === manana;
  const esCustom = Boolean(value) && !esHoy && !esManana;

  const segmentClass = (active: boolean) => cn(
    'h-7 px-3 text-xs font-medium transition-colors',
    active
      ? 'bg-white dark:bg-gray-700 text-blue-700 dark:text-blue-200 shadow-sm'
      : 'text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-gray-100',
  );

  return (
    <div className="inline-flex items-center gap-1.5">
      <Truck className="w-4 h-4 text-gray-500 dark:text-gray-400" aria-hidden="true" />
      <span className="text-xs text-gray-500 dark:text-gray-400 mr-1">Entrega:</span>
      <div className="inline-flex items-center p-0.5 rounded-lg border border-stone-200 dark:border-gray-700 bg-gray-100 dark:bg-gray-800">
        <button
          type="button"
          onClick={() => onChange(esHoy ? null : hoy)}
          className={cn(segmentClass(esHoy), 'rounded-md')}
        >
          Hoy
        </button>
        <button
          type="button"
          onClick={() => onChange(esManana ? null : manana)}
          className={cn(segmentClass(esManana), 'rounded-md')}
        >
          Mañana
        </button>
      </div>
      <input
        type="date"
        value={value || ''}
        onChange={(e) => onChange(e.target.value || null)}
        className={cn(
          'h-7 px-2 text-xs rounded-md border',
          esCustom
            ? 'bg-blue-50 dark:bg-blue-900/20 border-blue-300 dark:border-blue-700 text-blue-700 dark:text-blue-200'
            : 'bg-white dark:bg-gray-800 border-stone-200 dark:border-gray-700 text-gray-700 dark:text-gray-200',
        )}
      />
      {value && (
        <button
          type="button"
          onClick={() => onChange(null)}
          className="text-gray-400 hover:text-red-600 transition-colors"
          aria-label="Limpiar filtro de entrega"
        >
          <X className="w-3.5 h-3.5" />
        </button>
      )}
    </div>
  );
}

export default memo(PedidoFilters);
