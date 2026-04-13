import { useState, useMemo, memo } from 'react'
import { Loader2, Search, Truck } from 'lucide-react'
import ModalBase from './ModalBase'
import { usePedidosNoEntregadosQuery } from '../../hooks/queries'
import { getEstadoColor, getEstadoLabel, formatPrecio } from '../../utils/formatters'
import type { PerfilDB } from '../../types'

export interface ModalAsignarTransportistaMasivoProps {
  transportistas: PerfilDB[]
  onConfirm: (transportistaId: string, pedidoIds: string[], marcarListo: boolean) => Promise<void>
  onClose: () => void
  guardando: boolean
}

const ModalAsignarTransportistaMasivo = memo(function ModalAsignarTransportistaMasivo({
  transportistas,
  onConfirm,
  onClose,
  guardando,
}: ModalAsignarTransportistaMasivoProps) {
  const [selectedTransportista, setSelectedTransportista] = useState('')
  const [marcarListo, setMarcarListo] = useState(false)
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [busqueda, setBusqueda] = useState('')
  const [fechaDesde, setFechaDesde] = useState('')
  const [fechaHasta, setFechaHasta] = useState('')

  const { data: pedidos = [], isLoading } = usePedidosNoEntregadosQuery(true)

  // Filtrar pedidos sin transportista asignado
  const pedidosFiltrados = useMemo(() => {
    let resultado = pedidos.filter(p => !p.transportista_id)
    if (fechaDesde) resultado = resultado.filter(p => (p.fecha || p.created_at?.split('T')[0] || '') >= fechaDesde)
    if (fechaHasta) resultado = resultado.filter(p => (p.fecha || p.created_at?.split('T')[0] || '') <= fechaHasta)
    if (busqueda.trim()) {
      const term = busqueda.toLowerCase()
      resultado = resultado.filter(p =>
        p.cliente?.nombre_fantasia?.toLowerCase().includes(term) ||
        p.cliente?.direccion?.toLowerCase().includes(term) ||
        String(p.id).includes(term)
      )
    }
    return resultado
  }, [pedidos, busqueda, fechaDesde, fechaHasta])

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
  const canConfirm = selectedTransportista && selectedIds.size > 0 && !guardando

  return (
    <ModalBase title="Asignar Transportista Masivo" onClose={onClose} maxWidth="max-w-3xl">
      <div className="p-4 space-y-4">
        {/* Selector de transportista destino */}
        <div>
          <label className="block text-sm font-medium mb-1 text-gray-700 dark:text-gray-300">
            Asignar a transportista
          </label>
          <select
            value={selectedTransportista}
            onChange={e => setSelectedTransportista(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          >
            <option value="">Seleccionar transportista...</option>
            {transportistas.map(t => (
              <option key={t.id} value={t.id}>{t.nombre}</option>
            ))}
          </select>
        </div>

        {/* Marcar como listo */}
        <label className="flex items-center space-x-2 cursor-pointer">
          <input
            type="checkbox"
            checked={marcarListo}
            onChange={e => setMarcarListo(e.target.checked)}
            className="w-4 h-4 rounded border-gray-300"
          />
          <span className="text-sm text-gray-700 dark:text-gray-300">
            Marcar como listo para entregar
          </span>
        </label>

        {/* Filtro por fechas */}
        <div className="grid grid-cols-2 gap-3">
          <div>
            <label className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Desde</label>
            <input type="date" value={fechaDesde} onChange={e => setFechaDesde(e.target.value)}
              className="w-full px-3 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white" />
          </div>
          <div>
            <label className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Hasta</label>
            <input type="date" value={fechaHasta} onChange={e => setFechaHasta(e.target.value)}
              className="w-full px-3 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white" />
          </div>
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
              No hay pedidos sin transportista asignado
            </div>
          ) : (
            pedidosFiltrados.map(pedido => (
              <label
                key={pedido.id}
                className={`flex items-center p-3 border-b last:border-b-0 dark:border-gray-600 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors ${
                  selectedIds.has(pedido.id) ? 'bg-blue-50 dark:bg-blue-900/20' : ''
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
                    <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${getEstadoColor(pedido.estado)}`}>
                      {getEstadoLabel(pedido.estado)}
                    </span>
                    {pedido.fecha && (
                      <span className="text-xs text-gray-400">{pedido.fecha}</span>
                    )}
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
                </div>
              </label>
            ))
          )}
        </div>
      </div>

      {/* Footer */}
      <div className="flex items-center justify-between p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <span className="text-sm text-gray-600 dark:text-gray-400">
          {selectedIds.size} pedido{selectedIds.size !== 1 ? 's' : ''} seleccionado{selectedIds.size !== 1 ? 's' : ''}
        </span>
        <div className="flex space-x-3">
          <button
            onClick={onClose}
            className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg"
          >
            Cancelar
          </button>
          <button
            onClick={() => canConfirm && onConfirm(selectedTransportista, Array.from(selectedIds), marcarListo)}
            disabled={!canConfirm}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:opacity-50 disabled:cursor-not-allowed flex items-center"
          >
            {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
            <Truck className="w-4 h-4 mr-2" />
            Asignar Transportista
          </button>
        </div>
      </div>
    </ModalBase>
  )
})

export default ModalAsignarTransportistaMasivo
