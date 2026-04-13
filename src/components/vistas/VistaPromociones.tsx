/**
 * VistaPromociones
 *
 * Vista admin para gestionar promociones (bonificacion).
 * Muestra lista de promos con productos, reglas, contador de usos y ajuste de stock.
 */
import React, { useState } from 'react'
import { Plus, Edit2, Trash2, ToggleLeft, ToggleRight, Package, Gift, AlertTriangle, Check } from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
import type { ProductoDB } from '../../types'
import type { PromocionConDetalles } from '../../hooks/queries/usePromocionesQuery'

export interface VistaPromocionesProps {
  promociones: PromocionConDetalles[]
  productos: ProductoDB[]
  loading: boolean
  onNuevaPromocion: () => void
  onEditarPromocion: (promo: PromocionConDetalles) => void
  onEliminarPromocion: (id: string) => void
  onToggleActivo: (promo: PromocionConDetalles) => void
  onAjustarStock: (promo: PromocionConDetalles, observaciones: string) => void
}

export default function VistaPromociones({
  promociones,
  productos,
  loading,
  onNuevaPromocion,
  onEditarPromocion,
  onEliminarPromocion,
  onToggleActivo,
  onAjustarStock,
}: VistaPromocionesProps): React.ReactElement {
  const [ajustandoId, setAjustandoId] = useState<string | null>(null)
  const [observaciones, setObservaciones] = useState('')

  const getProductoNombre = (productoId: string): string => {
    const prod = productos.find(p => String(p.id) === String(productoId))
    return prod?.nombre || `Producto #${productoId}`
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
      <div className="flex justify-between items-center">
        <div>
          <h1 className="text-2xl font-bold dark:text-white">Promociones</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
            Gestiona promociones de bonificacion para productos
          </p>
        </div>
        <button
          onClick={onNuevaPromocion}
          className="flex items-center gap-2 px-4 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700 transition-colors"
        >
          <Plus className="w-4 h-4" />
          Nueva Promocion
        </button>
      </div>

      {/* Lista de promos */}
      {promociones.length === 0 ? (
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
          {promociones.map(promo => {
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
                      {promo.usos_pendientes > 0 && (
                        <span className="inline-flex items-center gap-1 text-xs px-2 py-0.5 bg-orange-100 text-orange-700 rounded-full font-medium">
                          <AlertTriangle className="w-3 h-3" />
                          {promo.usos_pendientes} uso{promo.usos_pendientes !== 1 ? 's' : ''} pendiente{promo.usos_pendientes !== 1 ? 's' : ''}
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

                {/* Contador de usos */}
                <div className="mb-3 px-3 py-2 bg-blue-50 dark:bg-blue-900/20 border border-blue-200 dark:border-blue-800 rounded-lg flex items-center justify-between">
                  <p className="text-sm text-blue-700 dark:text-blue-300">
                    <span className="font-medium">Unidades regaladas:</span> {promo.usos_pendientes} pendientes de ajuste
                  </p>
                  {promo.usos_pendientes > 0 && (
                    <span className="text-xs bg-orange-100 dark:bg-orange-900/30 text-orange-700 dark:text-orange-300 px-2 py-0.5 rounded-full font-medium">
                      Ajustar stock
                    </span>
                  )}
                </div>

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

                {/* Ajuste de stock */}
                {promo.usos_pendientes > 0 && (
                  <div className="mt-3 pt-3 border-t dark:border-gray-700">
                    {ajustandoId === promo.id ? (
                      <div className="flex items-center gap-2">
                        <input
                          type="text"
                          placeholder="Observaciones (opcional)"
                          value={observaciones}
                          onChange={e => setObservaciones(e.target.value)}
                          className="flex-1 px-3 py-1.5 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                        />
                        <button
                          onClick={() => {
                            onAjustarStock(promo, observaciones)
                            setAjustandoId(null)
                            setObservaciones('')
                          }}
                          className="flex items-center gap-1 px-3 py-1.5 bg-green-600 text-white text-sm rounded-lg hover:bg-green-700"
                        >
                          <Check className="w-4 h-4" />
                          Confirmar
                        </button>
                        <button
                          onClick={() => { setAjustandoId(null); setObservaciones('') }}
                          className="px-3 py-1.5 text-sm text-gray-500 hover:text-gray-700 dark:text-gray-400"
                        >
                          Cancelar
                        </button>
                      </div>
                    ) : (
                      <button
                        onClick={() => setAjustandoId(promo.id)}
                        className="flex items-center gap-2 px-3 py-1.5 bg-orange-100 text-orange-700 text-sm rounded-lg hover:bg-orange-200 transition-colors"
                      >
                        <Check className="w-4 h-4" />
                        Marcar stock ajustado ({promo.usos_pendientes} uso{promo.usos_pendientes !== 1 ? 's' : ''})
                      </button>
                    )}
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </div>
  )
}
