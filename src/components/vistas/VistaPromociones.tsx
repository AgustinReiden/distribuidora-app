/**
 * VistaPromociones
 *
 * Vista admin para gestionar promociones (bonificacion).
 * Todas las promos descuentan stock automaticamente (unidad entera en
 * cada venta o fraccion al cerrar bloque), por eso no hay ajuste manual.
 */
import React, { useMemo, useState } from 'react'
import { Plus, Edit2, Trash2, ToggleLeft, ToggleRight, Package, Gift, Layers, Ban, Zap, History, Filter } from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
import type { PromocionConDetalles } from '../../hooks/queries/usePromocionesQuery'

type FiltroEstado = 'vigentes' | 'todas' | 'inactivas'

export interface VistaPromocionesProps {
  promociones: PromocionConDetalles[]
  loading: boolean
  onNuevaPromocion: () => void
  onEditarPromocion: (promo: PromocionConDetalles) => void
  onEliminarPromocion: (id: string) => void
  onToggleActivo: (promo: PromocionConDetalles) => void
  /** Map producto_id -> nombre (para render de chips de productos asignados) */
  productoNombres: Map<string, string>
  /** Map promo_id -> total unidades regaladas historicas (suma de pedido_items.cantidad con es_bonificacion=true) */
  unidadesEntregadas?: Map<string, number>
}

export default function VistaPromociones({
  promociones,
  loading,
  onNuevaPromocion,
  onEditarPromocion,
  onEliminarPromocion,
  onToggleActivo,
  productoNombres,
  unidadesEntregadas,
}: VistaPromocionesProps): React.ReactElement {
  const [filtro, setFiltro] = useState<FiltroEstado>('vigentes')
  const [mostrarHistorico, setMostrarHistorico] = useState(false)

  const getProductoNombre = (productoId: string): string => {
    return productoNombres.get(String(productoId)) || `Producto #${productoId}`
  }

  const getReglaValor = (promo: PromocionConDetalles, clave: string): number | null => {
    const regla = promo.reglas.find(r => r.clave === clave)
    return regla ? Number(regla.valor) : null
  }

  const formatFecha = (fecha: string): string => {
    return new Date(fecha + 'T12:00:00').toLocaleDateString('es-AR', { day: '2-digit', month: 'short', year: 'numeric' })
  }

  const isPromoVigente = (promo: PromocionConDetalles): boolean => {
    if (!promo.activo) return false
    const hoy = fechaLocalISO()
    if (promo.fecha_inicio > hoy) return false
    if (promo.fecha_fin && promo.fecha_fin < hoy) return false
    return true
  }

  const promosFiltradas = useMemo(() => {
    if (filtro === 'todas') return promociones
    if (filtro === 'inactivas') return promociones.filter(p => !isPromoVigente(p))
    return promociones.filter(p => isPromoVigente(p))
  }, [promociones, filtro])  

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <div className="w-8 h-8 border-4 border-purple-600 border-t-transparent rounded-full animate-spin" />
      </div>
    )
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex justify-between items-center flex-wrap gap-3">
        <div>
          <h1 className="text-2xl font-bold dark:text-white">Promociones</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
            Gestiona promociones de bonificación para productos
          </p>
        </div>
        <div className="flex items-center gap-2">
          <button
            onClick={() => setMostrarHistorico(v => !v)}
            className={`flex items-center gap-2 px-3 py-2 rounded-lg border text-sm transition-colors ${
              mostrarHistorico
                ? 'bg-purple-50 dark:bg-purple-900/20 border-purple-400 text-purple-700 dark:text-purple-300'
                : 'bg-white dark:bg-gray-800 border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-700'
            }`}
            title="Mostrar unidades regaladas históricas por promo"
          >
            <History className="w-4 h-4" />
            {mostrarHistorico ? 'Ocultar' : 'Ver'} histórico
          </button>
          <button
            onClick={onNuevaPromocion}
            className="flex items-center gap-2 px-4 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700 transition-colors"
          >
            <Plus className="w-4 h-4" />
            Nueva Promoción
          </button>
        </div>
      </div>

      {/* Filtros de estado */}
      <div className="flex items-center gap-2 flex-wrap">
        <Filter className="w-4 h-4 text-gray-400" />
        {(['vigentes', 'todas', 'inactivas'] as FiltroEstado[]).map(f => (
          <button
            key={f}
            onClick={() => setFiltro(f)}
            className={`px-3 py-1 rounded-full text-sm capitalize transition-colors ${
              filtro === f
                ? 'bg-purple-600 text-white'
                : 'bg-white dark:bg-gray-800 text-gray-700 dark:text-gray-300 border border-gray-300 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700'
            }`}
          >
            {f === 'vigentes' ? 'Vigentes' : f === 'todas' ? 'Todas' : 'Inactivas / vencidas'}
          </button>
        ))}
        <span className="text-xs text-gray-500 ml-auto">{promosFiltradas.length} / {promociones.length}</span>
      </div>

      {/* Lista de promos */}
      {promosFiltradas.length === 0 ? (
        <div className="text-center py-16 bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700">
          <Gift className="w-12 h-12 text-gray-300 mx-auto mb-4" />
          <h3 className="text-lg font-medium text-gray-500 dark:text-gray-400">Sin promociones</h3>
          <p className="text-sm text-gray-400 dark:text-gray-500 mt-1">
            Crea una promocion para ofrecer bonificaciones a tus clientes
          </p>
          <button
            onClick={onNuevaPromocion}
            className="mt-4 px-4 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700 text-sm"
          >
            Crear primera promocion
          </button>
        </div>
      ) : (
        <div className="grid gap-4">
          {promosFiltradas.map(promo => {
            const cantCompra = getReglaValor(promo, 'cantidad_compra')
            const cantBonif = getReglaValor(promo, 'cantidad_bonificacion')
            const vigente = isPromoVigente(promo)

            return (
              <div
                key={promo.id}
                className={`bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700 p-5 ${
                  !promo.activo ? 'opacity-60' : ''
                }`}
              >
                {/* Encabezado */}
                <div className="flex justify-between items-start mb-4">
                  <div className="flex-1">
                    <div className="flex items-center gap-2 flex-wrap">
                      <h3 className="text-lg font-semibold dark:text-white">{promo.nombre}</h3>
                      {vigente ? (
                        <span className="text-xs px-2 py-0.5 bg-green-100 text-green-700 rounded-full font-medium">
                          Vigente
                        </span>
                      ) : !promo.activo ? (
                        <span className="text-xs px-2 py-0.5 bg-gray-200 dark:bg-gray-600 text-gray-600 dark:text-gray-300 rounded-full">
                          Inactiva
                        </span>
                      ) : (
                        <span className="text-xs px-2 py-0.5 bg-yellow-100 text-yellow-700 rounded-full">
                          Fuera de rango
                        </span>
                      )}
                      {promo.limite_usos && (
                        <span className={`text-xs px-2 py-0.5 rounded-full font-medium ${
                          promo.usos_pendientes >= promo.limite_usos
                            ? 'bg-red-100 text-red-700'
                            : 'bg-blue-100 text-blue-700'
                        }`}>
                          {promo.usos_pendientes}/{promo.limite_usos} usos
                        </span>
                      )}
                      {promo.modo_exclusion === 'excluyente' ? (
                        <span className="inline-flex items-center gap-1 text-xs px-2 py-0.5 bg-rose-100 text-rose-700 dark:bg-rose-900/30 dark:text-rose-300 rounded-full font-medium">
                          <Ban className="w-3 h-3" />
                          Excluyente
                        </span>
                      ) : (
                        <span className="inline-flex items-center gap-1 text-xs px-2 py-0.5 bg-purple-100 text-purple-700 dark:bg-purple-900/30 dark:text-purple-300 rounded-full font-medium">
                          <Layers className="w-3 h-3" />
                          Acumulable
                        </span>
                      )}
                      {promo.ajuste_automatico && (
                        <span className="inline-flex items-center gap-1 text-xs px-2 py-0.5 bg-blue-100 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300 rounded-full font-medium">
                          <Zap className="w-3 h-3" />
                          Auto-ajuste
                        </span>
                      )}
                      {mostrarHistorico && unidadesEntregadas && (
                        <span className="inline-flex items-center gap-1 text-xs px-2 py-0.5 bg-emerald-100 text-emerald-700 dark:bg-emerald-900/30 dark:text-emerald-300 rounded-full font-medium">
                          <History className="w-3 h-3" />
                          {unidadesEntregadas.get(String(promo.id)) ?? 0} unidades regaladas
                        </span>
                      )}
                    </div>
                    <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
                      {formatFecha(promo.fecha_inicio)}
                      {promo.fecha_fin ? ` — ${formatFecha(promo.fecha_fin)}` : ' — Sin fecha fin'}
                    </p>
                  </div>
                  <div className="flex items-center gap-1">
                    <button
                      onClick={() => onToggleActivo(promo)}
                      className="p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
                      title={promo.activo ? 'Desactivar' : 'Activar'}
                    >
                      {promo.activo ? (
                        <ToggleRight className="w-5 h-5 text-green-600" />
                      ) : (
                        <ToggleLeft className="w-5 h-5 text-gray-400" />
                      )}
                    </button>
                    <button
                      onClick={() => onEditarPromocion(promo)}
                      className="p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
                      title="Editar"
                    >
                      <Edit2 className="w-4 h-4 text-blue-600" />
                    </button>
                    <button
                      onClick={() => onEliminarPromocion(promo.id)}
                      className="p-2 rounded-lg hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors"
                      title="Eliminar"
                    >
                      <Trash2 className="w-4 h-4 text-red-500" />
                    </button>
                  </div>
                </div>

                {/* Reglas de bonificacion */}
                {cantCompra && cantBonif && (
                  <div className="mb-3 px-3 py-2 bg-purple-50 dark:bg-purple-900/20 border border-purple-200 dark:border-purple-800 rounded-lg">
                    <p className="text-sm font-medium text-purple-700 dark:text-purple-300">
                      <Gift className="w-4 h-4 inline mr-1" />
                      Comprando {cantCompra} fardos → {cantBonif} {promo.producto_regalo_id ? getProductoNombre(String(promo.producto_regalo_id)) : 'del mismo producto'} gratis
                      <span className="text-xs text-purple-500 ml-2">(acumulable)</span>
                    </p>
                  </div>
                )}

                {/* Subunidades pendientes para el proximo bloque (solo fracción) */}
                {promo.ajuste_automatico && promo.unidades_por_bloque && promo.unidades_por_bloque > 0 && (
                  (() => {
                    const pendientes = promo.usos_pendientes ?? 0
                    const porBloque = promo.unidades_por_bloque ?? 0
                    const falta = Math.max(porBloque - pendientes, 0)
                    const progreso = porBloque > 0 ? Math.min((pendientes / porBloque) * 100, 100) : 0
                    return (
                      <div className="mb-3 px-3 py-2 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg">
                        <div className="flex items-center justify-between gap-2 text-sm text-blue-700 dark:text-blue-300 mb-1.5">
                          <span className="font-medium">
                            Subunidades pendientes para descontar stock:
                          </span>
                          <span className="font-bold tabular-nums">
                            {pendientes} / {porBloque}
                          </span>
                        </div>
                        <div className="w-full bg-blue-100 dark:bg-blue-900/40 rounded-full h-2 overflow-hidden">
                          <div
                            className="bg-blue-500 dark:bg-blue-400 h-full transition-all"
                            style={{ width: `${progreso}%` }}
                            aria-label={`${pendientes} de ${porBloque}`}
                          />
                        </div>
                        <p className="text-[11px] text-blue-600 dark:text-blue-400 mt-1">
                          {pendientes === 0
                            ? 'Bloque recién cerrado — se descontó 1 unidad del contenedor.'
                            : `Faltan ${falta} subunidad${falta === 1 ? '' : 'es'} para cerrar el próximo bloque y descontar 1 unidad del contenedor.`
                          }
                        </p>
                      </div>
                    )
                  })()
                )}

                {/* Productos */}
                <div className="mb-3">
                  <div className="flex items-center gap-1 text-sm font-medium text-gray-600 dark:text-gray-300 mb-2">
                    <Package className="w-4 h-4" />
                    <span>Productos ({promo.productos.length})</span>
                  </div>
                  <div className="flex flex-wrap gap-2">
                    {promo.productos.map(pp => (
                      <span
                        key={pp.id}
                        className="text-xs px-2.5 py-1 bg-blue-50 dark:bg-blue-900/20 text-blue-700 dark:text-blue-300 rounded-full"
                      >
                        {getProductoNombre(pp.producto_id)}
                      </span>
                    ))}
                    {promo.productos.length === 0 && (
                      <span className="text-xs text-gray-400">Sin productos asignados</span>
                    )}
                  </div>
                </div>

              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
