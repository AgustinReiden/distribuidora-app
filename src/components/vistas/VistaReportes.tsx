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
 * - Stock de la red   (RPC reporte_stock_red — cross-sucursal, solo lectura)
 *
 * Los sub-componentes están extraídos en archivos separados para
 * mejor mantenibilidad y separación de concerns.
 *
 * Nota sobre los filtros: "Por Cliente" y "Por Zona" NO usan el panel
 * "Filtrar por Fecha" de arriba. Tienen el suyo (`FiltrosVentas`) porque además
 * de fechas filtran por preventista y ofrecen atajos de mes; el estado vive acá
 * para que las dos pestañas compartan la misma entrada de cache.
 */
import React, { useState, useEffect, useCallback, ChangeEvent } from 'react';
import { useSearchParams } from 'react-router-dom';
import { escribirRango, leerRango, leerSucursal } from '../../utils/paramsReporte';
import type { LucideIcon } from 'lucide-react';
import { TrendingUp, TrendingDown, BarChart3, X, Loader2, Users, DollarSign, MapPin, Boxes, Network } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import { Criterio } from '../ui/Criterio';
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
  ReporteStockRed,
  ReporteMermas,
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

type ReportTabId = 'preventistas' | 'cuentas' | 'rentabilidad' | 'clientes' | 'zonas' | 'valuacion' | 'stock-red' | 'mermas';

/** Tabs que traen sus propios filtros y no usan el panel de fechas de arriba. */
const TABS_CON_FILTROS_PROPIOS: ReportTabId[] = ['clientes', 'zonas', 'valuacion', 'stock-red', 'mermas'];

/** Los ids validos de `?tab=`. Un valor desconocido cae al default en vez de
 *  dejar la pantalla en blanco. */
const TAB_IDS: ReportTabId[] = [
  'preventistas', 'cuentas', 'rentabilidad', 'clientes', 'zonas', 'valuacion', 'stock-red', 'mermas',
];

function tabDeUrl(valor: string | null): ReportTabId | null {
  return TAB_IDS.includes(valor as ReportTabId) ? (valor as ReportTabId) : null;
}

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
  // La pestaña y el período viven en la URL: así "Ver detalle" del gerencial cae
  // acá con el MISMO período, el link es compartible y el back de Android
  // funciona (es una PWA).
  const [searchParams, setSearchParams] = useSearchParams();

  // OJO: el default de esta pantalla es SIN filtro, no "este mes". Varias
  // pestañas arrancan mostrando todo el histórico; sembrarles un período las
  // haría cambiar de números en silencio. Los params sólo aparecen cuando el
  // usuario elige un rango o cuando llega por un deep link.
  const rangoUrl = leerRango(searchParams);
  // El rango es estado del formulario, sembrado UNA vez desde la URL (igual que
  // `filtrosVentas` acá abajo). No puede leerse de la URL en cada render: mientras
  // el usuario completa una punta el rango está a medias, y `escribirRango`
  // descarta los rangos incompletos a propósito. Atado a la URL, la primera fecha
  // elegida se borraba sola y "Generar" salía sin filtro — el filtro no andaba.
  const [fechaDesde, setFechaDesdeState] = useState(rangoUrl.desde ?? '');
  const [fechaHasta, setFechaHastaState] = useState(rangoUrl.hasta ?? '');
  /** Publica en la URL lo que ella sabe representar; el formulario guarda el resto. */
  const setRango = useCallback((desde: string, hasta: string): void => {
    setFechaDesdeState(desde);
    setFechaHastaState(hasta);
    setSearchParams(escribirRango(searchParams, desde || null, hasta || null), { replace: true });
  }, [searchParams, setSearchParams]);
  const setFechaDesde = useCallback((v: string): void => setRango(v, fechaHasta), [setRango, fechaHasta]);
  const setFechaHasta = useCallback((v: string): void => setRango(fechaDesde, v), [setRango, fechaDesde]);
  /** La sucursal del contexto compartido, para las pestañas que la honran. */
  const sucursalUrl = leerSucursal(searchParams);
  const activeTab: ReportTabId = tabDeUrl(searchParams.get('tab')) ?? 'preventistas';
  const setActiveTab = useCallback((tab: ReportTabId): void => {
    const next = new URLSearchParams(searchParams);
    if (tab === 'preventistas') next.delete('tab'); else next.set('tab', tab);
    setSearchParams(next, { replace: true });
  }, [searchParams, setSearchParams]);
  const [filtrosVentas, setFiltrosVentas] = useState<FiltrosVentasValue>(() => {
    const base = filtrosVentasIniciales();
    // Un deep link con período gana sobre el preset default de la pestaña.
    return rangoUrl.desde && rangoUrl.hasta
      ? { ...base, desde: rangoUrl.desde, hasta: rangoUrl.hasta, presetId: 'custom' }
      : base;
  });

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
    { id: 'valuacion', label: 'Valuación de Stock', icon: Boxes },
    { id: 'stock-red', label: 'Stock de la Red', icon: Network },
    { id: 'mermas', label: 'Mermas', icon: TrendingDown }
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
  /** Recarga la pestaña activa con el rango dado. El rango viaja por argumento
   *  porque "Limpiar" lo recarga con el rango nuevo, no con el del render. */
  const recargarTab = async (desde: string, hasta: string): Promise<void> => {
    switch (activeTab) {
      case 'preventistas':
        await onCalcularReporte(desde || null, hasta || null);
        break;
      case 'cuentas': {
        const cuentas = await generarReporteCuentasPorCobrar();
        setReporteCuentas(cuentas);
        break;
      }
      case 'rentabilidad': {
        const rent = await generarReporteRentabilidad(desde || null, hasta || null);
        setReporteRentabilidad(rent);
        break;
      }
    }
  };

  const handleGenerarReporte = async (): Promise<void> => {
    await recargarTab(fechaDesde, fechaHasta);
  };

  // Limpiar tiene que recargar la pestaña que se está mirando, no sólo
  // preventistas: si no, el reporte sigue mostrando el período que el usuario
  // acaba de borrar.
  const handleLimpiarFiltros = async (): Promise<void> => {
    setRango('', '');
    await recargarTab('', '');
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
                aria-label="Limpiar filtros"
                title="Limpiar filtros"
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
        <>
          <Criterio className="mb-3">
            Venta = suma del <strong>total</strong> de los pedidos <strong>no cancelados</strong>, por fecha
            del pedido, atribuidos a quien lo cargó. Incluye pendientes y en camino, y no filtra por canal:
            por eso da más que "Equipo comercial" del reporte gerencial, que cuenta sólo los entregados del
            canal app.
          </Criterio>
          <ReportePreventistas
            reportePreventistas={reportePreventistas}
            loading={loading}
            formatPrecio={formatPrecio}
            desde={fechaDesde}
            hasta={fechaHasta}
          />
        </>
      )}

      {activeTab === 'cuentas' && (
        <>
          <Criterio className="mb-3">
            Saldo <strong>al día de hoy</strong>, no del período: el aging se calcula contra la fecha de
            entrega de cada pedido y los días de crédito del cliente, así que el período de arriba no lo
            afecta. Incluye clientes inactivos con deuda — un informe de deuda que esconde al que debe y ya
            no opera no sirve para cobrarle.
          </Criterio>
          <ReporteCuentasPorCobrar
            reporte={reporteCuentas}
            loading={loadingFinanciero}
            formatPrecio={formatPrecio}
            onVerCliente={onVerFichaCliente}
          />
        </>
      )}

      {activeTab === 'rentabilidad' && (
        <>
          <Criterio className="mb-3">
            Margen por producto de los pedidos <strong>no cancelados</strong>, filtrados por{' '}
            <strong>fecha de carga</strong> (<code>created_at</code>) y <strong>no</strong> por fecha del
            pedido, que es lo que usa el resto de los reportes: por eso no cierra contra "Por Cliente".
            Ingreso = ingreso real (FC neto · ZZ final); costo = cascada canónica.
          </Criterio>
          <ReporteRentabilidadSection
            reporte={reporteRentabilidad}
            loading={loadingFinanciero}
            formatPrecio={formatPrecio}
            desde={fechaDesde}
            hasta={fechaHasta}
          />
        </>
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
        <>
          <Criterio className="mb-3">
            Foto del stock de <strong>hoy</strong> a costo promedio ponderado. <strong>No depende del
            período</strong> elegido arriba ni de la sucursal del contexto: tiene su propio filtro.
          </Criterio>
          <ReporteValuacionInventario formatPrecio={formatPrecio} />
        </>
      )}

      {activeTab === 'stock-red' && (
        <>
          <Criterio className="mb-3">
            Stock de <strong>todas</strong> las sucursales al día de hoy. No depende del período ni de la
            sucursal del contexto: es cross-sucursal por definición.
          </Criterio>
          <ReporteStockRed formatPrecio={formatPrecio} />
        </>
      )}

      {activeTab === 'mermas' && (
        <>
          <Criterio className="mb-3">
            Mermas por <strong>día de carga</strong>, valuadas al <strong>costo congelado al momento</strong>;
            las anteriores al snapshot, al costo de hoy. El total <strong>excluye</strong> promociones y
            reversión de promoción. Es el mismo número que las Mermas del reporte gerencial.
          </Criterio>
          <ReporteMermas
            formatPrecio={formatPrecio}
            desde={fechaDesde}
            hasta={fechaHasta}
            sucursalUrl={sucursalUrl}
            onRango={setRango}
          />
        </>
      )}
    </div>
  );
}
