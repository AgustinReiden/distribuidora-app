/**
 * Vista de rendiciones (resumen auto-calculado + cierre + resolucion).
 * Muestra resumen por (dia de pago, transportista) con breakdown por forma de
 * pago, total entregado ese dia (comparador secundario), gastos del dia y
 * estado (pendiente/confirmada/disconformidad/resuelta).
 */
import React, { lazy, Suspense, useState, useEffect, useCallback, useMemo } from 'react'
import {
  Banknote,
  Calendar,
  User,
  CheckCircle,
  Clock,
  Filter,
  RefreshCw,
  ChevronDown,
  ChevronUp,
  AlertTriangle,
  FileText,
  Receipt
} from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
import { useRendiciones, useUsuarios } from '../../hooks/supabase'
import { useNotification } from '../../contexts/NotificationContext'
import { FORMAS_PAGO } from '../../constants/formasPago'
import type { ResumenRendicionDiaria, PerfilDB, EstadoRendicion, RendicionGastoInput } from '../../types'

const ModalCerrarRendicion = lazy(() => import('../modals/ModalCerrarRendicion'))
const ModalResolverRendicion = lazy(() => import('../modals/ModalResolverRendicion'))

function formatMoney(value: number | undefined | null): string {
  return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value || 0)
}

function formatFechaCorta(fechaISO: string): string {
  const [y, m, d] = fechaISO.split('-')
  return `${d}/${m}/${y}`
}

const ESTADO_STYLES: Record<EstadoRendicion, { label: string; badge: string; border: string }> = {
  pendiente: {
    label: 'Pendiente',
    badge: 'bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-300',
    border: 'border-gray-300 dark:border-gray-600'
  },
  confirmada: {
    label: 'Confirmada',
    badge: 'bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300',
    border: 'border-emerald-500'
  },
  disconformidad: {
    label: 'Disconformidad',
    badge: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300',
    border: 'border-red-500'
  },
  resuelta: {
    label: 'Resuelta',
    badge: 'bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300',
    border: 'border-blue-500'
  }
}

interface ResumenCardProps {
  resumen: ResumenRendicionDiaria
  onCerrar: (resumen: ResumenRendicionDiaria) => void
  onResolver: (resumen: ResumenRendicionDiaria) => void
}

function ResumenCard({ resumen, onCerrar, onResolver }: ResumenCardProps): React.ReactElement {
  const [expandido, setExpandido] = useState(false)
  const estadoStyle = ESTADO_STYLES[resumen.estado]

  const desgloses = useMemo(() => {
    const mapa: Record<string, number> = {
      efectivo: resumen.total_efectivo,
      transferencia: resumen.total_transferencia,
      cheque: resumen.total_cheque,
      cuenta_corriente: resumen.total_cuenta_corriente,
      tarjeta: resumen.total_tarjeta,
      otros: resumen.total_otros
    }
    return FORMAS_PAGO
      .map(fp => ({ meta: fp, value: mapa[fp.value] || 0 }))
      .filter(d => d.value > 0)
  }, [resumen])

  const diferencia = resumen.total_general - resumen.total_entregado
  const diferenciaStr = diferencia === 0
    ? 'Cobrado igual a entregado'
    : diferencia > 0
      ? `+${formatMoney(diferencia)} cobrado sobre entregado`
      : `${formatMoney(diferencia)} cobrado menos que entregado`

  return (
    <div className={`bg-white dark:bg-gray-800 rounded-xl shadow-sm border-l-4 ${estadoStyle.border} overflow-hidden`}>
      <div className="p-4">
        <div className="flex items-start justify-between flex-wrap gap-3">
          <div className="flex-1 min-w-[200px]">
            <div className="flex items-center gap-2 mb-1 flex-wrap">
              <User className="w-4 h-4 text-gray-500" />
              <span className="font-semibold text-gray-800 dark:text-white">
                {resumen.transportista_nombre}
              </span>
              <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${estadoStyle.badge}`}>
                {estadoStyle.label}
              </span>
            </div>
            <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400 flex-wrap">
              <Calendar className="w-4 h-4" />
              <span>{formatFechaCorta(resumen.fecha)}</span>
              <span className="px-2 py-0.5 rounded-full text-xs bg-gray-100 dark:bg-gray-700">
                {resumen.cantidad_pedidos} {resumen.cantidad_pedidos === 1 ? 'pedido entregado' : 'pedidos entregados'}
              </span>
            </div>
          </div>

          <div className="text-right">
            <p className="text-xs text-gray-500 dark:text-gray-400">Cobrado ese día</p>
            <p className="text-2xl font-bold text-gray-800 dark:text-white">
              {formatMoney(resumen.total_general)}
            </p>
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-0.5">
              Entregado: <span className="font-medium">{formatMoney(resumen.total_entregado)}</span>
            </p>
          </div>
        </div>

        {/* Breakdown por forma de pago (solo las que tienen monto) */}
        {desgloses.length > 0 && (
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 mt-4">
            {desgloses.map(({ meta, value }) => (
              <div key={meta.value} className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-2">
                <p className="text-xs text-gray-500 dark:text-gray-400">{meta.label}</p>
                <p className={`font-bold text-${meta.color}-700 dark:text-${meta.color}-400`}>{formatMoney(value)}</p>
              </div>
            ))}
          </div>
        )}

        {/* Indicadores de gastos y observaciones */}
        {(resumen.cantidad_gastos > 0 || resumen.observaciones) && (
          <div className="mt-3 flex items-center gap-3 text-xs flex-wrap">
            {resumen.cantidad_gastos > 0 && (
              <span className="inline-flex items-center gap-1 px-2 py-1 rounded bg-amber-50 dark:bg-amber-900/20 text-amber-700 dark:text-amber-300">
                <Receipt className="w-3 h-3" />
                {resumen.cantidad_gastos} gasto{resumen.cantidad_gastos !== 1 ? 's' : ''} · {formatMoney(resumen.total_gastos)}
              </span>
            )}
            {resumen.observaciones && (
              <span className="inline-flex items-center gap-1 px-2 py-1 rounded bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300">
                <FileText className="w-3 h-3" />
                Con observaciones
              </span>
            )}
          </div>
        )}

        {/* Footer con estado + acciones */}
        <div className="flex items-center justify-between mt-4 pt-3 border-t border-gray-200 dark:border-gray-700 flex-wrap gap-2">
          <div className="flex items-center gap-2 text-sm">
            {resumen.estado === 'confirmada' && (
              <>
                <CheckCircle className="w-5 h-5 text-emerald-500" />
                <div>
                  <p className="font-medium text-emerald-700 dark:text-emerald-400">Confirmada</p>
                  {resumen.controlada_at && (
                    <p className="text-xs text-gray-500 dark:text-gray-400">
                      {new Date(resumen.controlada_at).toLocaleString('es-AR')}
                      {resumen.controlada_por_nombre && ` por ${resumen.controlada_por_nombre}`}
                    </p>
                  )}
                </div>
              </>
            )}
            {resumen.estado === 'disconformidad' && (
              <>
                <AlertTriangle className="w-5 h-5 text-red-500" />
                <div>
                  <p className="font-medium text-red-700 dark:text-red-400">Disconformidad</p>
                  {resumen.controlada_at && (
                    <p className="text-xs text-gray-500 dark:text-gray-400">
                      Reportada {new Date(resumen.controlada_at).toLocaleString('es-AR')}
                      {resumen.controlada_por_nombre && ` por ${resumen.controlada_por_nombre}`}
                    </p>
                  )}
                </div>
              </>
            )}
            {resumen.estado === 'resuelta' && (
              <>
                <CheckCircle className="w-5 h-5 text-blue-500" />
                <div>
                  <p className="font-medium text-blue-700 dark:text-blue-400">Resuelta</p>
                  {resumen.resuelta_at && (
                    <p className="text-xs text-gray-500 dark:text-gray-400">
                      {new Date(resumen.resuelta_at).toLocaleString('es-AR')}
                      {resumen.resuelta_por_nombre && ` por ${resumen.resuelta_por_nombre}`}
                    </p>
                  )}
                </div>
              </>
            )}
            {resumen.estado === 'pendiente' && (
              <>
                <Clock className="w-5 h-5 text-gray-400" />
                <p className="text-gray-600 dark:text-gray-400">Pendiente de control</p>
              </>
            )}
          </div>

          <div className="flex items-center gap-2 flex-wrap">
            <button
              onClick={() => setExpandido(!expandido)}
              className="text-sm text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 flex items-center gap-1"
            >
              {expandido ? <ChevronUp className="w-4 h-4" /> : <ChevronDown className="w-4 h-4" />}
              Detalle
            </button>

            {resumen.estado === 'disconformidad' ? (
              <button
                onClick={() => onResolver(resumen)}
                className="px-4 py-2 rounded-lg text-sm font-medium bg-blue-600 hover:bg-blue-700 text-white"
              >
                Resolver
              </button>
            ) : (
              <button
                onClick={() => onCerrar(resumen)}
                className="px-4 py-2 rounded-lg text-sm font-medium bg-blue-600 hover:bg-blue-700 text-white"
              >
                {resumen.estado === 'pendiente' ? 'Cerrar rendición' : 'Editar cierre'}
              </button>
            )}
          </div>
        </div>

        {expandido && (
          <div className="mt-4 pt-3 border-t border-gray-200 dark:border-gray-700 text-sm space-y-3">
            <div>
              <p className="text-xs text-gray-500 mb-2">Breakdown completo por forma de pago</p>
              <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                <div><span className="text-gray-500">Efectivo:</span> <span className="font-medium">{formatMoney(resumen.total_efectivo)}</span></div>
                <div><span className="text-gray-500">Transferencia:</span> <span className="font-medium">{formatMoney(resumen.total_transferencia)}</span></div>
                <div><span className="text-gray-500">Cheque:</span> <span className="font-medium">{formatMoney(resumen.total_cheque)}</span></div>
                <div><span className="text-gray-500">Cuenta Cte.:</span> <span className="font-medium">{formatMoney(resumen.total_cuenta_corriente)}</span></div>
                <div><span className="text-gray-500">Tarjeta:</span> <span className="font-medium">{formatMoney(resumen.total_tarjeta)}</span></div>
                <div><span className="text-gray-500">Otros:</span> <span className="font-medium">{formatMoney(resumen.total_otros)}</span></div>
              </div>
            </div>

            <div className="flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
              <Banknote className="w-3 h-3" />
              <span>{diferenciaStr}</span>
            </div>

            {resumen.observaciones && (
              <div>
                <p className="text-xs text-gray-500 mb-1">Observaciones</p>
                <p className="text-sm text-gray-700 dark:text-gray-300 whitespace-pre-wrap bg-gray-50 dark:bg-gray-700/50 p-2 rounded">
                  {resumen.observaciones}
                </p>
              </div>
            )}
          </div>
        )}
      </div>
    </div>
  )
}

export default function VistaRendiciones(): React.ReactElement {
  const notify = useNotification()
  const {
    resumenes,
    loading,
    fetchResumen,
    confirmarRendicion,
    resolverRendicion
  } = useRendiciones()
  const { transportistas } = useUsuarios()

  const hoy = fechaLocalISO()
  const haceUnaSemana = useMemo(() => {
    const d = new Date()
    d.setDate(d.getDate() - 7)
    return fechaLocalISO(d)
  }, [])

  const [fechaDesde, setFechaDesde] = useState<string>(haceUnaSemana)
  const [fechaHasta, setFechaHasta] = useState<string>(hoy)
  const [transportistaFiltro, setTransportistaFiltro] = useState<string>('')
  const [estadoFiltro, setEstadoFiltro] = useState<'todas' | 'pendientes' | 'confirmadas' | 'disconformidad' | 'resueltas'>('todas')

  const [cerrarResumen, setCerrarResumen] = useState<ResumenRendicionDiaria | null>(null)
  const [resolverResumen, setResolverResumen] = useState<ResumenRendicionDiaria | null>(null)
  const [guardando, setGuardando] = useState(false)

  const cargar = useCallback(async (): Promise<void> => {
    await fetchResumen(fechaDesde, fechaHasta, transportistaFiltro || null)
  }, [fechaDesde, fechaHasta, transportistaFiltro, fetchResumen])

  useEffect(() => {
    cargar()
  }, [cargar])

  const handleCerrar = useCallback(async (
    estado: 'confirmada' | 'disconformidad',
    observaciones: string | null,
    gastos: RendicionGastoInput[]
  ): Promise<void> => {
    if (!cerrarResumen) return
    setGuardando(true)
    try {
      await confirmarRendicion(
        cerrarResumen.fecha,
        cerrarResumen.transportista_id,
        estado,
        observaciones,
        gastos
      )
      notify.success(estado === 'confirmada' ? 'Rendición confirmada' : 'Disconformidad registrada')
      setCerrarResumen(null)
    } catch {
      // Error ya notificado en el hook
    } finally {
      setGuardando(false)
    }
  }, [cerrarResumen, confirmarRendicion, notify])

  const handleResolver = useCallback(async (observaciones: string): Promise<void> => {
    if (!resolverResumen) return
    setGuardando(true)
    try {
      await resolverRendicion(
        resolverResumen.fecha,
        resolverResumen.transportista_id,
        observaciones
      )
      notify.success('Disconformidad resuelta')
      setResolverResumen(null)
    } catch {
      // Error ya notificado
    } finally {
      setGuardando(false)
    }
  }, [resolverResumen, resolverRendicion, notify])

  const resumenesFiltrados = useMemo(() => {
    if (estadoFiltro === 'todas') return resumenes
    if (estadoFiltro === 'pendientes') return resumenes.filter(r => r.estado === 'pendiente')
    if (estadoFiltro === 'confirmadas') return resumenes.filter(r => r.estado === 'confirmada')
    if (estadoFiltro === 'disconformidad') return resumenes.filter(r => r.estado === 'disconformidad')
    if (estadoFiltro === 'resueltas') return resumenes.filter(r => r.estado === 'resuelta')
    return resumenes
  }, [resumenes, estadoFiltro])

  const stats = useMemo(() => ({
    total: resumenes.length,
    confirmadas: resumenes.filter(r => r.estado === 'confirmada').length,
    pendientes: resumenes.filter(r => r.estado === 'pendiente').length,
    disconformidad: resumenes.filter(r => r.estado === 'disconformidad').length,
    totalCobrado: resumenes.reduce((sum, r) => sum + r.total_general, 0),
    totalEntregado: resumenes.reduce((sum, r) => sum + r.total_entregado, 0)
  }), [resumenes])

  return (
    <div className="space-y-4 p-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white flex items-center gap-2">
            <Banknote className="w-6 h-6" />
            Rendiciones Diarias
          </h1>
          <p className="text-gray-500 mt-1 text-sm">
            Resumen auto-calculado por transportista y día (basado en fecha de pago)
          </p>
        </div>
        <button
          onClick={cargar}
          disabled={loading}
          className="flex items-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg transition-colors disabled:opacity-50"
        >
          <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
          Refrescar
        </button>
      </div>

      {/* Stats */}
      <div className="grid grid-cols-2 md:grid-cols-6 gap-3">
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Total</p>
          <p className="text-2xl font-bold">{stats.total}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Confirmadas</p>
          <p className="text-2xl font-bold text-emerald-600">{stats.confirmadas}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Pendientes</p>
          <p className="text-2xl font-bold text-amber-600">{stats.pendientes}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Disconformidad</p>
          <p className="text-2xl font-bold text-red-600">{stats.disconformidad}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Cobrado total</p>
          <p className="text-lg font-bold">{formatMoney(stats.totalCobrado)}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Entregado total</p>
          <p className="text-lg font-bold">{formatMoney(stats.totalEntregado)}</p>
        </div>
      </div>

      {/* Filtros */}
      <div className="bg-white dark:bg-gray-800 rounded-lg p-4 shadow-sm">
        <div className="flex items-center gap-2 mb-3">
          <Filter className="w-4 h-4 text-gray-500" />
          <h3 className="text-sm font-medium text-gray-700 dark:text-gray-300">Filtros</h3>
        </div>
        <div className="grid grid-cols-1 sm:grid-cols-2 md:grid-cols-4 gap-3">
          <div>
            <label className="block text-xs text-gray-600 dark:text-gray-400 mb-1">Desde</label>
            <input
              type="date"
              value={fechaDesde}
              onChange={(e) => setFechaDesde(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-600 dark:text-gray-400 mb-1">Hasta</label>
            <input
              type="date"
              value={fechaHasta}
              onChange={(e) => setFechaHasta(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-sm"
            />
          </div>
          <div>
            <label className="block text-xs text-gray-600 dark:text-gray-400 mb-1">Transportista</label>
            <select
              value={transportistaFiltro}
              onChange={(e) => setTransportistaFiltro(e.target.value)}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-sm"
            >
              <option value="">Todos</option>
              {transportistas.map((t: PerfilDB) => (
                <option key={t.id} value={t.id}>{t.nombre}</option>
              ))}
            </select>
          </div>
          <div>
            <label className="block text-xs text-gray-600 dark:text-gray-400 mb-1">Estado</label>
            <select
              value={estadoFiltro}
              onChange={(e) => setEstadoFiltro(e.target.value as typeof estadoFiltro)}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-sm"
            >
              <option value="todas">Todas</option>
              <option value="pendientes">Pendientes</option>
              <option value="confirmadas">Confirmadas</option>
              <option value="disconformidad">Disconformidad</option>
              <option value="resueltas">Resueltas</option>
            </select>
          </div>
        </div>
      </div>

      {/* Lista */}
      {loading ? (
        <div className="text-center py-12">
          <RefreshCw className="w-8 h-8 animate-spin mx-auto text-gray-400" />
          <p className="mt-4 text-gray-500">Cargando rendiciones...</p>
        </div>
      ) : resumenesFiltrados.length === 0 ? (
        <div className="text-center py-12 bg-white dark:bg-gray-800 rounded-lg shadow-sm">
          <Banknote className="w-12 h-12 text-gray-300 mx-auto" />
          <p className="mt-4 text-gray-500">No hay rendiciones en el rango seleccionado</p>
        </div>
      ) : (
        <div className="space-y-3">
          {resumenesFiltrados.map(r => (
            <ResumenCard
              key={`${r.fecha}-${r.transportista_id}`}
              resumen={r}
              onCerrar={setCerrarResumen}
              onResolver={setResolverResumen}
            />
          ))}
        </div>
      )}

      {/* Modales */}
      {cerrarResumen && (
        <Suspense fallback={null}>
          <ModalCerrarRendicion
            fecha={cerrarResumen.fecha}
            transportistaNombre={cerrarResumen.transportista_nombre}
            totalCobrado={cerrarResumen.total_general}
            totalEntregado={cerrarResumen.total_entregado}
            observacionesPrevias={cerrarResumen.observaciones}
            onConfirmar={handleCerrar}
            onClose={() => setCerrarResumen(null)}
            guardando={guardando}
          />
        </Suspense>
      )}

      {resolverResumen && (
        <Suspense fallback={null}>
          <ModalResolverRendicion
            fecha={resolverResumen.fecha}
            transportistaNombre={resolverResumen.transportista_nombre}
            observacionesPrevias={resolverResumen.observaciones}
            onResolver={handleResolver}
            onClose={() => setResolverResumen(null)}
            guardando={guardando}
          />
        </Suspense>
      )}
    </div>
  )
}
