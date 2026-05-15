/**
 * ModalFiltrosPedidos
 *
 * Bottom sheet con los filtros secundarios del panel de Pedidos. Pensado
 * para mobile (en desktop los filtros viven inline en PedidoFilters).
 *
 * Secciones:
 *  - Estado del pedido
 *  - Pago (admin)
 *  - Transportista (admin)
 *  - Usuario que cargó (admin)
 *  - Salvedades (admin)
 *  - Entrega programada (admin) — segmented Hoy/Mañana + date input
 *  - Ver cancelados (toggle)
 *
 * Comportamiento "live": cada cambio aplica inmediatamente al estado de
 * filtros (via onFiltrosChange). El footer "Listo" cierra el sheet;
 * "Limpiar" resetea los filtros del sheet a default. Búsqueda y rango
 * de fechaDesde/fechaHasta NO se tocan acá (viven afuera del modal).
 */
import React, { type ChangeEvent } from 'react';
import { Truck, User, X } from 'lucide-react';
import BottomSheet from '../ui/BottomSheet';
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

export interface ModalFiltrosPedidosProps {
  open: boolean;
  filtros: FiltrosPedido;
  transportistas?: Usuario[];
  usuarios?: Usuario[];
  isAdmin: boolean;
  activosCount: number;
  onFiltrosChange: (f: FiltrosChange) => void;
  onClose: () => void;
}

// =============================================================================
// HELPERS LOCALES
// =============================================================================

const SECTION_LABEL = 'text-[11px] font-semibold uppercase tracking-[0.08em] text-stone-500 dark:text-stone-400 mb-2';

const SELECT_NATIVE = cn(
  'w-full h-11 pl-3 pr-9 rounded-lg border text-sm appearance-none',
  'bg-white dark:bg-gray-800 text-stone-800 dark:text-gray-100',
  'border-stone-200 dark:border-gray-700',
  'focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400',
);

interface SectionProps {
  label: string;
  children: React.ReactNode;
}

function Section({ label, children }: SectionProps) {
  return (
    <div className="py-3 first:pt-0 last:pb-0 border-b border-stone-100 dark:border-gray-700 last:border-b-0">
      <p className={SECTION_LABEL}>{label}</p>
      {children}
    </div>
  );
}

// =============================================================================
// MAIN
// =============================================================================

export default function ModalFiltrosPedidos({
  open,
  filtros,
  transportistas = [],
  usuarios = [],
  isAdmin,
  activosCount,
  onFiltrosChange,
  onClose,
}: ModalFiltrosPedidosProps): React.ReactElement {
  const handleLimpiar = () => {
    onFiltrosChange({
      estado: 'todos',
      estadoPago: 'todos',
      transportistaId: 'todos',
      usuarioId: 'todos',
      conSalvedad: 'todos',
      fechaEntregaProgramada: null,
      verCancelados: false,
    });
  };

  const hoy = fechaLocalISO();
  const manana = (() => {
    const d = new Date(hoy + 'T12:00:00');
    d.setDate(d.getDate() + 1);
    return fechaLocalISO(d);
  })();
  const entregaActiva = filtros.fechaEntregaProgramada ?? null;
  const esHoy = entregaActiva === hoy;
  const esManana = entregaActiva === manana;
  const esCustomEntrega = Boolean(entregaActiva) && !esHoy && !esManana;

  return (
    <BottomSheet
      open={open}
      onClose={onClose}
      title="Filtros"
      description={activosCount > 0 ? `${activosCount} filtro${activosCount === 1 ? '' : 's'} activo${activosCount === 1 ? '' : 's'}` : 'Refiná tu búsqueda'}
      footer={
        <div className="flex items-center justify-between gap-3">
          <button
            type="button"
            onClick={handleLimpiar}
            disabled={activosCount === 0}
            className="inline-flex items-center gap-1.5 h-10 px-3 rounded-lg text-sm font-medium text-stone-600 dark:text-stone-300 hover:bg-stone-100 dark:hover:bg-gray-700/50 disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
          >
            Limpiar todo
          </button>
          <button
            type="button"
            onClick={onClose}
            className="inline-flex items-center justify-center h-11 px-6 rounded-lg text-sm font-semibold text-white bg-gradient-to-br from-blue-500 to-blue-600 shadow-warm hover:from-blue-500 hover:to-blue-700 transition-colors"
          >
            Listo
          </button>
        </div>
      }
    >
      {/* Estado del pedido */}
      <Section label="Estado del pedido">
        <select
          value={filtros.estado}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ estado: e.target.value })}
          className={SELECT_NATIVE}
        >
          <option value="todos">Todos los estados</option>
          <option value="pendiente">Pendientes</option>
          <option value="en_preparacion">En preparación</option>
          <option value="asignado">En camino</option>
          <option value="entregado">Entregados</option>
          <option value="cancelado">Cancelados</option>
        </select>
      </Section>

      {/* Pago (admin) */}
      {isAdmin && (
        <Section label="Pago">
          <select
            value={filtros.estadoPago || 'todos'}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ estadoPago: e.target.value })}
            className={SELECT_NATIVE}
          >
            <option value="todos">Todos los pagos</option>
            <option value="pendiente">Pago pendiente</option>
            <option value="parcial">Pago parcial</option>
            <option value="pagado">Pagado</option>
          </select>
        </Section>
      )}

      {/* Transportista (admin) */}
      {isAdmin && (
        <Section label="Transportista">
          <div className="relative">
            <Truck className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-stone-400 pointer-events-none" aria-hidden="true" />
            <select
              value={filtros.transportistaId || 'todos'}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ transportistaId: e.target.value })}
              className={cn(SELECT_NATIVE, 'pl-9')}
            >
              <option value="todos">Todos los transportistas</option>
              <option value="sin_asignar">Sin asignar</option>
              {transportistas.map(t => (
                <option key={t.id} value={t.id}>{t.nombre}</option>
              ))}
            </select>
          </div>
        </Section>
      )}

      {/* Usuario (admin) */}
      {isAdmin && (
        <Section label="Cargado por">
          <div className="relative">
            <User className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-stone-400 pointer-events-none" aria-hidden="true" />
            <select
              value={filtros.usuarioId || 'todos'}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ usuarioId: e.target.value })}
              className={cn(SELECT_NATIVE, 'pl-9')}
            >
              <option value="todos">Todos los usuarios</option>
              {usuarios.map(u => (
                <option key={u.id} value={u.id}>{u.nombre}</option>
              ))}
            </select>
          </div>
        </Section>
      )}

      {/* Salvedades (admin) */}
      {isAdmin && (
        <Section label="Entregas con salvedad">
          <select
            value={filtros.conSalvedad || 'todos'}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ conSalvedad: e.target.value as 'todos' | 'con_salvedad' | 'sin_salvedad' })}
            className={SELECT_NATIVE}
          >
            <option value="todos">Todas las entregas</option>
            <option value="con_salvedad">Con salvedad</option>
            <option value="sin_salvedad">Sin salvedad</option>
          </select>
        </Section>
      )}

      {/* Entrega programada (admin) */}
      {isAdmin && (
        <Section label="Entrega programada">
          <div className="space-y-2">
            <div className="inline-flex items-center w-full p-1 rounded-lg border border-stone-200 dark:border-gray-700 bg-stone-100 dark:bg-gray-800/70">
              <button
                type="button"
                onClick={() => onFiltrosChange({ fechaEntregaProgramada: esHoy ? null : hoy })}
                className={cn(
                  'flex-1 h-9 rounded-md text-sm font-medium transition-colors',
                  esHoy
                    ? 'bg-white dark:bg-gray-700 text-blue-700 dark:text-blue-200 shadow-warm'
                    : 'text-stone-600 dark:text-stone-300',
                )}
              >
                Hoy
              </button>
              <button
                type="button"
                onClick={() => onFiltrosChange({ fechaEntregaProgramada: esManana ? null : manana })}
                className={cn(
                  'flex-1 h-9 rounded-md text-sm font-medium transition-colors',
                  esManana
                    ? 'bg-white dark:bg-gray-700 text-blue-700 dark:text-blue-200 shadow-warm'
                    : 'text-stone-600 dark:text-stone-300',
                )}
              >
                Mañana
              </button>
            </div>
            <div className="flex items-center gap-2">
              <input
                type="date"
                value={entregaActiva || ''}
                onChange={(e) => onFiltrosChange({ fechaEntregaProgramada: e.target.value || null })}
                className={cn(
                  'flex-1 h-10 px-3 rounded-lg border text-sm',
                  'bg-white dark:bg-gray-800 text-stone-800 dark:text-gray-100',
                  esCustomEntrega
                    ? 'bg-blue-50 dark:bg-blue-900/20 border-blue-300 dark:border-blue-700'
                    : 'border-stone-200 dark:border-gray-700',
                  'focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400',
                )}
              />
              {entregaActiva && (
                <button
                  type="button"
                  onClick={() => onFiltrosChange({ fechaEntregaProgramada: null })}
                  className="inline-flex items-center justify-center w-10 h-10 rounded-lg text-stone-500 hover:text-rose-600 hover:bg-rose-50 dark:hover:bg-rose-900/15 transition-colors"
                  aria-label="Limpiar filtro de entrega"
                >
                  <X className="w-4 h-4" />
                </button>
              )}
            </div>
          </div>
        </Section>
      )}

      {/* Ver cancelados */}
      <Section label="Otros">
        <label className="flex items-center justify-between gap-3 h-11 px-3 rounded-lg border border-stone-200 dark:border-gray-700 cursor-pointer bg-white dark:bg-gray-800">
          <span className="text-sm text-stone-700 dark:text-gray-200">
            Incluir cancelados
          </span>
          <input
            type="checkbox"
            checked={filtros.verCancelados || false}
            onChange={(e: ChangeEvent<HTMLInputElement>) => onFiltrosChange({ verCancelados: e.target.checked })}
            className="w-5 h-5 rounded border-stone-300 text-blue-600 focus:ring-blue-500"
          />
        </label>
      </Section>
    </BottomSheet>
  );
}
