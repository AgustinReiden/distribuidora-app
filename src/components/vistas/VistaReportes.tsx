/**
 * Vista principal de Reportes
 *
 * Muestra diferentes tipos de reportes financieros y de ventas:
 * - Por Preventista
 * - Cuentas por Cobrar (con aging)
 * - Rentabilidad por Producto
 * - Ventas por Cliente  (RPC reporte_ventas_por_cliente, mig 197)
 * - Ventas por Zona     (mismo RPC, mismo cache)
 * - Valuación de Stock
 *
 * Los sub-componentes están extraídos en archivos separados para
 * mejor mantenibilidad y separación de concerns.
 *
 * Nota sobre los filtros: "Por Cliente" y "Por Zona" NO usan el panel
 * "Filtrar por Fecha" de arriba. Tienen el suyo (`FiltrosVentas`) porque además
 * de fechas filtran por preventista y ofrecen atajos de mes; el estado vive acá
 * para que las dos pestañas compartan la misma entrada de cache.
 */
import React, { useState, useEffect, ChangeEvent } from 'react';
import type { LucideIcon } from 'lucide-react';
import { TrendingUp, BarChart3, X, Loader2, Users, DollarSign, MapPin, Boxes } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import { useReportesFinancieros } from '../../hooks/supabase';
import type {
  ClienteDB,
  ReportePreventista,
  ReporteCuentaPorCobrar,
  ReporteRentabilidad,
  TotalesRentabilidad
} from '../../types';

// Sub-componentes extraídos
import {
  ReportePreventistas,
  ReporteCuentasPorCobrar,
  ReporteRentabilidadSection,
  ReporteVentasClientes,
  ReporteVentasZonas,
  ReporteValuacionInventario,
  FiltrosVentas,
  filtrosVentasIniciales,
  type FiltrosVentasValue
} from './reportes';

// =============================================================================
// TYPES
// =============================================================================

export interface VistaReportesProps {
  reportePreventistas: ReportePreventista[];
  reporteInicializado: boolean;
  loading: boolean;
  onCalcularReporte: (fechaDesde: string | null, fechaHasta: string | null) => Promise<void>;
  onVerFichaCliente?: (cliente: ClienteDB) => void;
  onVerFichaClienteId?: (clienteId: string) => void;
}

interface TabConfig {
  id: ReportTabId;
  label: string;
  icon: LucideIcon;
}

type ReportTabId = 'preventistas' | 'cuentas' | 'rentabilidad' | 'clientes' | 'zonas' | 'valuacion';

/** Tabs que traen sus propios filtros y no usan el panel de fechas de arriba. */
const TABS_CON_FILTROS_PROPIOS: ReportTabId[] = ['clientes', 'zonas', 'valuacion'];

// =============================================================================
// COMPONENT
// =============================================================================

export default function VistaReportes({
  reportePreventistas,
  reporteInicializado,
  loading,
  onCalcularReporte,
  onVerFichaCliente,
  onVerFichaClienteId
}: VistaReportesProps): React.ReactElement {
  // Estado local
  const [fechaDesde, setFechaDesde] = useState<string>('');
  const [fechaHasta, setFechaHasta] = useState<string>('');
  const [activeTab, setActiveTab] = useState<ReportTabId>('preventistas');
  const [filtrosVentas, setFiltrosVentas] = useState<FiltrosVentasValue>(filtrosVentasIniciales);

  // Reportes financieros
  const {
    loading: loadingFinanciero,
    generarReporteCuentasPorCobrar,
    generarReporteRentabilidad
  } = useReportesFinancieros();

  // Estados de reportes
  const [reporteCuentas, setReporteCuentas] = useState<ReporteCuentaPorCobrar[]>([]);
  const [reporteRentabilidad, setReporteRentabilidad] = useState<ReporteRentabilidad>({
    productos: [],
    totales: {} as TotalesRentabilidad
  });

  // Configuración de tabs
  const tabs: TabConfig[] = [
    { id: 'preventistas', label: 'Por Preventista', icon: Users },
    { id: 'cuentas', label: 'Cuentas por Cobrar', icon: DollarSign },
    { id: 'rentabilidad', label: 'Rentabilidad', icon: TrendingUp },
    { id: 'clientes', label: 'Por Cliente', icon: Users },
    { id: 'zonas', label: 'Por Zona', icon: MapPin },
    { id: 'valuacion', label: 'Valuación de Stock', icon: Boxes }
  ];

  // Cargar reporte automáticamente solo la primera vez
  useEffect(() => {
    if (!reporteInicializado && !loading) {
      onCalcularReporte(null, null);
    }
  }, [reporteInicializado, loading, onCalcularReporte]);

  // Cargar reportes financieros al cambiar de tab
  useEffect(() => {
    const cargarReporteFinanciero = async (): Promise<void> => {
      switch (activeTab) {
        case 'cuentas':
          if (reporteCuentas.length === 0) {
            const cuentas = await generarReporteCuentasPorCobrar();
            setReporteCuentas(cuentas);
          }
          break;
        case 'rentabilidad':
          if (reporteRentabilidad.productos.length === 0) {
            const rent = await generarReporteRentabilidad(fechaDesde || null, fechaHasta || null);
            setReporteRentabilidad(rent);
          }
          break;
      }
    };

    cargarReporteFinanciero();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [activeTab]);

  // Handlers
  const handleGenerarReporte = async (): Promise<void> => {
    if (activeTab === 'preventistas') {
      await onCalcularReporte(fechaDesde || null, fechaHasta || null);
    } else {
      // Recargar el reporte financiero actual
      switch (activeTab) {
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
      }
    }
  };

  const handleLimpiarFiltros = async (): Promise<void> => {
    setFechaDesde('');
    setFechaHasta('');
    await onCalcularReporte(null, null);
  };

  const isLoading = loading || loadingFinanciero;
  const esTabDeVentas = activeTab === 'clientes' || activeTab === 'zonas';

  return (
    <div className="space-y-4">
      <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Reportes</h1>

      {/* Tabs */}
      <div className="flex flex-wrap gap-2 border-b border-gray-200 dark:border-gray-700 pb-2">
        {tabs.map((tab) => (
          <button
            key={tab.id}
            onClick={() => setActiveTab(tab.id)}
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

      {/* Filtros propios de las pestañas de ventas: preventista + período */}
      {esTabDeVentas && <FiltrosVentas value={filtrosVentas} onChange={setFiltrosVentas} />}

      {/* Filtros de fecha genéricos (la valuación es una foto del stock actual y
          las pestañas de ventas traen los suyos: no aplican) */}
      {!TABS_CON_FILTROS_PROPIOS.includes(activeTab) && (
      <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4">
        <h2 className="font-semibold mb-3 text-gray-700 dark:text-gray-200">Filtrar por Fecha</h2>
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 items-end">
          <div>
            <label
              htmlFor="fecha-desde"
              className="block text-sm font-medium mb-1 text-gray-600 dark:text-gray-400"
            >
              Desde
            </label>
            <input
              id="fecha-desde"
              type="date"
              value={fechaDesde}
              onChange={(e: ChangeEvent<HTMLInputElement>) => setFechaDesde(e.target.value)}
              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500"
            />
          </div>
          <div>
            <label
              htmlFor="fecha-hasta"
              className="block text-sm font-medium mb-1 text-gray-600 dark:text-gray-400"
            >
              Hasta
            </label>
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
              onClick={handleGenerarReporte}
              disabled={isLoading}
              className="flex items-center justify-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 transition-colors"
            >
              {isLoading ? (
                <Loader2 className="w-5 h-5 animate-spin" />
              ) : (
                <BarChart3 className="w-5 h-5" />
              )}
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
      )}

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
        <ReporteRentabilidadSection
          reporte={reporteRentabilidad}
          loading={loadingFinanciero}
          formatPrecio={formatPrecio}
        />
      )}

      {activeTab === 'clientes' && (
        <ReporteVentasClientes
          desde={filtrosVentas.desde}
          hasta={filtrosVentas.hasta}
          preventistaId={filtrosVentas.preventistaId}
          formatPrecio={formatPrecio}
          onVerCliente={onVerFichaClienteId}
        />
      )}

      {activeTab === 'zonas' && (
        <ReporteVentasZonas
          desde={filtrosVentas.desde}
          hasta={filtrosVentas.hasta}
          preventistaId={filtrosVentas.preventistaId}
          formatPrecio={formatPrecio}
        />
      )}

      {activeTab === 'valuacion' && (
        <ReporteValuacionInventario formatPrecio={formatPrecio} />
      )}
    </div>
  );
}
