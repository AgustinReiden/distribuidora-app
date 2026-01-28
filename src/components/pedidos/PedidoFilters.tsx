/**
 * Componente de filtros para la vista de pedidos
 */
import React, { memo, ChangeEvent } from 'react';
import { Search, Calendar, X } from 'lucide-react';
import type { Usuario, EstadoPedido, EstadoPago } from '../../types';

interface FiltrosPedido {
  estado: string;
  estadoPago?: string;
  transportistaId?: string;
  fechaDesde?: string | null;
  fechaHasta?: string | null;
  conSalvedad?: 'todos' | 'con_salvedad' | 'sin_salvedad';
}

interface FiltrosChange {
  estado?: string;
  estadoPago?: string;
  transportistaId?: string;
  fechaDesde?: string | null;
  fechaHasta?: string | null;
  conSalvedad?: 'todos' | 'con_salvedad' | 'sin_salvedad';
}

export interface PedidoFiltersProps {
  busqueda: string;
  filtros: FiltrosPedido;
  transportistas?: Usuario[];
  isAdmin: boolean;
  onBusquedaChange: (value: string) => void;
  onFiltrosChange: (filtros: FiltrosChange) => void;
  onModalFiltroFecha: () => void;
}

function PedidoFilters({
  busqueda,
  filtros,
  transportistas = [],
  isAdmin,
  onBusquedaChange,
  onFiltrosChange,
  onModalFiltroFecha
}: PedidoFiltersProps): React.ReactElement {
  return (
    <div className="flex flex-col gap-4">
      {/* Primera fila: Busqueda y filtros principales */}
      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" aria-hidden="true" />
          <input
            type="text"
            value={busqueda}
            onChange={(e: ChangeEvent<HTMLInputElement>) => onBusquedaChange(e.target.value)}
            className="w-full pl-10 pr-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
            placeholder="Buscar por cliente, direccion o ID..."
            aria-label="Buscar pedidos por cliente, dirección o número de pedido"
          />
        </div>
        <div>
          <label htmlFor="filtro-estado" className="sr-only">Filtrar por estado del pedido</label>
          <select
            id="filtro-estado"
            value={filtros.estado}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ estado: e.target.value })}
            className="px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          >
            <option value="todos">Todos los estados</option>
            <option value="pendiente">Pendientes</option>
            <option value="en_preparacion">En preparacion</option>
            <option value="asignado">En camino</option>
            <option value="entregado">Entregados</option>
          </select>
        </div>
        <button
          onClick={onModalFiltroFecha}
          aria-label="Filtrar pedidos por rango de fechas"
          className={`flex items-center space-x-2 px-4 py-2 border rounded-lg transition-colors ${
            filtros.fechaDesde || filtros.fechaHasta
              ? 'bg-blue-50 border-blue-300 dark:bg-blue-900/30 dark:border-blue-600'
              : 'hover:bg-gray-50 dark:hover:bg-gray-700'
          } dark:border-gray-600`}
        >
          <Calendar className="w-5 h-5" aria-hidden="true" />
          <span>Fechas</span>
        </button>
      </div>

      {/* Segunda fila: Filtros adicionales para admin */}
      {isAdmin && (
        <div className="flex flex-wrap gap-4">
          <div>
            <label htmlFor="filtro-pago" className="sr-only">Filtrar por estado de pago</label>
            <select
              id="filtro-pago"
              value={filtros.estadoPago || 'todos'}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ estadoPago: e.target.value })}
              className={`px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:border-gray-600 dark:text-white ${
                filtros.estadoPago && filtros.estadoPago !== 'todos'
                  ? 'bg-red-50 border-red-300 dark:bg-red-900/30 dark:border-red-600'
                  : ''
              }`}
            >
              <option value="todos">Todos los pagos</option>
              <option value="pendiente">Pago Pendiente</option>
              <option value="parcial">Pago Parcial</option>
              <option value="pagado">Pagado</option>
            </select>
          </div>
          <div>
            <label htmlFor="filtro-transportista" className="sr-only">Filtrar por transportista</label>
            <select
              id="filtro-transportista"
              value={filtros.transportistaId || 'todos'}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ transportistaId: e.target.value })}
              className={`px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:border-gray-600 dark:text-white ${
                filtros.transportistaId && filtros.transportistaId !== 'todos'
                  ? 'bg-orange-50 border-orange-300 dark:bg-orange-900/30 dark:border-orange-600'
                  : ''
              }`}
            >
              <option value="todos">Todos los transportistas</option>
              <option value="sin_asignar">Sin asignar</option>
              {transportistas.map(t => (
                <option key={t.id} value={t.id}>{t.nombre}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="filtro-salvedad" className="sr-only">Filtrar por salvedades en entrega</label>
            <select
              id="filtro-salvedad"
              value={filtros.conSalvedad || 'todos'}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ conSalvedad: e.target.value as 'todos' | 'con_salvedad' | 'sin_salvedad' })}
              className={`px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:border-gray-600 dark:text-white ${
                filtros.conSalvedad && filtros.conSalvedad !== 'todos'
                  ? 'bg-amber-50 border-amber-300 dark:bg-amber-900/30 dark:border-amber-600'
                  : ''
              }`}
            >
              <option value="todos">Todas las entregas</option>
              <option value="con_salvedad">Con salvedad</option>
              <option value="sin_salvedad">Sin salvedad</option>
            </select>
          </div>
        </div>
      )}

      {/* Filtro de fechas activo */}
      {(filtros.fechaDesde || filtros.fechaHasta) && (
        <div className="flex items-center space-x-2 text-sm text-blue-600" role="status" aria-live="polite">
          <Calendar className="w-4 h-4" aria-hidden="true" />
          <span>Filtrado: {filtros.fechaDesde || '...'} - {filtros.fechaHasta || '...'}</span>
          <button
            onClick={() => onFiltrosChange({ fechaDesde: null, fechaHasta: null })}
            className="text-red-500 hover:text-red-700"
            aria-label="Limpiar filtro de fechas"
          >
            <X className="w-4 h-4" aria-hidden="true" />
          </button>
        </div>
      )}
    </div>
  );
}

export default memo(PedidoFilters);
