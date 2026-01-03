import React, { useState } from 'react';
import { RefreshCw, Download, DollarSign, ShoppingCart, Clock, Package, Truck, Check } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';

const periodoLabels = {
  hoy: 'Hoy',
  semana: 'Última semana',
  mes: 'Este mes',
  anio: 'Este año',
  historico: 'Histórico',
  personalizado: 'Personalizado'
};

export default function VistaDashboard({
  metricas,
  loading,
  filtroPeriodo,
  onCambiarPeriodo,
  onRefetch,
  onDescargarBackup,
  exportando
}) {
  const [fechaDesdeLocal, setFechaDesdeLocal] = useState('');
  const [fechaHastaLocal, setFechaHastaLocal] = useState('');
  const [mostrarFechasPersonalizadas, setMostrarFechasPersonalizadas] = useState(false);

  const handlePeriodoChange = (periodo) => {
    if (periodo === 'personalizado') {
      setMostrarFechasPersonalizadas(true);
    } else {
      setMostrarFechasPersonalizadas(false);
      onCambiarPeriodo(periodo);
    }
  };

  const aplicarFechasPersonalizadas = () => {
    if (fechaDesdeLocal || fechaHastaLocal) {
      onCambiarPeriodo('personalizado', fechaDesdeLocal || null, fechaHastaLocal || null);
    }
  };

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <h1 className="text-2xl font-bold text-gray-800">Dashboard</h1>
        <div className="flex flex-wrap gap-2">
          <button
            onClick={onRefetch}
            disabled={loading}
            className="flex items-center space-x-2 px-4 py-2 bg-white border rounded-lg hover:bg-gray-50 transition-colors"
          >
            <RefreshCw className={`w-5 h-5 ${loading ? 'animate-spin' : ''}`} />
            <span>Actualizar</span>
          </button>
          <button
            onClick={() => onDescargarBackup('completo')}
            disabled={exportando}
            className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
          >
            <Download className="w-5 h-5" />
            <span>Backup</span>
          </button>
        </div>
      </div>

      {/* Filtro de período */}
      <div className="bg-white rounded-xl shadow p-4">
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-sm font-medium text-gray-600 mr-2">Período:</span>
          {Object.entries(periodoLabels).map(([key, label]) => (
            <button
              key={key}
              onClick={() => handlePeriodoChange(key)}
              className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-colors ${
                filtroPeriodo === key
                  ? 'bg-blue-600 text-white'
                  : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
              }`}
            >
              {label}
            </button>
          ))}
        </div>
        {mostrarFechasPersonalizadas && (
          <div className="mt-4 flex flex-wrap items-end gap-3">
            <div>
              <label className="block text-xs text-gray-500 mb-1">Desde</label>
              <input
                type="date"
                value={fechaDesdeLocal}
                onChange={e => setFechaDesdeLocal(e.target.value)}
                className="px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
              />
            </div>
            <div>
              <label className="block text-xs text-gray-500 mb-1">Hasta</label>
              <input
                type="date"
                value={fechaHastaLocal}
                onChange={e => setFechaHastaLocal(e.target.value)}
                className="px-3 py-2 border rounded-lg text-sm focus:ring-2 focus:ring-blue-500"
              />
            </div>
            <button
              onClick={aplicarFechasPersonalizadas}
              className="px-4 py-2 bg-blue-600 text-white rounded-lg text-sm hover:bg-blue-700 transition-colors"
            >
              Aplicar
            </button>
          </div>
        )}
      </div>

      {loading ? <LoadingSpinner /> : (
        <>
          {/* Métricas principales del período */}
          <div className="grid grid-cols-2 gap-4">
            <div className="bg-white rounded-xl shadow p-4">
              <div className="flex items-center space-x-3">
                <div className="p-3 bg-green-100 rounded-lg">
                  <DollarSign className="w-6 h-6 text-green-600" />
                </div>
                <div>
                  <p className="text-sm text-gray-500">Ventas ({periodoLabels[filtroPeriodo]})</p>
                  <p className="text-2xl font-bold text-green-600">{formatPrecio(metricas.ventasPeriodo)}</p>
                </div>
              </div>
            </div>
            <div className="bg-white rounded-xl shadow p-4">
              <div className="flex items-center space-x-3">
                <div className="p-3 bg-blue-100 rounded-lg">
                  <ShoppingCart className="w-6 h-6 text-blue-600" />
                </div>
                <div>
                  <p className="text-sm text-gray-500">Pedidos ({periodoLabels[filtroPeriodo]})</p>
                  <p className="text-2xl font-bold text-blue-600">{metricas.pedidosPeriodo}</p>
                </div>
              </div>
            </div>
          </div>

          {/* Estados de pedidos */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-yellow-50 border border-yellow-200 rounded-lg p-4">
              <div className="flex items-center space-x-2">
                <Clock className="w-5 h-5 text-yellow-600" />
                <span className="text-yellow-800 font-medium">Pendientes</span>
              </div>
              <p className="text-3xl font-bold text-yellow-600 mt-2">
                {metricas.pedidosPorEstado.pendiente}
              </p>
            </div>
            <div className="bg-orange-50 border border-orange-200 rounded-lg p-4">
              <div className="flex items-center space-x-2">
                <Package className="w-5 h-5 text-orange-600" />
                <span className="text-orange-800 font-medium">En preparación</span>
              </div>
              <p className="text-3xl font-bold text-orange-600 mt-2">
                {metricas.pedidosPorEstado.en_preparacion || 0}
              </p>
            </div>
            <div className="bg-blue-50 border border-blue-200 rounded-lg p-4">
              <div className="flex items-center space-x-2">
                <Truck className="w-5 h-5 text-blue-600" />
                <span className="text-blue-800 font-medium">En camino</span>
              </div>
              <p className="text-3xl font-bold text-blue-600 mt-2">
                {metricas.pedidosPorEstado.asignado}
              </p>
            </div>
            <div className="bg-green-50 border border-green-200 rounded-lg p-4">
              <div className="flex items-center space-x-2">
                <Check className="w-5 h-5 text-green-600" />
                <span className="text-green-800 font-medium">Entregados</span>
              </div>
              <p className="text-3xl font-bold text-green-600 mt-2">
                {metricas.pedidosPorEstado.entregado}
              </p>
            </div>
          </div>

          {/* Gráficos */}
          <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
            {/* Ventas últimos 7 días */}
            <div className="bg-white rounded-xl shadow p-4">
              <h3 className="font-semibold mb-4 text-gray-800">Ventas últimos 7 días</h3>
              <div className="space-y-2">
                {metricas.ventasPorDia.map((d, i) => {
                  const maxVenta = Math.max(...metricas.ventasPorDia.map(x => x.ventas)) || 1;
                  const porcentaje = (d.ventas / maxVenta) * 100;
                  return (
                    <div key={i} className="flex items-center space-x-3">
                      <span className="w-12 text-sm text-gray-600">{d.dia}</span>
                      <div className="flex-1 bg-gray-200 rounded-full h-6">
                        <div
                          className="bg-gradient-to-r from-blue-500 to-blue-600 rounded-full h-6 flex items-center justify-end pr-2 transition-all"
                          style={{ width: `${Math.max(porcentaje, 10)}%` }}
                        >
                          <span className="text-xs text-white font-medium">{formatPrecio(d.ventas)}</span>
                        </div>
                      </div>
                    </div>
                  );
                })}
              </div>
            </div>

            {/* Top 5 productos */}
            <div className="bg-white rounded-xl shadow p-4">
              <h3 className="font-semibold mb-4 text-gray-800">Top 5 Productos ({periodoLabels[filtroPeriodo]})</h3>
              <div className="space-y-3">
                {metricas.productosMasVendidos.length === 0 ? (
                  <p className="text-gray-500 text-center py-4">Sin datos en este período</p>
                ) : metricas.productosMasVendidos.map((p, i) => (
                  <div key={p.id} className="flex items-center justify-between">
                    <div className="flex items-center space-x-3">
                      <span className={`w-6 h-6 rounded-full flex items-center justify-center text-sm font-bold ${
                        i === 0 ? 'bg-yellow-400 text-yellow-900' :
                        i === 1 ? 'bg-gray-300 text-gray-700' :
                        i === 2 ? 'bg-orange-400 text-orange-900' :
                        'bg-gray-100 text-gray-600'
                      }`}>
                        {i + 1}
                      </span>
                      <span className="font-medium">{p.nombre}</span>
                    </div>
                    <span className="text-sm text-gray-600">{p.cantidad} unid.</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
