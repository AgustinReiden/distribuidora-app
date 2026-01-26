/**
 * Vista de salvedades para admin
 * Permite ver y resolver salvedades pendientes de items
 */
import React, { useState, useEffect, useCallback } from 'react'
import {
  AlertTriangle,
  Calendar,
  User,
  Package,
  Truck,
  CheckCircle,
  Filter,
  RefreshCw,
  ChevronDown,
  ChevronUp,
  Image
} from 'lucide-react'
import { useSalvedades } from '../../hooks/supabase'
import { MOTIVOS_SALVEDAD_LABELS, ESTADOS_RESOLUCION_LABELS } from '../../lib/schemas'
import ModalResolverSalvedad from '../modals/ModalResolverSalvedad'
import type { SalvedadItemDBExtended, MotivoSalvedad, EstadoResolucionSalvedad } from '../../types'

interface SalvedadCardProps {
  salvedad: SalvedadItemDBExtended;
  onResolver: (salvedad: SalvedadItemDBExtended) => void;
}

function SalvedadCard({ salvedad, onResolver }: SalvedadCardProps) {
  const [expandido, setExpandido] = useState(false)

  const formatMoney = (value: number): string => {
    return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value)
  }

  const formatDate = (dateStr: string | undefined): string => {
    if (!dateStr) return '-'
    return new Date(dateStr).toLocaleString('es-AR', { dateStyle: 'short', timeStyle: 'short' })
  }

  const estadoColor = salvedad.estado_resolucion === 'pendiente' ? 'amber' :
    salvedad.estado_resolucion === 'anulada' ? 'gray' : 'green'

  return (
    <div className="bg-white dark:bg-gray-800 rounded-lg border dark:border-gray-700 overflow-hidden">
      {/* Header */}
      <div
        className="p-4 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-750"
        onClick={() => setExpandido(!expandido)}
      >
        <div className="flex items-start justify-between gap-4">
          <div className="flex items-start gap-3 flex-1">
            <div className={`p-2 rounded-lg bg-${estadoColor}-100 dark:bg-${estadoColor}-900/30`}>
              <AlertTriangle className={`w-5 h-5 text-${estadoColor}-600`} />
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-center gap-2 flex-wrap">
                <Package className="w-4 h-4 text-gray-400" />
                <span className="font-medium text-gray-800 dark:text-white truncate">
                  {salvedad.producto_nombre || salvedad.producto?.nombre || 'Producto'}
                </span>
                <span className={`px-2 py-0.5 rounded-full text-xs bg-${estadoColor}-100 text-${estadoColor}-700 dark:bg-${estadoColor}-900/30 dark:text-${estadoColor}-400`}>
                  {ESTADOS_RESOLUCION_LABELS[salvedad.estado_resolucion]}
                </span>
              </div>
              <div className="flex items-center gap-4 text-sm text-gray-500 mt-1 flex-wrap">
                <span className="flex items-center gap-1">
                  <User className="w-3 h-3" />
                  {salvedad.cliente_nombre || '-'}
                </span>
                <span className="flex items-center gap-1">
                  <Truck className="w-3 h-3" />
                  {salvedad.transportista_nombre || '-'}
                </span>
                <span className="flex items-center gap-1">
                  <Calendar className="w-3 h-3" />
                  {formatDate(salvedad.created_at)}
                </span>
              </div>
              <div className="flex items-center gap-2 mt-2">
                <span className="px-2 py-0.5 bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-400 rounded text-xs">
                  {MOTIVOS_SALVEDAD_LABELS[salvedad.motivo]}
                </span>
              </div>
            </div>
          </div>

          <div className="flex items-center gap-4 flex-shrink-0">
            <div className="text-right">
              <p className="text-xs text-gray-500">Afectado</p>
              <p className="font-bold text-red-600">{salvedad.cantidad_afectada} u.</p>
            </div>
            <div className="text-right">
              <p className="text-xs text-gray-500">Monto</p>
              <p className="font-bold text-red-600">{formatMoney(salvedad.monto_afectado)}</p>
            </div>
            {expandido ? <ChevronUp className="w-5 h-5 text-gray-400" /> : <ChevronDown className="w-5 h-5 text-gray-400" />}
          </div>
        </div>
      </div>

      {/* Contenido expandido */}
      {expandido && (
        <div className="border-t dark:border-gray-700 p-4 space-y-4">
          {/* Detalle de cantidades */}
          <div className="grid grid-cols-3 gap-3">
            <div className="p-2 bg-gray-50 dark:bg-gray-900 rounded-lg text-center">
              <p className="text-xs text-gray-500">Original</p>
              <p className="font-bold text-gray-800 dark:text-white">{salvedad.cantidad_original} u.</p>
            </div>
            <div className="p-2 bg-red-50 dark:bg-red-900/20 rounded-lg text-center">
              <p className="text-xs text-red-500">Afectado</p>
              <p className="font-bold text-red-600">{salvedad.cantidad_afectada} u.</p>
            </div>
            <div className="p-2 bg-green-50 dark:bg-green-900/20 rounded-lg text-center">
              <p className="text-xs text-green-500">Entregado</p>
              <p className="font-bold text-green-600">{salvedad.cantidad_entregada} u.</p>
            </div>
          </div>

          {/* Descripcion */}
          {salvedad.descripcion && (
            <div className="p-3 bg-gray-50 dark:bg-gray-900 rounded-lg">
              <p className="text-xs text-gray-500 mb-1">Descripcion:</p>
              <p className="text-sm text-gray-700 dark:text-gray-300">{salvedad.descripcion}</p>
            </div>
          )}

          {/* Estado del stock */}
          <div className={`flex items-center gap-2 p-2 rounded-lg text-sm ${
            salvedad.stock_devuelto
              ? 'bg-green-50 dark:bg-green-900/20 text-green-700 dark:text-green-400'
              : 'bg-red-50 dark:bg-red-900/20 text-red-700 dark:text-red-400'
          }`}>
            {salvedad.stock_devuelto
              ? <CheckCircle className="w-4 h-4" />
              : <AlertTriangle className="w-4 h-4" />
            }
            <span>
              {salvedad.stock_devuelto
                ? 'Stock devuelto al inventario'
                : 'Stock NO devuelto (perdida)'}
            </span>
          </div>

          {/* Foto de evidencia */}
          {salvedad.foto_url && (
            <div>
              <p className="text-xs text-gray-500 mb-1 flex items-center gap-1">
                <Image className="w-3 h-3" />
                Evidencia:
              </p>
              <img
                src={salvedad.foto_url}
                alt="Evidencia"
                className="max-h-32 rounded-lg border dark:border-gray-700"
              />
            </div>
          )}

          {/* Notas de resolucion (si esta resuelta) */}
          {salvedad.estado_resolucion !== 'pendiente' && salvedad.resolucion_notas && (
            <div className="p-3 bg-blue-50 dark:bg-blue-900/20 rounded-lg">
              <p className="text-xs text-blue-600 dark:text-blue-400 mb-1">
                Resolucion ({formatDate(salvedad.resolucion_fecha)}):
              </p>
              <p className="text-sm text-blue-800 dark:text-blue-300">{salvedad.resolucion_notas}</p>
              {salvedad.resuelto_por_nombre && (
                <p className="text-xs text-blue-500 mt-1">Por: {salvedad.resuelto_por_nombre}</p>
              )}
            </div>
          )}

          {/* Boton resolver (solo si esta pendiente) */}
          {salvedad.estado_resolucion === 'pendiente' && (
            <button
              onClick={() => onResolver(salvedad)}
              className="w-full px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg flex items-center justify-center gap-2"
            >
              <CheckCircle className="w-4 h-4" />
              Resolver Salvedad
            </button>
          )}
        </div>
      )}
    </div>
  )
}

export default function VistaSalvedades(): React.ReactElement {
  const {
    salvedades,
    loading,
    fetchSalvedadesPendientes,
    fetchSalvedadesPorFecha,
    resolverSalvedad,
    getEstadisticas
  } = useSalvedades()

  const [filtroEstado, setFiltroEstado] = useState<'pendientes' | 'todas'>('pendientes')
  const [filtroMotivo, setFiltroMotivo] = useState<MotivoSalvedad | 'todos'>('todos')
  const [fechaDesde, setFechaDesde] = useState<string>(() => {
    const d = new Date()
    d.setDate(d.getDate() - 7)
    return d.toISOString().split('T')[0]
  })
  const [fechaHasta, setFechaHasta] = useState<string>(new Date().toISOString().split('T')[0])

  const [salvedadResolver, setSalvedadResolver] = useState<SalvedadItemDBExtended | null>(null)
  const [estadisticas, setEstadisticas] = useState<{
    total: number;
    pendientes: number;
    resueltas: number;
    monto_total_afectado: number;
    monto_pendiente: number;
  } | null>(null)

  const cargarDatos = useCallback(async () => {
    if (filtroEstado === 'pendientes') {
      await fetchSalvedadesPendientes()
    } else {
      await fetchSalvedadesPorFecha(fechaDesde, fechaHasta)
    }
  }, [filtroEstado, fechaDesde, fechaHasta, fetchSalvedadesPendientes, fetchSalvedadesPorFecha])

  // Calcular estadísticas cuando cambian los datos
  useEffect(() => {
    const calcular = async () => {
      const stats = await getEstadisticas()
      setEstadisticas(stats)
    }
    calcular()
  }, [salvedades, getEstadisticas])

  useEffect(() => {
    cargarDatos()
  }, [cargarDatos])

  const handleResolver = async (data: {
    salvedadId: string;
    estadoResolucion: Exclude<EstadoResolucionSalvedad, 'pendiente'>;
    notas: string;
  }) => {
    await resolverSalvedad(data)
    setSalvedadResolver(null)
    await cargarDatos()
    return { success: true }
  }

  const salvedadesFiltradas = salvedades.filter(s =>
    filtroMotivo === 'todos' || s.motivo === filtroMotivo
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
            <AlertTriangle className="w-7 h-7 text-amber-600" />
            Salvedades de Entregas
          </h1>
          <p className="text-gray-500 mt-1">Gestiona los items con problemas de entrega</p>
        </div>
        <button
          onClick={cargarDatos}
          disabled={loading}
          className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:bg-blue-400 text-white rounded-lg flex items-center gap-2"
        >
          <RefreshCw className={`w-4 h-4 ${loading ? 'animate-spin' : ''}`} />
          Actualizar
        </button>
      </div>

      {/* Filtros */}
      <div className="flex flex-wrap gap-4 items-center">
        <div className="flex items-center gap-2">
          <Filter className="w-5 h-5 text-gray-400" />
          <select
            value={filtroEstado}
            onChange={(e) => setFiltroEstado(e.target.value as 'pendientes' | 'todas')}
            className="px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white"
          >
            <option value="pendientes">Solo pendientes</option>
            <option value="todas">Todas</option>
          </select>
        </div>

        {filtroEstado === 'todas' && (
          <>
            <div className="flex items-center gap-2">
              <Calendar className="w-5 h-5 text-gray-400" />
              <input
                type="date"
                value={fechaDesde}
                onChange={(e) => setFechaDesde(e.target.value)}
                className="px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white"
              />
              <span className="text-gray-500">a</span>
              <input
                type="date"
                value={fechaHasta}
                onChange={(e) => setFechaHasta(e.target.value)}
                className="px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white"
              />
            </div>
          </>
        )}

        <select
          value={filtroMotivo}
          onChange={(e) => setFiltroMotivo(e.target.value as MotivoSalvedad | 'todos')}
          className="px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white"
        >
          <option value="todos">Todos los motivos</option>
          {Object.entries(MOTIVOS_SALVEDAD_LABELS).map(([value, label]) => (
            <option key={value} value={value}>{label}</option>
          ))}
        </select>
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
            <p className="text-2xl font-bold text-amber-600">{estadisticas.pendientes}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Resueltas</p>
            <p className="text-2xl font-bold text-green-600">{estadisticas.resueltas}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Monto Total</p>
            <p className="text-xl font-bold text-red-600">{formatMoney(estadisticas.monto_total_afectado)}</p>
          </div>
          <div className="bg-white dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
            <p className="text-sm text-gray-500">Monto Pendiente</p>
            <p className="text-xl font-bold text-amber-600">{formatMoney(estadisticas.monto_pendiente)}</p>
          </div>
        </div>
      )}

      {/* Lista de salvedades */}
      {loading ? (
        <div className="flex items-center justify-center py-12">
          <RefreshCw className="w-8 h-8 animate-spin text-blue-600" />
        </div>
      ) : salvedadesFiltradas.length === 0 ? (
        <div className="text-center py-12">
          <AlertTriangle className="w-12 h-12 mx-auto text-gray-300 dark:text-gray-600" />
          <p className="mt-4 text-gray-500">
            {filtroEstado === 'pendientes' ? 'No hay salvedades pendientes' : 'No hay salvedades en este periodo'}
          </p>
        </div>
      ) : (
        <div className="space-y-4">
          {salvedadesFiltradas.map(salvedad => (
            <SalvedadCard
              key={salvedad.id}
              salvedad={salvedad}
              onResolver={setSalvedadResolver}
            />
          ))}
        </div>
      )}

      {/* Modal resolver salvedad */}
      {salvedadResolver && (
        <ModalResolverSalvedad
          salvedad={salvedadResolver}
          onResolver={handleResolver}
          onClose={() => setSalvedadResolver(null)}
        />
      )}
    </div>
  )
}
