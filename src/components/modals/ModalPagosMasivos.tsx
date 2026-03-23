import { useState, useMemo, memo } from 'react'
import { Loader2, Search } from 'lucide-react'
import ModalBase from './ModalBase'
import { usePedidosNoPagadosQuery } from '../../hooks/queries'
import { getEstadoPagoColor, getEstadoPagoLabel, formatPrecio } from '../../utils/formatters'

export interface ModalPagosMasivosProps {
  onConfirm: (formaPago: string, pedidoIds: string[]) => Promise<void>
  onClose: () => void
  guardando: boolean
}

const FORMAS_PAGO = [
  { value: 'efectivo', label: 'Efectivo' },
  { value: 'transferencia', label: 'Transferencia' },
  { value: 'cheque', label: 'Cheque' },
  { value: 'cuenta_corriente', label: 'Cuenta Corriente' },
  { value: 'tarjeta', label: 'Tarjeta' },
]

const ModalPagosMasivos = memo(function ModalPagosMasivos({
  onConfirm,
  onClose,
  guardando,
}: ModalPagosMasivosProps) {
  const [selectedFormaPago, setSelectedFormaPago] = useState('')
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [busqueda, setBusqueda] = useState('')

  const { data: pedidos = [], isLoading } = usePedidosNoPagadosQuery(true)

  const pedidosFiltrados = useMemo(() => {
    if (!busqueda.trim()) return pedidos
    const term = busqueda.toLowerCase()
    return pedidos.filter(p =>
      p.cliente?.nombre_fantasia?.toLowerCase().includes(term) ||
      p.cliente?.direccion?.toLowerCase().includes(term) ||
      String(p.id).includes(term)
    )
  }, [pedidos, busqueda])

  const toggleSelect = (id: string) => {
    setSelectedIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const toggleAll = () => {
    if (selectedIds.size === pedidosFiltrados.length) {
      setSelectedIds(new Set())
    } else {
      setSelectedIds(new Set(pedidosFiltrados.map(p => p.id)))
    }
  }

  const allSelected = pedidosFiltrados.length > 0 && selectedIds.size === pedidosFiltrados.length
  const canConfirm = selectedFormaPago && selectedIds.size > 0 && !guardando

  // Calculate total of selected orders
  const totalSeleccionado = useMemo(() => {
    return pedidos
      .filter(p => selectedIds.has(p.id))
      .reduce((sum, p) => sum + (p.total || 0), 0)
  }, [pedidos, selectedIds])

  return (
    <ModalBase title="Pagos Masivos" onClose={onClose} maxWidth="max-w-3xl">
      <div className="p-4 space-y-4">
        {/* Selector de forma de pago */}
        <div>
          <label className="block text-sm font-medium mb-1 text-gray-700 dark:text-gray-300">
            Forma de pago
          </label>
          <select
            value={selectedFormaPago}
            onChange={e => setSelectedFormaPago(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          >
            <option value="">Seleccionar forma de pago...</option>
            {FORMAS_PAGO.map(fp => (
              <option key={fp.value} value={fp.value}>{fp.label}</option>
            ))}
          </select>
        </div>

        {/* Busqueda */}
        <div className="relative">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
          <input
            type="text"
            placeholder="Buscar por cliente, direccion o #pedido..."
            value={busqueda}
            onChange={e => setBusqueda(e.target.value)}
            className="w-full pl-9 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          />
        </div>

        {/* Seleccionar todos */}
        {pedidosFiltrados.length > 0 && (
          <label className="flex items-center space-x-2 cursor-pointer">
            <input
              type="checkbox"
              checked={allSelected}
              onChange={toggleAll}
              className="w-4 h-4 rounded border-gray-300"
            />
            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">
              Seleccionar todos ({pedidosFiltrados.length})
            </span>
          </label>
        )}

        {/* Lista de pedidos */}
        <div className="max-h-96 overflow-y-auto border rounded-lg dark:border-gray-600">
          {isLoading ? (
            <div className="flex items-center justify-center py-8">
              <Loader2 className="w-6 h-6 animate-spin text-blue-600" />
              <span className="ml-2 text-gray-500">Cargando pedidos...</span>
            </div>
          ) : pedidosFiltrados.length === 0 ? (
            <div className="text-center py-8 text-gray-500">
              No hay pedidos pendientes de pago
            </div>
          ) : (
            pedidosFiltrados.map(pedido => (
              <label
                key={pedido.id}
                className={`flex items-center p-3 border-b last:border-b-0 dark:border-gray-600 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors ${
                  selectedIds.has(pedido.id) ? 'bg-green-50 dark:bg-green-900/20' : ''
                }`}
              >
                <input
                  type="checkbox"
                  checked={selectedIds.has(pedido.id)}
                  onChange={() => toggleSelect(pedido.id)}
                  className="w-4 h-4 rounded border-gray-300 mr-3 flex-shrink-0"
                />
                <div className="flex-1 min-w-0">
                  <div className="flex items-center gap-2">
                    <span className="text-xs text-gray-400">#{pedido.id}</span>
                    <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${getEstadoPagoColor(pedido.estado_pago)}`}>
                      {getEstadoPagoLabel(pedido.estado_pago)}
                    </span>
                  </div>
                  <p className="font-medium text-gray-800 dark:text-white truncate">
                    {pedido.cliente?.nombre_fantasia || 'Sin cliente'}
                  </p>
                  <p className="text-xs text-gray-500 truncate">
                    {pedido.cliente?.direccion}
                  </p>
                </div>
                <div className="text-right ml-3 flex-shrink-0">
                  <p className="font-bold text-blue-600">{formatPrecio(pedido.total)}</p>
                  {(pedido.monto_pagado ?? 0) > 0 && (
                    <p className="text-xs text-green-600">Pagado: {formatPrecio(pedido.monto_pagado ?? 0)}</p>
                  )}
                </div>
              </label>
            ))
          )}
        </div>
      </div>

      {/* Footer */}
      <div className="flex items-center justify-between p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <div className="text-sm text-gray-600 dark:text-gray-400">
          <span>{selectedIds.size} pedido{selectedIds.size !== 1 ? 's' : ''} seleccionado{selectedIds.size !== 1 ? 's' : ''}</span>
          {selectedIds.size > 0 && (
            <span className="ml-2 font-semibold text-green-600">
              Total: {formatPrecio(totalSeleccionado)}
            </span>
          )}
        </div>
        <div className="flex space-x-3">
          <button
            onClick={onClose}
            className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg"
          >
            Cancelar
          </button>
          <button
            onClick={() => canConfirm && onConfirm(selectedFormaPago, Array.from(selectedIds))}
            disabled={!canConfirm}
            className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed flex items-center"
          >
            {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
            Marcar como Pagados
          </button>
        </div>
      </div>
    </ModalBase>
  )
})

export default ModalPagosMasivos
