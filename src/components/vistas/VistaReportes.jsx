import React, { useState, useEffect } from 'react';
import { TrendingUp, BarChart3, X, Loader2 } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';

export default function VistaReportes({
  reportePreventistas,
  reporteInicializado,
  loading,
  onCalcularReporte
}) {
  const [fechaDesde, setFechaDesde] = useState('');
  const [fechaHasta, setFechaHasta] = useState('');

  // Cargar reporte automáticamente solo la primera vez
  useEffect(() => {
    if (!reporteInicializado && !loading) {
      onCalcularReporte(null, null);
    }
  }, [reporteInicializado, loading, onCalcularReporte]);

  const handleGenerarReporte = async () => {
    await onCalcularReporte(fechaDesde || null, fechaHasta || null);
  };

  const handleLimpiarFiltros = async () => {
    setFechaDesde('');
    setFechaHasta('');
    await onCalcularReporte(null, null);
  };

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Reportes por Preventista</h1>

      {/* Filtros */}
      <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4">
        <h2 className="font-semibold mb-3 text-gray-700 dark:text-gray-200">Filtrar por Fecha</h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 items-end">
          <div>
            <label htmlFor="fecha-desde" className="block text-sm font-medium mb-1 text-gray-600 dark:text-gray-400">Desde</label>
            <input
              id="fecha-desde"
              type="date"
              value={fechaDesde}
              onChange={e => setFechaDesde(e.target.value)}
              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <div>
            <label htmlFor="fecha-hasta" className="block text-sm font-medium mb-1 text-gray-600 dark:text-gray-400">Hasta</label>
            <input
              id="fecha-hasta"
              type="date"
              value={fechaHasta}
              onChange={e => setFechaHasta(e.target.value)}
              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <div className="flex gap-2">
            <button
              onClick={handleGenerarReporte}
              disabled={loading}
              className="flex items-center justify-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 transition-colors"
              aria-busy={loading}
            >
              {loading ? <Loader2 className="w-5 h-5 animate-spin" aria-hidden="true" /> : <BarChart3 className="w-5 h-5" aria-hidden="true" />}
              <span>Generar Reporte</span>
            </button>
            {(fechaDesde || fechaHasta) && (
              <button
                onClick={handleLimpiarFiltros}
                disabled={loading}
                className="flex items-center justify-center space-x-2 px-4 py-2 bg-gray-500 dark:bg-gray-600 text-white rounded-lg hover:bg-gray-600 dark:hover:bg-gray-500 disabled:opacity-50 transition-colors"
              >
                <X className="w-5 h-5" aria-hidden="true" />
                <span>Limpiar</span>
              </button>
            )}
          </div>
        </div>
        {(fechaDesde || fechaHasta) && (
          <div className="mt-2 text-sm text-gray-600 dark:text-gray-400" aria-live="polite">
            Filtrando desde {fechaDesde || '(sin límite)'} hasta {fechaHasta || '(sin límite)'}
          </div>
        )}
      </div>

      {/* Tabla de reportes */}
      {loading ? (
        <LoadingSpinner />
      ) : reportePreventistas.length === 0 ? (
        <div className="text-center py-12 text-gray-500 dark:text-gray-400 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm">
          <TrendingUp className="w-12 h-12 mx-auto mb-3 opacity-50" aria-hidden="true" />
          <p className="font-semibold">No hay datos para mostrar</p>
          <p className="text-sm mt-2">No se encontraron pedidos con preventistas asignados en el rango seleccionado</p>
          <p className="text-sm mt-1 text-blue-600 dark:text-blue-400">Verifica que los pedidos tengan un usuario (preventista) asignado</p>
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full" role="table">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th scope="col" className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Preventista</th>
                <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Total Ventas</th>
                <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Cant. Pedidos</th>
                <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Pendientes</th>
                <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">En Camino</th>
                <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Entregados</th>
                <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Total Pagado</th>
                <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Total Pendiente</th>
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {reportePreventistas.map((preventista, index) => (
                <tr key={preventista.id || index} className="hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors">
                  <td className="px-4 py-3">
                    <div>
                      <p className="font-medium text-gray-800 dark:text-white">{preventista.nombre}</p>
                      <p className="text-sm text-gray-500 dark:text-gray-400">{preventista.email}</p>
                    </div>
                  </td>
                  <td className="px-4 py-3 text-right font-bold text-blue-600 dark:text-blue-400">
                    {formatPrecio(preventista.totalVentas)}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className="px-2 py-1 bg-purple-100 dark:bg-purple-900/30 text-purple-700 dark:text-purple-400 rounded-full text-sm">
                      {preventista.cantidadPedidos}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className="px-2 py-1 bg-yellow-100 dark:bg-yellow-900/30 text-yellow-700 dark:text-yellow-400 rounded-full text-sm">
                      {preventista.pedidosPendientes}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className="px-2 py-1 bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-400 rounded-full text-sm">
                      {preventista.pedidosAsignados}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className="px-2 py-1 bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400 rounded-full text-sm">
                      {preventista.pedidosEntregados}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right font-semibold text-green-600 dark:text-green-400">
                    {formatPrecio(preventista.totalPagado)}
                  </td>
                  <td className="px-4 py-3 text-right font-semibold text-red-600 dark:text-red-400">
                    {formatPrecio(preventista.totalPendiente)}
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
              <tr>
                <td className="px-4 py-3 text-gray-800 dark:text-white">TOTAL</td>
                <td className="px-4 py-3 text-right text-blue-600 dark:text-blue-400">
                  {formatPrecio(reportePreventistas.reduce((sum, p) => sum + p.totalVentas, 0))}
                </td>
                <td className="px-4 py-3 text-right dark:text-gray-300">
                  {reportePreventistas.reduce((sum, p) => sum + p.cantidadPedidos, 0)}
                </td>
                <td className="px-4 py-3 text-right dark:text-gray-300">
                  {reportePreventistas.reduce((sum, p) => sum + p.pedidosPendientes, 0)}
                </td>
                <td className="px-4 py-3 text-right dark:text-gray-300">
                  {reportePreventistas.reduce((sum, p) => sum + p.pedidosAsignados, 0)}
                </td>
                <td className="px-4 py-3 text-right dark:text-gray-300">
                  {reportePreventistas.reduce((sum, p) => sum + p.pedidosEntregados, 0)}
                </td>
                <td className="px-4 py-3 text-right text-green-600 dark:text-green-400">
                  {formatPrecio(reportePreventistas.reduce((sum, p) => sum + p.totalPagado, 0))}
                </td>
                <td className="px-4 py-3 text-right text-red-600 dark:text-red-400">
                  {formatPrecio(reportePreventistas.reduce((sum, p) => sum + p.totalPendiente, 0))}
                </td>
              </tr>
            </tfoot>
          </table>
        </div>
      )}
    </div>
  );
}
