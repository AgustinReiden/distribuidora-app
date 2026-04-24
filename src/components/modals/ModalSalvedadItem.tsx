/**
 * Modal para registrar salvedad en un item de pedido
 * Usado por transportistas y admin cuando un item no puede ser entregado
 */
import React, { useState, FormEvent, ChangeEvent } from 'react'
import { X, AlertTriangle, Package, FileText, AlertCircle, Gift, Minus, Plus } from 'lucide-react'
import { MOTIVOS_SALVEDAD_LABELS } from '../../lib/schemas'
import { useSimularSalvedadPromoImpactoQuery } from '../../hooks/queries'
import type { PedidoItemDB, MotivoSalvedad, RegistrarSalvedadResult } from '../../types'

interface MotivoOption {
  value: MotivoSalvedad;
  label: string;
  descripcion: string;
  devuelveStock: boolean;
}

const MOTIVOS_SALVEDAD: MotivoOption[] = [
  {
    value: 'faltante_stock',
    label: MOTIVOS_SALVEDAD_LABELS.faltante_stock,
    descripcion: 'No habia stock suficiente al cargar',
    devuelveStock: false
  },
  {
    value: 'producto_danado',
    label: MOTIVOS_SALVEDAD_LABELS.producto_danado,
    descripcion: 'El producto se danio durante el transporte',
    devuelveStock: false
  },
  {
    value: 'cliente_rechaza',
    label: MOTIVOS_SALVEDAD_LABELS.cliente_rechaza,
    descripcion: 'El cliente no acepto el producto',
    devuelveStock: true
  },
  {
    value: 'error_pedido',
    label: MOTIVOS_SALVEDAD_LABELS.error_pedido,
    descripcion: 'Error en la toma del pedido',
    devuelveStock: true
  },
  {
    value: 'producto_vencido',
    label: MOTIVOS_SALVEDAD_LABELS.producto_vencido,
    descripcion: 'El producto esta vencido o proximo a vencer',
    devuelveStock: false
  },
  {
    value: 'diferencia_precio',
    label: MOTIVOS_SALVEDAD_LABELS.diferencia_precio,
    descripcion: 'Desacuerdo con el precio del producto',
    devuelveStock: true
  },
  {
    value: 'otro',
    label: MOTIVOS_SALVEDAD_LABELS.otro,
    descripcion: 'Otro motivo (especificar en descripcion)',
    devuelveStock: true
  }
]

export interface ModalSalvedadItemProps {
  pedidoId: string;
  item: PedidoItemDB;
  onSave: (data: {
    pedidoId: string;
    pedidoItemId: string;
    cantidadAfectada: number;
    motivo: MotivoSalvedad;
    descripcion?: string;
    fotoUrl?: string;
    devolverStock: boolean;
  }) => Promise<RegistrarSalvedadResult>;
  onClose: () => void;
}

export default function ModalSalvedadItem({
  pedidoId,
  item,
  onSave,
  onClose
}: ModalSalvedadItemProps): React.ReactElement {
  const [cantidad, setCantidad] = useState<number | string>(item.cantidad)
  const [motivo, setMotivo] = useState<MotivoSalvedad | ''>('')
  const [descripcion, setDescripcion] = useState<string>('')
  const [guardando, setGuardando] = useState<boolean>(false)
  const [error, setError] = useState<string>('')

  const productoNombre = item.producto?.nombre || 'Producto'
  const productoCodigo = item.producto?.codigo

  const handleSubmit = async (e: FormEvent<HTMLFormElement>): Promise<void> => {
    e.preventDefault()
    setError('')

    const cantidadNum = typeof cantidad === 'string' ? parseInt(cantidad) || 0 : cantidad

    // Validaciones
    if (!motivo) {
      setError('Debe seleccionar un motivo')
      return
    }

    if (cantidadNum <= 0) {
      setError('La cantidad debe ser mayor a 0')
      return
    }

    if (cantidadNum > item.cantidad) {
      setError(`La cantidad no puede exceder ${item.cantidad} unidades`)
      return
    }

    if (motivo === 'otro' && descripcion.trim().length < 10) {
      setError('Para "Otro motivo" debe especificar una descripcion de al menos 10 caracteres')
      return
    }

    const motivoSeleccionado = MOTIVOS_SALVEDAD.find(m => m.value === motivo)

    setGuardando(true)
    try {
      const result = await onSave({
        pedidoId,
        pedidoItemId: item.id,
        cantidadAfectada: cantidadNum,
        motivo,
        descripcion: descripcion.trim() || undefined,
        devolverStock: motivoSeleccionado?.devuelveStock ?? true
      })

      if (!result.success) {
        setError(result.error || 'Error al registrar la salvedad')
        return
      }

      onClose()
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Error al registrar la salvedad'
      setError(errorMessage)
    } finally {
      setGuardando(false)
    }
  }

  const cantidadNum = typeof cantidad === 'string' ? parseInt(cantidad) || 0 : cantidad
  const motivoSeleccionado = MOTIVOS_SALVEDAD.find(m => m.value === motivo)
  const montoAfectado = cantidadNum * item.precio_unitario
  const cantidadRestante = item.cantidad - cantidadNum

  // Dry-run: detecta si esta salvedad rompe alguna bonificacion de promo.
  const { data: promosAfectadas = [] } = useSimularSalvedadPromoImpactoQuery(
    pedidoId,
    item.id,
    cantidadNum > 0 && cantidadNum <= item.cantidad ? cantidadNum : 0,
  )
  const tienePromoRota = promosAfectadas.length > 0

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-lg max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700 sticky top-0 bg-white dark:bg-gray-800">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-amber-100 dark:bg-amber-900/30 rounded-lg">
              <AlertTriangle className="w-5 h-5 text-amber-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Reportar Salvedad</h2>
              <p className="text-sm text-gray-500">Item no entregado o con problema</p>
            </div>
          </div>
          <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Info del producto */}
        <div className="p-4 bg-gray-50 dark:bg-gray-900 border-b dark:border-gray-700">
          <div className="flex items-center gap-3">
            <div className="p-2 bg-white dark:bg-gray-800 rounded-lg border dark:border-gray-700">
              <Package className="w-6 h-6 text-gray-400" />
            </div>
            <div className="flex-1">
              <p className="font-medium text-gray-800 dark:text-white">{productoNombre}</p>
              {productoCodigo && <p className="text-sm text-gray-500">Codigo: {productoCodigo}</p>}
              <div className="flex gap-4 mt-1 text-sm">
                <span>Cantidad pedida: <span className="font-bold text-blue-600">{item.cantidad}</span></span>
                <span>Precio: <span className="font-bold">${item.precio_unitario.toLocaleString()}</span></span>
              </div>
            </div>
          </div>
        </div>

        {/* Formulario */}
        <form onSubmit={handleSubmit} className="p-4 space-y-4">
          {/* Cantidad afectada — spinner touch-friendly */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              Cantidad con problema *
            </label>
            <div className="flex items-center gap-2">
              <button
                type="button"
                onClick={() => setCantidad(prev => {
                  const n = typeof prev === 'string' ? parseInt(prev) || 0 : prev
                  return Math.max(1, n - 1)
                })}
                disabled={cantidadNum <= 1}
                className="h-14 w-14 flex items-center justify-center rounded-lg border-2 border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-900/20 text-amber-700 dark:text-amber-300 hover:bg-amber-100 dark:hover:bg-amber-900/40 disabled:opacity-40 disabled:cursor-not-allowed active:scale-95 transition-all"
                aria-label="Restar uno"
              >
                <Minus className="w-6 h-6" />
              </button>
              <input
                type="number"
                inputMode="numeric"
                step="1"
                min="1"
                max={item.cantidad}
                value={cantidad}
                onChange={(e: ChangeEvent<HTMLInputElement>) => setCantidad(e.target.value)}
                className="flex-1 h-14 text-center text-2xl font-bold border-2 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-amber-500 dark:bg-gray-700 dark:text-white"
                required
              />
              <button
                type="button"
                onClick={() => setCantidad(prev => {
                  const n = typeof prev === 'string' ? parseInt(prev) || 0 : prev
                  return Math.min(item.cantidad, n + 1)
                })}
                disabled={cantidadNum >= item.cantidad}
                className="h-14 w-14 flex items-center justify-center rounded-lg border-2 border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-900/20 text-amber-700 dark:text-amber-300 hover:bg-amber-100 dark:hover:bg-amber-900/40 disabled:opacity-40 disabled:cursor-not-allowed active:scale-95 transition-all"
                aria-label="Sumar uno"
              >
                <Plus className="w-6 h-6" />
              </button>
            </div>
            <div className="mt-2 flex justify-between text-sm">
              <span className="text-gray-600 dark:text-gray-400">
                Se entregarán: <span className="font-bold text-green-600">{Math.max(0, cantidadRestante)}</span> unidades
              </span>
              <span className="text-gray-600 dark:text-gray-400">
                Monto: <span className="font-bold text-red-600">${montoAfectado.toLocaleString()}</span>
              </span>
            </div>
          </div>

          {/* Motivo */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
              Motivo de la salvedad *
            </label>
            <div className="space-y-2">
              {MOTIVOS_SALVEDAD.map(m => (
                <button
                  key={m.value}
                  type="button"
                  onClick={() => setMotivo(m.value)}
                  className={`w-full flex items-start gap-3 p-3 border rounded-lg text-left transition-colors ${
                    motivo === m.value
                      ? 'border-amber-500 bg-amber-50 dark:bg-amber-900/20'
                      : 'border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700'
                  }`}
                >
                  <div className={`w-4 h-4 rounded-full border-2 mt-0.5 flex-shrink-0 ${
                    motivo === m.value
                      ? 'border-amber-500 bg-amber-500'
                      : 'border-gray-300 dark:border-gray-500'
                  }`}>
                    {motivo === m.value && (
                      <div className="w-full h-full flex items-center justify-center">
                        <div className="w-1.5 h-1.5 bg-white rounded-full" />
                      </div>
                    )}
                  </div>
                  <div>
                    <p className={`font-medium ${motivo === m.value ? 'text-amber-700 dark:text-amber-400' : 'text-gray-700 dark:text-gray-300'}`}>
                      {m.label}
                    </p>
                    <p className="text-xs text-gray-500">{m.descripcion}</p>
                    {!m.devuelveStock && (
                      <p className="text-xs text-red-500 mt-1">No devuelve stock</p>
                    )}
                  </div>
                </button>
              ))}
            </div>
          </div>

          {/* Descripcion */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <FileText className="w-4 h-4 inline mr-1" />
              Descripcion {motivo === 'otro' ? '*' : '(opcional)'}
            </label>
            <textarea
              value={descripcion}
              onChange={(e: ChangeEvent<HTMLTextAreaElement>) => setDescripcion(e.target.value)}
              placeholder="Detalle adicional sobre el problema..."
              rows={3}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-amber-500 dark:bg-gray-700 dark:text-white"
              required={motivo === 'otro'}
            />
          </div>

          {/* Info de stock */}
          {motivoSeleccionado && (
            <div className={`p-3 rounded-lg flex items-start gap-2 ${
              motivoSeleccionado.devuelveStock
                ? 'bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800'
                : 'bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800'
            }`}>
              <AlertCircle className={`w-4 h-4 mt-0.5 flex-shrink-0 ${
                motivoSeleccionado.devuelveStock ? 'text-green-600' : 'text-red-600'
              }`} />
              <div className="text-sm">
                <p className={motivoSeleccionado.devuelveStock ? 'text-green-700 dark:text-green-400' : 'text-red-700 dark:text-red-400'}>
                  {motivoSeleccionado.devuelveStock
                    ? 'El stock se devolvera al inventario'
                    : 'El stock NO se devolvera (se considera perdida)'
                  }
                </p>
              </div>
            </div>
          )}

          {/* Alerta de promocion rota */}
          {tienePromoRota && (
            <div
              role="alert"
              className="p-3 bg-red-50 dark:bg-red-900/20 border-2 border-red-400 dark:border-red-700 rounded-lg space-y-2"
            >
              <div className="flex items-start gap-2">
                <Gift className="w-5 h-5 text-red-600 dark:text-red-400 flex-shrink-0 mt-0.5" />
                <div className="flex-1">
                  <p className="text-sm font-bold text-red-700 dark:text-red-300">
                    Atención: esta salvedad afecta {promosAfectadas.length === 1 ? 'una promoción' : 'varias promociones'}
                  </p>
                  <ul className="mt-1.5 space-y-1">
                    {promosAfectadas.map(p => (
                      <li key={p.promocion_id} className="text-sm text-red-700 dark:text-red-300">
                        •{' '}
                        <span className="font-semibold">{p.promo_nombre}:</span>{' '}
                        {p.sera_eliminada ? (
                          <>
                            se cancela por completo el regalo{' '}
                            <span className="italic">
                              &ldquo;{p.descripcion_regalo || `${p.bonif_actual} unidades`}&rdquo;
                            </span>
                          </>
                        ) : (
                          <>
                            el regalo baja de <span className="font-bold">{p.bonif_actual}</span> a{' '}
                            <span className="font-bold">{p.bonif_esperada}</span> unidades
                            {p.descripcion_regalo && ` (${p.descripcion_regalo})`}
                          </>
                        )}
                      </li>
                    ))}
                  </ul>
                </div>
              </div>
            </div>
          )}

          {/* Error */}
          {error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            </div>
          )}

          {/* Botones touch-friendly */}
          <div className="flex gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 min-h-[56px] px-4 py-3 border-2 dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors font-medium"
            >
              Cancelar
            </button>
            <button
              type="submit"
              disabled={guardando || !motivo || cantidadNum <= 0}
              className={`flex-1 min-h-[56px] px-4 py-3 text-white rounded-lg transition-colors flex items-center justify-center gap-2 font-semibold active:scale-95 ${
                tienePromoRota
                  ? 'bg-red-600 hover:bg-red-700 disabled:bg-red-400'
                  : 'bg-amber-600 hover:bg-amber-700 disabled:bg-amber-400'
              }`}
            >
              {guardando ? (
                <>
                  <span className="animate-spin">...</span>
                  Registrando...
                </>
              ) : (
                <>
                  <AlertTriangle className="w-5 h-5" />
                  {tienePromoRota ? 'Confirmar (se pierde promo)' : 'Registrar Salvedad'}
                </>
              )}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
