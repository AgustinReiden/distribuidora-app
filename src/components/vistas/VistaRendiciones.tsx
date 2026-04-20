/**
 * Vista de rendiciones (resumen auto-calculado + control diario)
 * Muestra resumen por (día, transportista) con breakdown por forma de pago.
 * Admin/encargado puede marcar/desmarcar como controlada.
 */
import React, { useState, useEffect, useCallback, useMemo } from 'react'
import {
  Banknote,
  Calendar,
  User,
  CheckCircle,
  Clock,
  Filter,
  RefreshCw,
  ChevronDown,
  ChevronUp
} from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
import { useRendiciones, useUsuarios } from '../../hooks/supabase'
import { useNotification } from '../../contexts/NotificationContext'
import type { ResumenRendicionDiaria, PerfilDB } from '../../types'

function formatMoney(value: number | undefined | null): string {
  return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value || 0)
}

function formatFechaCorta(fechaISO: string): string {
  const [y, m, d] = fechaISO.split('-')
  return `${d}/${m}/${y}`
}

interface ResumenCardProps {
  resumen: ResumenRendicionDiaria
  onMarcar: (fecha: string, transportistaId: string) => Promise<void>
  onDesmarcar: (fecha: string, transportistaId: string) => Promise<void>
}

function ResumenCard({ resumen, onMarcar, onDesmarcar }: ResumenCardProps): React.ReactElement {
  const [expandido, setExpandido] = useState(false)
  const [accionando, setAccionando] = useState(false)

  const handleToggle = async (): Promise<void> => {
    setAccionando(true)
    try {
      if (resumen.controlada) {
        await onDesmarcar(resumen.fecha, resumen.transportista_id)
      } else {
        await onMarcar(resumen.fecha, resumen.transportista_id)
      }
    } finally {
      setAccionando(false)
    }
  }

  const formasPago = [
    { label: 'Efectivo', value: resumen.total_efectivo, color: 'text-green-700 dark:text-green-400' },
    { label: 'Transferencia', value: resumen.total_transferencia, color: 'text-blue-700 dark:text-blue-400' },
    { label: 'Cheque', value: resumen.total_cheque, color: 'text-purple-700 dark:text-purple-400' },
    { label: 'Cuenta Cte.', value: resumen.total_cuenta_corriente, color: 'text-amber-700 dark:text-amber-400' },
    { label: 'Tarjeta', value: resumen.total_tarjeta, color: 'text-indigo-700 dark:text-indigo-400' },
    { label: 'Otros', value: resumen.total_otros, color: 'text-gray-700 dark:text-gray-400' }
  ].filter(fp => fp.value > 0)

  return (
    <div className={`bg-white dark:bg-gray-800 rounded-xl shadow-sm border-l-4 ${
      resumen.controlada ? 'border-green-500' : 'border-gray-300'
    } overflow-hidden`}>
      <div className="p-4">
        <div className="flex items-start justify-between flex-wrap gap-3">
          <div className="flex-1 min-w-[200px]">
            <div className="flex items-center gap-2 mb-1">
              <User className="w-4 h-4 text-gray-500" />
              <span className="font-semibold text-gray-800 dark:text-white">
                {resumen.transportista_nombre}
              </span>
            </div>
            <div className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-400">
              <Calendar className="w-4 h-4" />
              <span>{formatFechaCorta(resumen.fecha)}</span>
              <span className="px-2 py-0.5 rounded-full text-xs bg-gray-100 dark:bg-gray-700">
                {resumen.cantidad_pedidos} {resumen.cantidad_pedidos === 1 ? 'pedido' : 'pedidos'}
              </span>
            </div>
          </div>

          <div className="text-right">
            <p className="text-xs text-gray-500 dark:text-gray-400">Total general</p>
            <p className="text-2xl font-bold text-gray-800 dark:text-white">
              {formatMoney(resumen.total_general)}
            </p>
          </div>
        </div>

        <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 mt-4">
          {formasPago.map(fp => (
            <div key={fp.label} className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-2">
              <p className="text-xs text-gray-500 dark:text-gray-400">{fp.label}</p>
              <p className={`font-bold ${fp.color}`}>{formatMoney(fp.value)}</p>
            </div>
          ))}
        </div>

        <div className="flex items-center justify-between mt-4 pt-3 border-t border-gray-200 dark:border-gray-700 flex-wrap gap-2">
          <div className="flex items-center gap-2">
            {resumen.controlada ? (
              <>
                <CheckCircle className="w-5 h-5 text-green-500" />
                <div>
                  <p className="text-sm font-medium text-green-700 dark:text-green-400">Controlada</p>
                  {resumen.controlada_at && (
                    <p className="text-xs text-gray-500 dark:text-gray-400">
                      {new Date(resumen.controlada_at).toLocaleString('es-AR')}
                      {resumen.controlada_por_nombre && ` por ${resumen.controlada_por_nombre}`}
                    </p>
                  )}
                </div>
              </>
            ) : (
              <>
                <Clock className="w-5 h-5 text-gray-400" />
                <p className="text-sm text-gray-600 dark:text-gray-400">Pendiente de control</p>
              </>
            )}
          </div>

          <div className="flex items-center gap-2">
            <button
              onClick={() => setExpandido(!expandido)}
              className="text-sm text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 flex items-center gap-1"
            >
              {expandido ? <ChevronUp className="w-4 h-4" /> : <ChevronDown className="w-4 h-4" />}
              Detalle
            </button>

            <button
              onClick={handleToggle}
              disabled={accionando}
              className={`px-4 py-2 rounded-lg text-sm font-medium transition-colors disabled:opacity-50 ${
                resumen.controlada
                  ? 'bg-amber-100 hover:bg-amber-200 text-amber-800 dark:bg-amber-900/40 dark:text-amber-200'
                  : 'bg-green-600 hover:bg-green-700 text-white'
              }`}
            >
              {accionando
                ? '...'
                : resumen.controlada
                  ? 'Desmarcar'
                  : 'Marcar controlada'}
            </button>
          </div>
        </div>

        {expandido && (
          <div className="mt-4 pt-3 border-t border-gray-200 dark:border-gray-700 text-sm">
            <p className="text-xs text-gray-500 mb-2">Breakdown completo por forma de pago:</p>
            <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
              <div><span className="text-gray-500">Efectivo:</span> <span className="font-medium">{formatMoney(resumen.total_efectivo)}</span></div>
              <div><span className="text-gray-500">Transferencia:</span> <span className="font-medium">{formatMoney(resumen.total_transferencia)}</span></div>
              <div><span className="text-gray-500">Cheque:</span> <span className="font-medium">{formatMoney(resumen.total_cheque)}</span></div>
              <div><span className="text-gray-500">Cuenta Cte.:</span> <span className="font-medium">{formatMoney(resumen.total_cuenta_corriente)}</span></div>
              <div><span className="text-gray-500">Tarjeta:</span> <span className="font-medium">{formatMoney(resumen.total_tarjeta)}</span></div>
              <div><span className="text-gray-500">Otros:</span> <span className="font-medium">{formatMoney(resumen.total_otros)}</span></div>
            </div>
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
    marcarControlada,
    desmarcarControlada
  } = useRendiciones()
  const { transportistas } = useUsuarios()

  const hoy = fechaLocalISO()
  const haceUnaSemana = useMemo(() => {
    const d = new Date()
    d.setDate(d.getDate() - 7)
    return d.toISOString().split('T')[0]
  }, [])

  const [fechaDesde, setFechaDesde] = useState<string>(haceUnaSemana)
  const [fechaHasta, setFechaHasta] = useState<string>(hoy)
  const [transportistaFiltro, setTransportistaFiltro] = useState<string>('')
  const [estadoFiltro, setEstadoFiltro] = useState<'todas' | 'controladas' | 'pendientes'>('todas')

  const cargar = useCallback(async (): Promise<void> => {
    await fetchResumen(fechaDesde, fechaHasta, transportistaFiltro || null)
  }, [fechaDesde, fechaHasta, transportistaFiltro, fetchResumen])

  useEffect(() => {
    cargar()
  }, [cargar])

  const handleMarcar = async (fecha: string, transportistaId: string): Promise<void> => {
    try {
      await marcarControlada(fecha, transportistaId)
      notify.success('Rendición marcada como controlada')
    } catch {
      // Error ya notificado desde el hook
    }
  }

  const handleDesmarcar = async (fecha: string, transportistaId: string): Promise<void> => {
    try {
      await desmarcarControlada(fecha, transportistaId)
      notify.success('Control anulado')
    } catch {
      // Error ya notificado
    }
  }

  const resumenesFiltrados = useMemo(() => {
    if (estadoFiltro === 'controladas') return resumenes.filter(r => r.controlada)
    if (estadoFiltro === 'pendientes') return resumenes.filter(r => !r.controlada)
    return resumenes
  }, [resumenes, estadoFiltro])

  const stats = useMemo(() => {
    return {
      total: resumenes.length,
      controladas: resumenes.filter(r => r.controlada).length,
      pendientes: resumenes.filter(r => !r.controlada).length,
      totalGeneral: resumenes.reduce((sum, r) => sum + r.total_general, 0),
      totalEfectivo: resumenes.reduce((sum, r) => sum + r.total_efectivo, 0)
    }
  }, [resumenes])

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
            Resumen auto-calculado de pedidos entregados por transportista y día
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
      <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Total</p>
          <p className="text-2xl font-bold">{stats.total}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Controladas</p>
          <p className="text-2xl font-bold text-green-600">{stats.controladas}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Pendientes</p>
          <p className="text-2xl font-bold text-amber-600">{stats.pendientes}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Total general</p>
          <p className="text-lg font-bold">{formatMoney(stats.totalGeneral)}</p>
        </div>
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 shadow-sm">
          <p className="text-xs text-gray-500">Total efectivo</p>
          <p className="text-lg font-bold text-green-600">{formatMoney(stats.totalEfectivo)}</p>
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
              onChange={(e) => setEstadoFiltro(e.target.value as 'todas' | 'controladas' | 'pendientes')}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-sm"
            >
              <option value="todas">Todas</option>
              <option value="controladas">Controladas</option>
              <option value="pendientes">Pendientes</option>
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
              onMarcar={handleMarcar}
              onDesmarcar={handleDesmarcar}
            />
          ))}
        </div>
      )}
    </div>
  )
}
