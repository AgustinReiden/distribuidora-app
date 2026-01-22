/**
 * Componente de filtros para la vista de pedidos
 */
import React, { memo } from 'react';
import { Search, Calendar, X } from 'lucide-react';

function PedidoFilters({
  busqueda,
  filtros,
  transportistas = [],
  isAdmin,
  onBusquedaChange,
  onFiltrosChange,
  onModalFiltroFecha
}) {
  return (
    <div className="flex flex-col gap-4">
      {/* Primera fila: Búsqueda y filtros principales */}
      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
          <input
            type="text"
            value={busqueda}
            onChange={e => onBusquedaChange(e.target.value)}
            className="w-full pl-10 pr-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
            placeholder="Buscar por cliente, dirección o ID..."
          />
        </div>
        <select
          value={filtros.estado}
          onChange={e => onFiltrosChange({ estado: e.target.value })}
          className="px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:border-gray-600 dark:text-white"
        >
          <option value="todos">Todos los estados</option>
          <option value="pendiente">Pendientes</option>
          <option value="en_preparacion">En preparación</option>
          <option value="asignado">En camino</option>
          <option value="entregado">Entregados</option>
        </select>
        <button
          onClick={onModalFiltroFecha}
          className={`flex items-center space-x-2 px-4 py-2 border rounded-lg transition-colors ${
            filtros.fechaDesde || filtros.fechaHasta
              ? 'bg-blue-50 border-blue-300 dark:bg-blue-900/30 dark:border-blue-600'
              : 'hover:bg-gray-50 dark:hover:bg-gray-700'
          } dark:border-gray-600`}
        >
          <Calendar className="w-5 h-5" />
          <span>Fechas</span>
        </button>
      </div>

      {/* Segunda fila: Filtros adicionales para admin */}
      {isAdmin && (
        <div className="flex flex-wrap gap-4">
          <select
            value={filtros.estadoPago || 'todos'}
            onChange={e => onFiltrosChange({ estadoPago: e.target.value })}
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
          <select
            value={filtros.transportistaId || 'todos'}
            onChange={e => onFiltrosChange({ transportistaId: e.target.value })}
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
      )}

      {/* Filtro de fechas activo */}
      {(filtros.fechaDesde || filtros.fechaHasta) && (
        <div className="flex items-center space-x-2 text-sm text-blue-600">
          <Calendar className="w-4 h-4" />
          <span>Filtrado: {filtros.fechaDesde || '...'} - {filtros.fechaHasta || '...'}</span>
          <button
            onClick={() => onFiltrosChange({ fechaDesde: null, fechaHasta: null })}
            className="text-red-500 hover:text-red-700"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
      )}
    </div>
  );
}

export default memo(PedidoFilters);
