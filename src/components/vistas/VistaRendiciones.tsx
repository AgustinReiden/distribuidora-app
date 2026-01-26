/**
 * Vista de rendiciones para admin
 * Permite ver, aprobar y rechazar rendiciones de transportistas
 */
import React, { useState, useEffect, useCallback } from 'react'
import {
  Banknote,
  Calendar,
  User,
  CheckCircle,
  XCircle,
  Clock,
  AlertTriangle,
  ChevronDown,
  ChevronUp,
  Filter,
  RefreshCw,
  Eye,
  Plus,
  X
} from 'lucide-react'
import { useRendiciones, useUsuarios, useRecorridos } from '../../hooks/supabase'
import { useNotification } from '../../contexts/NotificationContext'
import type { RendicionDBExtended, EstadoRendicion, PerfilDB } from '../../types'

interface RendicionCardProps {
  rendicion: RendicionDBExtended;
  onAprobar: (id: string) => void;
  onRechazar: (id: string, observaciones: string) => void;
  onObservar: (id: string, observaciones: string) => void;
  onVerDetalle: (rendicion: RendicionDBExtended) => void;
}

const ESTADO_CONFIG: Record<EstadoRendicion, { label: string; color: string; icon: React.ElementType }> = {
  pendiente: { label: 'Pendiente', color: 'gray', icon: Clock },
  presentada: { label: 'Presentada', color: 'blue', icon: Eye },
  aprobada: { label: 'Aprobada', color: 'green', icon: CheckCircle },
  rechazada: { label: 'Rechazada', color: 'red', icon: XCircle },
  con_observaciones: { label: 'Con Observaciones', color: 'amber', icon: AlertTriangle }
}

function RendicionCard({ rendicion, onAprobar, onRechazar, onObservar, onVerDetalle }: RendicionCardProps) {
  const [expandido, setExpandido] = useState(false)
  const [observaciones, setObservaciones] = useState('')
  const [accionando, setAccionando] = useState(false)

  const estadoConfig = ESTADO_CONFIG[rendicion.estado]
  const Icon = estadoConfig.icon

  const formatMoney = (value: number | undefined): string => {
    return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value || 0)
  }

  const handleAccion = async (accion: 'aprobar' | 'rechazar' | 'observar') => {
    if (accion !== 'aprobar' && !observaciones.trim()) {
      return
    }
    setAccionando(true)
    try {
      if (accion === 'aprobar') {
        await onAprobar(rendicion.id)
      } else if (accion === 'rechazar') {
        await onRechazar(rendicion.id, observaciones)
      } else {
        await onObservar(rendicion.id, observaciones)
      }
      setObservaciones('')
    } finally {
      setAccionando(false)
    }
  }

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg border dark:border-gray-700 overflow-hidden">
      {/* Header */}
      <div
        className="p-4 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-750"
        onClick={() => setExpandido(!expandido)}
      >
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className={`p-2 rounded-lg bg-${estadoConfig.color}-100 dark:bg-${estadoConfig.color}-900/30`}>
              <Icon className={`w-5 h-5 text-${estadoConfig.color}-600`} />
            </div>
            <div>
              <div className="flex items-center gap-2">
                <User className="w-4 h-4 text-gray-400" />
                <span className="font-medium text-gray-800 dark:text-white">
                  {rendicion.transportista?.nombre || 'Transportista'}
                </span>
              </div>
              <div className="flex items-center gap-2 text-sm text-gray-500">
                <Calendar className="w-3 h-3" />
                <span>{new Date(rendicion.fecha).toLocaleDateString('es-AR')}</span>
                <span className={`px-2 py-0.5 rounded-full text-xs bg-${estadoConfig.color}-100 text-${estadoConfig.color}-700 dark:bg-${estadoConfig.color}-900/30 dark:text-${estadoConfig.color}-400`}>
                  {estadoConfig.label}
                </span>
              </div>
            </div>
          </div>

          <div className="flex items-center gap-4">
            <div className="text-right">
              <p className="text-xs text-gray-500">Efectivo esperado</p>
              <p className="font-bold text-green-600">{formatMoney(rendicion.total_efectivo_esperado)}</p>
            </div>
            <div className="text-right">
              <p className="text-xs text-gray-500">Rendido</p>
              <p className="font-bold text-blue-600">{formatMoney(rendicion.monto_rendido)}</p>
            </div>
            <div className="text-right">
              <p className="text-xs text-gray-500">Diferencia</p>
              <p className={`font-bold ${
                rendicion.diferencia === 0 ? 'text-gray-500' :
                rendicion.diferencia > 0 ? 'text-blue-600' : 'text-red-600'
              }`}>
                {formatMoney(rendicion.diferencia)}
              </p>
            </div>
            {expandido ? <ChevronUp className="w-5 h-5 text-gray-400" /> : <ChevronDown className="w-5 h-5 text-gray-400" />}
          </div>
        </div>
      </div>

      {/* Contenido expandido */}
      {expandido && (
        <div className="border-t dark:border-gray-700 p-4 space-y-4">
          {/* Resumen del recorrido */}
          <div className="grid grid-cols-4 gap-3">
            <div className="p-2 bg-gray-50 dark:bg-gray-900 rounded-lg text-center">
              <p className="text-xs text-gray-500">Pedidos</p>
              <p className="font-bold text-gray-800 dark:text-white">
                {rendicion.pedidos_entregados || 0}/{rendicion.total_pedidos || 0}
              </p>
            </div>
            <div className="p-2 bg-gray-50 dark:bg-gray-900 rounded-lg text-center">
              <p className="text-xs text-gray-500">Facturado</p>
              <p className="font-bold text-gray-800 dark:text-white">
                {formatMoney(rendicion.total_facturado)}
              </p>
            </div>
            <div className="p-2 bg-gray-50 dark:bg-gray-900 rounded-lg text-center">
              <p className="text-xs text-gray-500">Otros medios</p>
              <p className="font-bold text-purple-600">
                {formatMoney(rendicion.total_otros_medios)}
              </p>
            </div>
            <div className="p-2 bg-gray-50 dark:bg-gray-900 rounded-lg text-center">
              <p className="text-xs text-gray-500">Ajustes</p>
              <p className="font-bold text-gray-800 dark:text-white">
                {rendicion.total_ajustes || 0}
              </p>
            </div>
          </div>

          {/* Justificacion */}
          {rendicion.justificacion_transportista && (
            <div className="p-3 bg-blue-50 dark:bg-blue-900/20 rounded-lg">
              <p className="text-xs text-blue-600 dark:text-blue-400 mb-1">Justificacion del transportista:</p>
              <p className="text-sm text-blue-800 dark:text-blue-300">{rendicion.justificacion_transportista}</p>
            </div>
          )}

          {/* Observaciones admin */}
          {rendicion.observaciones_admin && (
            <div className="p-3 bg-amber-50 dark:bg-amber-900/20 rounded-lg">
              <p className="text-xs text-amber-600 dark:text-amber-400 mb-1">Observaciones del admin:</p>
              <p className="text-sm text-amber-800 dark:text-amber-300">{rendicion.observaciones_admin}</p>
            </div>
          )}

          {/* Acciones (solo si esta presentada) */}
          {rendicion.estado === 'presentada' && (
            <div className="space-y-3 pt-2 border-t dark:border-gray-700">
              <textarea
                value={observaciones}
                onChange={(e) => setObservaciones(e.target.value)}
                placeholder="Observaciones (requerido para rechazar u observar)..."
                rows={2}
                className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white text-sm"
              />
              <div className="flex gap-2">
                <button
                  onClick={() => handleAccion('aprobar')}
                  disabled={accionando}
                  className="flex-1 px-3 py-2 bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg text-sm flex items-center justify-center gap-1"
                >
                  <CheckCircle className="w-4 h-4" />
                  Aprobar
                </button>
                <button
                  onClick={() => handleAccion('observar')}
                  disabled={accionando || !observaciones.trim()}
                  className="flex-1 px-3 py-2 bg-amber-600 hover:bg-amber-700 disabled:bg-amber-400 text-white rounded-lg text-sm flex items-center justify-center gap-1"
                >
                  <AlertTriangle className="w-4 h-4" />
                  Observar
                </button>
                <button
                  onClick={() => handleAccion('rechazar')}
                  disabled={accionando || !observaciones.trim()}
                  className="flex-1 px-3 py-2 bg-red-600 hover:bg-red-700 disabled:bg-red-400 text-white rounded-lg text-sm flex items-center justify-center gap-1"
                >
                  <XCircle className="w-4 h-4" />
                  Rechazar
                </button>
              </div>
            </div>
          )}

          {/* Boton ver detalle */}
          <button
            onClick={() => onVerDetalle(rendicion)}
            className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 text-sm flex items-center justify-center gap-1"
          >
            <Eye className="w-4 h-4" />
            Ver detalle completo
          </button>
        </div>
      )}
    </div>
  )
}

// Modal para crear rendicion
interface ModalCrearRendicionProps {
  transportistas: PerfilDB[];
  fecha: string;
  onCrear: (transportistaId: string) => Promise<void>;
  onClose: () => void;
  creando: boolean;
}

function ModalCrearRendicion({ transportistas, fecha, onCrear, onClose, creando }: ModalCrearRendicionProps) {
  const [transportistaId, setTransportistaId] = useState<string>('')

  const handleCrear = async () => {
    if (!transportistaId) return
    await onCrear(transportistaId)
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-md">
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700">
          <div className="flex items-center gap-2">
            <Plus className="w-5 h-5 text-green-600" />
            <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Crear Rendicion</h2>
          </div>
          <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-5 h-5" />
          </button>
        </div>

        <div className="p-4 space-y-4">
          <div>
            <p className="text-sm text-gray-500 mb-2">
              Crear rendicion para la fecha: <span className="font-medium">{new Date(fecha + 'T12:00:00').toLocaleDateString('es-AR')}</span>
            </p>
          </div>

          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Transportista
            </label>
            <select
              value={transportistaId}
              onChange={(e) => setTransportistaId(e.target.value)}
              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white"
            >
              <option value="">Seleccionar transportista...</option>
              {transportistas.map(t => (
                <option key={t.id} value={t.id}>{t.nombre}</option>
              ))}
            </select>
          </div>

          <p className="text-xs text-gray-500">
            Se creara una rendicion para los pedidos entregados por este transportista en la fecha seleccionada.
          </p>
        </div>

        <div className="flex gap-3 p-4 border-t dark:border-gray-700">
          <button
            onClick={onClose}
            className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700"
          >
            Cancelar
          </button>
          <button
            onClick={handleCrear}
            disabled={!transportistaId || creando}
            className="flex-1 px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg flex items-center justify-center gap-2"
          >
            {creando ? (
              <>
                <RefreshCw className="w-4 h-4 animate-spin" />
                Creando...
              </>
            ) : (
              <>
                <Plus className="w-4 h-4" />
                Crear Rendicion
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  )
}

export default function VistaRendiciones(): React.ReactElement {
  const notify = useNotification()
  const {
    rendiciones,
    loading,
    fetchRendicionesPorFecha,
    revisarRendicion,
    crearRendicion,
    getEstadisticas
  } = useRendiciones()
  const { transportistas } = useUsuarios()
  const { fetchRecorridosPorFecha, recorridos } = useRecorridos()

  const [fechaFiltro, setFechaFiltro] = useState<string>(new Date().toISOString().split('T')[0])
  const [estadoFiltro, setEstadoFiltro] = useState<EstadoRendicion | 'todas'>('todas')
  const [modalCrearOpen, setModalCrearOpen] = useState(false)
  const [creandoRendicion, setCreandoRendicion] = useState(false)
  const [estadisticas, setEstadisticas] = useState<{
    total: number;
    pendientes: number;
    aprobadas: number;
    rechazadas: number;
    total_rendido: number;
    total_diferencias: number;
  } | null>(null)

  const cargarDatos = useCallback(async () => {
    await Promise.all([
      fetchRendicionesPorFecha(fechaFiltro),
      fetchRecorridosPorFecha(fechaFiltro)
    ])
  }, [fechaFiltro, fetchRendicionesPorFecha, fetchRecorridosPorFecha])

  const handleCrearRendicion = async (transportistaId: string) => {
    setCreandoRendicion(true)
    try {
      // Buscar recorrido del transportista en esta fecha
      const recorrido = recorridos.find(r => r.transportista_id === transportistaId)

      if (!recorrido) {
        notify.error('No hay recorrido para este transportista en la fecha seleccionada')
        return
      }

      // Verificar si ya existe una rendicion para este recorrido
      const yaExiste = rendiciones.some(r => r.recorrido_id === recorrido.id)
      if (yaExiste) {
        notify.warning('Ya existe una rendicion para este transportista en esta fecha')
        return
      }

      await crearRendicion(String(recorrido.id), transportistaId)
      notify.success('Rendicion creada correctamente')
      setModalCrearOpen(false)
      await cargarDatos()
    } catch (error) {
      notify.error('Error al crear la rendicion: ' + (error as Error).message)
    } finally {
      setCreandoRendicion(false)
    }
  }

  // Calcular estadísticas cuando cambian los datos
  useEffect(() => {
    const calcular = async () => {
      const stats = await getEstadisticas()
      setEstadisticas(stats)
    }
    calcular()
  }, [rendiciones, getEstadisticas])

  useEffect(() => {
    cargarDatos()
  }, [cargarDatos])

  const handleAprobar = async (rendicionId: string) => {
    await revisarRendicion({ rendicionId, accion: 'aprobar' })
    await cargarDatos()
  }

  const handleRechazar = async (rendicionId: string, observaciones: string) => {
    await revisarRendicion({ rendicionId, accion: 'rechazar', observaciones })
    await cargarDatos()
  }

  const handleObservar = async (rendicionId: string, observaciones: string) => {
    await revisarRendicion({ rendicionId, accion: 'observar', observaciones })
    await cargarDatos()
  }

  const rendicionesFiltradas = rendiciones.filter(r =>
    estadoFiltro === 'todas' || r.estado === estadoFiltro
  )

  const formatMoney = (value: number | undefined): string => {
    return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value || 0)
  }

  return (
    <div className="p-4 md:p-6 space-y-6">
      {/* Header */}
      <div className="flex flex-col md:flex-row md:items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white flex items-center gap-2">
            <Banknote className="w-7 h-7 text-green-600" />
            Rendiciones de Transportistas
          </h1>
          <p className="text-gray-500 mt-1">Revisa y aprueba las rendiciones diarias</p>
        </div>
        <div className="flex gap-2">
          <button
            onClick={() => setModalCrearOpen(true)}
            className="px-4 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg flex items-center gap-2"
          >
            <Plus className="w-4 h-4" />
            Crear Rendicion
          </button>
          <button
            onClick={cargarDatos}
            disabled={loading}
            className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white rounded-lg flex items-center gap-2"
          >
            <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
            Actualizar
          </button>
        </div>
      </div>

      {/* Filtros */}
      <div className="flex flex-wrap gap-4 items-center">
        <div className="flex items-center gap-2">
          <Calendar className="w-5 h-5 text-gray-400" />
          <input
            type="date"
            value={fechaFiltro}
            onChange={(e) => setFechaFiltro(e.target.value)}
            className="px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white"
          />
        </div>
        <div className="flex items-center gap-2">
          <Filter className="w-5 h-5 text-gray-400" />
          <select
            value={estadoFiltro}
            onChange={(e) => setEstadoFiltro(e.target.value as EstadoRendicion | 'todas')}
            className="px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white"
          >
            <option value="todas">Todos los estados</option>
            <option value="pendiente">Pendientes</option>
            <option value="presentada">Presentadas</option>
            <option value="aprobada">Aprobadas</option>
            <option value="rechazada">Rechazadas</option>
            <option value="con_observaciones">Con observaciones</option>
          </select>
        </div>
      </div>

      {/* Estadisticas */}
      {estadisticas && (
        <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Total</p>
            <p className="text-2xl font-bold text-gray-800 dark:text-white">{estadisticas.total}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Pendientes</p>
            <p className="text-2xl font-bold text-blue-600">{estadisticas.pendientes}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Aprobadas</p>
            <p className="text-2xl font-bold text-green-600">{estadisticas.aprobadas}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Total Rendido</p>
            <p className="text-xl font-bold text-green-600">{formatMoney(estadisticas.total_rendido)}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Diferencias</p>
            <p className={`text-xl font-bold ${estadisticas.total_diferencias >= 0 ? 'text-blue-600' : 'text-red-600'}`}>
              {formatMoney(estadisticas.total_diferencias)}
            </p>
          </div>
        </div>
      )}

      {/* Lista de rendiciones */}
      {loading ? (
        <div className="flex items-center justify-center py-12">
          <RefreshCw className="w-8 h-8 animate-spin text-blue-600" />
        </div>
      ) : rendicionesFiltradas.length === 0 ? (
        <div className="text-center py-12">
          <Banknote className="w-12 h-12 mx-auto text-gray-300 dark:text-gray-600" />
          <p className="mt-4 text-gray-500">No hay rendiciones para esta fecha</p>
        </div>
      ) : (
        <div className="space-y-4">
          {rendicionesFiltradas.map(rendicion => (
            <RendicionCard
              key={rendicion.id}
              rendicion={rendicion}
              onAprobar={handleAprobar}
              onRechazar={handleRechazar}
              onObservar={handleObservar}
              onVerDetalle={() => {}}
            />
          ))}
        </div>
      )}

      {/* Modal crear rendicion */}
      {modalCrearOpen && (
        <ModalCrearRendicion
          transportistas={transportistas}
          fecha={fechaFiltro}
          onCrear={handleCrearRendicion}
          onClose={() => setModalCrearOpen(false)}
          creando={creandoRendicion}
        />
      )}
    </div>
  )
}
