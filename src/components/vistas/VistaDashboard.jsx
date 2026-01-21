import React, { useState, useMemo, memo } from 'react';
import { RefreshCw, Download, DollarSign, ShoppingCart, Clock, Package, Truck, Check, TrendingUp, TrendingDown, Minus, Target, Users, AlertTriangle } from 'lucide-react';
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

// Componente de indicador de tendencia
const TendenciaIndicator = memo(function TendenciaIndicator({ valor, comparacion, invertido = false }) {
  if (!comparacion || comparacion === 0) {
    return (
      <span className="flex items-center text-xs text-gray-500">
        <Minus className="w-3 h-3 mr-1" />
        Sin datos previos
      </span>
    );
  }

  const porcentaje = ((valor - comparacion) / comparacion) * 100;
  const esPositivo = invertido ? porcentaje < 0 : porcentaje > 0;
  const esNeutro = Math.abs(porcentaje) < 1;

  if (esNeutro) {
    return (
      <span className="flex items-center text-xs text-gray-500">
        <Minus className="w-3 h-3 mr-1" />
        Sin cambios
      </span>
    );
  }

  return (
    <span className={`flex items-center text-xs ${esPositivo ? 'text-green-600' : 'text-red-600'}`}>
      {esPositivo ? <TrendingUp className="w-3 h-3 mr-1" /> : <TrendingDown className="w-3 h-3 mr-1" />}
      {Math.abs(porcentaje).toFixed(1)}% vs período anterior
    </span>
  );
});

// Componente de tarjeta de métrica grande
const MetricaCard = memo(function MetricaCard({ icono, titulo, valor, subtitulo, colorClase, tendencia }) {
  const Icono = icono;
  return (
    <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6 hover:shadow-xl transition-shadow">
      <div className="flex items-start justify-between">
        <div className={`p-3 ${colorClase.bg} rounded-xl`}>
          <Icono className={`w-7 h-7 ${colorClase.icon}`} />
        </div>
        {tendencia && (
          <div className="text-right">
            {tendencia}
          </div>
        )}
      </div>
      <div className="mt-4">
        <p className="text-sm text-gray-500 dark:text-gray-400">{titulo}</p>
        <p className={`text-3xl font-bold mt-1 ${colorClase.text}`}>{valor}</p>
        {subtitulo && <p className="text-xs text-gray-400 mt-1">{subtitulo}</p>}
      </div>
    </div>
  );
});

// Componente de tarjeta de estado pequeña
const EstadoCard = memo(function EstadoCard({ icono, titulo, valor, colorClase, onClick }) {
  const Icono = icono;
  return (
    <button
      onClick={onClick}
      className={`${colorClase.bg} border ${colorClase.border} rounded-xl p-4 text-left hover:scale-105 transition-transform w-full`}
    >
      <div className="flex items-center justify-between">
        <div className="flex items-center space-x-2">
          <Icono className={`w-5 h-5 ${colorClase.icon}`} />
          <span className={`${colorClase.text} font-medium text-sm`}>{titulo}</span>
        </div>
      </div>
      <p className={`text-3xl font-bold ${colorClase.icon} mt-2`}>{valor}</p>
    </button>
  );
});

// Componente de barra de progreso animada
const BarraProgreso = memo(function BarraProgreso({ dia, ventas, maxVenta, index }) {
  const porcentaje = maxVenta > 0 ? (ventas / maxVenta) * 100 : 0;
  const esHoy = index === 6; // Último día es hoy

  return (
    <div className="flex items-center space-x-3 group">
      <span className={`w-12 text-sm ${esHoy ? 'font-bold text-blue-600' : 'text-gray-600'}`}>
        {dia}
      </span>
      <div className="flex-1 bg-gray-200 dark:bg-gray-700 rounded-full h-8 overflow-hidden">
        <div
          className={`h-8 rounded-full flex items-center justify-end pr-3 transition-all duration-500 ${
            esHoy
              ? 'bg-gradient-to-r from-blue-500 to-blue-600'
              : 'bg-gradient-to-r from-blue-400 to-blue-500'
          }`}
          style={{
            width: `${Math.max(porcentaje, 15)}%`,
            animationDelay: `${index * 100}ms`
          }}
        >
          <span className="text-xs text-white font-medium truncate">
            {formatPrecio(ventas)}
          </span>
        </div>
      </div>
      <div className="w-16 text-right opacity-0 group-hover:opacity-100 transition-opacity">
        <span className="text-xs text-gray-500">{porcentaje.toFixed(0)}%</span>
      </div>
    </div>
  );
});

export default function VistaDashboard({
  metricas,
  loading,
  filtroPeriodo,
  onCambiarPeriodo,
  onRefetch,
  onDescargarBackup,
  exportando,
  productosStockBajo = [],
  totalClientes = 0,
  isAdmin = false,
  isPreventista = false
}) {
  const [fechaDesdeLocal, setFechaDesdeLocal] = useState('');
  const [fechaHastaLocal, setFechaHastaLocal] = useState('');
  const [mostrarFechasPersonalizadas, setMostrarFechasPersonalizadas] = useState(false);

  // Calcular métricas adicionales
  const metricasCalculadas = useMemo(() => {
    if (!metricas) return null;

    const ticketPromedio = metricas.pedidosPeriodo > 0
      ? metricas.ventasPeriodo / metricas.pedidosPeriodo
      : 0;

    const tasaEntrega = metricas.pedidosPorEstado
      ? (metricas.pedidosPorEstado.entregado /
         (metricas.pedidosPorEstado.pendiente +
          metricas.pedidosPorEstado.en_preparacion +
          metricas.pedidosPorEstado.asignado +
          metricas.pedidosPorEstado.entregado || 1)) * 100
      : 0;

    return { ticketPromedio, tasaEntrega };
  }, [metricas]);

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

  if (loading) return <LoadingSpinner />;

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white">
            {isPreventista && !isAdmin ? 'Mis Métricas' : 'Dashboard'}
          </h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            {isPreventista && !isAdmin
              ? `Resumen de mis ventas - ${periodoLabels[filtroPeriodo]}`
              : `Resumen de actividad - ${periodoLabels[filtroPeriodo]}`
            }
          </p>
        </div>
        <div className="flex flex-wrap gap-2">
          <button
            onClick={onRefetch}
            disabled={loading}
            className="flex items-center space-x-2 px-4 py-2 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
            aria-label="Actualizar datos"
          >
            <RefreshCw className={`w-5 h-5 ${loading ? 'animate-spin' : ''}`} />
            <span>Actualizar</span>
          </button>
          {isAdmin && (
            <button
              onClick={() => onDescargarBackup('completo')}
              disabled={exportando}
              className="flex items-center space-x-2 px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors"
              aria-label="Descargar backup"
            >
              <Download className="w-5 h-5" />
              <span>Backup</span>
            </button>
          )}
        </div>
      </div>

      {/* Alerta de stock bajo */}
      {productosStockBajo.length > 0 && (
        <div className="bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-xl p-4 flex items-start space-x-3">
          <AlertTriangle className="w-5 h-5 text-amber-600 flex-shrink-0 mt-0.5" />
          <div>
            <p className="font-medium text-amber-800 dark:text-amber-200">
              Atención: {productosStockBajo.length} producto(s) con stock bajo
            </p>
            <p className="text-sm text-amber-600 dark:text-amber-300 mt-1">
              {productosStockBajo.slice(0, 3).map(p => p.nombre).join(', ')}
              {productosStockBajo.length > 3 && ` y ${productosStockBajo.length - 3} más`}
            </p>
          </div>
        </div>
      )}

      {/* Filtro de período */}
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow p-4">
        <div className="flex flex-wrap items-center gap-2">
          <span className="text-sm font-medium text-gray-600 dark:text-gray-300 mr-2">Período:</span>
          {Object.entries(periodoLabels).map(([key, label]) => (
            <button
              key={key}
              onClick={() => handlePeriodoChange(key)}
              className={`px-3 py-1.5 rounded-lg text-sm font-medium transition-all ${
                filtroPeriodo === key
                  ? 'bg-blue-600 text-white shadow-md'
                  : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
              }`}
              aria-pressed={filtroPeriodo === key}
            >
              {label}
            </button>
          ))}
        </div>
        {mostrarFechasPersonalizadas && (
          <div className="mt-4 flex flex-wrap items-end gap-3">
            <div>
              <label htmlFor="fecha-desde" className="block text-xs text-gray-500 dark:text-gray-400 mb-1">Desde</label>
              <input
                id="fecha-desde"
                type="date"
                value={fechaDesdeLocal}
                onChange={e => setFechaDesdeLocal(e.target.value)}
                className="px-3 py-2 border dark:border-gray-600 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
              />
            </div>
            <div>
              <label htmlFor="fecha-hasta" className="block text-xs text-gray-500 dark:text-gray-400 mb-1">Hasta</label>
              <input
                id="fecha-hasta"
                type="date"
                value={fechaHastaLocal}
                onChange={e => setFechaHastaLocal(e.target.value)}
                className="px-3 py-2 border dark:border-gray-600 rounded-lg text-sm focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white"
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

      {/* Métricas principales */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
        <MetricaCard
          icono={DollarSign}
          titulo="Ventas"
          valor={formatPrecio(metricas.ventasPeriodo)}
          subtitulo={periodoLabels[filtroPeriodo]}
          colorClase={{ bg: 'bg-green-100 dark:bg-green-900/30', icon: 'text-green-600', text: 'text-green-600' }}
          tendencia={<TendenciaIndicator valor={metricas.ventasPeriodo} comparacion={metricas.ventasPeriodoAnterior} />}
        />
        <MetricaCard
          icono={ShoppingCart}
          titulo="Pedidos"
          valor={metricas.pedidosPeriodo}
          subtitulo={periodoLabels[filtroPeriodo]}
          colorClase={{ bg: 'bg-blue-100 dark:bg-blue-900/30', icon: 'text-blue-600', text: 'text-blue-600' }}
          tendencia={<TendenciaIndicator valor={metricas.pedidosPeriodo} comparacion={metricas.pedidosPeriodoAnterior} />}
        />
        <MetricaCard
          icono={Target}
          titulo="Ticket Promedio"
          valor={formatPrecio(metricasCalculadas?.ticketPromedio || 0)}
          subtitulo="Por pedido"
          colorClase={{ bg: 'bg-purple-100 dark:bg-purple-900/30', icon: 'text-purple-600', text: 'text-purple-600' }}
        />
        <MetricaCard
          icono={Users}
          titulo="Clientes"
          valor={totalClientes}
          subtitulo="Registrados"
          colorClase={{ bg: 'bg-indigo-100 dark:bg-indigo-900/30', icon: 'text-indigo-600', text: 'text-indigo-600' }}
        />
      </div>

      {/* Estados de pedidos */}
      <div>
        <h3 className="text-lg font-semibold text-gray-800 dark:text-white mb-3">Estado de Pedidos</h3>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
          <EstadoCard
            icono={Clock}
            titulo="Pendientes"
            valor={metricas.pedidosPorEstado.pendiente}
            colorClase={{
              bg: 'bg-yellow-50 dark:bg-yellow-900/20',
              border: 'border-yellow-200 dark:border-yellow-800',
              icon: 'text-yellow-600',
              text: 'text-yellow-800 dark:text-yellow-200'
            }}
          />
          <EstadoCard
            icono={Package}
            titulo="En preparación"
            valor={metricas.pedidosPorEstado.en_preparacion || 0}
            colorClase={{
              bg: 'bg-orange-50 dark:bg-orange-900/20',
              border: 'border-orange-200 dark:border-orange-800',
              icon: 'text-orange-600',
              text: 'text-orange-800 dark:text-orange-200'
            }}
          />
          <EstadoCard
            icono={Truck}
            titulo="En camino"
            valor={metricas.pedidosPorEstado.asignado}
            colorClase={{
              bg: 'bg-blue-50 dark:bg-blue-900/20',
              border: 'border-blue-200 dark:border-blue-800',
              icon: 'text-blue-600',
              text: 'text-blue-800 dark:text-blue-200'
            }}
          />
          <EstadoCard
            icono={Check}
            titulo="Entregados"
            valor={metricas.pedidosPorEstado.entregado}
            colorClase={{
              bg: 'bg-green-50 dark:bg-green-900/20',
              border: 'border-green-200 dark:border-green-800',
              icon: 'text-green-600',
              text: 'text-green-800 dark:text-green-200'
            }}
          />
        </div>
      </div>

      {/* Gráficos */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        {/* Ventas últimos 7 días */}
        <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6">
          <div className="flex items-center justify-between mb-4">
            <h3 className="font-semibold text-gray-800 dark:text-white">Ventas últimos 7 días</h3>
            <span className="text-sm text-gray-500 dark:text-gray-400">
              Total: {formatPrecio(metricas.ventasPorDia.reduce((sum, d) => sum + d.ventas, 0))}
            </span>
          </div>
          <div className="space-y-3">
            {metricas.ventasPorDia.map((d, i) => {
              const maxVenta = Math.max(...metricas.ventasPorDia.map(x => x.ventas)) || 1;
              return (
                <BarraProgreso
                  key={i}
                  dia={d.dia}
                  ventas={d.ventas}
                  maxVenta={maxVenta}
                  index={i}
                />
              );
            })}
          </div>
        </div>

        {/* Top 5 productos */}
        <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6">
          <h3 className="font-semibold text-gray-800 dark:text-white mb-4">
            Top 5 Productos
            <span className="text-sm font-normal text-gray-500 dark:text-gray-400 ml-2">
              ({periodoLabels[filtroPeriodo]})
            </span>
          </h3>
          <div className="space-y-4">
            {metricas.productosMasVendidos.length === 0 ? (
              <p className="text-gray-500 dark:text-gray-400 text-center py-8">
                Sin datos en este período
              </p>
            ) : metricas.productosMasVendidos.map((p, i) => {
              const maxCantidad = metricas.productosMasVendidos[0]?.cantidad || 1;
              const porcentaje = (p.cantidad / maxCantidad) * 100;

              return (
                <div key={p.id} className="flex items-center space-x-3">
                  <span className={`w-8 h-8 rounded-full flex items-center justify-center text-sm font-bold shadow-sm ${
                    i === 0 ? 'bg-gradient-to-br from-yellow-400 to-yellow-500 text-yellow-900' :
                    i === 1 ? 'bg-gradient-to-br from-gray-300 to-gray-400 text-gray-700' :
                    i === 2 ? 'bg-gradient-to-br from-orange-400 to-orange-500 text-orange-900' :
                    'bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300'
                  }`}>
                    {i + 1}
                  </span>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center justify-between mb-1">
                      <span className="font-medium text-gray-800 dark:text-white truncate">{p.nombre}</span>
                      <span className="text-sm text-gray-600 dark:text-gray-400 ml-2">{p.cantidad} unid.</span>
                    </div>
                    <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-2">
                      <div
                        className={`h-2 rounded-full transition-all duration-500 ${
                          i === 0 ? 'bg-yellow-500' :
                          i === 1 ? 'bg-gray-400' :
                          i === 2 ? 'bg-orange-500' :
                          'bg-blue-500'
                        }`}
                        style={{ width: `${porcentaje}%` }}
                      />
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      </div>

      {/* Tasa de entrega */}
      {metricasCalculadas && (
        <div className="bg-white dark:bg-gray-800 rounded-xl shadow-lg p-6">
          <h3 className="font-semibold text-gray-800 dark:text-white mb-4">Tasa de Entrega</h3>
          <div className="flex items-center space-x-4">
            <div className="flex-1">
              <div className="w-full bg-gray-200 dark:bg-gray-700 rounded-full h-4">
                <div
                  className="bg-gradient-to-r from-green-500 to-green-600 h-4 rounded-full transition-all duration-500"
                  style={{ width: `${metricasCalculadas.tasaEntrega}%` }}
                />
              </div>
            </div>
            <span className="text-2xl font-bold text-green-600">
              {metricasCalculadas.tasaEntrega.toFixed(1)}%
            </span>
          </div>
          <p className="text-sm text-gray-500 dark:text-gray-400 mt-2">
            Porcentaje de pedidos entregados del total
          </p>
        </div>
      )}
    </div>
  );
}
