import React, { useState, useMemo } from 'react'
import { X, FileText, AlertTriangle } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import type { NotaCreditoDB, NotaCreditoFormInput } from '../../types'

interface CompraItem {
  producto_id: string
  producto?: { id: string; nombre: string } | null
  cantidad: number
  costo_unitario: number
  bonificacion?: number
}

export interface ModalNotaCreditoProps {
  compra: {
    id: string
    items: CompraItem[]
    proveedor_nombre?: string
    proveedor?: { nombre: string } | null
    numero_factura?: string
  }
  notasExistentes: NotaCreditoDB[]
  onSave: (data: NotaCreditoFormInput) => Promise<void>
  onClose: () => void
}

export default function ModalNotaCredito({
  compra,
  notasExistentes,
  onSave,
  onClose,
}: ModalNotaCreditoProps): React.ReactElement {
  const [saving, setSaving] = useState(false)
  const [motivo, setMotivo] = useState('')
  const [numeroNota, setNumeroNota] = useState('')
  const [cantidades, setCantidades] = useState<Record<string, number>>(() => {
    const initial: Record<string, number> = {}
    for (const item of compra.items) {
      initial[item.producto_id] = 0
    }
    return initial
  })

  // Calculate already-credited quantities per product from existing notas
  const yaAcreditado = useMemo(() => {
    const acreditado: Record<string, number> = {}
    for (const nota of notasExistentes) {
      for (const ncItem of nota.items || []) {
        acreditado[ncItem.producto_id] = (acreditado[ncItem.producto_id] || 0) + ncItem.cantidad
      }
    }
    return acreditado
  }, [notasExistentes])

  // Calculate max creditable per product
  const maxCreditable = useMemo(() => {
    const max: Record<string, number> = {}
    for (const item of compra.items) {
      max[item.producto_id] = item.cantidad - (yaAcreditado[item.producto_id] || 0)
    }
    return max
  }, [compra.items, yaAcreditado])

  // Calculate subtotal from credited items
  const { subtotal, iva, total, itemsConCantidad } = useMemo(() => {
    let sub = 0
    const itemsList: Array<{
      productoId: string
      cantidad: number
      costoUnitario: number
      subtotal: number
    }> = []

    for (const item of compra.items) {
      const cant = cantidades[item.producto_id] || 0
      if (cant > 0) {
        const itemSub = cant * item.costo_unitario
        sub += itemSub
        itemsList.push({
          productoId: item.producto_id,
          cantidad: cant,
          costoUnitario: item.costo_unitario,
          subtotal: itemSub,
        })
      }
    }

    const ivaCalc = sub * 0.21
    return {
      subtotal: sub,
      iva: ivaCalc,
      total: sub + ivaCalc,
      itemsConCantidad: itemsList,
    }
  }, [cantidades, compra.items])

  const handleCantidadChange = (productoId: string, value: string) => {
    const num = parseInt(value, 10)
    const max = maxCreditable[productoId] || 0
    if (isNaN(num) || num < 0) {
      setCantidades(prev => ({ ...prev, [productoId]: 0 }))
    } else {
      setCantidades(prev => ({ ...prev, [productoId]: Math.min(num, max) }))
    }
  }

  const handleGuardar = async () => {
    if (itemsConCantidad.length === 0) return
    setSaving(true)
    try {
      const data: NotaCreditoFormInput = {
        compraId: compra.id,
        numeroNota: numeroNota || null,
        motivo: motivo || null,
        subtotal,
        iva,
        total,
        items: itemsConCantidad,
      }
      await onSave(data)
    } finally {
      setSaving(false)
    }
  }

  const referencia = compra.numero_factura
    ? `Factura ${compra.numero_factura}`
    : compra.proveedor?.nombre || compra.proveedor_nombre || `Compra #${compra.id}`

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-3xl max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-blue-100 dark:bg-blue-900/30 rounded-lg">
              <FileText className="w-5 h-5 text-blue-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">
                Nota de Credito
              </h2>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                {referencia}
              </p>
            </div>
          </div>
          <button
            onClick={onClose}
            className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg"
          >
            <X className="w-5 h-5 text-gray-500" />
          </button>
        </div>

        {/* Content */}
        <div className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Warning if all items fully credited */}
          {compra.items.every(item => (maxCreditable[item.producto_id] || 0) <= 0) && (
            <div className="flex items-center gap-2 p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg">
              <AlertTriangle className="w-5 h-5 text-yellow-600 flex-shrink-0" />
              <p className="text-sm text-yellow-700 dark:text-yellow-400">
                Todos los items de esta compra ya fueron acreditados en su totalidad.
              </p>
            </div>
          )}

          {/* Items table */}
          <div className="bg-gray-50 dark:bg-gray-900 rounded-lg overflow-hidden">
            <table className="w-full text-sm">
              <thead className="bg-gray-100 dark:bg-gray-800">
                <tr>
                  <th className="text-left px-4 py-2 text-gray-600 dark:text-gray-400">Producto</th>
                  <th className="text-center px-4 py-2 text-gray-600 dark:text-gray-400">Cant. Original</th>
                  <th className="text-center px-4 py-2 text-gray-600 dark:text-gray-400">Ya Acreditado</th>
                  <th className="text-center px-4 py-2 text-gray-600 dark:text-gray-400">A Acreditar</th>
                  <th className="text-right px-4 py-2 text-gray-600 dark:text-gray-400">Subtotal</th>
                </tr>
              </thead>
              <tbody className="divide-y dark:divide-gray-700">
                {compra.items.map((item) => {
                  const ya = yaAcreditado[item.producto_id] || 0
                  const max = maxCreditable[item.producto_id] || 0
                  const cant = cantidades[item.producto_id] || 0
                  const itemSubtotal = cant * item.costo_unitario

                  return (
                    <tr key={item.producto_id}>
                      <td className="px-4 py-3">
                        <p className="font-medium text-gray-800 dark:text-white">
                          {item.producto?.nombre || 'Producto'}
                        </p>
                        <p className="text-xs text-gray-500 dark:text-gray-400">
                          {formatPrecio(item.costo_unitario)} c/u
                        </p>
                      </td>
                      <td className="px-4 py-3 text-center text-gray-800 dark:text-white">
                        {item.cantidad}
                      </td>
                      <td className="px-4 py-3 text-center">
                        <span className={ya > 0 ? 'text-orange-600 dark:text-orange-400 font-medium' : 'text-gray-400 dark:text-gray-500'}>
                          {ya}
                        </span>
                      </td>
                      <td className="px-4 py-3 text-center">
                        <input
                          type="number"
                          min={0}
                          max={max}
                          value={cant}
                          onChange={(e) => handleCantidadChange(item.producto_id, e.target.value)}
                          disabled={max <= 0}
                          className="w-20 px-2 py-1 text-center border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-800 dark:text-white disabled:opacity-50 disabled:cursor-not-allowed focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                        />
                        {max > 0 && (
                          <p className="text-xs text-gray-400 dark:text-gray-500 mt-1">max: {max}</p>
                        )}
                      </td>
                      <td className="px-4 py-3 text-right font-medium text-gray-800 dark:text-white">
                        {cant > 0 ? formatPrecio(itemSubtotal) : '-'}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>

          {/* Motivo */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Motivo
            </label>
            <textarea
              value={motivo}
              onChange={(e) => setMotivo(e.target.value)}
              placeholder="Motivo de la nota de credito..."
              rows={3}
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-800 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:ring-2 focus:ring-blue-500 focus:border-blue-500 resize-none"
            />
          </div>

          {/* Numero de nota */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Numero de nota (opcional)
            </label>
            <input
              type="text"
              value={numeroNota}
              onChange={(e) => setNumeroNota(e.target.value)}
              placeholder="Ej: NC-0001"
              className="w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-800 dark:text-white placeholder-gray-400 dark:placeholder-gray-500 focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          {/* Totals */}
          <div className="bg-blue-50 dark:bg-blue-900/20 rounded-lg p-4">
            <div className="space-y-2">
              <div className="flex justify-between text-sm">
                <span className="text-gray-600 dark:text-gray-400">Subtotal:</span>
                <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(subtotal)}</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-gray-600 dark:text-gray-400">IVA (21%):</span>
                <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(iva)}</span>
              </div>
              <div className="flex justify-between text-lg font-bold pt-2 border-t border-blue-200 dark:border-blue-800">
                <span className="text-gray-800 dark:text-white">Total:</span>
                <span className="text-blue-600">{formatPrecio(total)}</span>
              </div>
            </div>
          </div>
        </div>

        {/* Footer */}
        <div className="flex gap-3 p-4 border-t dark:border-gray-700">
          <button
            onClick={onClose}
            className="flex-1 px-4 py-2 bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600 text-gray-800 dark:text-white rounded-lg transition-colors"
          >
            Cancelar
          </button>
          <button
            onClick={handleGuardar}
            disabled={saving || itemsConCantidad.length === 0}
            className="flex-1 px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed text-white rounded-lg transition-colors font-medium"
          >
            {saving ? 'Guardando...' : 'Guardar'}
          </button>
        </div>
      </div>
    </div>
  )
}
