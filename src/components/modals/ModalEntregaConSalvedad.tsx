/**
 * Modal para registrar entrega con salvedades
 * Permite seleccionar items con problemas antes de marcar el pedido como entregado
 * Validación con Zod
 */
import React, { useState, useCallback } from 'react'
import { X, AlertTriangle, Package, Check, ChevronDown, ChevronUp, Truck } from 'lucide-react'
import { MOTIVOS_SALVEDAD_LABELS, itemSalvedadSchema } from '../../lib/schemas'
import type { PedidoDB, PedidoItemDB, MotivoSalvedad, RegistrarSalvedadInput, RegistrarSalvedadResult } from '../../types'

interface MotivoOption {
  value: MotivoSalvedad;
  label: string;
  devuelveStock: boolean;
}

const MOTIVOS_SALVEDAD: MotivoOption[] = [
  { value: 'faltante_stock', label: MOTIVOS_SALVEDAD_LABELS.faltante_stock, devuelveStock: false },
  { value: 'producto_danado', label: MOTIVOS_SALVEDAD_LABELS.producto_danado, devuelveStock: false },
  { value: 'cliente_rechaza', label: MOTIVOS_SALVEDAD_LABELS.cliente_rechaza, devuelveStock: true },
  { value: 'error_pedido', label: MOTIVOS_SALVEDAD_LABELS.error_pedido, devuelveStock: true },
  { value: 'producto_vencido', label: MOTIVOS_SALVEDAD_LABELS.producto_vencido, devuelveStock: false },
  { value: 'diferencia_precio', label: MOTIVOS_SALVEDAD_LABELS.diferencia_precio, devuelveStock: true },
  { value: 'otro', label: MOTIVOS_SALVEDAD_LABELS.otro, devuelveStock: false }
]

interface ItemSalvedad {
  item: PedidoItemDB;
  seleccionado: boolean;
  cantidadAfectada: number;
  motivo: MotivoSalvedad | '';
  descripcion: string;
}

export interface ModalEntregaConSalvedadProps {
  pedido: PedidoDB;
  onSave: (salvedades: RegistrarSalvedadInput[]) => Promise<RegistrarSalvedadResult[]>;
  onMarcarEntregado: () => Promise<void>;
  onClose: () => void;
}

export default function ModalEntregaConSalvedad({
  pedido,
  onSave,
  onMarcarEntregado,
  onClose
}: ModalEntregaConSalvedadProps): React.ReactElement {
  const [itemsSalvedad, setItemsSalvedad] = useState<ItemSalvedad[]>(
    (pedido.items || []).map(item => ({
      item,
      seleccionado: false,
      cantidadAfectada: item.cantidad,
      motivo: '',
      descripcion: ''
    }))
  )
  const [expandido, setExpandido] = useState<string | null>(null)
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')
  const [paso, setPaso] = useState<'seleccion' | 'confirmacion'>('seleccion')

  const itemsConSalvedad = itemsSalvedad.filter(i => i.seleccionado)
  const itemsSinProblemas = itemsSalvedad.filter(i => !i.seleccionado)

  const toggleItem = useCallback((itemId: string) => {
    setItemsSalvedad(prev => prev.map(i =>
      i.item.id === itemId ? { ...i, seleccionado: !i.seleccionado } : i
    ))
    setExpandido(prev => prev === itemId ? null : itemId)
  }, [])

  const updateItemSalvedad = useCallback((itemId: string, data: Partial<Omit<ItemSalvedad, 'item'>>) => {
    setItemsSalvedad(prev => prev.map(i =>
      i.item.id === itemId ? { ...i, ...data } : i
    ))
  }, [])

  const validarDatos = (): boolean => {
    for (const itemSalv of itemsConSalvedad) {
      const productoNombre = itemSalv.item.producto?.nombre || 'Producto'

      // Validar con Zod schema
      const result = itemSalvedadSchema.safeParse({
        itemId: itemSalv.item.id,
        cantidadAfectada: itemSalv.cantidadAfectada,
        motivo: itemSalv.motivo || undefined,
        descripcion: itemSalv.descripcion
      })

      if (!result.success) {
        const firstError = result.error.issues[0]?.message || 'Error de validación'
        setError(`${productoNombre}: ${firstError}`)
        return false
      }

      // Validación adicional: cantidad no puede exceder la cantidad del item
      if (itemSalv.cantidadAfectada > itemSalv.item.cantidad) {
        setError(`La cantidad no puede exceder ${itemSalv.item.cantidad} para "${productoNombre}"`)
        return false
      }
    }
    return true
  }

  const handleContinuar = () => {
    setError('')
    if (!validarDatos()) return
    setPaso('confirmacion')
  }

  const handleConfirmar = async () => {
    setError('')
    setGuardando(true)

    try {
      // Registrar todas las salvedades
      if (itemsConSalvedad.length > 0) {
        const salvedades: RegistrarSalvedadInput[] = itemsConSalvedad.map(itemSalv => {
          const motivoConfig = MOTIVOS_SALVEDAD.find(m => m.value === itemSalv.motivo)
          return {
            pedidoId: pedido.id,
            pedidoItemId: itemSalv.item.id,
            cantidadAfectada: itemSalv.cantidadAfectada,
            motivo: itemSalv.motivo as MotivoSalvedad,
            descripcion: itemSalv.descripcion.trim() || undefined,
            devolverStock: motivoConfig?.devuelveStock ?? true
          }
        })

        const results = await onSave(salvedades)
        const errores = results.filter(r => !r.success)
        if (errores.length > 0) {
          setError(`Error al registrar ${errores.length} salvedad(es): ${errores[0].error}`)
          return
        }
      }

      // Marcar pedido como entregado
      await onMarcarEntregado()
      onClose()
    } catch (err) {
      const errorMessage = err instanceof Error ? err.message : 'Error al procesar la entrega'
      setError(errorMessage)
    } finally {
      setGuardando(false)
    }
  }

  const formatMoney = (value: number): string => {
    return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS' }).format(value)
  }

  const totalEntregado = itemsSinProblemas.reduce((sum, i) => sum + (i.item.precio_unitario * i.item.cantidad), 0) +
    itemsConSalvedad.reduce((sum, i) => sum + (i.item.precio_unitario * (i.item.cantidad - i.cantidadAfectada)), 0)

  const totalSalvedades = itemsConSalvedad.reduce((sum, i) => sum + (i.item.precio_unitario * i.cantidadAfectada), 0)

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700 bg-white dark:bg-gray-800">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-amber-100 dark:bg-amber-900/30 rounded-lg">
              <AlertTriangle className="w-5 h-5 text-amber-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Entrega con Salvedad</h2>
              <p className="text-sm text-gray-500">Pedido #{pedido.id} - {pedido.cliente?.nombre_fantasia || 'Cliente'}</p>
            </div>
          </div>
          <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Contenido */}
        <div className="flex-1 overflow-y-auto p-4">
          {paso === 'seleccion' ? (
            <div className="space-y-4">
              <p className="text-sm text-gray-600 dark:text-gray-400">
                Selecciona los productos que tuvieron algun problema en la entrega:
              </p>

              {/* Lista de items */}
              <div className="space-y-2">
                {itemsSalvedad.map(itemSalv => {
                  const isExpanded = expandido === itemSalv.item.id
                  return (
                    <div
                      key={itemSalv.item.id}
                      className={`border rounded-lg overflow-hidden transition-colors ${
                        itemSalv.seleccionado
                          ? 'border-amber-500 bg-amber-50 dark:bg-amber-900/20'
                          : 'border-gray-200 dark:border-gray-700'
                      }`}
                    >
                      {/* Item header */}
                      <div
                        className="flex items-center gap-3 p-3 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50"
                        onClick={() => toggleItem(itemSalv.item.id)}
                      >
                        <div className={`w-5 h-5 rounded border-2 flex items-center justify-center ${
                          itemSalv.seleccionado
                            ? 'border-amber-500 bg-amber-500'
                            : 'border-gray-300 dark:border-gray-600'
                        }`}>
                          {itemSalv.seleccionado && <Check className="w-3 h-3 text-white" />}
                        </div>
                        <Package className="w-5 h-5 text-gray-400" />
                        <div className="flex-1">
                          <p className="font-medium text-gray-800 dark:text-white">
                            {itemSalv.item.producto?.nombre || 'Producto'}
                          </p>
                          <p className="text-sm text-gray-500">
                            {itemSalv.item.cantidad} x {formatMoney(itemSalv.item.precio_unitario)}
                          </p>
                        </div>
                        <div className="text-right">
                          <p className="font-bold text-gray-800 dark:text-white">
                            {formatMoney(itemSalv.item.cantidad * itemSalv.item.precio_unitario)}
                          </p>
                        </div>
                        {itemSalv.seleccionado && (
                          isExpanded ? <ChevronUp className="w-5 h-5 text-gray-400" /> : <ChevronDown className="w-5 h-5 text-gray-400" />
                        )}
                      </div>

                      {/* Detalles de la salvedad (expandido) */}
                      {itemSalv.seleccionado && isExpanded && (
                        <div className="p-3 border-t dark:border-gray-700 bg-white dark:bg-gray-800 space-y-3">
                          {/* Cantidad afectada */}
                          <div>
                            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                              Cantidad con problema
                            </label>
                            <input
                              type="number"
                              min="1"
                              max={itemSalv.item.cantidad}
                              value={itemSalv.cantidadAfectada}
                              onChange={(e) => updateItemSalvedad(itemSalv.item.id, { cantidadAfectada: parseInt(e.target.value) || 0 })}
                              onClick={(e) => e.stopPropagation()}
                              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-amber-500 dark:bg-gray-700 dark:text-white"
                            />
                            <p className="text-xs text-gray-500 mt-1">
                              Se entregaran: {itemSalv.item.cantidad - itemSalv.cantidadAfectada} unidades
                            </p>
                          </div>

                          {/* Motivo */}
                          <div>
                            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                              Motivo
                            </label>
                            <select
                              value={itemSalv.motivo}
                              onChange={(e) => updateItemSalvedad(itemSalv.item.id, { motivo: e.target.value as MotivoSalvedad })}
                              onClick={(e) => e.stopPropagation()}
                              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-amber-500 dark:bg-gray-700 dark:text-white"
                            >
                              <option value="">Seleccionar motivo...</option>
                              {MOTIVOS_SALVEDAD.map(m => (
                                <option key={m.value} value={m.value}>{m.label}</option>
                              ))}
                            </select>
                          </div>

                          {/* Descripcion */}
                          <div>
                            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                              Descripcion {itemSalv.motivo === 'otro' ? '(requerida)' : '(opcional)'}
                            </label>
                            <textarea
                              value={itemSalv.descripcion}
                              onChange={(e) => updateItemSalvedad(itemSalv.item.id, { descripcion: e.target.value })}
                              onClick={(e) => e.stopPropagation()}
                              placeholder="Detalle adicional..."
                              rows={2}
                              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-amber-500 dark:bg-gray-700 dark:text-white"
                            />
                          </div>
                        </div>
                      )}
                    </div>
                  )
                })}
              </div>
            </div>
          ) : (
            /* Confirmacion */
            <div className="space-y-4">
              <div className="p-4 bg-blue-50 dark:bg-blue-900/20 rounded-lg border border-blue-200 dark:border-blue-800">
                <h3 className="font-semibold text-blue-800 dark:text-blue-400 mb-2">Resumen de la entrega</h3>

                {/* Items entregados correctamente */}
                {itemsSinProblemas.length > 0 && (
                  <div className="mb-3">
                    <p className="text-sm font-medium text-green-700 dark:text-green-400 flex items-center gap-1 mb-1">
                      <Check className="w-4 h-4" /> Productos entregados correctamente:
                    </p>
                    <ul className="text-sm text-gray-600 dark:text-gray-300 ml-5 space-y-1">
                      {itemsSinProblemas.map(i => (
                        <li key={i.item.id}>
                          {i.item.cantidad}x {i.item.producto?.nombre} - {formatMoney(i.item.cantidad * i.item.precio_unitario)}
                        </li>
                      ))}
                    </ul>
                  </div>
                )}

                {/* Items con salvedad */}
                {itemsConSalvedad.length > 0 && (
                  <div className="mb-3">
                    <p className="text-sm font-medium text-amber-700 dark:text-amber-400 flex items-center gap-1 mb-1">
                      <AlertTriangle className="w-4 h-4" /> Productos con salvedad:
                    </p>
                    <ul className="text-sm text-gray-600 dark:text-gray-300 ml-5 space-y-1">
                      {itemsConSalvedad.map(i => {
                        const motivoLabel = MOTIVOS_SALVEDAD.find(m => m.value === i.motivo)?.label || i.motivo
                        const entregados = i.item.cantidad - i.cantidadAfectada
                        return (
                          <li key={i.item.id}>
                            {i.item.producto?.nombre}: {i.cantidadAfectada} ud. con problema ({motivoLabel})
                            {entregados > 0 && ` - Se entregan ${entregados} ud.`}
                          </li>
                        )
                      })}
                    </ul>
                  </div>
                )}

                {/* Totales */}
                <div className="pt-3 border-t border-blue-200 dark:border-blue-700 space-y-1">
                  <div className="flex justify-between text-sm">
                    <span className="text-gray-600 dark:text-gray-400">Total original:</span>
                    <span className="font-medium">{formatMoney(pedido.total)}</span>
                  </div>
                  <div className="flex justify-between text-sm text-red-600">
                    <span>Monto afectado por salvedades:</span>
                    <span className="font-medium">-{formatMoney(totalSalvedades)}</span>
                  </div>
                  <div className="flex justify-between text-base font-bold text-green-700 dark:text-green-400">
                    <span>Total efectivo a cobrar:</span>
                    <span>{formatMoney(totalEntregado)}</span>
                  </div>
                </div>
              </div>
            </div>
          )}

          {/* Error */}
          {error && (
            <div className="mt-4 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="p-4 border-t dark:border-gray-700 bg-gray-50 dark:bg-gray-900 flex gap-3">
          {paso === 'seleccion' ? (
            <>
              <button
                onClick={onClose}
                className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700"
              >
                Cancelar
              </button>
              <button
                onClick={handleContinuar}
                disabled={itemsConSalvedad.length === 0}
                className="flex-1 px-4 py-2 bg-amber-600 hover:bg-amber-700 disabled:bg-gray-400 text-white rounded-lg flex items-center justify-center gap-2"
              >
                Continuar
                <ChevronDown className="w-4 h-4 rotate-[-90deg]" />
              </button>
            </>
          ) : (
            <>
              <button
                onClick={() => setPaso('seleccion')}
                disabled={guardando}
                className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700"
              >
                Volver
              </button>
              <button
                onClick={handleConfirmar}
                disabled={guardando}
                className="flex-1 px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg flex items-center justify-center gap-2"
              >
                {guardando ? (
                  <>
                    <span className="animate-spin">...</span>
                    Procesando...
                  </>
                ) : (
                  <>
                    <Truck className="w-4 h-4" />
                    Confirmar Entrega
                  </>
                )}
              </button>
            </>
          )}
        </div>
      </div>
    </div>
  )
}
