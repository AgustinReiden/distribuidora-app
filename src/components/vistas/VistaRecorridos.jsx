import React, { useState, useEffect, useMemo } from 'react';
import { Route, Truck, Calendar, Clock, Package, Check, MapPin, Phone, DollarSign, ChevronDown, ChevronUp, Navigation, RefreshCw, BarChart3, X } from 'lucide-react';
import { formatPrecio, formatFecha } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';

// Componente de tarjeta de pedido en recorrido
function PedidoRecorridoCard({ pedido, orden }) {
  const [expandido, setExpandido] = useState(false);

  const estadoColors = {
    entregado: 'bg-green-100 text-green-700 border-green-200',
    asignado: 'bg-blue-100 text-blue-700 border-blue-200',
    pendiente: 'bg-yellow-100 text-yellow-700 border-yellow-200'
  };

  const estadoPagoColors = {
    pagado: 'bg-green-100 text-green-700',
    parcial: 'bg-yellow-100 text-yellow-700',
    pendiente: 'bg-red-100 text-red-700'
  };

  const pedidoData = pedido.pedido || pedido;
  const cliente = pedidoData.cliente || {};

  return (
    <div className={`bg-white dark:bg-gray-800 rounded-lg border shadow-sm ${
      pedidoData.estado === 'entregado'
        ? 'border-green-300 dark:border-green-700'
        : 'border-gray-200 dark:border-gray-700'
    }`}>
      <div className="p-3">
        <div className="flex items-start gap-3">
          {/* Numero de orden */}
          <div className={`w-8 h-8 rounded-full flex items-center justify-center text-white font-bold text-sm flex-shrink-0 ${
            pedidoData.estado === 'entregado' ? 'bg-green-500' : 'bg-blue-500'
          }`}>
            {pedidoData.estado === 'entregado' ? <Check className="w-4 h-4" /> : orden}
          </div>

          {/* Info del pedido */}
          <div className="flex-1 min-w-0">
            <div className="flex items-start justify-between gap-2">
              <div>
                <h4 className="font-semibold text-gray-900 dark:text-white text-sm">
                  {cliente.nombre_fantasia || 'Cliente'}
                </h4>
                <p className="text-xs text-gray-500 dark:text-gray-400">Pedido #{pedidoData.id}</p>
              </div>
              <div className="flex flex-col items-end gap-1">
                <span className={`px-2 py-0.5 text-xs font-medium rounded-full ${estadoColors[pedidoData.estado] || estadoColors.pendiente}`}>
                  {pedidoData.estado === 'entregado' ? 'Entregado' : 'Pendiente'}
                </span>
                <span className={`px-2 py-0.5 text-xs font-medium rounded-full ${estadoPagoColors[pedidoData.estado_pago] || estadoPagoColors.pendiente}`}>
                  {pedidoData.estado_pago === 'pagado' ? 'Pagado' : pedidoData.estado_pago === 'parcial' ? 'Parcial' : 'Pend. Pago'}
                </span>
              </div>
            </div>

            <div className="mt-2 flex items-center gap-4 text-sm">
              <span className="font-bold text-blue-600">{formatPrecio(pedidoData.total)}</span>
              {pedidoData.monto_pagado > 0 && pedidoData.estado_pago === 'parcial' && (
                <span className="text-xs text-gray-500">
                  (Pagado: {formatPrecio(pedidoData.monto_pagado)})
                </span>
              )}
            </div>

            {/* Direccion */}
            <a
              href={`https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(cliente.direccion || '')}`}
              target="_blank"
              rel="noopener noreferrer"
              className="flex items-start gap-1 mt-2 text-blue-600 dark:text-blue-400 hover:underline text-xs"
            >
              <MapPin className="w-3 h-3 mt-0.5 flex-shrink-0" />
              <span>{cliente.direccion || 'Sin dirección'}</span>
            </a>

            {cliente.telefono && (
              <a
                href={`tel:${cliente.telefono}`}
                className="flex items-center gap-1 mt-1 text-gray-500 dark:text-gray-400 hover:text-blue-600 text-xs"
              >
                <Phone className="w-3 h-3" />
                <span>{cliente.telefono}</span>
              </a>
            )}
          </div>
        </div>

        {/* Expandir detalles */}
        <button
          onClick={() => setExpandido(!expandido)}
          className="w-full flex items-center justify-center gap-1 mt-2 pt-2 border-t dark:border-gray-700 text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 text-xs"
        >
          <span>{expandido ? 'Ver menos' : 'Ver productos'}</span>
          {expandido ? <ChevronUp className="w-3 h-3" /> : <ChevronDown className="w-3 h-3" />}
        </button>
      </div>

      {/* Contenido expandido */}
      {expandido && pedidoData.items && (
        <div className="px-3 pb-3 border-t dark:border-gray-700">
          <div className="mt-2 space-y-1">
            {pedidoData.items.map(item => (
              <div key={item.id} className="flex justify-between text-xs bg-gray-50 dark:bg-gray-700 p-2 rounded">
                <span className="text-gray-700 dark:text-gray-300">
                  {item.cantidad}x {item.producto?.nombre || 'Producto'}
                </span>
                <span className="text-gray-500">{formatPrecio(item.subtotal || item.precio_unitario * item.cantidad)}</span>
              </div>
            ))}
          </div>
          {pedidoData.notas && (
            <div className="mt-2 p-2 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded text-xs">
              <strong>Nota:</strong> {pedidoData.notas}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// Componente de tarjeta de recorrido
function RecorridoCard({ recorrido, defaultExpanded = false }) {
  const [expandido, setExpandido] = useState(defaultExpanded);

  const pedidosOrdenados = useMemo(() => {
    if (!recorrido.pedidos) return [];
    return [...recorrido.pedidos].sort((a, b) => (a.orden_entrega || 0) - (b.orden_entrega || 0));
  }, [recorrido.pedidos]);

  const totalPedidos = recorrido.total_pedidos || pedidosOrdenados.length;
  const pedidosEntregados = recorrido.pedidos_entregados ||
    pedidosOrdenados.filter(p => (p.pedido?.estado || p.estado) === 'entregado').length;
  const progreso = totalPedidos > 0 ? Math.round((pedidosEntregados / totalPedidos) * 100) : 0;

  const estadoRecorrido = recorrido.estado === 'completado'
    ? { label: 'Completado', color: 'bg-green-100 text-green-700 border-green-300' }
    : progreso === 100
      ? { label: 'Listo', color: 'bg-green-100 text-green-700 border-green-300' }
      : { label: 'En curso', color: 'bg-blue-100 text-blue-700 border-blue-300' };

  return (
    <div className="bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700 shadow-sm overflow-hidden">
      {/* Header */}
      <div className="p-4 bg-gradient-to-r from-blue-50 to-blue-100 dark:from-blue-900/30 dark:to-blue-800/30 border-b dark:border-gray-700">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-12 h-12 bg-blue-600 rounded-full flex items-center justify-center">
              <Truck className="w-6 h-6 text-white" />
            </div>
            <div>
              <h3 className="font-bold text-gray-900 dark:text-white text-lg">
                {recorrido.transportista?.nombre || 'Transportista'}
              </h3>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                {formatFecha(recorrido.fecha)} • {totalPedidos} entregas
              </p>
            </div>
          </div>
          <span className={`px-3 py-1 rounded-full border text-sm font-medium ${estadoRecorrido.color}`}>
            {estadoRecorrido.label}
          </span>
        </div>

        {/* Barra de progreso */}
        <div className="mt-4">
          <div className="flex justify-between text-sm mb-1">
            <span className="text-gray-600 dark:text-gray-400">Progreso</span>
            <span className="font-medium text-gray-900 dark:text-white">{pedidosEntregados}/{totalPedidos}</span>
          </div>
          <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2">
            <div
              className="bg-green-500 h-2 rounded-full transition-all duration-500"
              style={{ width: `${progreso}%` }}
            />
          </div>
        </div>

        {/* Métricas */}
        <div className="grid grid-cols-3 gap-3 mt-4">
          <div className="bg-white/50 dark:bg-gray-700/50 rounded-lg p-2 text-center">
            <p className="text-lg font-bold text-gray-900 dark:text-white">
              {formatPrecio(recorrido.total_facturado || 0)}
            </p>
            <p className="text-xs text-gray-500 dark:text-gray-400">Facturado</p>
          </div>
          <div className="bg-white/50 dark:bg-gray-700/50 rounded-lg p-2 text-center">
            <p className="text-lg font-bold text-green-600">
              {formatPrecio(recorrido.total_cobrado || 0)}
            </p>
            <p className="text-xs text-gray-500 dark:text-gray-400">Cobrado</p>
          </div>
          <div className="bg-white/50 dark:bg-gray-700/50 rounded-lg p-2 text-center">
            <p className="text-lg font-bold text-red-600">
              {formatPrecio((recorrido.total_facturado || 0) - (recorrido.total_cobrado || 0))}
            </p>
            <p className="text-xs text-gray-500 dark:text-gray-400">Pendiente</p>
          </div>
        </div>
      </div>

      {/* Botón expandir */}
      <button
        onClick={() => setExpandido(!expandido)}
        className="w-full flex items-center justify-center gap-2 py-3 text-gray-600 dark:text-gray-400 hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors"
      >
        <Navigation className="w-4 h-4" />
        <span>{expandido ? 'Ocultar recorrido' : 'Ver recorrido detallado'}</span>
        {expandido ? <ChevronUp className="w-4 h-4" /> : <ChevronDown className="w-4 h-4" />}
      </button>

      {/* Lista de pedidos */}
      {expandido && (
        <div className="p-4 border-t dark:border-gray-700 bg-gray-50 dark:bg-gray-900/50">
          <h4 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-3 flex items-center gap-2">
            <Route className="w-4 h-4" />
            Orden de Entregas
          </h4>
          <div className="space-y-3">
            {pedidosOrdenados.length > 0 ? (
              pedidosOrdenados.map((pedido, index) => (
                <PedidoRecorridoCard
                  key={pedido.id || index}
                  pedido={pedido}
                  orden={pedido.orden_entrega || index + 1}
                />
              ))
            ) : (
              <p className="text-center text-gray-500 dark:text-gray-400 py-4">
                No hay pedidos en este recorrido
              </p>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

export default function VistaRecorridos({
  recorridos = [],
  loading = false,
  onRefresh,
  onFechaChange,
  fechaSeleccionada,
  estadisticas = null
}) {
  const [vistaEstadisticas, setVistaEstadisticas] = useState(false);
  const [fechaDesde, setFechaDesde] = useState(() => {
    const d = new Date();
    d.setDate(d.getDate() - 7);
    return d.toISOString().split('T')[0];
  });
  const [fechaHasta, setFechaHasta] = useState(() => new Date().toISOString().split('T')[0]);

  // Resumen del día
  const resumenDia = useMemo(() => {
    if (!recorridos.length) return null;

    return recorridos.reduce((acc, r) => ({
      totalRecorridos: acc.totalRecorridos + 1,
      totalPedidos: acc.totalPedidos + (r.total_pedidos || 0),
      pedidosEntregados: acc.pedidosEntregados + (r.pedidos_entregados || 0),
      totalFacturado: acc.totalFacturado + (r.total_facturado || 0),
      totalCobrado: acc.totalCobrado + (r.total_cobrado || 0)
    }), {
      totalRecorridos: 0,
      totalPedidos: 0,
      pedidosEntregados: 0,
      totalFacturado: 0,
      totalCobrado: 0
    });
  }, [recorridos]);

  const hoy = new Date().toISOString().split('T')[0];
  const esHoy = fechaSeleccionada === hoy;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white flex items-center gap-2">
            <Route className="w-7 h-7 text-blue-600" />
            Recorridos
          </h1>
          <p className="text-gray-500 dark:text-gray-400 mt-1">
            {esHoy ? 'Recorridos de hoy' : `Recorridos del ${formatFecha(fechaSeleccionada)}`}
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <button
            onClick={() => setVistaEstadisticas(!vistaEstadisticas)}
            className={`flex items-center gap-2 px-4 py-2 rounded-lg transition-colors ${
              vistaEstadisticas
                ? 'bg-purple-600 text-white'
                : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
            }`}
          >
            <BarChart3 className="w-5 h-5" />
            <span>Estadísticas</span>
          </button>
          <button
            onClick={onRefresh}
            disabled={loading}
            className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors disabled:opacity-50"
          >
            <RefreshCw className={`w-5 h-5 ${loading ? 'animate-spin' : ''}`} />
            <span>Actualizar</span>
          </button>
        </div>
      </div>

      {/* Selector de fecha */}
      <div className="bg-white dark:bg-gray-800 rounded-lg border dark:border-gray-700 p-4">
        <div className="flex flex-wrap items-center gap-4">
          <div className="flex items-center gap-2">
            <Calendar className="w-5 h-5 text-gray-500" />
            <span className="text-gray-700 dark:text-gray-300">Fecha:</span>
          </div>
          <input
            type="date"
            value={fechaSeleccionada}
            onChange={(e) => onFechaChange(e.target.value)}
            max={hoy}
            className="px-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
          />
          {!esHoy && (
            <button
              onClick={() => onFechaChange(hoy)}
              className="px-3 py-2 text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/30 rounded-lg transition-colors text-sm"
            >
              Ir a hoy
            </button>
          )}
        </div>
      </div>

      {/* Vista de estadísticas */}
      {vistaEstadisticas && (
        <div className="bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700 p-6">
          <div className="flex items-center justify-between mb-4">
            <h2 className="text-lg font-bold text-gray-800 dark:text-white flex items-center gap-2">
              <BarChart3 className="w-5 h-5 text-purple-600" />
              Estadísticas de Recorridos
            </h2>
            <button
              onClick={() => setVistaEstadisticas(false)}
              className="p-1 hover:bg-gray-100 dark:hover:bg-gray-700 rounded"
            >
              <X className="w-5 h-5 text-gray-500" />
            </button>
          </div>

          <div className="flex flex-wrap gap-4 mb-4">
            <div>
              <label className="text-sm text-gray-600 dark:text-gray-400">Desde</label>
              <input
                type="date"
                value={fechaDesde}
                onChange={(e) => setFechaDesde(e.target.value)}
                className="ml-2 px-3 py-1 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white text-sm"
              />
            </div>
            <div>
              <label className="text-sm text-gray-600 dark:text-gray-400">Hasta</label>
              <input
                type="date"
                value={fechaHasta}
                onChange={(e) => setFechaHasta(e.target.value)}
                className="ml-2 px-3 py-1 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white text-sm"
              />
            </div>
          </div>

          {estadisticas ? (
            <div className="space-y-4">
              <div className="grid grid-cols-2 sm:grid-cols-4 gap-4">
                <div className="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-4 text-center">
                  <p className="text-3xl font-bold text-blue-600">{estadisticas.total}</p>
                  <p className="text-sm text-gray-600 dark:text-gray-400">Recorridos totales</p>
                </div>
                <div className="bg-green-50 dark:bg-green-900/20 rounded-lg p-4 text-center">
                  <p className="text-3xl font-bold text-green-600">
                    {estadisticas.porTransportista?.reduce((s, t) => s + t.pedidosEntregados, 0) || 0}
                  </p>
                  <p className="text-sm text-gray-600 dark:text-gray-400">Entregas realizadas</p>
                </div>
                <div className="bg-purple-50 dark:bg-purple-900/20 rounded-lg p-4 text-center">
                  <p className="text-2xl font-bold text-purple-600">
                    {formatPrecio(estadisticas.porTransportista?.reduce((s, t) => s + t.totalFacturado, 0) || 0)}
                  </p>
                  <p className="text-sm text-gray-600 dark:text-gray-400">Total facturado</p>
                </div>
                <div className="bg-emerald-50 dark:bg-emerald-900/20 rounded-lg p-4 text-center">
                  <p className="text-2xl font-bold text-emerald-600">
                    {formatPrecio(estadisticas.porTransportista?.reduce((s, t) => s + t.totalCobrado, 0) || 0)}
                  </p>
                  <p className="text-sm text-gray-600 dark:text-gray-400">Total cobrado</p>
                </div>
              </div>

              {estadisticas.porTransportista && estadisticas.porTransportista.length > 0 && (
                <div>
                  <h3 className="font-semibold text-gray-800 dark:text-white mb-3">Por Transportista</h3>
                  <div className="space-y-2">
                    {estadisticas.porTransportista.map((t, idx) => (
                      <div key={idx} className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3 flex items-center justify-between">
                        <div className="flex items-center gap-3">
                          <div className="w-10 h-10 bg-blue-100 dark:bg-blue-900/50 rounded-full flex items-center justify-center">
                            <Truck className="w-5 h-5 text-blue-600" />
                          </div>
                          <div>
                            <p className="font-medium text-gray-900 dark:text-white">
                              {t.transportista?.nombre || 'Transportista'}
                            </p>
                            <p className="text-sm text-gray-500">
                              {t.recorridos} recorridos • {t.pedidosEntregados}/{t.pedidosTotales} entregas
                            </p>
                          </div>
                        </div>
                        <div className="text-right">
                          <p className="font-bold text-blue-600">{formatPrecio(t.totalFacturado)}</p>
                          <p className="text-sm text-green-600">Cobrado: {formatPrecio(t.totalCobrado)}</p>
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          ) : (
            <p className="text-center text-gray-500 dark:text-gray-400 py-8">
              Seleccione un rango de fechas para ver las estadísticas
            </p>
          )}
        </div>
      )}

      {/* Resumen del día */}
      {resumenDia && !vistaEstadisticas && (
        <div className="bg-gradient-to-r from-blue-600 to-blue-700 rounded-xl p-6 text-white shadow-lg">
          <h2 className="text-xl font-bold mb-4">Resumen del Día</h2>
          <div className="grid grid-cols-2 sm:grid-cols-5 gap-4">
            <div className="bg-white/10 rounded-lg p-3 text-center">
              <p className="text-3xl font-bold">{resumenDia.totalRecorridos}</p>
              <p className="text-sm text-blue-100">Recorridos</p>
            </div>
            <div className="bg-white/10 rounded-lg p-3 text-center">
              <p className="text-3xl font-bold">{resumenDia.totalPedidos}</p>
              <p className="text-sm text-blue-100">Pedidos</p>
            </div>
            <div className="bg-white/10 rounded-lg p-3 text-center">
              <p className="text-3xl font-bold">{resumenDia.pedidosEntregados}</p>
              <p className="text-sm text-blue-100">Entregados</p>
            </div>
            <div className="bg-white/10 rounded-lg p-3 text-center">
              <p className="text-xl font-bold">{formatPrecio(resumenDia.totalFacturado)}</p>
              <p className="text-sm text-blue-100">Facturado</p>
            </div>
            <div className="bg-white/10 rounded-lg p-3 text-center">
              <p className="text-xl font-bold">{formatPrecio(resumenDia.totalCobrado)}</p>
              <p className="text-sm text-blue-100">Cobrado</p>
            </div>
          </div>
        </div>
      )}

      {/* Lista de recorridos */}
      {loading ? (
        <LoadingSpinner />
      ) : recorridos.length === 0 ? (
        <div className="text-center py-12 bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700">
          <Route className="w-16 h-16 mx-auto text-gray-300 dark:text-gray-600 mb-4" />
          <h3 className="text-xl font-semibold text-gray-600 dark:text-gray-400 mb-2">
            No hay recorridos
          </h3>
          <p className="text-gray-500 dark:text-gray-500">
            {esHoy
              ? 'No se han creado recorridos para hoy. Los recorridos se crean al optimizar rutas.'
              : 'No hay recorridos registrados para esta fecha.'
            }
          </p>
        </div>
      ) : (
        <div className="space-y-6">
          {recorridos.map((recorrido, index) => (
            <RecorridoCard
              key={recorrido.id || index}
              recorrido={recorrido}
              defaultExpanded={recorridos.length === 1}
            />
          ))}
        </div>
      )}
    </div>
  );
}
