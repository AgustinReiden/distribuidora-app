/**
 * Pestaña "Notas de crédito" de la ficha del cliente (#833, mig 276).
 *
 * Lista las NCs de venta del cliente (vigentes y anuladas) con su detalle. La
 * anulación es sólo admin y se confirma acá mismo, dentro del modal Radix de la
 * ficha (una confirmación hermana quedaría detrás del overlay). El servidor la
 * rechaza si el crédito ya se aplicó a algún pedido; el mensaje se muestra tal
 * cual. Si la ficha le pasa los pagos del cliente, eso ya se sabe antes: el
 * botón «Anular» no se ofrece y se explica por qué, y la NC con crédito libre
 * ofrece «Imputar a pedido».
 */
import { useState } from 'react'
import { AlertTriangle, FileMinus, Info, Loader2, XCircle } from 'lucide-react'
import { Button } from '../ui/Button'
import { Badge } from '../ui/Badge'
import { formatPrecio, formatFecha } from '../../utils/formatters'
import {
  LEYENDA_NC_NO_AFECTA_COMISION,
  motivoNCVentaLabel,
  totalNotasCreditoVigentes,
} from '../../utils/notaCreditoVenta'
import {
  useAnularNotaCreditoVentaMutation,
  useNotasCreditoVentaClienteQuery,
} from '../../hooks/queries/useNotasCreditoVentaQuery'
import { useNotification } from '../../contexts/NotificationContext'
import { estadoCreditoNotaCredito, TOLERANCIA_CENTAVOS, type PagoDeCredito } from '../../utils/imputacionCredito'
import type { CreditoAImputar } from './ModalImputarCredito'

export interface NotasCreditoVentaClienteProps {
  clienteId: string
  puedeAnular: boolean
  /** Para refrescar el saldo y los pagos de la ficha tras anular. */
  onCambio?: () => void
  /**
   * Pagos del cliente (los que ya tiene la ficha): de ahí sale cuánto crédito de
   * cada NC sigue libre y cuánto ya se imputó. Sin ellos no se sabe y la lista
   * se comporta como antes.
   */
  pagos?: ReadonlyArray<PagoDeCredito>
  /** Abre la imputación del crédito libre de una NC. Sin esto no se ofrece. */
  onImputar?: (credito: CreditoAImputar) => void
}

export default function NotasCreditoVentaCliente({ clienteId, puedeAnular, onCambio, pagos, onImputar }: NotasCreditoVentaClienteProps) {
  const notify = useNotification()
  const { data: notas = [], isLoading, error } = useNotasCreditoVentaClienteQuery(clienteId)
  const anular = useAnularNotaCreditoVentaMutation()
  const [anulandoId, setAnulandoId] = useState<string | null>(null)
  const [motivoAnulacion, setMotivoAnulacion] = useState('')

  const handleAnular = async (id: string) => {
    try {
      await anular.mutateAsync({ notaCreditoId: id, motivo: motivoAnulacion.trim() || null })
      notify.success(`Nota de crédito #${id} anulada. Se quitó el crédito del cliente.`)
      setAnulandoId(null)
      setMotivoAnulacion('')
      onCambio?.()
    } catch (err) {
      notify.error(err instanceof Error ? err.message : 'No se pudo anular la nota de crédito')
    }
  }

  if (isLoading) {
    return (
      <div className="flex justify-center py-12">
        <Loader2 className="h-6 w-6 animate-spin text-teal-600" />
      </div>
    )
  }
  if (error) {
    return <p className="py-8 text-center text-sm text-red-600">No se pudieron cargar las notas de crédito.</p>
  }

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h3 className="font-semibold text-gray-900 dark:text-white">Notas de crédito</h3>
        {notas.length > 0 && (
          <span className="text-sm text-gray-600 dark:text-gray-400">
            Vigentes: <strong>{formatPrecio(totalNotasCreditoVigentes(notas))}</strong>
          </span>
        )}
      </div>
      <p className="flex items-center gap-2 rounded-lg bg-teal-50 p-2 text-xs text-teal-800 dark:bg-teal-900/20 dark:text-teal-300">
        <Info className="h-4 w-4 shrink-0" />
        {LEYENDA_NC_NO_AFECTA_COMISION}. El crédito queda como saldo a favor y aparece en Pagos como “Nota de crédito”.
      </p>

      {notas.length === 0 ? (
        <div className="py-12 text-center text-gray-500">
          <FileMinus className="mx-auto mb-3 h-12 w-12 opacity-50" />
          <p>No hay notas de crédito</p>
        </div>
      ) : (
        notas.map(nc => {
          const credito = pagos ? estadoCreditoNotaCredito(pagos, nc.id) : null
          const yaAplicada = !!credito && credito.aplicado > TOLERANCIA_CENTAVOS
          const pagoLibre = credito?.pagoLibre && credito.pagoLibre.monto > TOLERANCIA_CENTAVOS ? credito.pagoLibre : null
          return (
          <div
            key={nc.id}
            className={`rounded-xl p-4 ${nc.anulada ? 'bg-gray-100 opacity-70 dark:bg-gray-800' : 'bg-gray-50 dark:bg-gray-700/50'}`}
          >
            <div className="flex flex-wrap items-start justify-between gap-2">
              <div>
                <p className="font-semibold text-gray-900 dark:text-white">
                  NC #{nc.id} · {formatPrecio(nc.total)}
                </p>
                <p className="text-sm text-gray-500">
                  {formatFecha(nc.fecha)} • {motivoNCVentaLabel(nc.motivo)} • Pedido #{nc.pedido_id}
                </p>
                {nc.observaciones && <p className="mt-1 text-sm text-gray-400">{nc.observaciones}</p>}
              </div>
              <div className="flex items-center gap-2">
                {nc.anulada
                  ? <Badge tone="danger" icon={XCircle}>Anulada</Badge>
                  : <Badge tone="brand">No afecta comisión</Badge>}
                {onImputar && !nc.anulada && pagoLibre && (
                  <Button
                    variant="secondary"
                    size="sm"
                    onClick={() => onImputar({
                      pagoId: pagoLibre.id,
                      monto: pagoLibre.monto,
                      notaCreditoId: String(nc.id),
                      pedidoOrigenId: String(nc.pedido_id),
                    })}
                  >
                    Imputar a pedido
                  </Button>
                )}
                {puedeAnular && !nc.anulada && !yaAplicada && anulandoId !== String(nc.id) && (
                  <Button variant="ghost" size="sm" onClick={() => setAnulandoId(String(nc.id))}>
                    Anular
                  </Button>
                )}
              </div>
            </div>

            {credito && !nc.anulada && (
              <p className="mt-1 text-sm text-gray-600 dark:text-gray-300">
                Crédito disponible: <strong>{formatPrecio(credito.disponible)}</strong>
                {yaAplicada && <> · ya imputado a pedidos: {formatPrecio(credito.aplicado)}</>}
              </p>
            )}
            {puedeAnular && !nc.anulada && yaAplicada && (
              <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                No se puede anular: ya se aplicaron {formatPrecio(credito!.aplicado)} del crédito a pedidos del cliente.
              </p>
            )}

            {nc.items && nc.items.length > 0 && (
              <ul className="mt-2 space-y-0.5 text-sm text-gray-600 dark:text-gray-300">
                {nc.items.map(it => (
                  <li key={it.id} className="flex justify-between gap-2">
                    <span>{it.cantidad} × {it.producto?.nombre ?? `Producto #${it.producto_id}`}</span>
                    <span className="tabular-nums">{formatPrecio(it.subtotal)}</span>
                  </li>
                ))}
              </ul>
            )}

            {nc.anulada && (
              <p className="mt-2 text-xs text-gray-500">
                Anulada el {formatFecha(nc.anulada_at ?? '')}{nc.motivo_anulacion ? ` · ${nc.motivo_anulacion}` : ''}
              </p>
            )}

            {anulandoId === String(nc.id) && (
              <div className="mt-3 space-y-2 rounded-lg border border-red-200 bg-red-50 p-3 dark:border-red-800 dark:bg-red-900/20">
                <p className="flex items-start gap-2 text-sm text-red-700 dark:text-red-300">
                  <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" />
                  <span>
                    ¿Anular la nota de crédito #{nc.id}? Se quita el crédito de{' '}
                    <strong>{formatPrecio(nc.total)}</strong> del cliente. Si ya se usó en algún
                    pedido no se puede anular.
                  </span>
                </p>
                <input
                  type="text"
                  value={motivoAnulacion}
                  onChange={e => setMotivoAnulacion(e.target.value)}
                  placeholder="Motivo (opcional)"
                  aria-label="Motivo de la anulación"
                  className="w-full rounded border px-2 py-1 text-sm dark:border-gray-600 dark:bg-gray-700 dark:text-white"
                />
                <div className="flex justify-end gap-2">
                  <Button variant="secondary" size="sm" disabled={anular.isPending} onClick={() => setAnulandoId(null)}>
                    Cancelar
                  </Button>
                  <Button variant="danger" size="sm" disabled={anular.isPending} onClick={() => { void handleAnular(String(nc.id)) }}>
                    {anular.isPending ? 'Anulando…' : 'Sí, anular'}
                  </Button>
                </div>
              </div>
            )}
          </div>
          )
        })
      )}
    </div>
  )
}
