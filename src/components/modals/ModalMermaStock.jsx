import React, { useState } from 'react'
import { X, AlertTriangle, Package, Minus, FileText } from 'lucide-react'

const MOTIVOS_MERMA = [
  { value: 'rotura', label: 'Rotura', icon: '💔' },
  { value: 'vencimiento', label: 'Vencimiento', icon: '📅' },
  { value: 'robo', label: 'Robo/Hurto', icon: '🚨' },
  { value: 'decomiso', label: 'Decomiso', icon: '⚠️' },
  { value: 'devolucion', label: 'Devolución defectuosa', icon: '↩️' },
  { value: 'error_inventario', label: 'Error de inventario', icon: '📋' },
  { value: 'muestra', label: 'Muestra/Degustación', icon: '🎁' },
  { value: 'otro', label: 'Otro motivo', icon: '📝' }
]

export default function ModalMermaStock({ producto, onSave, onClose, isOffline = false }) {
  const [cantidad, setCantidad] = useState(1)
  const [motivo, setMotivo] = useState('')
  const [observaciones, setObservaciones] = useState('')
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  if (!producto) return null

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError('')

    if (cantidad <= 0) {
      setError('La cantidad debe ser mayor a 0')
      return
    }

    if (cantidad > producto.stock) {
      setError(`No puede dar de baja más de ${producto.stock} unidades (stock actual)`)
      return
    }

    if (!motivo) {
      setError('Debe seleccionar un motivo')
      return
    }

    setGuardando(true)
    try {
      await onSave({
        productoId: producto.id,
        productoNombre: producto.nombre,
        productoCodigo: producto.codigo,
        cantidad: parseInt(cantidad),
        motivo,
        motivoLabel: MOTIVOS_MERMA.find(m => m.value === motivo)?.label || motivo,
        observaciones,
        stockAnterior: producto.stock,
        stockNuevo: producto.stock - cantidad
      })
      onClose()
    } catch (err) {
      setError(err.message || 'Error al registrar la merma')
    } finally {
      setGuardando(false)
    }
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-md">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-red-100 dark:bg-red-900/30 rounded-lg">
              <Minus className="w-5 h-5 text-red-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Baja de Stock</h2>
              <p className="text-sm text-gray-500">Registrar merma o pérdida</p>
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
            <div>
              <p className="font-medium text-gray-800 dark:text-white">{producto.nombre}</p>
              {producto.codigo && <p className="text-sm text-gray-500">Código: {producto.codigo}</p>}
              <p className="text-sm">
                Stock actual: <span className="font-bold text-blue-600">{producto.stock}</span> unidades
              </p>
            </div>
          </div>
        </div>

        {/* Formulario */}
        <form onSubmit={handleSubmit} className="p-4 space-y-4">
          {/* Indicador offline */}
          {isOffline && (
            <div className="flex items-center gap-2 p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
              <AlertTriangle className="w-4 h-4 text-amber-600" />
              <p className="text-sm text-amber-700 dark:text-amber-400">
                Sin conexión. Se guardará localmente y sincronizará después.
              </p>
            </div>
          )}

          {/* Cantidad */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Cantidad a dar de baja *
            </label>
            <input
              type="number"
              min="1"
              max={producto.stock}
              value={cantidad}
              onChange={e => setCantidad(e.target.value)}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-red-500 dark:bg-gray-700 dark:text-white"
              required
            />
            <p className="mt-1 text-xs text-gray-500">
              Stock después de la baja: <span className="font-bold">{Math.max(0, producto.stock - (cantidad || 0))}</span>
            </p>
          </div>

          {/* Motivo */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Motivo de la baja *
            </label>
            <div className="grid grid-cols-2 gap-2">
              {MOTIVOS_MERMA.map(m => (
                <button
                  key={m.value}
                  type="button"
                  onClick={() => setMotivo(m.value)}
                  className={`flex items-center gap-2 p-2 border rounded-lg text-sm text-left transition-colors ${
                    motivo === m.value
                      ? 'border-red-500 bg-red-50 dark:bg-red-900/20 text-red-700 dark:text-red-400'
                      : 'border-gray-200 dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700'
                  }`}
                >
                  <span>{m.icon}</span>
                  <span>{m.label}</span>
                </button>
              ))}
            </div>
          </div>

          {/* Observaciones */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <FileText className="w-4 h-4 inline mr-1" />
              Observaciones (opcional)
            </label>
            <textarea
              value={observaciones}
              onChange={e => setObservaciones(e.target.value)}
              placeholder="Detalle adicional sobre la baja..."
              rows={2}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-red-500 dark:bg-gray-700 dark:text-white"
            />
          </div>

          {/* Error */}
          {error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            </div>
          )}

          {/* Botones */}
          <div className="flex gap-3 pt-2">
            <button
              type="button"
              onClick={onClose}
              className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
            >
              Cancelar
            </button>
            <button
              type="submit"
              disabled={guardando || !motivo || cantidad <= 0}
              className="flex-1 px-4 py-2 bg-red-600 hover:bg-red-700 disabled:bg-red-400 text-white rounded-lg transition-colors flex items-center justify-center gap-2"
            >
              {guardando ? (
                <>
                  <span className="animate-spin">⏳</span>
                  Registrando...
                </>
              ) : (
                <>
                  <Minus className="w-4 h-4" />
                  Registrar Baja
                </>
              )}
            </button>
          </div>
        </form>
      </div>
    </div>
  )
}
