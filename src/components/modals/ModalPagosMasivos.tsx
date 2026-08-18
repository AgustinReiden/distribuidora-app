import { useState, useMemo, memo } from 'react'
import { Loader2, Search, Calendar, AlertTriangle } from 'lucide-react'
import ModalBase from './ModalBase'
// La confirmación se renderiza DENTRO del ModalBase: ModalBase es un Radix
// Dialog que portalea su contenido con z-50, así que un hermano `fixed inset-0
// z-50` pierde el empate de z-index y queda inalcanzable. Misma convención que
// ModalPedido/ModalEditarPedido.
import ModalConfirmacion, { type ModalConfirmacionConfig } from './ModalConfirmacion'
import { usePedidosNoPagadosQuery, useRendicionCerradaQuery } from '../../hooks/queries'
import { getEstadoPagoColor, getEstadoPagoLabel, formatPrecio, fechaLocalISO } from '../../utils/formatters'
import { FORMAS_PAGO_SELECCIONABLES } from '../../constants/formasPago'

export interface ModalPagosMasivosProps {
  /**
   * Callback de confirmación.
   * @param formaPago - Forma de pago seleccionada
   * @param pedidoIds - IDs de los pedidos seleccionados
   * @param fechaPago - Fecha contable a aplicar al pago (YYYY-MM-DD)
   */
  onConfirm: (formaPago: string, pedidoIds: string[], fechaPago: string) => Promise<void>
  onClose: () => void
  guardando: boolean
  /** Si el caller es encargado (no admin): fecha bloqueada a hoy y check de rendicion. */
  isEncargado?: boolean
  isAdmin?: boolean
}

const ModalPagosMasivos = memo(function ModalPagosMasivos({
  onConfirm,
  onClose,
  guardando,
  isEncargado = false,
  isAdmin = false,
}: ModalPagosMasivosProps) {
  const hoy = fechaLocalISO()
  const fechaBloqueada = isEncargado && !isAdmin
  const [selectedFormaPago, setSelectedFormaPago] = useState('')
  const [selectedIds, setSelectedIds] = useState<Set<string>>(new Set())
  const [busqueda, setBusqueda] = useState('')
  // Arranca acotado al mes en curso. La query no filtra por fecha y trae TODO
  // el backlog de impagos de la sucursal (116 boletas / $6,6M al 18/08, la más
  // vieja del 25/03). Con el filtro vacío, "Seleccionar todos" abarcaba cinco
  // meses de deuda y se cobraba de un saque.
  const [fechaDesde, setFechaDesde] = useState(`${hoy.slice(0, 7)}-01`)
  const [fechaHasta, setFechaHasta] = useState('')
  const [fechaPago, setFechaPago] = useState<string>(hoy)
  const [confirmConfig, setConfirmConfig] = useState<ModalConfirmacionConfig | null>(null)

  const { data: pedidos = [], isLoading } = usePedidosNoPagadosQuery(true)
  const { data: rendicionCerrada = false } = useRendicionCerradaQuery(fechaPago, fechaBloqueada)

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
    !!selectedFormaPago &&
    selectedIds.size > 0 &&
    !guardando &&
    !!fechaPago &&
    !bloqueadoPorRendicion

  // Lo que se va a cobrar es el SALDO, no el total: un pedido con pago parcial
  // sólo aporta lo que le falta. Antes sumaba `p.total` e inflaba el número que
  // el encargado usa para decidir (mismo criterio que ModalEntregaYPagoMasivos).
  const totalSeleccionado = useMemo(() => {
    return pedidos
      .filter(p => selectedIds.has(p.id))
      .reduce((sum, p) => sum + Math.max(0, (p.total || 0) - (p.monto_pagado || 0)), 0)
  }, [pedidos, selectedIds])

  /** Rango de fechas de lo seleccionado, para que la confirmación no mienta. */
  const rangoSeleccionado = useMemo(() => {
    const fechas = pedidos
      .filter(p => selectedIds.has(p.id))
      .map(p => p.fecha || p.created_at?.split('T')[0] || '')
      .filter(Boolean)
      .sort()
    if (fechas.length === 0) return null
    return { desde: fechas[0], hasta: fechas[fechas.length - 1] }
  }, [pedidos, selectedIds])

  const pedirConfirmacion = (): void => {
    const n = selectedIds.size
    const rango =
      rangoSeleccionado && rangoSeleccionado.desde !== rangoSeleccionado.hasta
        ? ` con fecha entre ${rangoSeleccionado.desde} y ${rangoSeleccionado.hasta}`
        : rangoSeleccionado
          ? ` del ${rangoSeleccionado.desde}`
          : ''
    setConfirmConfig({
      visible: true,
      tipo: 'warning',
      titulo: `Cobrar ${n} ${n === 1 ? 'boleta' : 'boletas'}`,
      mensaje:
        `Se van a registrar ${n} ${n === 1 ? 'pago' : 'pagos'} por ${formatPrecio(totalSeleccionado)}` +
        `${rango}, con fecha ${fechaPago}. Esta acción no se puede deshacer en bloque.`,
      onConfirm: () => {
        setConfirmConfig(null)
        void onConfirm(selectedFormaPago, Array.from(selectedIds), fechaPago)
      },
    })
  }

  return (
    <ModalBase title="Pagos Masivos" onClose={onClose} maxWidth="max-w-3xl">
      <div className="p-4 space-y-4">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
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

          {/* Fecha contable del pago */}
          <div>
            <label className="block text-sm font-medium mb-1 text-gray-700 dark:text-gray-300 flex items-center gap-1">
              <Calendar className="w-4 h-4" />
              Fecha del pago
            </label>
            <input
              type="date"
              value={fechaPago}
              onChange={e => setFechaPago(e.target.value)}
              disabled={fechaBloqueada}
              min={fechaBloqueada ? hoy : undefined}
              max={fechaBloqueada ? hoy : undefined}
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:bg-gray-100 dark:disabled:bg-gray-800 disabled:cursor-not-allowed"
            />
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              {fechaBloqueada
                ? 'Como encargado solo podés registrar pagos con fecha de hoy. Si necesitás otra fecha pedíselo a un admin.'
                : 'Se imputa a la rendición de esa fecha. Por defecto hoy.'}
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
            onClick={() => canConfirm && pedirConfirmacion()}
            disabled={!canConfirm}
            className="px-4 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50 disabled:cursor-not-allowed flex items-center"
          >
            {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
            Marcar como Pagados
          </button>
        </div>
      </div>
      <ModalConfirmacion config={confirmConfig} onClose={() => setConfirmConfig(null)} />
    </ModalBase>
  )
})

export default ModalPagosMasivos
