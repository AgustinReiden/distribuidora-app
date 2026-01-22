import React, { useState, useEffect, ChangeEvent } from 'react';
import type { LucideIcon } from 'lucide-react';
import { TrendingUp, BarChart3, X, Loader2, Users, DollarSign, Package, MapPin, AlertTriangle, FileText } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';
import { useReportesFinancieros } from '../../hooks/supabase';
import type {
  ClienteDB,
  ReportePreventista,
  ReporteCuentaPorCobrar,
  ReporteRentabilidad,
  VentaPorCliente,
  VentaPorZona,
  TotalesRentabilidad
} from '../../types';

// =============================================================================
// INTERFACES DE PROPS
// =============================================================================

export interface VistaReportesProps {
  reportePreventistas: ReportePreventista[];
  reporteInicializado: boolean;
  loading: boolean;
  onCalcularReporte: (fechaDesde: string | null, fechaHasta: string | null) => Promise<void>;
  onVerFichaCliente?: (cliente: ClienteDB) => void;
}

interface TabConfig {
  id: string;
  label: string;
  icon: LucideIcon;
}

interface ReportePreventistasProps {
  reportePreventistas: ReportePreventista[];
  loading: boolean;
  formatPrecio: (precio: number) => string;
}

interface ReporteCuentasPorCobrarProps {
  reporte: ReporteCuentaPorCobrar[];
  loading: boolean;
  formatPrecio: (precio: number) => string;
  onVerCliente?: (cliente: ClienteDB) => void;
}

interface ReporteRentabilidadProps {
  reporte: ReporteRentabilidad;
  loading: boolean;
  formatPrecio: (precio: number) => string;
}

interface ReporteVentasClientesProps {
  reporte: VentaPorCliente[];
  loading: boolean;
  formatPrecio: (precio: number) => string;
  onVerCliente?: (cliente: ClienteDB | null) => void;
}

interface ReporteVentasZonasProps {
  reporte: VentaPorZona[];
  loading: boolean;
  formatPrecio: (precio: number) => string;
}

type ReportTabId = 'preventistas' | 'cuentas' | 'rentabilidad' | 'clientes' | 'zonas';

export default function VistaReportes({
  reportePreventistas,
  reporteInicializado,
  loading,
  onCalcularReporte,
  onVerFichaCliente
}: VistaReportesProps) {
  const [fechaDesde, setFechaDesde] = useState<string>('');
  const [fechaHasta, setFechaHasta] = useState<string>('');
  const [activeTab, setActiveTab] = useState<ReportTabId>('preventistas');

  // Reportes financieros
  const {
    loading: loadingFinanciero,
    generarReporteCuentasPorCobrar,
    generarReporteRentabilidad,
    generarReporteVentasPorCliente,
    generarReporteVentasPorZona
  } = useReportesFinancieros();

  const [reporteCuentas, setReporteCuentas] = useState<ReporteCuentaPorCobrar[]>([]);
  const [reporteRentabilidad, setReporteRentabilidad] = useState<ReporteRentabilidad>({ productos: [], totales: {} as TotalesRentabilidad });
  const [reporteClientes, setReporteClientes] = useState<VentaPorCliente[]>([]);
  const [reporteZonas, setReporteZonas] = useState<VentaPorZona[]>([]);

  // Cargar reporte automáticamente solo la primera vez
  useEffect(() => {
    if (!reporteInicializado && !loading) {
      onCalcularReporte(null, null);
    }
  }, [reporteInicializado, loading, onCalcularReporte]);

  const handleGenerarReporte = async (): Promise<void> => {
    await onCalcularReporte(fechaDesde || null, fechaHasta || null);
  };

  const handleLimpiarFiltros = async (): Promise<void> => {
    setFechaDesde('');
    setFechaHasta('');
    await onCalcularReporte(null, null);
  };

  const handleCargarReporteFinanciero = async (tipo: ReportTabId): Promise<void> => {
    switch (tipo) {
      case 'cuentas': {
        const cuentas = await generarReporteCuentasPorCobrar();
        setReporteCuentas(cuentas);
        break;
      }
      case 'rentabilidad': {
        const rent = await generarReporteRentabilidad(fechaDesde || null, fechaHasta || null);
        setReporteRentabilidad(rent);
        break;
      }
      case 'clientes': {
        const clientes = await generarReporteVentasPorCliente(fechaDesde || null, fechaHasta || null);
        setReporteClientes(clientes);
        break;
      }
      case 'zonas': {
        const zonas = await generarReporteVentasPorZona(fechaDesde || null, fechaHasta || null);
        setReporteZonas(zonas);
        break;
      }
    }
  };

  useEffect(() => {
    if (activeTab === 'cuentas' && reporteCuentas.length === 0) handleCargarReporteFinanciero('cuentas');
    if (activeTab === 'rentabilidad' && reporteRentabilidad.productos.length === 0) handleCargarReporteFinanciero('rentabilidad');
    if (activeTab === 'clientes' && reporteClientes.length === 0) handleCargarReporteFinanciero('clientes');
    if (activeTab === 'zonas' && reporteZonas.length === 0) handleCargarReporteFinanciero('zonas');
  }, [activeTab]);

  const tabs: TabConfig[] = [
    { id: 'preventistas', label: 'Por Preventista', icon: Users },
    { id: 'cuentas', label: 'Cuentas por Cobrar', icon: DollarSign },
    { id: 'rentabilidad', label: 'Rentabilidad', icon: TrendingUp },
    { id: 'clientes', label: 'Por Cliente', icon: Users },
    { id: 'zonas', label: 'Por Zona', icon: MapPin }
  ];

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Reportes</h1>

      {/* Tabs */}
      <div className="flex flex-wrap gap-2 border-b border-gray-200 dark:border-gray-700 pb-2">
        {tabs.map(tab => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id as ReportTabId)}
            className={`flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium transition-colors ${
              activeTab === tab.id
                ? 'bg-blue-600 text-white'
                : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
            }`}
          >
            <tab.icon className="w-4 h-4" />
            {tab.label}
          </button>
        ))}
      </div>

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
              onChange={(e: ChangeEvent<HTMLInputElement>) => setFechaDesde(e.target.value)}
              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <div>
            <label htmlFor="fecha-hasta" className="block text-sm font-medium mb-1 text-gray-600 dark:text-gray-400">Hasta</label>
            <input
              id="fecha-hasta"
              type="date"
              value={fechaHasta}
              onChange={(e: ChangeEvent<HTMLInputElement>) => setFechaHasta(e.target.value)}
              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <div className="flex gap-2">
            <button
              onClick={() => {
                if (activeTab === 'preventistas') handleGenerarReporte();
                else handleCargarReporteFinanciero(activeTab);
              }}
              disabled={loading || loadingFinanciero}
              className="flex items-center justify-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 transition-colors"
            >
              {(loading || loadingFinanciero) ? <Loader2 className="w-5 h-5 animate-spin" /> : <BarChart3 className="w-5 h-5" />}
              <span>Generar</span>
            </button>
            {(fechaDesde || fechaHasta) && (
              <button
                onClick={handleLimpiarFiltros}
                disabled={loading}
                className="flex items-center justify-center space-x-2 px-4 py-2 bg-gray-500 dark:bg-gray-600 text-white rounded-lg hover:bg-gray-600 dark:hover:bg-gray-500 disabled:opacity-50 transition-colors"
              >
                <X className="w-5 h-5" />
              </button>
            )}
          </div>
        </div>
      </div>

      {/* Contenido según tab */}
      {activeTab === 'preventistas' && (
        <ReportePreventistas
          reportePreventistas={reportePreventistas}
          loading={loading}
          formatPrecio={formatPrecio}
        />
      )}

      {activeTab === 'cuentas' && (
        <ReporteCuentasPorCobrar
          reporte={reporteCuentas}
          loading={loadingFinanciero}
          formatPrecio={formatPrecio}
          onVerCliente={onVerFichaCliente}
        />
      )}

      {activeTab === 'rentabilidad' && (
        <ReporteRentabilidad
          reporte={reporteRentabilidad}
          loading={loadingFinanciero}
          formatPrecio={formatPrecio}
        />
      )}

      {activeTab === 'clientes' && (
        <ReporteVentasClientes
          reporte={reporteClientes}
          loading={loadingFinanciero}
          formatPrecio={formatPrecio}
          onVerCliente={onVerFichaCliente}
        />
      )}

      {activeTab === 'zonas' && (
        <ReporteVentasZonas
          reporte={reporteZonas}
          loading={loadingFinanciero}
          formatPrecio={formatPrecio}
        />
      )}
    </div>
  );
}

function ReportePreventistas({ reportePreventistas, loading, formatPrecio }: ReportePreventistasProps) {
  if (loading) return <LoadingSpinner />;

  if (reportePreventistas.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500 dark:text-gray-400 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm">
        <TrendingUp className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p className="font-semibold">No hay datos para mostrar</p>
      </div>
    );
  }

  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-x-auto">
      <table className="w-full">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Preventista</th>
            <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Total Ventas</th>
            <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Pedidos</th>
            <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Pagado</th>
            <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Pendiente</th>
          </tr>
        </thead>
        <tbody className="divide-y dark:divide-gray-700">
          {reportePreventistas.map((p, i) => (
            <tr key={p.id || i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
              <td className="px-4 py-3">
                <p className="font-medium text-gray-800 dark:text-white">{p.nombre}</p>
                <p className="text-sm text-gray-500">{p.email}</p>
              </td>
              <td className="px-4 py-3 text-right font-bold text-blue-600">{formatPrecio(p.totalVentas)}</td>
              <td className="px-4 py-3 text-right">{p.cantidadPedidos}</td>
              <td className="px-4 py-3 text-right text-green-600">{formatPrecio(p.totalPagado)}</td>
              <td className="px-4 py-3 text-right text-red-600">{formatPrecio(p.totalPendiente)}</td>
            </tr>
          ))}
        </tbody>
        <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
          <tr>
            <td className="px-4 py-3">TOTAL</td>
            <td className="px-4 py-3 text-right text-blue-600">{formatPrecio(reportePreventistas.reduce((s, p) => s + p.totalVentas, 0))}</td>
            <td className="px-4 py-3 text-right">{reportePreventistas.reduce((s, p) => s + p.cantidadPedidos, 0)}</td>
            <td className="px-4 py-3 text-right text-green-600">{formatPrecio(reportePreventistas.reduce((s, p) => s + p.totalPagado, 0))}</td>
            <td className="px-4 py-3 text-right text-red-600">{formatPrecio(reportePreventistas.reduce((s, p) => s + p.totalPendiente, 0))}</td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

function ReporteCuentasPorCobrar({ reporte, loading, formatPrecio, onVerCliente }: ReporteCuentasPorCobrarProps) {
  if (loading) return <LoadingSpinner />;

  // Totales por aging
  const totalCorriente = reporte.reduce((s, r) => s + r.aging.corriente, 0);
  const total30 = reporte.reduce((s, r) => s + r.aging.vencido30, 0);
  const total60 = reporte.reduce((s, r) => s + r.aging.vencido60, 0);
  const total90 = reporte.reduce((s, r) => s + r.aging.vencido90, 0);
  const totalGeneral = reporte.reduce((s, r) => s + r.saldoPendiente, 0);

  return (
    <div className="space-y-4">
      {/* Resumen Aging */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
        <div className="bg-green-50 dark:bg-green-900/20 p-4 rounded-lg">
          <p className="text-sm text-green-600 dark:text-green-400">Corriente</p>
          <p className="text-xl font-bold text-green-700 dark:text-green-300">{formatPrecio(totalCorriente)}</p>
        </div>
        <div className="bg-yellow-50 dark:bg-yellow-900/20 p-4 rounded-lg">
          <p className="text-sm text-yellow-600 dark:text-yellow-400">1-30 días</p>
          <p className="text-xl font-bold text-yellow-700 dark:text-yellow-300">{formatPrecio(total30)}</p>
        </div>
        <div className="bg-orange-50 dark:bg-orange-900/20 p-4 rounded-lg">
          <p className="text-sm text-orange-600 dark:text-orange-400">31-60 días</p>
          <p className="text-xl font-bold text-orange-700 dark:text-orange-300">{formatPrecio(total60)}</p>
        </div>
        <div className="bg-red-50 dark:bg-red-900/20 p-4 rounded-lg">
          <p className="text-sm text-red-600 dark:text-red-400">+60 días</p>
          <p className="text-xl font-bold text-red-700 dark:text-red-300">{formatPrecio(total90)}</p>
        </div>
        <div className="bg-gray-100 dark:bg-gray-700 p-4 rounded-lg">
          <p className="text-sm text-gray-600 dark:text-gray-400">Total</p>
          <p className="text-xl font-bold text-gray-900 dark:text-white">{formatPrecio(totalGeneral)}</p>
        </div>
      </div>

      {reporte.length === 0 ? (
        <div className="text-center py-12 text-gray-500 bg-white dark:bg-gray-800 rounded-lg">
          <DollarSign className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>No hay cuentas pendientes de cobro</p>
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium">Cliente</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Saldo</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Corriente</th>
                <th className="px-4 py-3 text-right text-sm font-medium">1-30</th>
                <th className="px-4 py-3 text-right text-sm font-medium">31-60</th>
                <th className="px-4 py-3 text-right text-sm font-medium">+60</th>
                <th className="px-4 py-3 text-center text-sm font-medium">Acciones</th>
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {reporte.map((r, i) => (
                <tr key={i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
                  <td className="px-4 py-3">
                    <p className="font-medium">{r.cliente.nombre_fantasia}</p>
                    <p className="text-sm text-gray-500">{r.cliente.zona || 'Sin zona'}</p>
                  </td>
                  <td className="px-4 py-3 text-right font-bold text-red-600">{formatPrecio(r.saldoPendiente)}</td>
                  <td className="px-4 py-3 text-right text-green-600">{r.aging.corriente > 0 ? formatPrecio(r.aging.corriente) : '-'}</td>
                  <td className="px-4 py-3 text-right text-yellow-600">{r.aging.vencido30 > 0 ? formatPrecio(r.aging.vencido30) : '-'}</td>
                  <td className="px-4 py-3 text-right text-orange-600">{r.aging.vencido60 > 0 ? formatPrecio(r.aging.vencido60) : '-'}</td>
                  <td className="px-4 py-3 text-right text-red-600">{r.aging.vencido90 > 0 ? formatPrecio(r.aging.vencido90) : '-'}</td>
                  <td className="px-4 py-3 text-center">
                    <button
                      onClick={() => onVerCliente?.(r.cliente)}
                      className="text-blue-600 hover:text-blue-700 text-sm"
                    >
                      Ver ficha
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function ReporteRentabilidad({ reporte, loading, formatPrecio }) {
  if (loading) return <LoadingSpinner />;

  const { productos, totales } = reporte;

  return (
    <div className="space-y-4">
      {/* Resumen */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div className="bg-blue-50 dark:bg-blue-900/20 p-4 rounded-lg">
          <p className="text-sm text-blue-600">Ingresos</p>
          <p className="text-xl font-bold text-blue-700">{formatPrecio(totales.ingresosTotales || 0)}</p>
        </div>
        <div className="bg-red-50 dark:bg-red-900/20 p-4 rounded-lg">
          <p className="text-sm text-red-600">Costos</p>
          <p className="text-xl font-bold text-red-700">{formatPrecio(totales.costosTotales || 0)}</p>
        </div>
        <div className="bg-green-50 dark:bg-green-900/20 p-4 rounded-lg">
          <p className="text-sm text-green-600">Margen</p>
          <p className="text-xl font-bold text-green-700">{formatPrecio(totales.margenTotal || 0)}</p>
        </div>
        <div className="bg-purple-50 dark:bg-purple-900/20 p-4 rounded-lg">
          <p className="text-sm text-purple-600">% Margen</p>
          <p className="text-xl font-bold text-purple-700">{(totales.margenPorcentaje || 0).toFixed(1)}%</p>
        </div>
      </div>

      {productos.length === 0 ? (
        <div className="text-center py-12 text-gray-500 bg-white dark:bg-gray-800 rounded-lg">
          <Package className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>No hay datos de rentabilidad</p>
          <p className="text-sm mt-1">Asegúrate de tener costos cargados en los productos</p>
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium">Producto</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Vendido</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Ingresos</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Costos</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Margen</th>
                <th className="px-4 py-3 text-right text-sm font-medium">%</th>
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {productos.slice(0, 20).map((p, i) => (
                <tr key={i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
                  <td className="px-4 py-3">
                    <p className="font-medium">{p.nombre}</p>
                    {p.codigo && <p className="text-sm text-gray-500">{p.codigo}</p>}
                  </td>
                  <td className="px-4 py-3 text-right">{p.cantidadVendida}</td>
                  <td className="px-4 py-3 text-right">{formatPrecio(p.ingresos)}</td>
                  <td className="px-4 py-3 text-right text-red-600">{formatPrecio(p.costos)}</td>
                  <td className="px-4 py-3 text-right font-bold text-green-600">{formatPrecio(p.margen)}</td>
                  <td className="px-4 py-3 text-right">
                    <span className={`px-2 py-1 rounded text-sm ${p.margenPorcentaje >= 20 ? 'bg-green-100 text-green-700' : p.margenPorcentaje >= 10 ? 'bg-yellow-100 text-yellow-700' : 'bg-red-100 text-red-700'}`}>
                      {p.margenPorcentaje.toFixed(1)}%
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

function ReporteVentasClientes({ reporte, loading, formatPrecio, onVerCliente }) {
  if (loading) return <LoadingSpinner />;

  if (reporte.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500 bg-white dark:bg-gray-800 rounded-lg">
        <Users className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p>No hay datos de ventas por cliente</p>
      </div>
    );
  }

  const totalVentas = reporte.reduce((s, r) => s + r.totalVentas, 0);

  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg overflow-x-auto">
      <table className="w-full">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className="px-4 py-3 text-left text-sm font-medium">Cliente</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Pedidos</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Total</th>
            <th className="px-4 py-3 text-right text-sm font-medium">% Total</th>
            <th className="px-4 py-3 text-center text-sm font-medium">Acciones</th>
          </tr>
        </thead>
        <tbody className="divide-y dark:divide-gray-700">
          {reporte.slice(0, 30).map((r, i) => (
            <tr key={i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
              <td className="px-4 py-3">
                <p className="font-medium">{r.cliente?.nombre_fantasia || 'Cliente'}</p>
                <p className="text-sm text-gray-500">{r.cliente?.zona || 'Sin zona'}</p>
              </td>
              <td className="px-4 py-3 text-right">{r.cantidadPedidos}</td>
              <td className="px-4 py-3 text-right font-bold text-blue-600">{formatPrecio(r.totalVentas)}</td>
              <td className="px-4 py-3 text-right text-gray-600">
                {((r.totalVentas / totalVentas) * 100).toFixed(1)}%
              </td>
              <td className="px-4 py-3 text-center">
                <button
                  onClick={() => onVerCliente?.(r.cliente)}
                  className="text-blue-600 hover:text-blue-700 text-sm"
                >
                  Ver ficha
                </button>
              </td>
            </tr>
          ))}
        </tbody>
        <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
          <tr>
            <td className="px-4 py-3">TOTAL ({reporte.length} clientes)</td>
            <td className="px-4 py-3 text-right">{reporte.reduce((s, r) => s + r.cantidadPedidos, 0)}</td>
            <td className="px-4 py-3 text-right text-blue-600">{formatPrecio(totalVentas)}</td>
            <td className="px-4 py-3 text-right">100%</td>
            <td></td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}

function ReporteVentasZonas({ reporte, loading, formatPrecio }) {
  if (loading) return <LoadingSpinner />;

  if (reporte.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500 bg-white dark:bg-gray-800 rounded-lg">
        <MapPin className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p>No hay datos de ventas por zona</p>
      </div>
    );
  }

  const totalVentas = reporte.reduce((s, r) => s + r.totalVentas, 0);

  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg overflow-x-auto">
      <table className="w-full">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className="px-4 py-3 text-left text-sm font-medium">Zona</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Clientes</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Pedidos</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Total</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Ticket Prom.</th>
            <th className="px-4 py-3 text-right text-sm font-medium">% Total</th>
          </tr>
        </thead>
        <tbody className="divide-y dark:divide-gray-700">
          {reporte.map((r, i) => (
            <tr key={i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
              <td className="px-4 py-3 font-medium">{r.zona}</td>
              <td className="px-4 py-3 text-right">{r.cantidadClientes}</td>
              <td className="px-4 py-3 text-right">{r.cantidadPedidos}</td>
              <td className="px-4 py-3 text-right font-bold text-blue-600">{formatPrecio(r.totalVentas)}</td>
              <td className="px-4 py-3 text-right text-gray-600">{formatPrecio(r.ticketPromedio)}</td>
              <td className="px-4 py-3 text-right">
                <div className="flex items-center justify-end gap-2">
                  <div className="w-16 bg-gray-200 rounded-full h-2">
                    <div
                      className="bg-blue-600 h-2 rounded-full"
                      style={{ width: `${(r.totalVentas / totalVentas) * 100}%` }}
                    />
                  </div>
                  <span className="text-sm">{((r.totalVentas / totalVentas) * 100).toFixed(1)}%</span>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
        <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
          <tr>
            <td className="px-4 py-3">TOTAL</td>
            <td className="px-4 py-3 text-right">{reporte.reduce((s, r) => s + r.cantidadClientes, 0)}</td>
            <td className="px-4 py-3 text-right">{reporte.reduce((s, r) => s + r.cantidadPedidos, 0)}</td>
            <td className="px-4 py-3 text-right text-blue-600">{formatPrecio(totalVentas)}</td>
            <td className="px-4 py-3 text-right">{formatPrecio(totalVentas / Math.max(1, reporte.reduce((s, r) => s + r.cantidadPedidos, 0)))}</td>
            <td className="px-4 py-3 text-right">100%</td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
