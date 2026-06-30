import { useState, useMemo, memo } from 'react'
import { Loader2, Search, Calendar, AlertTriangle, Truck } from 'lucide-react'
import ModalBase from './ModalBase'
import { usePedidosNoEntregadosQuery, useRendicionCerradaQuery } from '../../hooks/queries'
import {
  getEstadoColor, getEstadoLabel,
  getEstadoPagoColor, getEstadoPagoLabel,
  formatPrecio, fechaLocalISO,
} from '../../utils/formatters'
import { FORMAS_PAGO_SELECCIONABLES } from '../../constants/formasPago'
import type { PerfilDB } from '../../types'

export interface ModalEntregaYPagoMasivosProps {
  transportistas: PerfilDB[]
  /**
   * Callback de confirmación.
   * @param transportistaId - ID del transportista a asignar a la entrega
   * @param formaPago - Forma de pago a registrar
   * @param pedidoIds - IDs de los pedidos seleccionados
   * @param fecha - Fecha contable de entrega y pago (YYYY-MM-DD)
   */
  onConfirm: (transportistaId: string, formaPago: string, pedidoIds: string[], fecha: string) => Promise<void>
  onClose: () => void
  guardando: boolean
  /** Si el caller es encargado (no admin): fecha bloqueada a hoy y check de rendicion. */
  isEncargado?: boolean
  isAdmin?: boolean
}

const ModalEntregaYPagoMasivos = memo(function ModalEntregaYPagoMasivos({
  transportistas,
  onConfirm,
  onClose,
  guardando,
  isEncargado = false,
  isAdmin = false,
}: ModalEntregaYPagoMasivosProps) {
  const hoy = fechaLocalISO()
  const fechaBloqueada = isEncargado && !isAdmin
  const [selectedTransportista, setSelectedTransportista] = useState('')
  const [selectedFormaPago, setSelectedFormaPago] = useState('')
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [busqueda, setBusqueda] = useState('')
  const [fechaDesde, setFechaDesde] = useState('')
  const [fechaHasta, setFechaHasta] = useState('')
  const [fecha, setFecha] = useState<string>(hoy)

  // Universo: pedidos NO entregados (la entrega es la acción que habilita el combo).
  const { data: pedidos = [], isLoading } = usePedidosNoEntregadosQuery(true)
  const { data: rendicionCerrada = false } = useRendicionCerradaQuery(fecha, fechaBloqueada)

  const pedidosFiltrados = useMemo(() => {
    let resultado = pedidos
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
  const bloqueadoPorRendicion = fechaBloqueada && rendicionCerrada
  const canConfirm =
    !!selectedTransportista &&
    !!selectedFormaPago &&
    selectedIds.size > 0 &&
    !guardando &&
    !!fecha &&
    !bloqueadoPorRendicion

  // Total a cobrar = suma del saldo pendiente de los pedidos seleccionados
  const totalACobrar = useMemo(() => {
    return pedidos
      .filter(p => selectedIds.has(p.id))
      .reduce((sum, p) => sum + Math.max(0, (p.total || 0) - (p.monto_pagado ?? 0)), 0)
  }, [pedidos, selectedIds])

  return (
    <ModalBase title="Entrega y Pago Masivos" onClose={onClose} maxWidth="max-w-3xl">
      <div className="p-4 space-y-4">
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          {/* Selector de transportista */}
          <div>
            <label className="block text-sm font-medium mb-1 text-gray-700 dark:text-gray-300 flex items-center gap-1">
              <Truck className="w-4 h-4" />
              Transportista
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
              {FORMAS_PAGO_SELECCIONABLES.map(fp => (
                <option key={fp.value} value={fp.value}>{fp.label}</option>
              ))}
            </select>
          </div>

          {/* Fecha contable de entrega y pago */}
          <div>
            <label className="block text-sm font-medium mb-1 text-gray-700 dark:text-gray-300 flex items-center gap-1">
              <Calendar className="w-4 h-4" />
              Fecha
            </label>
            <input
              type="date"
              value={fecha}
              onChange={e => setFecha(e.target.value)}
              disabled={fechaBloqueada}
              min={fechaBloqueada ? hoy : undefined}
              max={fechaBloqueada ? hoy : undefined}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:bg-gray-100 dark:disabled:bg-gray-800 disabled:cursor-not-allowed"
            />
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              {fechaBloqueada
                ? 'Como encargado solo podés registrar con fecha de hoy. Si necesitás otra fecha pedíselo a un admin.'
                : 'Se aplica a la entrega y al pago. Por defecto hoy.'}
            </p>
          </div>
        </div>

        {bloqueadoPorRendicion && (
          <div className="flex items-start gap-2 p-3 rounded-lg border border-amber-300 bg-amber-50 dark:bg-amber-900/20 dark:border-amber-700">
            <AlertTriangle className="w-5 h-5 text-amber-600 dark:text-amber-400 flex-shrink-0 mt-0.5" />
            <div className="text-sm text-amber-900 dark:text-amber-200">
              <p className="font-medium">Rendición cerrada</p>
              <p>La rendición de hoy ya fue confirmada. No podés registrar más pagos a esta fecha. Pedile a un admin si necesitás corregir algo.</p>
            </div>
          </div>
        )}

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
              No hay pedidos disponibles para entregar
            </div>
          ) : (
            pedidosFiltrados.map(pedido => {
              const saldo = Math.max(0, (pedido.total || 0) - (pedido.monto_pagado ?? 0))
              return (
                <label
                  key={pedido.id}
                  className={`flex items-center p-3 border-b last:border-b-0 dark:border-gray-600 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors ${
                    selectedIds.has(pedido.id) ? 'bg-indigo-50 dark:bg-indigo-900/20' : ''
                  }`}
                >
                  <input
                    type="checkbox"
                    checked={selectedIds.has(pedido.id)}
                    onChange={() => toggleSelect(pedido.id)}
                    className="w-4 h-4 rounded border-gray-300 mr-3 flex-shrink-0"
                  />
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 flex-wrap">
                      <span className="text-xs text-gray-400">#{pedido.id}</span>
                      <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${getEstadoColor(pedido.estado)}`}>
                        {getEstadoLabel(pedido.estado)}
                      </span>
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
                    {saldo > 0 ? (
                      <p className="text-xs text-amber-600">A cobrar: {formatPrecio(saldo)}</p>
                    ) : (
                      <p className="text-xs text-green-600">Ya pagado</p>
                    )}
                  </div>
                </label>
              )
            })
          )}
        </div>
      </div>

      {/* Footer */}
      <div className="flex items-center justify-between p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <div className="text-sm text-gray-600 dark:text-gray-400">
          <span>{selectedIds.size} pedido{selectedIds.size !== 1 ? 's' : ''} seleccionado{selectedIds.size !== 1 ? 's' : ''}</span>
          {selectedIds.size > 0 && (
            <span className="ml-2 font-semibold text-green-600">
              A cobrar: {formatPrecio(totalACobrar)}
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
            onClick={() => canConfirm && onConfirm(selectedTransportista, selectedFormaPago, Array.from(selectedIds), fecha)}
            disabled={!canConfirm}
            className="px-4 py-2 bg-indigo-600 text-white rounded-lg hover:bg-indigo-700 disabled:opacity-50 disabled:cursor-not-allowed flex items-center"
          >
            {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
            Entregar y registrar pago
          </button>
        </div>
      </div>
    </ModalBase>
  )
})

export default ModalEntregaYPagoMasivos
