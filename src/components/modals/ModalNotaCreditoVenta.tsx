/**
 * Nota de crédito de VENTA sobre un pedido entregado (#833, mig 274).
 *
 * El cliente aceptó el pedido y después reclamó vencidos. No se devuelve plata:
 * se le reconoce un crédito que queda de saldo a favor en su cuenta corriente y
 * se consume en las compras siguientes. La NC NO modifica el pedido (ni total,
 * ni ítems, ni estado), no mueve stock y no afecta la comisión del vendedor.
 *
 * La cuenta es la de `utils/notaCreditoVenta`; el servidor la rehace con el
 * precio del pedido y revalida las cantidades.
 */
import { useMemo, useState } from 'react'
import { z } from 'zod'
import { AlertTriangle, FileText, Info, Loader2 } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import NumberInput from '../ui/NumberInput'
import { formatPrecio, formatFecha } from '../../utils/formatters'
import {
  LEYENDA_NC_NO_AFECTA_COMISION,
  MOTIVOS_NC_VENTA,
  itemsNotaCreditoParaRPC,
  lineasAcreditables,
  totalNotaCreditoVenta,
  validarNotaCreditoVenta,
  type CantidadesNC,
  type MotivoNCVenta,
} from '../../utils/notaCreditoVenta'
import {
  useCrearNotaCreditoVentaMutation,
  useNotasCreditoVentaPedidoQuery,
} from '../../hooks/queries/useNotasCreditoVentaQuery'
import { useRequestIdEstable } from '../../hooks/useRequestIdEstable'
import { useNotification } from '../../contexts/NotificationContext'
import type { PedidoDB } from '../../types'

// Co-locado a propósito (CLAUDE.md): un modal lazy no valida contra un schema de
// un chunk compartido que un bundle viejo del PWA podría tener desincronizado.
// eslint-disable-next-line react-refresh/only-export-components
export const notaCreditoVentaSchema = z.object({
  motivo: z.enum(['producto_vencido', 'producto_danado', 'otro']),
  observaciones: z.string().max(500, { message: 'Máximo 500 caracteres' }).optional(),
})

export interface ModalNotaCreditoVentaProps {
  pedido: PedidoDB
  onClose: () => void
}

export default function ModalNotaCreditoVenta({ pedido, onClose }: ModalNotaCreditoVentaProps) {
  const notify = useNotification()
  const { data: notasPedido = [], isLoading } = useNotasCreditoVentaPedidoQuery(pedido.id)
  const crear = useCrearNotaCreditoVentaMutation()
  const requestId = useRequestIdEstable()

  const [cantidades, setCantidades] = useState<CantidadesNC>({})
  const [motivo, setMotivo] = useState<MotivoNCVenta>('producto_vencido')
  const [observaciones, setObservaciones] = useState('')
  const [error, setError] = useState<string | null>(null)

  const lineas = useMemo(
    () => lineasAcreditables(pedido.items ?? [], notasPedido),
    [pedido.items, notasPedido],
  )
  const total = totalNotaCreditoVenta(lineas, cantidades)
  const notasVigentes = notasPedido.filter(n => !n.anulada)
  const nada = lineas.every(l => l.disponible <= 0)

  const handleConfirmar = async () => {
    const parsed = notaCreditoVentaSchema.safeParse({ motivo, observaciones: observaciones || undefined })
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? 'Datos inválidos')
      return
    }
    const invalido = validarNotaCreditoVenta(lineas, cantidades)
    if (invalido) {
      setError(invalido)
      return
    }
    setError(null)
    const items = itemsNotaCreditoParaRPC(lineas, cantidades)
    // Mismo UUID mientras no cambie lo que se emite: un reintento tras una
    // respuesta perdida no crea una segunda NC (ledger de pagos, mig 167).
    const huella = `${pedido.id}|${motivo}|${JSON.stringify(items)}`
    try {
      const r = await crear.mutateAsync({
        pedidoId: pedido.id,
        clienteId: pedido.cliente_id,
        items,
        motivo,
        observaciones: observaciones.trim() || null,
        clientRequestId: requestId(huella),
      })
      notify.success(`Nota de crédito #${r.nota_credito_id} por ${formatPrecio(r.total)}: queda como saldo a favor del cliente.`)
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo emitir la nota de crédito')
    }
  }

  return (
    <ModalBase
      title="Nota de crédito (vencidos)"
      description={`Pedido #${pedido.id} · ${pedido.cliente?.nombre_fantasia ?? ''}`}
      onClose={onClose}
      maxWidth="max-w-2xl"
    >
      <div className="space-y-4 p-5">
        <div className="flex items-start gap-2 rounded-lg border border-teal-200 bg-teal-50 p-3 text-sm text-teal-800 dark:border-teal-800 dark:bg-teal-900/20 dark:text-teal-300">
          <Info className="mt-0.5 h-4 w-4 shrink-0" />
          <div>
            <p className="font-semibold">{LEYENDA_NC_NO_AFECTA_COMISION}</p>
            <p>
              El pedido no se modifica y no se mueve stock. El crédito queda como saldo a
              favor en la cuenta corriente del cliente y se usa en sus próximas compras.
            </p>
          </div>
        </div>

        {notasVigentes.length > 0 && (
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Este pedido ya tiene {notasVigentes.length === 1 ? 'una nota de crédito' : `${notasVigentes.length} notas de crédito`}{' '}
            ({notasVigentes.map(n => `#${n.id} ${formatFecha(n.fecha)}`).join(', ')}). Lo ya acreditado se descuenta.
          </p>
        )}

        {isLoading ? (
          <div className="flex justify-center py-8">
            <Loader2 className="h-6 w-6 animate-spin text-teal-600" />
          </div>
        ) : nada ? (
          <div className="flex items-center gap-2 rounded-lg border border-yellow-200 bg-yellow-50 p-3 text-sm text-yellow-800 dark:border-yellow-800 dark:bg-yellow-900/20 dark:text-yellow-300">
            <AlertTriangle className="h-4 w-4 shrink-0" />
            No queda nada por acreditar en este pedido.
          </div>
        ) : (
          <div className="overflow-x-auto rounded-lg border dark:border-gray-700">
            <table className="w-full text-sm">
              <thead className="bg-gray-50 text-gray-600 dark:bg-gray-800 dark:text-gray-400">
                <tr>
                  <th className="px-3 py-2 text-left">Producto</th>
                  <th className="px-3 py-2 text-center">Entregado</th>
                  <th className="px-3 py-2 text-center">A acreditar</th>
                  <th className="px-3 py-2 text-right">Subtotal</th>
                </tr>
              </thead>
              <tbody className="divide-y dark:divide-gray-700">
                {lineas.map(l => {
                  const cant = cantidades[l.pedidoItemId] ?? 0
                  return (
                    <tr key={l.pedidoItemId}>
                      <td className="px-3 py-2">
                        <p className="font-medium text-gray-900 dark:text-white">{l.nombre}</p>
                        <p className="text-xs text-gray-500">{formatPrecio(l.precioUnitario)} c/u</p>
                      </td>
                      <td className="px-3 py-2 text-center text-gray-700 dark:text-gray-300">
                        {l.entregada}
                        {l.yaAcreditada > 0 && (
                          <span className="block text-xs text-orange-600 dark:text-orange-400">
                            {l.yaAcreditada} ya acreditad{l.yaAcreditada === 1 ? 'o' : 'os'}
                          </span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-center">
                        <NumberInput
                          integer
                          min={0}
                          max={l.disponible}
                          value={cant}
                          commitOnChange
                          disabled={l.disponible <= 0}
                          onChange={v => setCantidades(prev => ({ ...prev, [l.pedidoItemId]: v }))}
                          aria-label={`Cantidad a acreditar de ${l.nombre}`}
                          className="w-20 rounded border px-2 py-1 text-center dark:border-gray-600 dark:bg-gray-700 dark:text-white"
                        />
                      </td>
                      <td className="px-3 py-2 text-right tabular-nums text-gray-900 dark:text-white">
                        {cant > 0 ? formatPrecio(cant * l.precioUnitario) : '—'}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}

        <div className="grid gap-3 sm:grid-cols-2">
          <label className="block text-sm">
            <span className="mb-1 block font-medium text-gray-700 dark:text-gray-300">Motivo</span>
            <select
              value={motivo}
              onChange={e => setMotivo(e.target.value as MotivoNCVenta)}
              className="w-full rounded-lg border px-3 py-2 dark:border-gray-600 dark:bg-gray-700 dark:text-white"
            >
              {MOTIVOS_NC_VENTA.map(m => (
                <option key={m.value} value={m.value}>{m.label}</option>
              ))}
            </select>
          </label>
          <label className="block text-sm">
            <span className="mb-1 block font-medium text-gray-700 dark:text-gray-300">Observaciones</span>
            <textarea
              value={observaciones}
              onChange={e => setObservaciones(e.target.value)}
              rows={2}
              maxLength={500}
              className="w-full rounded-lg border px-3 py-2 dark:border-gray-600 dark:bg-gray-700 dark:text-white"
            />
          </label>
        </div>

        {error && (
          <p role="alert" className="text-sm text-red-600 dark:text-red-400">{error}</p>
        )}

        <div className="flex flex-wrap items-center justify-between gap-3 border-t pt-4 dark:border-gray-700">
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Crédito a favor del cliente:{' '}
            <strong className="text-lg text-teal-700 dark:text-teal-300">{formatPrecio(total)}</strong>
          </p>
          <div className="flex gap-2">
            <Button variant="secondary" onClick={onClose} disabled={crear.isPending}>Cancelar</Button>
            <Button
              onClick={() => { void handleConfirmar() }}
              disabled={crear.isPending || nada || total <= 0}
              className="gap-1"
            >
              {crear.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileText className="h-4 w-4" />}
              Emitir nota de crédito
            </Button>
          </div>
        </div>
      </div>
    </ModalBase>
  )
}
