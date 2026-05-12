/**
 * Vista admin "Geolocalización"
 *
 * Panel unificado que consolida los tres usos del check-in GPS:
 *   1. Última ubicación conocida (mapa con un pin por preventista)
 *   2. Recorrido del día (drill-down al seleccionar un preventista)
 *   3. Verificación de visita (anomalías + chip de distancia en cada pedido)
 *
 * Solo accesible a `rol === 'admin'`. La fuente de datos es la RPC
 * `obtener_geolocalizacion_preventistas`, scope a la sucursal activa.
 */
import React, { useMemo, useState } from 'react'
import { MapPin, Users, ShoppingCart, AlertTriangle, RefreshCw, Calendar } from 'lucide-react'
import {
  useGeolocalizacionPreventistasQuery,
  type PedidoConGps,
  type VisitaConGps,
} from '../../hooks/queries'
import { fechaLocalISO } from '../../utils/formatters'
import { ANOMALIA_DISTANCIA_METROS } from '../../utils/geo'
import KpiCard from '../geolocalizacion/KpiCard'
import SidebarPreventistas from '../geolocalizacion/SidebarPreventistas'
import MapaPreventistas from '../geolocalizacion/MapaPreventistas'
import TimelineRecorrido from '../geolocalizacion/TimelineRecorrido'
import TablaAnomalias from '../geolocalizacion/TablaAnomalias'

type RangoPreset = 'hoy' | 'ayer' | 'semana' | 'custom'

interface Rango {
  desde: string
  hasta: string
  preset: RangoPreset
}

function diasAtras(n: number): string {
  const d = new Date()
  d.setDate(d.getDate() - n)
  return d.toISOString().slice(0, 10)
}

function buildRangoDefault(): Rango {
  const hoy = fechaLocalISO()
  return { desde: hoy, hasta: hoy, preset: 'hoy' }
}

function rangoFromPreset(preset: Exclude<RangoPreset, 'custom'>): Rango {
  if (preset === 'hoy') {
    const hoy = fechaLocalISO()
    return { desde: hoy, hasta: hoy, preset }
  }
  if (preset === 'ayer') {
    const ayer = diasAtras(1)
    return { desde: ayer, hasta: ayer, preset }
  }
  // semana: últimos 7 días incluyendo hoy
  return { desde: diasAtras(6), hasta: fechaLocalISO(), preset }
}

const PRESET_LABELS: Record<Exclude<RangoPreset, 'custom'>, string> = {
  hoy: 'Hoy',
  ayer: 'Ayer',
  semana: 'Últimos 7 días',
}

export default function VistaGeolocalizacion(): React.ReactElement {
  const [rango, setRango] = useState<Rango>(buildRangoDefault)
  const [preventistaSelectedId, setPreventistaSelectedId] = useState<string | null>(null)
  const [pedidoSelectedId, setPedidoSelectedId] = useState<number | null>(null)
  const [tab, setTab] = useState<'timeline' | 'anomalias'>('timeline')

  // Auto-refresh solo si el rango incluye hoy.
  const autoRefresh = rango.hasta === fechaLocalISO()

  const { data, isLoading, isFetching, error, refetch } = useGeolocalizacionPreventistasQuery(
    rango.desde,
    rango.hasta,
    { autoRefresh },
  )

  // Estabilizamos las referencias para que los useMemo de KPIs no se
  // re-disparen en cada render cuando `data` es undefined.
  const preventistas = useMemo(() => data?.preventistas ?? [], [data?.preventistas])
  const pedidos: PedidoConGps[] = useMemo(() => data?.pedidos ?? [], [data?.pedidos])
  const visitas: VisitaConGps[] = useMemo(() => data?.visitas ?? [], [data?.visitas])

  // KPIs
  const kpis = useMemo(() => {
    const total = pedidos.length
    const conGps = pedidos.filter(p => p.gps_status === 'ok').length
    const sinGps = total - conGps
    const visitasTotal = visitas.length
    const anomaliasPedidos = pedidos.filter(p => {
      if (p.gps_status !== 'ok') return true
      return p.distancia_m != null && p.distancia_m >= ANOMALIA_DISTANCIA_METROS
    }).length
    const anomaliasVisitas = visitas.filter(v => {
      if (v.gps_status !== 'ok') return true
      return v.distancia_m != null && v.distancia_m >= ANOMALIA_DISTANCIA_METROS
    }).length
    return {
      preventistasActivos: preventistas.length,
      conGps,
      sinGps,
      visitas: visitasTotal,
      anomalias: anomaliasPedidos + anomaliasVisitas,
    }
  }, [pedidos, visitas, preventistas])

  const preventistaSelectedNombre = useMemo(() => {
    if (!preventistaSelectedId) return null
    return preventistas.find(p => p.preventista_id === preventistaSelectedId)?.preventista_nombre ?? null
  }, [preventistaSelectedId, preventistas])

  // Handlers
  const setPreset = (preset: Exclude<RangoPreset, 'custom'>) => {
    setRango(rangoFromPreset(preset))
    setPreventistaSelectedId(null)
    setPedidoSelectedId(null)
  }

  const handleSelectPreventista = (id: string | null) => {
    setPreventistaSelectedId(id)
    setPedidoSelectedId(null)
    if (id) setTab('timeline')
  }

  const handleSelectAnomalia = (pedidoId: number, preventistaId: string) => {
    setPreventistaSelectedId(preventistaId)
    setPedidoSelectedId(pedidoId)
    setTab('timeline')
  }

  return (
    <div className="space-y-4 p-4 max-w-7xl mx-auto">
      {/* Header con filtros */}
      <header className="flex flex-col sm:flex-row sm:items-center justify-between gap-3">
        <div>
          <h1 className="text-xl sm:text-2xl font-semibold text-gray-900 dark:text-white flex items-center gap-2">
            <MapPin className="w-6 h-6 text-blue-600" />
            Control de geolocalización
          </h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Última ubicación, recorrido del día y verificación de visitas de los preventistas.
          </p>
        </div>
        <div className="flex items-center gap-2 flex-wrap">
          <div className="inline-flex rounded-lg overflow-hidden border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800">
            {(Object.keys(PRESET_LABELS) as Array<Exclude<RangoPreset, 'custom'>>).map(p => (
              <button
                key={p}
                type="button"
                onClick={() => setPreset(p)}
                className={`px-3 py-2 text-sm font-medium transition-colors ${
                  rango.preset === p
                    ? 'bg-blue-600 text-white'
                    : 'text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700'
                }`}
              >
                {PRESET_LABELS[p]}
              </button>
            ))}
          </div>
          <div className="inline-flex items-center gap-1 px-3 py-2 text-sm rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200">
            <Calendar className="w-4 h-4 text-gray-400" aria-hidden />
            <input
              type="date"
              value={rango.desde}
              max={rango.hasta}
              onChange={e => setRango(r => ({ ...r, desde: e.target.value, preset: 'custom' }))}
              className="bg-transparent outline-none text-sm tabular-nums"
              aria-label="Fecha desde"
            />
            <span className="text-gray-400">→</span>
            <input
              type="date"
              value={rango.hasta}
              min={rango.desde}
              onChange={e => setRango(r => ({ ...r, hasta: e.target.value, preset: 'custom' }))}
              className="bg-transparent outline-none text-sm tabular-nums"
              aria-label="Fecha hasta"
            />
          </div>
          <button
            type="button"
            onClick={() => refetch()}
            disabled={isFetching}
            className="inline-flex items-center gap-1 px-3 py-2 text-sm font-medium rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700 disabled:opacity-60"
            aria-label="Actualizar"
            title={autoRefresh ? 'Auto-refresca cada 60 s' : 'Refrescar'}
          >
            <RefreshCw className={`w-4 h-4 ${isFetching ? 'animate-spin' : ''}`} />
            <span className="hidden sm:inline">Actualizar</span>
          </button>
        </div>
      </header>

      {/* KPIs */}
      <div className="grid grid-cols-2 sm:grid-cols-3 lg:grid-cols-5 gap-3">
        <KpiCard
          label="Preventistas activos"
          value={kpis.preventistasActivos}
          icon={Users}
          tone="blue"
          hint={autoRefresh ? 'Actualizado en tiempo real' : undefined}
        />
        <KpiCard
          label="Pedidos con GPS"
          value={kpis.conGps}
          icon={ShoppingCart}
          tone="green"
        />
        <KpiCard
          label="Visitas marcadas"
          value={kpis.visitas}
          icon={MapPin}
          tone="blue"
          hint="Pings sin pedido asociado"
        />
        <KpiCard
          label="Sin ubicación"
          value={kpis.sinGps}
          icon={MapPin}
          tone="slate"
        />
        <KpiCard
          label="Anomalías"
          value={kpis.anomalias}
          icon={AlertTriangle}
          tone={kpis.anomalias > 0 ? 'red' : 'green'}
          hint="Sin GPS o ≥1 km del cliente"
        />
      </div>

      {error && (
        <div className="rounded-lg border border-red-200 bg-red-50 dark:bg-red-900/20 text-red-700 dark:text-red-300 px-4 py-3 text-sm">
          Error cargando datos: {(error as Error).message}
        </div>
      )}

      {/* Grid principal: sidebar + mapa */}
      <div className="grid grid-cols-1 lg:grid-cols-[18rem_1fr] gap-4">
        <aside className="lg:order-1">
          {isLoading ? (
            <div className="bg-white dark:bg-gray-800 border border-gray-200 dark:border-gray-700 rounded-xl p-8 text-center text-sm text-gray-500">
              Cargando preventistas…
            </div>
          ) : (
            <SidebarPreventistas
              preventistas={preventistas}
              selectedId={preventistaSelectedId}
              onSelect={handleSelectPreventista}
            />
          )}
        </aside>
        <section className="lg:order-2">
          <MapaPreventistas
            preventistas={preventistas}
            pedidos={pedidos}
            visitas={visitas}
            preventistaSelectedId={preventistaSelectedId}
            pedidoSelectedId={pedidoSelectedId}
            onSelectPreventista={handleSelectPreventista}
            onSelectPedido={setPedidoSelectedId}
          />
        </section>
      </div>

      {/* Tabs: timeline / anomalias */}
      <div>
        <div className="border-b border-gray-200 dark:border-gray-700 flex items-center gap-1">
          <button
            type="button"
            onClick={() => setTab('timeline')}
            className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors -mb-px ${
              tab === 'timeline'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:hover:text-gray-300'
            }`}
            aria-pressed={tab === 'timeline'}
          >
            Timeline
          </button>
          <button
            type="button"
            onClick={() => setTab('anomalias')}
            className={`px-4 py-2 text-sm font-medium border-b-2 transition-colors -mb-px ${
              tab === 'anomalias'
                ? 'border-blue-600 text-blue-600 dark:text-blue-400'
                : 'border-transparent text-gray-500 hover:text-gray-700 dark:hover:text-gray-300'
            }`}
            aria-pressed={tab === 'anomalias'}
          >
            Anomalías
            {kpis.anomalias > 0 && (
              <span className="ml-2 inline-flex items-center px-1.5 py-0.5 rounded-full text-xs bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300">
                {kpis.anomalias}
              </span>
            )}
          </button>
        </div>
        <div className="mt-3">
          {tab === 'timeline' ? (
            <TimelineRecorrido
              pedidos={pedidos}
              visitas={visitas}
              preventistaId={preventistaSelectedId}
              preventistaNombre={preventistaSelectedNombre}
              selectedPedidoId={pedidoSelectedId}
              onSelectPedido={setPedidoSelectedId}
            />
          ) : (
            <TablaAnomalias
              pedidos={pedidos}
              visitas={visitas}
              preventistas={preventistas}
              onSelectPedido={handleSelectAnomalia}
              onSelectVisitaPreventista={(preventistaId) => {
                setPreventistaSelectedId(preventistaId)
                setPedidoSelectedId(null)
                setTab('timeline')
              }}
            />
          )}
        </div>
      </div>
    </div>
  )
}
