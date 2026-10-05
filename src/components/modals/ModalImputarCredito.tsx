/**
 * Imputar un crédito a favor del cliente a un pedido ELEGIDO.
 *
 * El crédito es una fila de `pagos` sin pedido: una nota de crédito de venta
 * (mig 276) o un pago a cuenta / anticipo. La imputación automática (FIFO) lo
 * aplica a los pedidos más viejos; esto es para cuando el encargado quiere
 * elegir a cuál. La RPC `imputar_credito_a_pedido` imputa LEAST(crédito,
 * faltante, monto) y deja el resto a favor.
 *
 * Dos formas de mostrarse:
 *   - como modal propio (desde la ficha del cliente);
 *   - `inline`, sin ModalBase, para el paso final de ModalNotaCreditoVenta: la
 *     confirmación tiene que quedar DENTRO del modal Radix que ya está abierto.
 * En los dos casos la confirmación se pide acá mismo, no en un modal hermano.
 */
import { useMemo, useRef, useState } from 'react'
import { z } from 'zod'
import { AlertTriangle, ArrowRightLeft, Info, Loader2 } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import NumberInput from '../ui/NumberInput'
import { formatPrecio, formatFecha } from '../../utils/formatters'
import {
  calcularImputacion,
  pedidosImputables,
  validarMontoImputacion,
  TOLERANCIA_CENTAVOS,
} from '../../utils/imputacionCredito'
import {
  useImputarCreditoMutation,
  usePedidoOrigenNCQuery,
  usePedidosParaImputarQuery,
  type ImputarCreditoResult,
} from '../../hooks/queries/useImputarCreditoQuery'
import { useRequestIdEstable } from '../../hooks/useRequestIdEstable'
import { useNotification } from '../../contexts/NotificationContext'

// Co-locado a propósito (CLAUDE.md): un modal lazy no valida contra un schema de
// un chunk compartido que un bundle viejo del PWA podría tener desincronizado.
// Los ids llegan como number en runtime: z.coerce.string().
// eslint-disable-next-line react-refresh/only-export-components
export const imputarCreditoSchema = z.object({
  pagoId: z.coerce.string().min(1, { message: 'Falta el crédito a imputar' }),
  pedidoId: z.coerce.string().min(1, { message: 'Elegí un pedido' }),
  monto: z.coerce
    .number({ error: 'El monto debe ser un número' })
    .positive({ message: 'El monto a imputar tiene que ser mayor a $0' }),
})

export interface CreditoAImputar {
  /** Fila de `pagos` sin pedido que se imputa. */
  pagoId: string
  monto: number
  /** Si sale de una nota de crédito de venta. */
  notaCreditoId?: string | null
  /** Pedido del que salió la NC: no se le puede imputar. Si falta, se busca. */
  pedidoOrigenId?: string | null
}

export interface ModalImputarCreditoProps {
  clienteId: string
  credito: CreditoAImputar
  onClose: () => void
  /** Después de imputar (antes de cerrar): para que la ficha refresque su estado local. */
  onImputado?: (r: ImputarCreditoResult) => void
  /** Sin ModalBase: para incrustarlo en un modal que ya está abierto. */
  inline?: boolean
}

export default function ModalImputarCredito({ clienteId, credito, onClose, onImputado, inline = false }: ModalImputarCreditoProps) {
  const notify = useNotification()
  const esNC = !!credito.notaCreditoId
  const { data: pedidos = [], isLoading: cargandoPedidos, error: errorPedidos } = usePedidosParaImputarQuery(clienteId)
  const { data: origenBuscado, isLoading: cargandoOrigen } = usePedidoOrigenNCQuery(
    credito.notaCreditoId,
    esNC && !credito.pedidoOrigenId,
  )
  const pedidoOrigenId = credito.pedidoOrigenId ?? origenBuscado ?? null
  const imputar = useImputarCreditoMutation()
  const requestId = useRequestIdEstable()
  // Corta el doble toque antes de que React re-renderice con isPending (mismo
  // patrón que ModalRegistrarPago); el UUID estable cubre el reintento tras un error.
  const enVueloRef = useRef(false)

  const opciones = useMemo(
    () => pedidosImputables(pedidos, { pedidoOrigenId }),
    [pedidos, pedidoOrigenId],
  )

  const [pedidoElegido, setPedidoElegido] = useState<string>('')
  // `null` = el monto por defecto (todo lo posible para el pedido elegido).
  const [montoManual, setMontoManual] = useState<number | null>(null)
  const [confirmando, setConfirmando] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const pedido = opciones.find(p => p.id === pedidoElegido) ?? opciones[0] ?? null
  const montoPorDefecto = pedido ? calcularImputacion(credito.monto, pedido.faltante).monto : 0
  const monto = montoManual ?? montoPorDefecto
  const invalido = pedido ? validarMontoImputacion(monto, credito.monto, pedido.faltante) : null
  const preview = pedido && !invalido ? calcularImputacion(credito.monto, pedido.faltante, monto) : null

  const cargando = cargandoPedidos || (esNC && !credito.pedidoOrigenId && cargandoOrigen)
  const origenTexto = esNC
    ? `Nota de crédito #${credito.notaCreditoId}${pedidoOrigenId ? ` (origen pedido #${pedidoOrigenId})` : ''}`
    : 'Pago a cuenta'

  const cambiarPedido = (id: string) => {
    setPedidoElegido(id)
    setMontoManual(null)
    setConfirmando(false)
    setError(null)
  }

  const pedirConfirmacion = () => {
    const parsed = imputarCreditoSchema.safeParse({ pagoId: credito.pagoId, pedidoId: pedido?.id ?? '', monto })
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? 'Datos inválidos')
      return
    }
    if (invalido) {
      setError(invalido)
      return
    }
    setError(null)
    setConfirmando(true)
  }

  const handleImputar = async () => {
    if (enVueloRef.current || !pedido || !preview) return
    enVueloRef.current = true
    setError(null)
    // Mismo UUID mientras no cambie qué se imputa a dónde: un reintento tras una
    // respuesta perdida no imputa dos veces.
    const huella = `${credito.pagoId}|${pedido.id}|${preview.monto}`
    try {
      const r = await imputar.mutateAsync({
        pagoId: credito.pagoId,
        pedidoId: pedido.id,
        monto: preview.monto,
        clientRequestId: requestId(huella),
      })
      notify.success(
        `Se imputaron ${formatPrecio(r.montoImputado)} al pedido #${r.pedidoId}` +
        (r.restoAFavor > TOLERANCIA_CENTAVOS ? `. Quedan ${formatPrecio(r.restoAFavor)} a favor del cliente.` : '.'),
      )
      onImputado?.(r)
      onClose()
    } catch (err) {
      setConfirmando(false)
      setError(err instanceof Error ? err.message : 'No se pudo imputar el crédito')
    } finally {
      enVueloRef.current = false
    }
  }

  const contenido = (
    <div className={inline ? 'space-y-4' : 'space-y-4 p-5'}>
      <div className="rounded-lg border border-teal-200 bg-teal-50 p-3 text-sm text-teal-800 dark:border-teal-800 dark:bg-teal-900/20 dark:text-teal-300">
        <p className="text-xs uppercase tracking-wide opacity-80">Crédito a favor</p>
        <p className="text-lg font-bold">{formatPrecio(credito.monto)}</p>
        <p>{origenTexto}</p>
      </div>

      {cargando ? (
        <div className="flex justify-center py-8">
          <Loader2 className="h-6 w-6 animate-spin text-teal-600" aria-label="Cargando pedidos" />
        </div>
      ) : errorPedidos ? (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">No se pudieron cargar los pedidos del cliente.</p>
      ) : opciones.length === 0 ? (
        <div className="flex items-start gap-2 rounded-lg border border-gray-200 bg-gray-50 p-3 text-sm text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300">
          <Info className="mt-0.5 h-4 w-4 shrink-0" />
          <p>
            El cliente no tiene pedidos con saldo pendiente
            {esNC && pedidoOrigenId ? ` (sin contar el pedido #${pedidoOrigenId}, del que salió la nota de crédito)` : ''}.
            El crédito queda a favor y se va a usar en su próxima compra.
          </p>
        </div>
      ) : (
        <>
          <label className="block text-sm">
            <span className="mb-1 block font-medium text-gray-700 dark:text-gray-300">Pedido</span>
            <select
              value={pedido?.id ?? ''}
              onChange={e => cambiarPedido(e.target.value)}
              disabled={imputar.isPending}
              className="w-full rounded-lg border px-3 py-2 dark:border-gray-600 dark:bg-gray-700 dark:text-white"
            >
              {opciones.map(p => (
                <option key={p.id} value={p.id}>
                  Pedido #{p.id} · {formatFecha(p.fecha)} · falta {formatPrecio(p.faltante)}
                </option>
              ))}
            </select>
          </label>

          <label className="block text-sm">
            <span className="mb-1 block font-medium text-gray-700 dark:text-gray-300">Monto a imputar</span>
            <NumberInput
              min={0}
              value={monto}
              commitOnChange
              disabled={imputar.isPending}
              onChange={v => { setMontoManual(v); setConfirmando(false); setError(null) }}
              aria-label="Monto a imputar"
              className="w-full rounded-lg border px-3 py-2 dark:border-gray-600 dark:bg-gray-700 dark:text-white"
            />
            {pedido && (
              <span className="mt-1 block text-xs text-gray-500 dark:text-gray-400">
                Máximo {formatPrecio(montoPorDefecto)}
              </span>
            )}
          </label>

          {invalido ? (
            <p role="alert" className="text-sm text-red-600 dark:text-red-400">{invalido}</p>
          ) : preview && pedido && (
            <p className="text-sm text-gray-700 dark:text-gray-300" data-testid="preview-imputacion">
              Se imputan <strong>{formatPrecio(preview.monto)}</strong> al pedido #{pedido.id} · quedan{' '}
              <strong>{formatPrecio(preview.resto)}</strong> a favor
            </p>
          )}

          {esNC && (
            <p className="flex items-start gap-2 rounded-lg border border-yellow-200 bg-yellow-50 p-2 text-xs text-yellow-800 dark:border-yellow-800 dark:bg-yellow-900/20 dark:text-yellow-300">
              <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
              Una vez imputada, la nota de crédito ya no se puede anular.
            </p>
          )}
        </>
      )}

      {error && !invalido && (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">{error}</p>
      )}

      {confirmando && preview && pedido ? (
        <div className="space-y-2 rounded-lg border border-teal-300 bg-teal-50 p-3 dark:border-teal-700 dark:bg-teal-900/20">
          <p className="text-sm text-teal-900 dark:text-teal-200">
            ¿Imputar <strong>{formatPrecio(preview.monto)}</strong> al pedido #{pedido.id}?
            {preview.resto > TOLERANCIA_CENTAVOS && <> Quedan {formatPrecio(preview.resto)} a favor del cliente.</>}
          </p>
          <div className="flex justify-end gap-2">
            <Button variant="secondary" size="sm" disabled={imputar.isPending} onClick={() => setConfirmando(false)}>
              Volver
            </Button>
            <Button size="sm" disabled={imputar.isPending} loading={imputar.isPending} onClick={() => { void handleImputar() }}>
              Sí, imputar
            </Button>
          </div>
        </div>
      ) : (
        <div className="flex justify-end gap-2 border-t pt-4 dark:border-gray-700">
          <Button variant="secondary" onClick={onClose} disabled={imputar.isPending}>
            {opciones.length === 0 && !cargando ? 'Cerrar' : 'Cancelar'}
          </Button>
          {opciones.length > 0 && !cargando && (
            <Button onClick={pedirConfirmacion} disabled={imputar.isPending || !preview} className="gap-1">
              <ArrowRightLeft className="h-4 w-4" />
              Imputar
            </Button>
          )}
        </div>
      )}
    </div>
  )

  if (inline) return contenido
  return (
    <ModalBase title="Imputar crédito a un pedido" description={origenTexto} onClose={onClose} maxWidth="max-w-lg">
      {contenido}
    </ModalBase>
  )
}
