/**
 * ModalPagoPedido — registrar/anular pagos asociados a un pedido especifico.
 *
 * Reemplaza la seccion de pago que vivia dentro de ModalEditarPedido. Soporta
 * dos modos de invocacion:
 *  - Estandar: admin/encargado lo abre desde el dropdown "Registrar Pago".
 *  - `modoEntregaTransportista`: el transportista lo abre cuando marca como
 *    entregado, y puede confirmar "entregar sin pago" o "entregar y registrar
 *    pago" en una misma operacion.
 *
 * Persistencia: cada forma de pago se guarda como una row separada en `pagos`
 * (mejor para reportes que el formato `[Pago combinado: ...]` en notas). El
 * trigger SQL `actualizar_estado_pago_pedido` recalcula `pedidos.estado_pago`
 * y `pedidos.monto_pagado` automaticamente.
 *
 * Sobrepago bloqueado en frontend (totalIngresado > saldoPendiente). Anulacion
 * de pagos previos solo si el caller pasa `onAnularPago` (admin/encargado).
 */
import { memo, useEffect, useMemo, useState } from 'react'
import { Loader2, DollarSign, Plus, Trash2, AlertCircle, X } from 'lucide-react'
import ModalBase from './ModalBase'
import { formatPrecio, fechaLocalISO, formatDateTime, getFormaPagoLabel } from '../../utils/formatters'
import { parsePrecio } from '../../utils/calculations'
import type { PedidoDB, PagoDBWithUsuario } from '../../types'

export interface PagoPedidoPayload {
  pedidoId: string
  clienteId: string
  fechaPago: string
  observaciones?: string
  pagos: Array<{ formaPago: string; monto: number }>
}

export interface ModalPagoPedidoProps {
  pedido: PedidoDB
  pagosPrevios: PagoDBWithUsuario[]
  loadingPagosPrevios?: boolean
  onConfirmar: (payload: PagoPedidoPayload) => Promise<void>
  /** Si esta presente, se permite anular pagos previos (admin/encargado). */
  onAnularPago?: (pagoId: string) => Promise<void>
  /** Activa el flujo "Entregar sin pago / Entregar y registrar pago". */
  modoEntregaTransportista?: boolean
  /** Solo aplica con modoEntregaTransportista. */
  onEntregarSinPago?: () => Promise<void>
  onClose: () => void
  guardando: boolean
}

interface LineaPago {
  formaPago: string
  monto: string
}

const FORMAS_PAGO_OPCIONES: Array<{ value: string; label: string }> = [
  { value: 'efectivo', label: 'Efectivo' },
  { value: 'transferencia', label: 'Transferencia' },
  { value: 'cheque', label: 'Cheque' },
  { value: 'cuenta_corriente', label: 'Cuenta Corriente' },
  { value: 'tarjeta', label: 'Tarjeta' },
]

const ModalPagoPedido = memo(function ModalPagoPedido({
  pedido,
  pagosPrevios,
  loadingPagosPrevios,
  onConfirmar,
  onAnularPago,
  modoEntregaTransportista,
  onEntregarSinPago,
  onClose,
  guardando,
}: ModalPagoPedidoProps) {
  const yaPagado = useMemo(
    () => pagosPrevios.reduce((s, p) => s + (p.monto || 0), 0),
    [pagosPrevios],
  )
  const total = pedido.total || 0
  const saldoPendiente = Math.max(0, total - yaPagado)

  const [fechaPago, setFechaPago] = useState<string>(fechaLocalISO())
  const [observaciones, setObservaciones] = useState<string>('')
  const [lineas, setLineas] = useState<LineaPago[]>([
    { formaPago: 'efectivo', monto: saldoPendiente > 0 ? saldoPendiente.toFixed(2) : '' },
  ])
  const [error, setError] = useState<string>('')

  // Si los pagos previos cambian (anulacion), reajustar la linea por default al saldo restante.
  useEffect(() => {
    if (saldoPendiente > 0 && lineas.length === 1 && (!lineas[0].monto || parsePrecio(lineas[0].monto) === 0)) {
      setLineas([{ formaPago: lineas[0].formaPago, monto: saldoPendiente.toFixed(2) }])
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [saldoPendiente])

  const totalIngresado = useMemo(
    () => lineas.reduce((s, l) => s + parsePrecio(l.monto), 0),
    [lineas],
  )
  const excedeSaldo = totalIngresado > saldoPendiente + 0.001
  const algunMontoValido = lineas.some(l => parsePrecio(l.monto) > 0)

  const handleAgregarLinea = (): void => {
    setLineas(prev => [...prev, { formaPago: 'transferencia', monto: '' }])
  }

  const handleQuitarLinea = (index: number): void => {
    setLineas(prev => prev.filter((_, i) => i !== index))
  }

  const handleLineaChange = (index: number, patch: Partial<LineaPago>): void => {
    setLineas(prev => prev.map((l, i) => (i === index ? { ...l, ...patch } : l)))
  }

  const handleSubmit = async (): Promise<void> => {
    setError('')
    if (saldoPendiente <= 0) {
      setError('El pedido ya esta completamente pagado.')
      return
    }
    if (!algunMontoValido) {
      setError('Ingresa al menos un monto mayor a 0.')
      return
    }
    if (excedeSaldo) {
      setError(
        `El total ingresado (${formatPrecio(totalIngresado)}) excede el saldo pendiente (${formatPrecio(saldoPendiente)}).`,
      )
      return
    }
    if (!fechaPago) {
      setError('Ingresa la fecha de pago.')
      return
    }
    try {
      await onConfirmar({
        pedidoId: String(pedido.id),
        clienteId: String(pedido.cliente_id),
        fechaPago,
        observaciones: observaciones.trim() || undefined,
        pagos: lineas
          .filter(l => parsePrecio(l.monto) > 0)
          .map(l => ({ formaPago: l.formaPago, monto: parsePrecio(l.monto) })),
      })
    } catch (e) {
      setError((e as Error).message || 'Error al registrar el pago')
    }
  }

  const handleEntregarSinPago = async (): Promise<void> => {
    if (!onEntregarSinPago) return
    setError('')
    try {
      await onEntregarSinPago()
    } catch (e) {
      setError((e as Error).message || 'Error al marcar como entregado')
    }
  }

  return (
    <ModalBase
      title={modoEntregaTransportista ? `Entregar Pedido #${pedido.id}` : `Registrar Pago — Pedido #${pedido.id}`}
      description="Registrar o anular pagos del pedido. Cada forma de pago se guarda como un movimiento separado."
      onClose={onClose}
      maxWidth="max-w-xl"
    >
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        {/* Header con totales */}
        <div className="bg-gray-50 dark:bg-gray-700 rounded-lg p-3 border dark:border-gray-600">
          <p className="text-sm text-gray-600 dark:text-gray-400">{pedido.cliente?.nombre_fantasia}</p>
          <div className="mt-2 grid grid-cols-3 gap-2 text-sm">
            <div>
              <p className="text-xs text-gray-500">Total pedido</p>
              <p className="font-semibold dark:text-white">{formatPrecio(total)}</p>
            </div>
            <div>
              <p className="text-xs text-gray-500">Ya pagado</p>
              <p className="font-semibold text-green-700 dark:text-green-400">{formatPrecio(yaPagado)}</p>
            </div>
            <div>
              <p className="text-xs text-gray-500">Saldo pendiente</p>
              <p className={`font-semibold ${saldoPendiente > 0 ? 'text-red-600 dark:text-red-400' : 'text-gray-500'}`}>
                {formatPrecio(saldoPendiente)}
              </p>
            </div>
          </div>
        </div>

        {/* Pagos previos */}
        {loadingPagosPrevios ? (
          <div className="flex items-center gap-2 text-sm text-gray-500">
            <Loader2 className="w-4 h-4 animate-spin" /> Cargando pagos previos...
          </div>
        ) : pagosPrevios.length > 0 && (
          <div className="border dark:border-gray-600 rounded-lg overflow-hidden">
            <div className="bg-gray-50 dark:bg-gray-700 px-3 py-2 text-sm font-medium dark:text-white">
              Pagos previos ({pagosPrevios.length})
            </div>
            <div className="divide-y dark:divide-gray-600">
              {pagosPrevios.map(p => (
                <div key={p.id} className="px-3 py-2 flex items-center justify-between text-sm">
                  <div>
                    <p className="dark:text-white">
                      {formatPrecio(p.monto)}{' '}
                      <span className="text-gray-500">· {getFormaPagoLabel(p.forma_pago)}</span>
                    </p>
                    <p className="text-xs text-gray-500">
                      {p.created_at && formatDateTime(p.created_at)}
                      {p.usuario?.nombre ? ` · ${p.usuario.nombre}` : ''}
                    </p>
                    {p.notas && <p className="text-xs text-gray-400 italic">{p.notas}</p>}
                  </div>
                  {onAnularPago && (
                    <button
                      type="button"
                      onClick={() => { void onAnularPago(p.id) }}
                      disabled={guardando}
                      className="p-1.5 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded disabled:opacity-50"
                      aria-label="Anular pago"
                      title="Anular pago"
                    >
                      <X className="w-4 h-4" />
                    </button>
                  )}
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Form nuevo pago */}
        {saldoPendiente > 0 ? (
          <>
            <div>
              <label className="block text-sm font-medium mb-1 dark:text-gray-200">Fecha de pago</label>
              <input
                type="date"
                value={fechaPago}
                onChange={e => setFechaPago(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              />
            </div>

            <div>
              <div className="flex items-center justify-between mb-1">
                <label className="text-sm font-medium dark:text-gray-200 flex items-center gap-2">
                  <DollarSign className="w-4 h-4 text-green-600" /> Pago
                </label>
                <button
                  type="button"
                  onClick={handleAgregarLinea}
                  className="text-xs text-blue-600 hover:underline flex items-center gap-1"
                >
                  <Plus className="w-3 h-3" /> Agregar forma de pago
                </button>
              </div>
              <div className="space-y-2">
                {lineas.map((linea, index) => (
                  <div key={index} className="flex items-center gap-2">
                    <select
                      value={linea.formaPago}
                      onChange={e => handleLineaChange(index, { formaPago: e.target.value })}
                      className="flex-1 px-2 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                    >
                      {FORMAS_PAGO_OPCIONES.map(o => (
                        <option key={o.value} value={o.value}>{o.label}</option>
                      ))}
                    </select>
                    <div className="relative flex-1">
                      <span className="absolute left-2 top-1/2 -translate-y-1/2 text-gray-400 text-sm">$</span>
                      <input
                        type="number"
                        inputMode="decimal"
                        step="0.01"
                        min="0"
                        value={linea.monto}
                        onChange={e => handleLineaChange(index, { monto: e.target.value })}
                        placeholder="0.00"
                        className="w-full pl-6 pr-2 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white font-semibold"
                      />
                    </div>
                    {lineas.length > 1 && (
                      <button
                        type="button"
                        onClick={() => handleQuitarLinea(index)}
                        className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded"
                        aria-label="Quitar linea de pago"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    )}
                  </div>
                ))}
              </div>
              <div className={`mt-2 text-right text-sm ${excedeSaldo ? 'text-red-600 dark:text-red-400' : 'text-gray-500 dark:text-gray-400'}`}>
                Total a registrar:{' '}
                <span className={`font-bold ${excedeSaldo ? 'text-red-600 dark:text-red-400' : 'text-gray-800 dark:text-white'}`}>
                  {formatPrecio(totalIngresado)}
                </span>
                {excedeSaldo && (
                  <span className="block text-xs">Excede el saldo pendiente ({formatPrecio(saldoPendiente)})</span>
                )}
              </div>
            </div>

            <div>
              <label className="block text-sm font-medium mb-1 dark:text-gray-200">Observaciones (opcional)</label>
              <textarea
                value={observaciones}
                onChange={e => setObservaciones(e.target.value)}
                rows={2}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                placeholder="Notas sobre el pago, numero de transferencia, cheque, etc."
              />
            </div>
          </>
        ) : (
          <div className="bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg p-3 flex items-start gap-2">
            <AlertCircle className="w-5 h-5 text-green-600 flex-shrink-0 mt-0.5" />
            <div className="text-sm">
              <p className="font-medium text-green-800 dark:text-green-300">Pedido completamente pagado</p>
              <p className="text-green-700 dark:text-green-400">No queda saldo pendiente.</p>
            </div>
          </div>
        )}
      </div>

      {error && (
        <div className="mx-4 mb-2 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
          <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
        </div>
      )}

      <div className="flex justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <button
          onClick={onClose}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg"
        >
          Cancelar
        </button>
        {modoEntregaTransportista && onEntregarSinPago && (
          <button
            onClick={() => { void handleEntregarSinPago() }}
            disabled={guardando}
            className="px-4 py-2 bg-amber-600 text-white rounded-lg hover:bg-amber-700 flex items-center disabled:opacity-50"
          >
            {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
            Entregar sin pago
          </button>
        )}
        {saldoPendiente > 0 && (
          <button
            onClick={() => { void handleSubmit() }}
            disabled={guardando || excedeSaldo || !algunMontoValido}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center disabled:opacity-50"
          >
            {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
            {modoEntregaTransportista ? 'Entregar y registrar pago' : 'Registrar pago'}
          </button>
        )}
      </div>
    </ModalBase>
  )
})

export default ModalPagoPedido
