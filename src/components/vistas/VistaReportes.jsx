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
      <h1 className="text-2xl font-bold text-gray-800">Reportes por Preventista</h1>

      {/* Filtros */}
      <div className="bg-white border rounded-lg shadow-sm p-4">
        <h2 className="font-semibold mb-3 text-gray-700">Filtrar por Fecha</h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 items-end">
          <div>
            <label className="block text-sm font-medium mb-1 text-gray-600">Desde</label>
            <input
              type="date"
              value={fechaDesde}
              onChange={e => setFechaDesde(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1 text-gray-600">Hasta</label>
            <input
              type="date"
              value={fechaHasta}
              onChange={e => setFechaHasta(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <div className="flex gap-2">
            <button
              onClick={handleGenerarReporte}
              disabled={loading}
              className="flex items-center justify-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 transition-colors"
            >
              {loading ? <Loader2 className="w-5 h-5 animate-spin" /> : <BarChart3 className="w-5 h-5" />}
              <span>Generar Reporte</span>
            </button>
            {(fechaDesde || fechaHasta) && (
              <button
                onClick={handleLimpiarFiltros}
                disabled={loading}
                className="flex items-center justify-center space-x-2 px-4 py-2 bg-gray-500 text-white rounded-lg hover:bg-gray-600 disabled:opacity-50 transition-colors"
              >
                <X className="w-5 h-5" />
                <span>Limpiar</span>
              </button>
            )}
          </div>
        </div>
        {(fechaDesde || fechaHasta) && (
          <div className="mt-2 text-sm text-gray-600">
            Filtrando desde {fechaDesde || '(sin límite)'} hasta {fechaHasta || '(sin límite)'}
          </div>
        )}
      </div>

      {/* Tabla de reportes */}
      {loading ? (
        <LoadingSpinner />
      ) : reportePreventistas.length === 0 ? (
        <div className="text-center py-12 text-gray-500 bg-white border rounded-lg shadow-sm">
          <TrendingUp className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p className="font-semibold">No hay datos para mostrar</p>
          <p className="text-sm mt-2">No se encontraron pedidos con preventistas asignados en el rango seleccionado</p>
          <p className="text-sm mt-1 text-blue-600">Verifica que los pedidos tengan un usuario (preventista) asignado</p>
        </div>
      ) : (
        <div className="bg-white border rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700">Preventista</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">Total Ventas</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">Cant. Pedidos</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">Pendientes</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">En Camino</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">Entregados</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">Total Pagado</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">Total Pendiente</th>
              </tr>
            </thead>
            <tbody className="divide-y">
              {reportePreventistas.map((preventista, index) => (
                <tr key={preventista.id || index} className="hover:bg-gray-50 transition-colors">
                  <td className="px-4 py-3">
                    <div>
                      <p className="font-medium text-gray-800">{preventista.nombre}</p>
                      <p className="text-sm text-gray-500">{preventista.email}</p>
                    </div>
                  </td>
                  <td className="px-4 py-3 text-right font-bold text-blue-600">
                    {formatPrecio(preventista.totalVentas)}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className="px-2 py-1 bg-purple-100 text-purple-700 rounded-full text-sm">
                      {preventista.cantidadPedidos}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className="px-2 py-1 bg-yellow-100 text-yellow-700 rounded-full text-sm">
                      {preventista.pedidosPendientes}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className="px-2 py-1 bg-blue-100 text-blue-700 rounded-full text-sm">
                      {preventista.pedidosAsignados}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className="px-2 py-1 bg-green-100 text-green-700 rounded-full text-sm">
                      {preventista.pedidosEntregados}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right font-semibold text-green-600">
                    {formatPrecio(preventista.totalPagado)}
                  </td>
                  <td className="px-4 py-3 text-right font-semibold text-red-600">
                    {formatPrecio(preventista.totalPendiente)}
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot className="bg-gray-50 font-bold">
              <tr>
                <td className="px-4 py-3 text-gray-800">TOTAL</td>
                <td className="px-4 py-3 text-right text-blue-600">
                  {formatPrecio(reportePreventistas.reduce((sum, p) => sum + p.totalVentas, 0))}
                </td>
                <td className="px-4 py-3 text-right">
                  {reportePreventistas.reduce((sum, p) => sum + p.cantidadPedidos, 0)}
                </td>
                <td className="px-4 py-3 text-right">
                  {reportePreventistas.reduce((sum, p) => sum + p.pedidosPendientes, 0)}
                </td>
                <td className="px-4 py-3 text-right">
                  {reportePreventistas.reduce((sum, p) => sum + p.pedidosAsignados, 0)}
                </td>
                <td className="px-4 py-3 text-right">
                  {reportePreventistas.reduce((sum, p) => sum + p.pedidosEntregados, 0)}
                </td>
                <td className="px-4 py-3 text-right text-green-600">
                  {formatPrecio(reportePreventistas.reduce((sum, p) => sum + p.totalPagado, 0))}
                </td>
                <td className="px-4 py-3 text-right text-red-600">
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
