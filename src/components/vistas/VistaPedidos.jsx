import React, { useState, useRef, useEffect } from 'react';
import { ShoppingCart, Search, Calendar, Plus, Route, FileDown, Clock, Package, Truck, Check, X, MoreVertical, History, Edit2, User, AlertTriangle, Trash2, FileText, CreditCard } from 'lucide-react';
import { formatPrecio, formatFecha, getEstadoColor, getEstadoLabel, getEstadoPagoColor, getEstadoPagoLabel, getFormaPagoLabel } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';
import Paginacion from '../layout/Paginacion';

// Componente de dropdown de acciones
function AccionesDropdown({ pedido, isAdmin, isPreventista, isTransportista, onHistorial, onEditar, onPreparar, onAsignar, onEntregado, onRevertir, onEliminar }) {
  const [abierto, setAbierto] = useState(false);
  const dropdownRef = useRef(null);

  useEffect(() => {
    const handleClickOutside = (event) => {
      if (dropdownRef.current && !dropdownRef.current.contains(event.target)) {
        setAbierto(false);
      }
    };
    document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, []);

  const acciones = [];

  // Siempre visible
  acciones.push({ label: 'Ver Historial', icon: History, onClick: () => onHistorial(pedido), color: 'text-gray-700' });

  // Admin o preventista pueden editar
  if (isAdmin || isPreventista) {
    acciones.push({ label: 'Editar', icon: Edit2, onClick: () => onEditar(pedido), color: 'text-blue-700' });
  }

  // Admin puede preparar si está pendiente
  if (isAdmin && pedido.estado === 'pendiente') {
    acciones.push({ label: 'Marcar en Preparación', icon: Package, onClick: () => onPreparar(pedido), color: 'text-orange-700' });
  }

  // Admin puede asignar si no está entregado
  if (isAdmin && pedido.estado !== 'entregado') {
    acciones.push({
      label: pedido.transportista ? 'Reasignar Transportista' : 'Asignar Transportista',
      icon: User,
      onClick: () => onAsignar(pedido),
      color: 'text-orange-700'
    });
  }

  // Transportista o admin pueden marcar entregado
  if ((isTransportista || isAdmin) && pedido.estado === 'asignado') {
    acciones.push({ label: 'Marcar Entregado', icon: Check, onClick: () => onEntregado(pedido), color: 'text-green-700' });
  }

  // Admin puede revertir si está entregado
  if (isAdmin && pedido.estado === 'entregado') {
    acciones.push({ label: 'Revertir Entrega', icon: AlertTriangle, onClick: () => onRevertir(pedido), color: 'text-yellow-700' });
  }

  // Admin puede eliminar
  if (isAdmin) {
    acciones.push({ label: 'Eliminar', icon: Trash2, onClick: () => onEliminar(pedido.id), color: 'text-red-600', divider: true });
  }

  return (
    <div className="relative" ref={dropdownRef}>
      <button
        onClick={() => setAbierto(!abierto)}
        className="p-2 hover:bg-gray-100 rounded-lg transition-colors"
        aria-label="Más acciones"
      >
        <MoreVertical className="w-5 h-5 text-gray-600 dark:text-gray-300" />
      </button>

      {abierto && (
        <div className="absolute right-0 mt-2 w-56 bg-white dark:bg-gray-800 rounded-lg shadow-lg border dark:border-gray-700 z-50 py-1">
          {acciones.map((accion, idx) => (
            <React.Fragment key={idx}>
              {accion.divider && <div className="border-t dark:border-gray-700 my-1" />}
              <button
                onClick={() => { accion.onClick(); setAbierto(false); }}
                className={`w-full flex items-center space-x-2 px-4 py-2 text-sm hover:bg-gray-50 dark:hover:bg-gray-700 ${accion.color} dark:text-gray-300`}
              >
                <accion.icon className="w-4 h-4" />
                <span>{accion.label}</span>
              </button>
            </React.Fragment>
          ))}
        </div>
      )}
    </div>
  );
}

// Componente de stepper de estado
function EstadoStepper({ estado }) {
  const estados = [
    { key: 'pendiente', label: 'Pendiente', icon: Clock },
    { key: 'en_preparacion', label: 'Preparando', icon: Package },
    { key: 'asignado', label: 'En camino', icon: Truck },
    { key: 'entregado', label: 'Entregado', icon: Check },
  ];

  const estadoIndex = estados.findIndex(e => e.key === estado);

  return (
    <div className="flex items-center space-x-1 text-xs">
      {estados.map((e, idx) => {
        const isCompleted = idx <= estadoIndex;
        const isCurrent = idx === estadoIndex;
        return (
          <React.Fragment key={e.key}>
            <div className={`flex items-center space-x-1 px-2 py-1 rounded ${
              isCurrent ? getEstadoColor(estado) :
              isCompleted ? 'bg-gray-200 text-gray-600' :
              'bg-gray-100 text-gray-400'
            }`}>
              <e.icon className="w-3 h-3" />
              <span className="hidden sm:inline">{e.label}</span>
            </div>
            {idx < estados.length - 1 && (
              <div className={`w-4 h-0.5 ${isCompleted ? 'bg-gray-400' : 'bg-gray-200'}`} />
            )}
          </React.Fragment>
        );
      })}
    </div>
  );
}

export default function VistaPedidos({
  pedidos,
  pedidosParaMostrar,
  pedidosPaginados,
  paginaActual,
  totalPaginas,
  busqueda,
  filtros,
  isAdmin,
  isPreventista,
  isTransportista,
  loading,
  exportando,
  onBusquedaChange,
  onFiltrosChange,
  onPageChange,
  onNuevoPedido,
  onOptimizarRuta,
  onExportarPDF,
  onExportarCSV,
  onModalFiltroFecha,
  onVerHistorial,
  onEditarPedido,
  onMarcarEnPreparacion,
  onAsignarTransportista,
  onMarcarEntregado,
  onDesmarcarEntregado,
  onEliminarPedido
}) {
  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Pedidos</h1>
        <div className="flex flex-wrap gap-2">
          {isAdmin && (
            <button
              onClick={onOptimizarRuta}
              className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
            >
              <Route className="w-5 h-5" />
              <span>Optimizar Ruta</span>
            </button>
          )}
          {isAdmin && (
            <button
              onClick={onExportarPDF}
              className="flex items-center space-x-2 px-4 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700 transition-colors"
            >
              <FileDown className="w-5 h-5" />
              <span>Exportar PDF</span>
            </button>
          )}
          {isAdmin && (
            <button
              onClick={onExportarCSV}
              disabled={exportando}
              className="flex items-center space-x-2 px-4 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-700 transition-colors"
            >
              <FileDown className="w-5 h-5" />
              <span>CSV</span>
            </button>
          )}
          {(isAdmin || isPreventista) && (
            <button
              onClick={onNuevoPedido}
              className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
            >
              <Plus className="w-5 h-5" />
              <span>Nuevo</span>
            </button>
          )}
        </div>
      </div>

      {/* Filtros */}
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
          className="px-4 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500"
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
            filtros.fechaDesde || filtros.fechaHasta ? 'bg-blue-50 border-blue-300' : 'hover:bg-gray-50'
          }`}
        >
          <Calendar className="w-5 h-5" />
          <span>Fechas</span>
        </button>
      </div>

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

      {/* Resumen de estados */}
      <div className="grid grid-cols-2 sm:grid-cols-5 gap-4">
        <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-3">
          <Clock className="w-5 h-5 text-yellow-600" />
          <p className="text-xl font-bold text-yellow-600">{pedidos.filter(p => p.estado === 'pendiente').length}</p>
          <p className="text-sm text-yellow-800">Pendientes</p>
        </div>
        <div className="bg-orange-50 border border-orange-200 rounded-lg p-3">
          <Package className="w-5 h-5 text-orange-600" />
          <p className="text-xl font-bold text-orange-600">{pedidos.filter(p => p.estado === 'en_preparacion').length}</p>
          <p className="text-sm text-orange-800">En preparación</p>
        </div>
        <div className="bg-blue-50 border border-blue-200 rounded-lg p-3">
          <Truck className="w-5 h-5 text-blue-600" />
          <p className="text-xl font-bold text-blue-600">{pedidos.filter(p => p.estado === 'asignado').length}</p>
          <p className="text-sm text-blue-800">En camino</p>
        </div>
        <div className="bg-green-50 border border-green-200 rounded-lg p-3">
          <Check className="w-5 h-5 text-green-600" />
          <p className="text-xl font-bold text-green-600">{pedidos.filter(p => p.estado === 'entregado').length}</p>
          <p className="text-sm text-green-800">Entregados</p>
        </div>
        <div className="bg-purple-50 border border-purple-200 rounded-lg p-3">
          <ShoppingCart className="w-5 h-5 text-purple-600" />
          <p className="text-xl font-bold text-purple-600">{pedidosParaMostrar.length}</p>
          <p className="text-sm text-purple-800">Mostrando</p>
        </div>
      </div>

      {/* Lista de pedidos */}
      {loading ? <LoadingSpinner /> : pedidosParaMostrar.length === 0 ? (
        <div className="text-center py-12 text-gray-500">
          <ShoppingCart className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>No hay pedidos</p>
        </div>
      ) : (
        <>
          <div className="space-y-3">
            {pedidosPaginados.map(pedido => (
              <div key={pedido.id} className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4 hover:shadow-md transition-shadow">
                {/* Header del pedido */}
                <div className="flex justify-between items-start">
                  <div className="flex-1">
                    <div className="flex items-start justify-between">
                      <div>
                        <h3 className="font-semibold text-lg text-gray-800 dark:text-white">
                          {pedido.cliente?.nombre_fantasia || 'Sin cliente'}
                        </h3>
                        <p className="text-sm text-gray-500 dark:text-gray-400">{pedido.cliente?.direccion}</p>
                        <p className="text-sm text-gray-400 dark:text-gray-500 mt-1">
                          #{pedido.id} • {formatFecha(pedido.created_at)}
                        </p>
                      </div>
                    </div>
                    {pedido.transportista && (
                      <div className="mt-2 inline-flex items-center px-2 py-1 bg-orange-100 text-orange-700 rounded-full text-sm">
                        <Truck className="w-4 h-4 mr-1" />
                        {pedido.transportista.nombre}
                      </div>
                    )}
                  </div>

                  {/* Acciones */}
                  <div className="flex items-start space-x-2">
                    <div className="flex flex-col items-end gap-2">
                      <EstadoStepper estado={pedido.estado} />
                      {pedido.estado_pago && (
                        <span className={`px-3 py-1 rounded-full text-xs font-medium ${getEstadoPagoColor(pedido.estado_pago)}`}>
                          {getEstadoPagoLabel(pedido.estado_pago)}
                        </span>
                      )}
                    </div>
                    <AccionesDropdown
                      pedido={pedido}
                      isAdmin={isAdmin}
                      isPreventista={isPreventista}
                      isTransportista={isTransportista}
                      onHistorial={onVerHistorial}
                      onEditar={onEditarPedido}
                      onPreparar={onMarcarEnPreparacion}
                      onAsignar={onAsignarTransportista}
                      onEntregado={onMarcarEntregado}
                      onRevertir={onDesmarcarEntregado}
                      onEliminar={onEliminarPedido}
                    />
                  </div>
                </div>

                {/* Contenido del pedido */}
                <div className="mt-3 pt-3 border-t">
                  <p className="text-sm text-gray-600 mb-2">
                    {pedido.items?.map(i => (
                      <span key={i.id} className="inline-block mr-2 mb-1 px-2 py-0.5 bg-gray-100 dark:bg-gray-700 rounded text-xs dark:text-gray-300">
                        {i.producto?.nombre} x{i.cantidad}
                      </span>
                    ))}
                  </p>

                  {pedido.notas && (
                    <div className="mb-2 p-2 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg">
                      <p className="text-xs text-blue-700 dark:text-blue-300 flex items-start">
                        <FileText className="w-3 h-3 mr-1 mt-0.5 flex-shrink-0" />
                        <span>{pedido.notas}</span>
                      </p>
                    </div>
                  )}

                  <div className="flex flex-wrap justify-between items-center gap-2">
                    <div className="flex flex-col">
                      <p className="text-lg font-bold text-blue-600">{formatPrecio(pedido.total)}</p>
                      {pedido.forma_pago && (
                        <p className="text-xs text-gray-500 flex items-center">
                          <CreditCard className="w-3 h-3 mr-1" />
                          {getFormaPagoLabel(pedido.forma_pago)}
                        </p>
                      )}
                    </div>
                  </div>
                </div>
              </div>
            ))}
          </div>

          <Paginacion
            paginaActual={paginaActual}
            totalPaginas={totalPaginas}
            onPageChange={onPageChange}
            totalItems={pedidosParaMostrar.length}
            itemsLabel="pedidos"
          />
        </>
      )}
    </div>
  );
}
