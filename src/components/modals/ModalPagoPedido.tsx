/**
 * ModalPagoPedido — registrar/anular pagos asociados a un pedido especifico.
 *
 * Reemplaza la seccion de pago que vivia dentro de ModalEditarPedido. Soporta
 * dos modos de invocacion:
 *  - Estandar: admin/encargado lo abre desde el dropdown "Registrar Pago".
 *  - `modoEntregaTransportista`: se abre al marcar como entregado. Con saldo,
 *    dos botones: "Entregar a cuenta corriente" (no registra pago, queda
 *    saldo) y "Entregar y registrar pago". Sin saldo, "Confirmar entrega".
 *    Si el pedido no tiene chofer, pregunta quién lo repartió (#1204).
 *
 * Persistencia: cada forma de pago se guarda como una row separada en `pagos`
 * (mejor para reportes que el formato `[Pago combinado: ...]` en notas). El
 * trigger SQL `actualizar_estado_pago_pedido` recalcula `pedidos.estado_pago`
 * y `pedidos.monto_pagado` automaticamente.
 *
 * Sobrepago bloqueado en frontend (totalIngresado > saldoPendiente). Anulacion
 * de pagos previos solo si el caller pasa `onAnularPago` (solo admin).
 */
import { memo, useEffect, useMemo, useRef, useState } from 'react'
import { Loader2, DollarSign, Plus, Trash2, AlertCircle, X } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import NumberInput from '../ui/NumberInput'
import { formatPrecio, fechaLocalISO, formatDateTime, getFormaPagoLabel } from '../../utils/formatters'
import { parsePrecio } from '../../utils/calculations'
import { FORMAS_PAGO_SELECCIONABLES, esFormaPagoNoDineraria } from '../../constants/formasPago'
import { useFechaMinimaPago } from '../../hooks/queries/useUltimaFechaCajaCerradaQuery'
import { useRequestIdEstable } from '../../hooks/useRequestIdEstable'
import CampoQuienRepartio from './CampoQuienRepartio'
import type { EleccionChofer } from '../../utils/choferDeEntrega'
import type { PedidoDB, PagoDBWithUsuario, PerfilDB } from '../../types'

export interface PagoPedidoPayload {
  pedidoId: string
  clienteId: string
  fechaPago: string
  observaciones?: string
  pagos: Array<{ formaPago: string; monto: number }>
  /**
   * UUID de idempotencia por línea de `pagos`, alineado por posición (mig 167).
   * Estable mientras no cambien los montos/formas: un reintento tras un error
   * de red no duplica el cobro.
   */
  clientRequestIds?: string[]
  /** Sólo en modo entrega, si el pedido no tenía chofer (#1204). */
  eleccionChofer?: EleccionChofer
}

/** Entregar sin registrar pago: fecha de la entrega y, si faltaba, el chofer. */
export interface EntregaSinPagoPayload {
  fechaEntrega: string
  eleccionChofer?: EleccionChofer
}

export interface ModalPagoPedidoProps {
  pedido: PedidoDB
  pagosPrevios: PagoDBWithUsuario[]
  loadingPagosPrevios?: boolean
  onConfirmar: (payload: PagoPedidoPayload) => Promise<void>
  /** Si esta presente, se permite anular pagos previos (admin/encargado). */
  onAnularPago?: (pagoId: string) => Promise<void>
  /**
   * Si esta presente, se permite editar la forma de pago de pagos previos
   * (admin/encargado). El backend bloquea la edicion si la rendicion del
   * dia del pago esta cerrada.
   */
  onEditarFormaPago?: (pagoId: string, nuevaForma: string) => Promise<void>
  /**
   * Solo ver y anular pagos previos, sin poder registrar uno nuevo.
   * Es el caso del pedido CANCELADO: cobrarlo no corresponde, pero si tenia
   * pagos hay que poder verlos y anularlos. Antes ese pedido no ofrecia ninguna
   * accion de pago, asi que el unico camino era SQL.
   */
  soloAnulacion?: boolean
  /** Activa el flujo "Entregar sin pago / Entregar y registrar pago". */
  modoEntregaTransportista?: boolean
  /** Solo aplica con modoEntregaTransportista. */
  onEntregarSinPago?: (payload: EntregaSinPagoPayload) => Promise<void>
  /**
   * Modo entrega con un pedido sin chofer (#1204): pide quién lo repartió en
   * la misma pantalla. El server rechaza la entrega sin chofer ni retiro.
   */
  pedirChofer?: boolean
  transportistas?: PerfilDB[]
  /** "Retiró en depósito": sólo admin y encargado. */
  permitirRetiro?: boolean
  onClose: () => void
  guardando: boolean
}

interface LineaPago {
  formaPago: string
  monto: string
}

// Opciones de forma de pago seleccionables. `cuenta_corriente` no es una forma
// de pago: registrar un "pago" en cuenta corriente marcaba el pedido como pagado
// sin que el cliente pagara. Entregar fiado es su propio botón, "Entregar a
// cuenta corriente", que no registra pago y deja el saldo. Entre el #1204 y
// este cambio fue una opción del selector, y el reparto pidió volver al botón:
// es un toque en vez de cambiar la forma y confirmar.
const FORMAS_PAGO_OPCIONES: Array<{ value: string; label: string }> =
  FORMAS_PAGO_SELECCIONABLES.map(m => ({ value: m.value, label: m.label }))

const ModalPagoPedido = memo(function ModalPagoPedido({
  pedido,
  pagosPrevios,
  loadingPagosPrevios,
  onConfirmar,
  onAnularPago,
  onEditarFormaPago,
  soloAnulacion,
  modoEntregaTransportista,
  onEntregarSinPago,
  pedirChofer,
  transportistas = [],
  permitirRetiro = false,
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
  // Fecha minima: dia siguiente al ultimo cierre de caja de la sucursal (mig 134).
  const fechaMinima = useFechaMinimaPago()
  const [observaciones, setObservaciones] = useState<string>('')
  // Arranca VACIO a proposito. El container abre el modal y recien despues
  // resuelve los pagos previos (setPagosPreviosPedido([]) + await refresh...),
  // asi que en el primer render `saldoPendiente` vale el total entero. Con el
  // valor prellenado ahi, un pedido a medias cobrar se abria pidiendo el total,
  // en rojo y con el boton muerto: habia que borrar y retipear a mano. El
  // efecto de abajo lo completa cuando los pagos previos ya estan.
  const [lineas, setLineas] = useState<LineaPago[]>([
    { formaPago: 'efectivo', monto: '' },
  ])
  const [error, setError] = useState<string>('')
  const [eleccionChofer, setEleccionChofer] = useState<EleccionChofer | null>(null)
  const faltaChofer = !!modoEntregaTransportista && !!pedirChofer && !eleccionChofer
  // pagoId en curso de edicion de forma_pago (para mostrar spinner inline).
  const [editandoPagoId, setEditandoPagoId] = useState<string | null>(null)

  // Idempotencia (mig 167): `enVueloRef` corta el doble toque instantaneo y
  // `requestId` hace que el reintento tras un error reuse el mismo UUID, para
  // que el server lo reconozca en vez de volver a cobrar.
  const enVueloRef = useRef<boolean>(false)
  const requestId = useRequestIdEstable()

  // Sugiere el saldo cuando ya se sabe cual es, y lo reajusta si los pagos
  // previos cambian (anulacion). Solo pisa una linea vacia: lo que el usuario
  // haya tipeado no se toca.
  //
  // El gate de `loadingPagosPrevios` es la mitad del fix: sin el, este efecto
  // corria en el primer render —cuando pagosPrevios todavia es []— y dejaba
  // prellenado el total, que ya no volvia a corregirse porque la linea dejaba
  // de estar vacia.
  useEffect(() => {
    if (loadingPagosPrevios) return
    if (saldoPendiente > 0 && lineas.length === 1 && (!lineas[0].monto || parsePrecio(lineas[0].monto) === 0)) {
      setLineas([{ formaPago: lineas[0].formaPago, monto: saldoPendiente.toFixed(2) }])
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [saldoPendiente, loadingPagosPrevios])

  const totalIngresado = useMemo(
    () => lineas.reduce((s, l) => s + parsePrecio(l.monto), 0),
    [lineas],
  )
  const excedeSaldo = totalIngresado > saldoPendiente + 0.001
  const algunMontoValido = lineas.some(l => parsePrecio(l.monto) > 0)

  const handleAgregarLinea = (): void => {
    // Auto-sugerir el saldo restante: cliente pidio que el monto del nuevo
    // renglon se prellene con (saldo - sumaActual). Sigue siendo editable.
    const restante = Math.max(0, saldoPendiente - totalIngresado)
    setLineas(prev => [
      ...prev,
      { formaPago: 'transferencia', monto: restante > 0 ? restante.toFixed(2) : '' },
    ])
  }

  const handleQuitarLinea = (index: number): void => {
    setLineas(prev => prev.filter((_, i) => i !== index))
  }

  const handleLineaChange = (index: number, patch: Partial<LineaPago>): void => {
    setLineas(prev => prev.map((l, i) => (i === index ? { ...l, ...patch } : l)))
  }

  const handleSubmit = async (): Promise<void> => {
    if (enVueloRef.current) return
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
    if (faltaChofer) {
      setError('Elegí quién repartió el pedido.')
      return
    }
    const eleccion = modoEntregaTransportista && pedirChofer && eleccionChofer ? eleccionChofer : undefined
    const pagos = lineas
      .filter(l => parsePrecio(l.monto) > 0)
      .map(l => ({ formaPago: l.formaPago, monto: parsePrecio(l.monto) }))

    // Huella: todo lo que define "este cobro y no otro". Cambiar un monto o una
    // forma de pago acuña UUIDs nuevos; reintentar lo mismo reusa los de antes.
    const huella = [
      pedido.id, fechaPago, observaciones.trim(),
      pagos.map(p => `${p.monto}@${p.formaPago}`).join(','),
    ].join('|')

    enVueloRef.current = true
    try {
      await onConfirmar({
        pedidoId: String(pedido.id),
        clienteId: String(pedido.cliente_id),
        fechaPago,
        observaciones: observaciones.trim() || undefined,
        pagos,
        clientRequestIds: pagos.map((_, i) => requestId(`${huella}#${i}`)),
        ...(eleccion ? { eleccionChofer: eleccion } : {}),
      })
    } catch (e) {
      setError((e as Error).message || 'Error al registrar el pago')
    } finally {
      enVueloRef.current = false
    }
  }

  const handleEditarFormaPago = async (pagoId: string, nuevaForma: string): Promise<void> => {
    if (!onEditarFormaPago) return
    setError('')
    setEditandoPagoId(pagoId)
    try {
      await onEditarFormaPago(pagoId, nuevaForma)
    } catch (e) {
      setError((e as Error).message || 'Error al actualizar forma de pago')
    } finally {
      setEditandoPagoId(null)
    }
  }

  const handleEntregarSinPago = async (fechaEntrega: string): Promise<void> => {
    if (!onEntregarSinPago) return
    setError('')
    if (faltaChofer) {
      setError('Elegí quién repartió el pedido.')
      return
    }
    if (enVueloRef.current) return
    enVueloRef.current = true
    try {
      await onEntregarSinPago({
        fechaEntrega,
        ...(pedirChofer && eleccionChofer ? { eleccionChofer } : {}),
      })
    } catch (e) {
      setError((e as Error).message || 'Error al marcar como entregado')
    } finally {
      enVueloRef.current = false
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
              {pagosPrevios.map(p => {
                const editandoEste = editandoPagoId === p.id
                return (
                  <div key={p.id} className="px-3 py-2 flex items-center justify-between gap-2 text-sm">
                    <div className="min-w-0 flex-1">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="font-medium dark:text-white">{formatPrecio(p.monto)}</span>
                        {/* #832/#833: una forma no dineraria (adelanto de sueldo, crédito de
                            nota de crédito) no cambia de forma (la RPC lo rechaza): se muestra
                            como etiqueta fija. */}
                        {onEditarFormaPago && !esFormaPagoNoDineraria(p.forma_pago) ? (
                          <div className="flex items-center gap-1">
                            <span className="text-gray-400">·</span>
                            <select
                              value={p.forma_pago || 'efectivo'}
                              onChange={e => { void handleEditarFormaPago(p.id, e.target.value) }}
                              disabled={guardando || editandoEste}
                              className="text-xs px-1.5 py-0.5 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white disabled:opacity-50"
                              aria-label="Editar forma de pago"
                              title="Editar forma de pago"
                            >
                              {/* Pago histórico con forma ya no seleccionable (ej: cuenta_corriente):
                                  se muestra deshabilitada para no cambiarla en silencio. */}
                              {p.forma_pago && !FORMAS_PAGO_OPCIONES.some(o => o.value === p.forma_pago) && (
                                <option value={p.forma_pago} disabled>{getFormaPagoLabel(p.forma_pago)}</option>
                              )}
                              {FORMAS_PAGO_OPCIONES.map(o => (
                                <option key={o.value} value={o.value}>{o.label}</option>
                              ))}
                            </select>
                            {editandoEste && <Loader2 className="w-3 h-3 animate-spin text-gray-400" />}
                          </div>
                        ) : (
                          <span className="text-gray-500">· {getFormaPagoLabel(p.forma_pago)}</span>
                        )}
                      </div>
                      <p className="text-xs text-gray-500">
                        {p.created_at && formatDateTime(p.created_at)}
                        {p.usuario?.nombre ? ` · ${p.usuario.nombre}` : ''}
                      </p>
                      {p.notas && <p className="text-xs text-gray-400 italic">{p.notas}</p>}
                    </div>
                    {onAnularPago && (() => {
                      // Un pago de una caja ya cerrada no se anula: se pudo
                      // vaciar plata de rendiciones confirmadas 15 veces, por
                      // $936.100. La mig 181 lo rechaza en la base; acá el botón
                      // se apaga y dice por qué, para no llegar al error crudo.
                      const cajaCerrada = !!fechaMinima && !!p.fecha && p.fecha < fechaMinima
                      return (
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          onClick={() => { if (!cajaCerrada) void onAnularPago(p.id) }}
                          disabled={guardando || cajaCerrada}
                          className="text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 dark:text-red-400"
                          aria-label="Anular pago"
                          title={
                            cajaCerrada
                              ? 'La caja de ese día ya está cerrada. Reabrí la rendición para poder anularlo.'
                              : 'Anular pago'
                          }
                        >
                          <X className="w-4 h-4" />
                        </Button>
                      )
                    })()}
                  </div>
                )
              })}
            </div>
          </div>
        )}

        {/* Aviso del modo solo-anulacion */}
        {soloAnulacion && (
          <div className="rounded-lg border border-amber-300 bg-amber-50 p-3 text-sm text-amber-900 dark:border-amber-700 dark:bg-amber-900/20 dark:text-amber-200">
            Este pedido está <strong>{pedido.estado === 'anulado' ? 'anulado' : 'cancelado'}</strong>. No se pueden registrar pagos
            nuevos; sí se pueden anular los que hayan quedado registrados.
          </div>
        )}

        {modoEntregaTransportista && pedirChofer && (
          <CampoQuienRepartio
            transportistas={transportistas}
            permitirRetiro={permitirRetiro}
            value={eleccionChofer}
            onChange={setEleccionChofer}
          />
        )}

        {/* Form nuevo pago */}
        {!soloAnulacion && saldoPendiente > 0 ? (
          <>
            <div>
              <label className="block text-sm font-medium mb-1 dark:text-gray-200">
                {modoEntregaTransportista ? 'Fecha de entrega y pago' : 'Fecha de pago'}
              </label>
              <input
                type="date"
                value={fechaPago}
                min={fechaMinima}
                // #1246: el server no acepta un pago con fecha futura (y otra
                // fecha que hoy, solo del admin).
                max={fechaLocalISO()}
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
                      <NumberInput
                        min={0}
                        emptyValue={0}
                        commitOnChange
                        value={Number(linea.monto) || 0}
                        onChange={(n) => handleLineaChange(index, { monto: String(n) })}
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

      <div className="flex flex-wrap justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800">
        <Button variant="ghost" size="md" onClick={onClose}>
          Cancelar
        </Button>
        {/* Entrega sin saldo: el pedido ya está cobrado y esto sólo confirma la
            entrega. Ofrecerle "cuenta corriente" al chofer que acaba de recibir
            la plata en la mano lo hacía cancelar, y la parada le quedaba sin
            entregar: sin saldo no hay formulario ni se nombra la cuenta corriente. */}
        {modoEntregaTransportista && onEntregarSinPago && saldoPendiente <= 0 && (
          <Button
            variant="primary"
            size="md"
            onClick={() => { void handleEntregarSinPago(fechaPago) }}
            disabled={guardando || faltaChofer}
            loading={guardando}
          >
            Confirmar entrega
          </Button>
        )}
        {/* Con saldo, entregar fiado es un toque: no registra pago, el saldo
            queda en la cuenta corriente, en la fecha elegida. No mira las
            líneas de pago a propósito: ni un monto en 0 lo traba. */}
        {modoEntregaTransportista && onEntregarSinPago && saldoPendiente > 0 && (
          <Button
            variant="secondary"
            size="md"
            className="border-amber-400 text-amber-800 hover:bg-amber-50 dark:border-amber-600 dark:text-amber-300 dark:hover:bg-amber-900/20"
            onClick={() => { void handleEntregarSinPago(fechaPago) }}
            disabled={guardando || faltaChofer || !fechaPago}
            loading={guardando}
          >
            Entregar a cuenta corriente
          </Button>
        )}
        {!soloAnulacion && saldoPendiente > 0 && (
          <Button
            variant="primary"
            size="md"
            onClick={() => { void handleSubmit() }}
            disabled={guardando || excedeSaldo || !algunMontoValido || faltaChofer}
            loading={guardando}
          >
            {modoEntregaTransportista ? 'Entregar y registrar pago' : 'Registrar pago'}
          </Button>
        )}
      </div>
    </ModalBase>
  )
})

export default ModalPagoPedido
