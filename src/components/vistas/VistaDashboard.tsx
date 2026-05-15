import React, { useState, useMemo, memo } from 'react';
import type { LucideIcon } from 'lucide-react';
import {
  DollarSign, ShoppingCart, Clock, Package, Truck, Check,
  TrendingUp, TrendingDown, Minus, Target, Users, AlertTriangle,
} from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';
import DashboardViewHeader from '../dashboard/DashboardViewHeader';
import DashboardToolbar from '../dashboard/DashboardToolbar';
import { cn } from '../../lib/utils';
import type {
  ProductoDB,
  DashboardMetricasExtended,
  FiltroPeriodo,
} from '../../types';

// =============================================================================
// INTERFACES DE PROPS
// =============================================================================

interface TendenciaIndicatorProps {
  valor: number;
  comparacion?: number | null;
  invertido?: boolean;
}

interface MetricaSemantica {
  /** Border-left coloreado (border-l-...) */
  accentBorder: string;
  /** Color del número y el icono dentro del badge */
  accentText: string;
  /** Fondo del badge circular del icono */
  badgeBg: string;
  /** Color del icono en el badge */
  badgeIcon: string;
  /** Gradient overlay sutil (before:from-...) */
  gradientFrom: string;
}

interface MetricaCardProps {
  icono: LucideIcon;
  titulo: string;
  valor: string | number;
  subtitulo?: string;
  semantica: MetricaSemantica;
  tendencia?: React.ReactNode;
}

interface EstadoSemantica {
  accentBorder: string;
  accentText: string;
  badgeBg: string;
  badgeIcon: string;
}

interface EstadoCardProps {
  icono: LucideIcon;
  titulo: string;
  valor: number;
  semantica: EstadoSemantica;
  onClick?: () => void;
}

interface BarraProgresoProps {
  dia: string;
  ventas: number;
  maxVenta: number;
  index: number;
}

export interface VistaDashboardProps {
  metricas: DashboardMetricasExtended;
  loading: boolean;
  filtroPeriodo: string;
  onCambiarPeriodo: (periodo: FiltroPeriodo | string, fechaDesde?: string | null, fechaHasta?: string | null) => void;
  onRefetch: () => void;
  onDescargarBackup: (tipo: string) => void;
  exportando: boolean;
  productosStockBajo?: ProductoDB[];
  totalClientes?: number;
  isAdmin?: boolean;
  isPreventista?: boolean;
  isPreventistaTaco?: boolean;
  isEncargado?: boolean;
}

interface MetricasCalculadas {
  ticketPromedio: number;
  tasaEntrega: number;
}

const periodoLabels: Record<string, string> = {
  hoy: 'Hoy',
  semana: 'Última semana',
  mes: 'Este mes',
  anio: 'Este año',
  historico: 'Histórico',
  personalizado: 'Personalizado',
};

// =============================================================================
// SUB-COMPONENTES
// =============================================================================

const TendenciaIndicator = memo(function TendenciaIndicator({ valor, comparacion, invertido = false }: TendenciaIndicatorProps) {
  if (!comparacion || comparacion === 0) {
    return (
      <span className="inline-flex items-center gap-1 text-[11px] text-stone-400 dark:text-stone-500">
        <Minus className="w-3 h-3" />
        Sin datos previos
      </span>
    );
  }

  const porcentaje = ((valor - comparacion) / comparacion) * 100;
  const esPositivo = invertido ? porcentaje < 0 : porcentaje > 0;
  const esNeutro = Math.abs(porcentaje) < 1;

  if (esNeutro) {
    return (
      <span className="inline-flex items-center gap-1 text-[11px] text-stone-400 dark:text-stone-500">
        <Minus className="w-3 h-3" />
        Sin cambios
      </span>
    );
  }

  return (
    <span className={cn(
      'inline-flex items-center gap-1 text-[11px] font-medium tabular-nums px-1.5 py-0.5 rounded-md',
      esPositivo
        ? 'bg-emerald-50 text-emerald-700 dark:bg-emerald-900/20 dark:text-emerald-300'
        : 'bg-rose-50 text-rose-700 dark:bg-rose-900/20 dark:text-rose-300',
    )}>
      {esPositivo ? <TrendingUp className="w-3 h-3" /> : <TrendingDown className="w-3 h-3" />}
      {Math.abs(porcentaje).toFixed(1)}%
    </span>
  );
});

const MetricaCard = memo(function MetricaCard({ icono, titulo, valor, subtitulo, semantica, tendencia }: MetricaCardProps) {
  const Icono = icono;
  return (
    <div
      className={cn(
        'group relative overflow-hidden bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 border-l-4 rounded-xl px-5 py-4 shadow-warm hover:shadow-warm-md hover:-translate-y-px transition-[transform,box-shadow] duration-200',
        semantica.accentBorder,
        'before:absolute before:inset-0 before:bg-gradient-to-br before:to-transparent before:pointer-events-none',
        semantica.gradientFrom,
      )}
    >
      <div className="relative flex items-start justify-between gap-3">
        <span className={cn('inline-flex items-center justify-center w-9 h-9 rounded-lg flex-shrink-0', semantica.badgeBg)}>
          <Icono className={cn('w-[18px] h-[18px]', semantica.badgeIcon)} aria-hidden="true" />
        </span>
        {tendencia && <div className="flex-shrink-0 mt-1">{tendencia}</div>}
      </div>
      <div className="relative mt-3">
        <p className="text-[11px] font-semibold uppercase tracking-[0.08em] text-stone-500 dark:text-stone-400">
          {titulo}
        </p>
        <p
          className={cn('text-[28px] tabular-nums leading-tight mt-1', semantica.accentText)}
          style={{ fontWeight: 800, letterSpacing: '-0.025em' }}
        >
          {valor}
        </p>
        {subtitulo && (
          <p className="text-xs text-stone-500 dark:text-stone-400 mt-0.5">{subtitulo}</p>
        )}
      </div>
    </div>
  );
});

const EstadoCard = memo(function EstadoCard({ icono, titulo, valor, semantica, onClick }: EstadoCardProps) {
  const Icono = icono;
  const Container: React.ElementType = onClick ? 'button' : 'div';
  return (
    <Container
      onClick={onClick}
      className={cn(
        'group relative overflow-hidden text-left bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 border-l-4 rounded-xl px-4 py-3 shadow-warm hover:shadow-warm-md hover:-translate-y-px transition-[transform,box-shadow] duration-200 w-full',
        semantica.accentBorder,
        onClick && 'cursor-pointer',
      )}
    >
      <div className="flex items-center gap-2.5">
        <span className={cn('inline-flex items-center justify-center w-7 h-7 rounded-lg flex-shrink-0', semantica.badgeBg)}>
          <Icono className={cn('w-3.5 h-3.5', semantica.badgeIcon)} aria-hidden="true" />
        </span>
        <span className="text-[11px] font-semibold uppercase tracking-[0.08em] text-stone-500 dark:text-stone-400 leading-tight">
          {titulo}
        </span>
      </div>
      <p
        className={cn('text-[26px] tabular-nums leading-tight mt-1.5', semantica.accentText)}
        style={{ fontWeight: 800, letterSpacing: '-0.025em' }}
      >
        {valor.toLocaleString('es-AR')}
      </p>
    </Container>
  );
});

const BarraProgreso = memo(function BarraProgreso({ dia, ventas, maxVenta, index }: BarraProgresoProps) {
  const porcentaje = maxVenta > 0 ? (ventas / maxVenta) * 100 : 0;
  const esHoy = index === 6;

  return (
    <div className="flex items-center gap-3 group">
      <span className={cn(
        'w-12 text-sm tabular-nums',
        esHoy ? 'font-bold text-blue-700 dark:text-blue-300' : 'text-stone-500 dark:text-stone-400',
      )}>
        {dia}
      </span>
      <div className="flex-1 bg-stone-100 dark:bg-gray-700 rounded-full h-7 overflow-hidden">
        <div
          className={cn(
            'h-7 rounded-full flex items-center justify-end pr-3 transition-all duration-500',
            esHoy
              ? 'bg-gradient-to-r from-blue-500 to-blue-600'
              : 'bg-gradient-to-r from-blue-400/80 to-blue-500/80',
          )}
          style={{
            width: `${Math.max(porcentaje, 14)}%`,
            animationDelay: `${index * 100}ms`,
          }}
        >
          <span className="text-xs text-white font-semibold tabular-nums truncate">
            {formatPrecio(ventas)}
          </span>
        </div>
      </div>
      <div className="w-12 text-right opacity-0 group-hover:opacity-100 transition-opacity">
        <span className="text-xs text-stone-500 dark:text-stone-400 tabular-nums">{porcentaje.toFixed(0)}%</span>
      </div>
    </div>
  );
});

// Mapping de semánticas (consistente con KPI cards de Pedidos)
const METRICAS_SEMANTICA: Record<'ventas' | 'pedidos' | 'ticket' | 'clientes', MetricaSemantica> = {
  ventas: {
    accentBorder: 'border-l-emerald-500',
    accentText: 'text-emerald-700 dark:text-emerald-300',
    badgeBg: 'bg-emerald-100 dark:bg-emerald-500/15',
    badgeIcon: 'text-emerald-600 dark:text-emerald-400',
    gradientFrom: 'before:from-emerald-500/[0.07]',
  },
  pedidos: {
    accentBorder: 'border-l-blue-500',
    accentText: 'text-blue-700 dark:text-blue-300',
    badgeBg: 'bg-blue-100 dark:bg-blue-500/15',
    badgeIcon: 'text-blue-600 dark:text-blue-400',
    gradientFrom: 'before:from-blue-500/[0.07]',
  },
  ticket: {
    accentBorder: 'border-l-purple-500',
    accentText: 'text-purple-700 dark:text-purple-300',
    badgeBg: 'bg-purple-100 dark:bg-purple-500/15',
    badgeIcon: 'text-purple-600 dark:text-purple-400',
    gradientFrom: 'before:from-purple-500/[0.07]',
  },
  clientes: {
    accentBorder: 'border-l-indigo-500',
    accentText: 'text-indigo-700 dark:text-indigo-300',
    badgeBg: 'bg-indigo-100 dark:bg-indigo-500/15',
    badgeIcon: 'text-indigo-600 dark:text-indigo-400',
    gradientFrom: 'before:from-indigo-500/[0.07]',
  },
};

const ESTADOS_SEMANTICA: Record<'pendiente' | 'preparacion' | 'camino' | 'entregado', EstadoSemantica> = {
  pendiente: {
    accentBorder: 'border-l-amber-500',
    accentText: 'text-amber-700 dark:text-amber-300',
    badgeBg: 'bg-amber-100 dark:bg-amber-500/15',
    badgeIcon: 'text-amber-600 dark:text-amber-400',
  },
  preparacion: {
    accentBorder: 'border-l-orange-500',
    accentText: 'text-orange-700 dark:text-orange-300',
    badgeBg: 'bg-orange-100 dark:bg-orange-500/15',
    badgeIcon: 'text-orange-600 dark:text-orange-400',
  },
  camino: {
    accentBorder: 'border-l-blue-500',
    accentText: 'text-blue-700 dark:text-blue-300',
    badgeBg: 'bg-blue-100 dark:bg-blue-500/15',
    badgeIcon: 'text-blue-600 dark:text-blue-400',
  },
  entregado: {
    accentBorder: 'border-l-emerald-500',
    accentText: 'text-emerald-700 dark:text-emerald-300',
    badgeBg: 'bg-emerald-100 dark:bg-emerald-500/15',
    badgeIcon: 'text-emerald-600 dark:text-emerald-400',
  },
};

// =============================================================================
// VISTA PRINCIPAL
// =============================================================================

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
  isPreventista = false,
  isPreventistaTaco = false,
  isEncargado = false,
}: VistaDashboardProps) {
  // Visibilidad por rol:
  //  - admin: ve todo
  //  - encargado: solo "Ventas ultimos 7 dias" + estados de pedido (sin facturacion total ni agregados)
  //  - preventista_taco: solo items (Top 5 productos) + estados; sin ningun monto
  //  - preventista regular: ve montos pero filtrados a sus propias ventas
  const verMontosAgregados = isAdmin || (isPreventista && !isPreventistaTaco)
  const verVentasSemanales = !isPreventistaTaco // taco no ve ningun monto
  const verTopProductos = !isEncargado || isAdmin // encargado no ve agregados de productos
  const verEstadoPedidos = true
  const [fechaDesdeLocal, setFechaDesdeLocal] = useState<string>('');
  const [fechaHastaLocal, setFechaHastaLocal] = useState<string>('');
  const [mostrarFechasPersonalizadas, setMostrarFechasPersonalizadas] = useState<boolean>(false);

  const metricasCalculadas = useMemo((): MetricasCalculadas | null => {
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

  const handlePeriodoChange = (periodo: string): void => {
    if (periodo === 'personalizado') {
      setMostrarFechasPersonalizadas(true);
    } else {
      setMostrarFechasPersonalizadas(false);
      onCambiarPeriodo(periodo);
    }
  };

  const aplicarFechasPersonalizadas = (): void => {
    if (fechaDesdeLocal || fechaHastaLocal) {
      onCambiarPeriodo('personalizado', fechaDesdeLocal || null, fechaHastaLocal || null);
    }
  };

  if (loading) return <LoadingSpinner />;

  const verbo = (isPreventista && !isAdmin && !isPreventistaTaco) ? 'Mis métricas' : 'Resumen';

  return (
    <div className="space-y-5">
      {/* Header editorial con toolbar */}
      <DashboardViewHeader
        filtroPeriodo={filtroPeriodo}
        fechaDesde={mostrarFechasPersonalizadas ? fechaDesdeLocal || null : null}
        fechaHasta={mostrarFechasPersonalizadas ? fechaHastaLocal || null : null}
        verbo={verbo}
        periodoLabel={periodoLabels[filtroPeriodo] || filtroPeriodo}
        loading={loading}
        actions={
          <DashboardToolbar
            loading={loading}
            exportando={exportando}
            isAdmin={isAdmin}
            onRefetch={onRefetch}
            onDescargarBackup={onDescargarBackup}
          />
        }
      />

      {/* Alerta de stock bajo: chip compacto (no banner) */}
      {productosStockBajo.length > 0 && (
        <div className="inline-flex items-start gap-2.5 bg-amber-50 dark:bg-amber-900/15 border border-amber-200 dark:border-amber-800/40 rounded-lg px-3.5 py-2.5 text-sm">
          <AlertTriangle className="w-4 h-4 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5" aria-hidden="true" />
          <div className="min-w-0">
            <p className="font-medium text-amber-800 dark:text-amber-200">
              {productosStockBajo.length} producto{productosStockBajo.length === 1 ? '' : 's'} con stock bajo
            </p>
            <p className="text-xs text-amber-700/80 dark:text-amber-300/80 mt-0.5 truncate">
              {productosStockBajo.slice(0, 3).map(p => p.nombre).join(' · ')}
              {productosStockBajo.length > 3 && ` · +${productosStockBajo.length - 3} más`}
            </p>
          </div>
        </div>
      )}

      {/* Filtro de período: chips horizontales */}
      <div className="bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 rounded-xl shadow-warm p-4">
        <div className="flex flex-wrap items-center gap-1.5">
          <span className="text-[11px] font-semibold uppercase tracking-[0.08em] text-stone-500 dark:text-stone-400 mr-2">
            Período
          </span>
          {Object.entries(periodoLabels).map(([key, label]) => (
            <button
              key={key}
              onClick={() => handlePeriodoChange(key)}
              className={cn(
                'h-8 px-3 rounded-lg text-sm font-medium transition-colors',
                filtroPeriodo === key
                  ? 'bg-blue-600 text-white shadow-warm'
                  : 'bg-stone-100 dark:bg-gray-700 text-stone-700 dark:text-stone-200 hover:bg-stone-200 dark:hover:bg-gray-600',
              )}
              aria-pressed={filtroPeriodo === key}
            >
              {label}
            </button>
          ))}
        </div>
        {mostrarFechasPersonalizadas && (
          <div className="mt-4 pt-4 border-t border-stone-200 dark:border-gray-700 flex flex-wrap items-end gap-3">
            <div>
              <label htmlFor="fecha-desde" className="block text-[10px] font-semibold uppercase tracking-[0.08em] text-stone-500 dark:text-stone-400 mb-1">Desde</label>
              <input
                id="fecha-desde"
                type="date"
                value={fechaDesdeLocal}
                onChange={e => setFechaDesdeLocal(e.target.value)}
                className="h-9 px-3 rounded-lg border border-stone-200 dark:border-gray-700 text-sm bg-white dark:bg-gray-800 text-stone-700 dark:text-stone-200 focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400"
              />
            </div>
            <div>
              <label htmlFor="fecha-hasta" className="block text-[10px] font-semibold uppercase tracking-[0.08em] text-stone-500 dark:text-stone-400 mb-1">Hasta</label>
              <input
                id="fecha-hasta"
                type="date"
                value={fechaHastaLocal}
                onChange={e => setFechaHastaLocal(e.target.value)}
                className="h-9 px-3 rounded-lg border border-stone-200 dark:border-gray-700 text-sm bg-white dark:bg-gray-800 text-stone-700 dark:text-stone-200 focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400"
              />
            </div>
            <button
              onClick={aplicarFechasPersonalizadas}
              className="h-9 px-4 rounded-lg text-sm font-semibold bg-blue-600 text-white hover:bg-blue-700 transition-colors"
            >
              Aplicar
            </button>
          </div>
        )}
      </div>

      {/* Métricas principales */}
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-3">
        {verMontosAgregados && (
          <MetricaCard
            icono={DollarSign}
            titulo="Ventas"
            valor={formatPrecio(metricas.ventasPeriodo)}
            subtitulo={periodoLabels[filtroPeriodo]}
            semantica={METRICAS_SEMANTICA.ventas}
            tendencia={<TendenciaIndicator valor={metricas.ventasPeriodo} comparacion={metricas.ventasPeriodoAnterior} />}
          />
        )}
        <MetricaCard
          icono={ShoppingCart}
          titulo="Pedidos"
          valor={metricas.pedidosPeriodo.toLocaleString('es-AR')}
          subtitulo={periodoLabels[filtroPeriodo]}
          semantica={METRICAS_SEMANTICA.pedidos}
          tendencia={<TendenciaIndicator valor={metricas.pedidosPeriodo} comparacion={metricas.pedidosPeriodoAnterior} />}
        />
        {verMontosAgregados && (
          <MetricaCard
            icono={Target}
            titulo="Ticket promedio"
            valor={formatPrecio(metricasCalculadas?.ticketPromedio || 0)}
            subtitulo="Por pedido"
            semantica={METRICAS_SEMANTICA.ticket}
          />
        )}
        <MetricaCard
          icono={Users}
          titulo="Clientes"
          valor={totalClientes.toLocaleString('es-AR')}
          subtitulo="Registrados"
          semantica={METRICAS_SEMANTICA.clientes}
        />
      </div>

      {/* Estados de pedidos */}
      <div>
        <h3 className="text-[11px] font-semibold uppercase tracking-[0.14em] text-stone-500 dark:text-stone-400 mb-2.5">
          Estado de pedidos
        </h3>
        <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
          <EstadoCard icono={Clock} titulo="Pendientes" valor={metricas.pedidosPorEstado.pendiente} semantica={ESTADOS_SEMANTICA.pendiente} />
          <EstadoCard icono={Package} titulo="En preparación" valor={metricas.pedidosPorEstado.en_preparacion || 0} semantica={ESTADOS_SEMANTICA.preparacion} />
          <EstadoCard icono={Truck} titulo="En camino" valor={metricas.pedidosPorEstado.asignado} semantica={ESTADOS_SEMANTICA.camino} />
          <EstadoCard icono={Check} titulo="Entregados" valor={metricas.pedidosPorEstado.entregado} semantica={ESTADOS_SEMANTICA.entregado} />
        </div>
      </div>

      {/* Gráficos */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-5">
        {/* Ventas últimos 7 días */}
        {verVentasSemanales && (
        <div className="bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 rounded-xl shadow-warm p-5">
          <div className="flex items-center justify-between mb-4">
            <h3 className="text-base font-semibold text-stone-900 dark:text-white">Ventas últimos 7 días</h3>
            {verMontosAgregados && (
              <span className="text-xs text-stone-500 dark:text-stone-400 tabular-nums">
                Total: <span className="font-semibold text-stone-700 dark:text-stone-200">{formatPrecio(metricas.ventasPorDia.reduce((sum, d) => sum + d.ventas, 0))}</span>
              </span>
            )}
          </div>
          <div className="space-y-2.5">
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
        )}

        {/* Top 5 productos */}
        {verTopProductos && (
        <div className="bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 rounded-xl shadow-warm p-5">
          <div className="flex items-center justify-between mb-4">
            <h3 className="text-base font-semibold text-stone-900 dark:text-white">
              Top 5 productos
            </h3>
            <span className="text-xs text-stone-500 dark:text-stone-400">
              {periodoLabels[filtroPeriodo]}
            </span>
          </div>
          <div className="space-y-3.5">
            {metricas.productosMasVendidos.length === 0 ? (
              <p className="text-stone-500 dark:text-stone-400 text-center py-8 text-sm">
                Sin datos en este período
              </p>
            ) : metricas.productosMasVendidos.map((p, i) => {
              const maxCantidad = metricas.productosMasVendidos[0]?.cantidad || 1;
              const porcentaje = (p.cantidad / maxCantidad) * 100;
              const rankClass =
                i === 0 ? 'bg-gradient-to-br from-amber-400 to-amber-500 text-amber-900' :
                i === 1 ? 'bg-gradient-to-br from-stone-300 to-stone-400 text-stone-800' :
                i === 2 ? 'bg-gradient-to-br from-orange-400 to-orange-500 text-orange-900' :
                'bg-stone-100 dark:bg-gray-700 text-stone-600 dark:text-stone-300';
              const barColor =
                i === 0 ? 'bg-amber-500' :
                i === 1 ? 'bg-stone-400' :
                i === 2 ? 'bg-orange-500' :
                'bg-blue-500';
              return (
                <div key={p.id} className="flex items-center gap-3">
                  <span className={cn(
                    'w-8 h-8 rounded-full flex items-center justify-center text-sm font-bold shadow-warm flex-shrink-0',
                    rankClass,
                  )}>
                    {i + 1}
                  </span>
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center justify-between mb-1.5 gap-2">
                      <span className="font-medium text-sm text-stone-800 dark:text-white truncate">{p.nombre}</span>
                      <span className="text-xs text-stone-600 dark:text-stone-300 tabular-nums flex-shrink-0">
                        {p.cantidad.toLocaleString('es-AR')} <span className="text-stone-400">unid.</span>
                      </span>
                    </div>
                    <div className="w-full bg-stone-100 dark:bg-gray-700 rounded-full h-1.5 overflow-hidden">
                      <div
                        className={cn('h-1.5 rounded-full transition-all duration-500', barColor)}
                        style={{ width: `${porcentaje}%` }}
                      />
                    </div>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
        )}
      </div>

      {/* Tasa de entrega */}
      {metricasCalculadas && verEstadoPedidos && (
        <div className="bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 rounded-xl shadow-warm p-5">
          <div className="flex items-center justify-between mb-3">
            <div>
              <h3 className="text-base font-semibold text-stone-900 dark:text-white">Tasa de entrega</h3>
              <p className="text-xs text-stone-500 dark:text-stone-400 mt-0.5">Porcentaje de pedidos entregados del total</p>
            </div>
            <span
              className="text-3xl text-emerald-700 dark:text-emerald-300 tabular-nums"
              style={{ fontWeight: 800, letterSpacing: '-0.025em' }}
            >
              {metricasCalculadas.tasaEntrega.toFixed(1)}%
            </span>
          </div>
          <div className="w-full bg-stone-100 dark:bg-gray-700 rounded-full h-3 overflow-hidden">
            <div
              className="bg-gradient-to-r from-emerald-500 to-emerald-600 h-3 rounded-full transition-all duration-500"
              style={{ width: `${metricasCalculadas.tasaEntrega}%` }}
            />
          </div>
        </div>
      )}
    </div>
  );
}
