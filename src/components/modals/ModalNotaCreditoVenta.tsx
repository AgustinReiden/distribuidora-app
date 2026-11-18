/**
 * Nota de crédito de VENTA sobre un pedido entregado (#833, mig 276).
 *
 * El cliente aceptó el pedido y después reclamó vencidos. No se devuelve plata:
 * se le reconoce un crédito en su cuenta corriente. Desde la mig 479 (COB-1) el
 * crédito baja primero este pedido, si sigue impago, y lo que sobra va FIFO a las
 * otras boletas abiertas del cliente; sólo queda de saldo a favor lo que no
 * alcanza a ninguna. La NC NO modifica el pedido (ni total, ni ítems, ni estado).
 * Se imputa al día del pedido; según el motivo le descuenta o no al vendedor, y el
 * modal lo dice al elegirlo (B16, decisiones del dueño del 16/11 y del 17/11).
 *
 * B22 (decisiones del dueño del 17 y 18/11): según el motivo, la mercadería
 * reingresa al stock (a su lote), queda como merma o no se mueve. El motivo no viene
 * elegido (no se emite sin elegirlo), y antes de emitir el modal dice qué va a pasar,
 * con las unidades: «Vuelven al stock 2 u.», «Van a merma 2 u.» o «No mueve stock».
 * Con un motivo que mueve, cada renglón le pide al server que la mueva
 * (`mercaderia: true`); sin eso el server no la mueve (un PWA anterior).
 * Con «descuento comercial» la carga es por MONTO, sin unidades: sobre toda la
 * boleta (en plata o en %, con sus números a la vista), repartido entre los renglones
 * en proporción a lo que le queda a cada uno, sin pasar lo de ninguno; o, en
 * «avanzado», un monto por producto. Un monto que pasa lo que queda va en rojo con
 * «Quedan $ X por acreditar» y no se emite.
 *
 * La cuenta es la de `utils/notaCreditoVenta`; el servidor la rehace con el
 * precio del pedido, revalida las cantidades y los topes, y prorratea.
 *
 * Tras emitir, el modal NO se cierra: dice adónde fue el crédito y, si algo quedó
 * suelto, ofrece imputarlo ya mismo a otro pedido del cliente (nunca al de origen)
 * o dejarlo como saldo a favor. La imputación se muestra inline, dentro de este
 * mismo modal Radix.
 */
import { Suspense, useMemo, useState } from 'react'
import { z } from 'zod'
import { AlertTriangle, CheckCircle, FileText, Info, Loader2 } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import NumberInput from '../ui/NumberInput'
import { CampoNumero } from '../ui/CampoNumero'
import { formatPrecio, formatFecha } from '../../utils/formatters'
import {
  LEYENDA_NC_COMISION,
  MOTIVOS_NC_VENTA,
  diaEmisionNotaCreditoVenta,
  esMotivoPorMonto,
  itemsDescuentoParaRPC,
  leyendaMercaderiaNCVenta,
  leyendaMotivoNCVenta,
  leyendaPorcentajeNC,
  itemsNotaCreditoParaRPC,
  lineasAcreditables,
  lineasReparticionCreditoNC,
  montoDePorcentaje,
  montoDisponibleBoleta,
  montoUnidadesNC,
  reparticionCreditoNC,
  repartoDescuentoNC,
  resumenMercaderiaNC,
  totalDescuentoNC,
  totalNotaCreditoVenta,
  unidadesNotaCreditoVenta,
  validarDescuentoNC,
  validarNotaCreditoVenta,
  type CantidadesNC,
  type MontosNC,
  type MotivoNCVenta,
} from '../../utils/notaCreditoVenta'
import {
  leerDecimalSinMiles,
  leerNumero,
  motivoPlataTipeada,
  motivoSinMilesTipeado,
} from '../../utils/normalizarNumero'
import { redondearSQL } from '../../utils/calculations'
import {
  useCrearNotaCreditoVentaMutation,
  useNotasCreditoVentaPedidoQuery,
} from '../../hooks/queries/useNotasCreditoVentaQuery'
import { useRequestIdPersistente } from '../../hooks/useRequestIdPersistente'
import { useNotification } from '../../contexts/NotificationContext'
import { lazyWithReload } from '../../utils/lazyWithReload'
import type { CrearNotaCreditoVentaResult } from '../../hooks/queries/useNotasCreditoVentaQuery'
import type { PedidoDB } from '../../types'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'
import { AvisoCamposEnRojo } from '../ui/AvisoCamposEnRojo'

const ModalImputarCredito = lazyWithReload(() => import('./ModalImputarCredito'))

const TITULO_NC = 'Nota de crédito de venta'

// Co-locado a propósito (CLAUDE.md): un modal lazy no valida contra un schema de
// un chunk compartido que un bundle viejo del PWA podría tener desincronizado.
// eslint-disable-next-line react-refresh/only-export-components
export const notaCreditoVentaSchema = z.object({
  // Los de nc_venta_motivos() (B16 v3): lo vigila constants/motivosNCVenta.espejo.test.ts.
  motivo: z.enum([
    'cliente_rechaza',
    'error_pedido',
    'error_entrega',
    'producto_vencido',
    'producto_danado',
    'descuento_comercial',
    'otro',
  ]),
  observaciones: z.string().max(500, { message: 'Máximo 500 caracteres' }).optional(),
})

// B22: el descuento comercial por monto. Co-locado por la misma razón. El tope (lo que le
// queda a la boleta o al renglón) lo mira validarDescuentoNC, y el server de nuevo.
// eslint-disable-next-line react-refresh/only-export-components
export const descuentoNCVentaSchema = z.object({
  modo: z.enum(['boleta', 'productos']),
  total: z.number().finite().positive({ message: 'El descuento tiene que ser mayor a $0' }),
})

type ModoDescuento = 'boleta' | 'productos'

/**
 * El rojo de un monto de plata (H8 de la revisión): lo que no se entiende, o más de lo que queda
 * por acreditar. No se apoya en el recorte de un `max`: lo que pasa se ve y no se emite.
 */
function motivoMontoNC(texto: string, queda: number): string | null {
  const ilegible = motivoPlataTipeada(texto)
  if (ilegible) return ilegible
  const n = leerNumero(texto)
  if (n != null && redondearSQL(n, 2) > queda + 0.005) return `Quedan ${formatPrecio(queda)} por acreditar`
  return null
}

/** El rojo del porcentaje: lo que no se entiende, o más de 100 %. */
function motivoPorcentajeNC(texto: string): string | null {
  const ilegible = motivoSinMilesTipeado(texto)
  if (ilegible) return ilegible
  const n = leerDecimalSinMiles(texto)
  if (n != null && n > 100) return 'Hasta 100 %: es un porcentaje de lo que queda por acreditar'
  return null
}

export interface ModalNotaCreditoVentaProps {
  pedido: PedidoDB
  onClose: () => void
}

export default function ModalNotaCreditoVenta({ pedido, onClose }: ModalNotaCreditoVentaProps) {
  const notify = useNotification()
  const { data: notasPedido = [], isLoading } = useNotasCreditoVentaPedidoQuery(pedido.id)
  const crear = useCrearNotaCreditoVentaMutation()
  const { requestId, olvidar } = useRequestIdPersistente()
  // B20: los campos de número en rojo frenan el guardado.
  const ilegibles = useRegistroIlegibles()

  const [cantidades, setCantidades] = useState<CantidadesNC>({})
  // B22 (H1 de la revisión): sin motivo elegido de entrada. Lo que hace con la mercadería depende
  // de él, y un motivo puesto de oficio movía stock sin que nadie lo eligiera.
  const [motivo, setMotivo] = useState<MotivoNCVenta | ''>('')
  // B22: el descuento comercial por monto. Los campos guardan el texto tipeado; se lee con el
  // mismo lector que decide el rojo (leerNumero en la plata, leerDecimalSinMiles en el %).
  const [modoDescuento, setModoDescuento] = useState<ModoDescuento>('boleta')
  const [enPorcentaje, setEnPorcentaje] = useState(false)
  const [valorDescuento, setValorDescuento] = useState('')
  const [montosTexto, setMontosTexto] = useState<Readonly<Record<string, string>>>({})
  const [observaciones, setObservaciones] = useState('')
  const [error, setError] = useState<string | null>(null)
  // Paso final: la NC ya está emitida. `imputando` muestra la imputación inline.
  const [emitida, setEmitida] = useState<CrearNotaCreditoVentaResult | null>(null)
  const [imputando, setImputando] = useState(false)

  const lineas = useMemo(
    () => lineasAcreditables(pedido.items ?? [], notasPedido),
    [pedido.items, notasPedido],
  )
  const porMonto = esMotivoPorMonto(motivo)
  const quedaBoleta = montoDisponibleBoleta(lineas)
  const pct = enPorcentaje ? leerDecimalSinMiles(valorDescuento) : null
  const montoBoleta = enPorcentaje ? montoDePorcentaje(lineas, pct ?? 0) : (leerNumero(valorDescuento) ?? 0)
  const motivoValor = enPorcentaje ? motivoPorcentajeNC(valorDescuento) : motivoMontoNC(valorDescuento, quedaBoleta)
  const montos: MontosNC = Object.fromEntries(Object.entries(montosTexto).map(([k, t]) => [k, leerNumero(t) ?? 0]))
  const montosDescuento = modoDescuento === 'productos' ? montos : null
  const unidades = porMonto ? 0 : unidadesNotaCreditoVenta(cantidades)
  const reparto = porMonto && modoDescuento === 'boleta' && montoBoleta > 0 && montoBoleta <= quedaBoleta + 0.005
    ? repartoDescuentoNC(lineas, montoBoleta)
    : []
  const total = porMonto ? totalDescuentoNC(montoBoleta, montosDescuento) : totalNotaCreditoVenta(lineas, cantidades)
  const notasVigentes = notasPedido.filter(n => !n.anulada)
  const nada = porMonto ? quedaBoleta <= 0 : lineas.every(l => l.disponible <= 0)

  const handleConfirmar = async () => {
    if (ilegibles.hay) return
    if (!motivo) {
      setError('Elegí el motivo de la nota de crédito')
      return
    }
    const parsed = notaCreditoVentaSchema.safeParse({ motivo, observaciones: observaciones || undefined })
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? 'Datos inválidos')
      return
    }
    const invalido = porMonto
      ? validarDescuentoNC(lineas, montoBoleta, montosDescuento)
      : validarNotaCreditoVenta(lineas, cantidades)
    if (invalido) {
      setError(invalido)
      return
    }
    if (porMonto) {
      const desc = descuentoNCVentaSchema.safeParse({ modo: modoDescuento, total })
      if (!desc.success) {
        setError(desc.error.issues[0]?.message ?? 'Datos inválidos')
        return
      }
    }
    setError(null)
    const items = porMonto
      ? itemsDescuentoParaRPC(lineas, montoBoleta, montosDescuento)
      : itemsNotaCreditoParaRPC(lineas, cantidades, motivo)
    // Mismo UUID mientras no cambie lo que se emite: un reintento tras una
    // respuesta perdida no crea una segunda NC (ledger de pagos, mig 167), aunque
    // se cierre el modal o se recargue la app (#1410).
    const huella = `nc|${pedido.id}|${motivo}|${JSON.stringify(items)}`
    try {
      const r = await crear.mutateAsync({
        pedidoId: pedido.id,
        clienteId: pedido.cliente_id,
        items,
        motivo,
        observaciones: observaciones.trim() || null,
        clientRequestId: requestId(huella),
      })
      olvidar([huella])
      const lineas = lineasReparticionCreditoNC(reparticionCreditoNC(r))
      notify.success(
        `Nota de crédito #${r.nota_credito_id} por ${formatPrecio(r.total)}.` +
        (lineas.length > 0 ? ` ${lineas.join('. ')}.` : ''),
      )
      setEmitida(r)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo emitir la nota de crédito')
    }
  }

  if (emitida) {
    const reparto = reparticionCreditoNC(emitida)
    const lineasReparto = lineasReparticionCreditoNC(reparto)
    // Sólo se ofrece imputar lo que quedó suelto: el resto ya bajó boletas.
    const haySuelto = reparto.disponible > 0.005
    return (
      <ModalBase
        title={TITULO_NC}
        description={`Pedido #${pedido.id} · ${pedido.cliente?.nombre_fantasia ?? ''}`}
        onClose={onClose}
        maxWidth="max-w-2xl"
      >
        <div className="space-y-4 p-5">
          <div className="flex items-start gap-2 rounded-lg border border-green-200 bg-green-50 p-3 text-sm text-green-800 dark:border-green-800 dark:bg-green-900/20 dark:text-green-300">
            <CheckCircle className="mt-0.5 h-5 w-5 shrink-0" />
            <div>
              <p className="font-semibold">
                Crédito de {formatPrecio(emitida.total)} emitido (nota de crédito #{emitida.nota_credito_id}).
              </p>
              {lineasReparto.length > 0 && (
                <ul className="mt-1 list-disc pl-5">
                  {lineasReparto.map(l => <li key={l}>{l}</li>)}
                </ul>
              )}
              {!imputando && haySuelto && <p className="mt-1">¿Imputar lo que quedó a favor ahora a un pedido?</p>}
            </div>
          </div>

          {imputando ? (
            <Suspense
              fallback={(
                <div className="flex justify-center py-8">
                  <Loader2 className="h-6 w-6 animate-spin text-teal-600" />
                </div>
              )}
            >
              <ModalImputarCredito
                inline
                clienteId={String(pedido.cliente_id)}
                credito={{
                  pagoId: String(emitida.pago_id),
                  monto: reparto.disponible,
                  notaCreditoId: String(emitida.nota_credito_id),
                  pedidoOrigenId: String(pedido.id),
                }}
                onClose={onClose}
              />
            </Suspense>
          ) : (
            <div className="flex flex-wrap justify-end gap-2 border-t pt-4 dark:border-gray-700">
              {haySuelto ? (
                <>
                  <Button variant="secondary" onClick={onClose}>Dejar como saldo a favor</Button>
                  <Button onClick={() => setImputando(true)}>Imputar a un pedido</Button>
                </>
              ) : (
                <Button onClick={onClose}>Cerrar</Button>
              )}
            </div>
          )}
        </div>
      </ModalBase>
    )
  }

  return (
<RegistroIlegiblesContext.Provider value={ilegibles.registro}>
    <ModalBase
      title={TITULO_NC}
      description={`Pedido #${pedido.id} · ${pedido.cliente?.nombre_fantasia ?? ''}`}
      onClose={onClose}
      maxWidth="max-w-2xl"
    >
      <div className="space-y-4 p-5">
        <div className="flex items-start gap-2 rounded-lg border border-teal-200 bg-teal-50 p-3 text-sm text-teal-800 dark:border-teal-800 dark:bg-teal-900/20 dark:text-teal-300">
          <Info className="mt-0.5 h-4 w-4 shrink-0" />
          <div>
            <p className="font-semibold">{LEYENDA_NC_COMISION}</p>
            <p>
              El pedido no se modifica. El crédito baja primero este pedido,
              si todavía debe algo, y lo que sobra va a las otras boletas abiertas del cliente,
              de la más vieja a la más nueva. Sólo queda de saldo a favor lo que no alcanza a ninguna.
            </p>
          </div>
        </div>

        {notasVigentes.length > 0 && (
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Este pedido ya tiene {notasVigentes.length === 1 ? 'una nota de crédito' : `${notasVigentes.length} notas de crédito`}{' '}
            ({notasVigentes.map(n => `#${n.id} del ${formatFecha(diaEmisionNotaCreditoVenta(n))}`).join(', ')}). Lo ya acreditado se descuenta.
          </p>
        )}

        <label className="block text-sm">
          <span className="mb-1 block font-medium text-gray-700 dark:text-gray-300">Motivo</span>
          <select
            value={motivo}
            onChange={e => { setMotivo(e.target.value as MotivoNCVenta | ''); setError(null) }}
            className="w-full rounded-lg border px-3 py-2 dark:border-gray-600 dark:bg-gray-700 dark:text-white"
          >
            <option value="" disabled>Elegí el motivo</option>
            {MOTIVOS_NC_VENTA.map(m => (
              <option key={m.value} value={m.value}>{m.label}</option>
            ))}
          </select>
          {motivo && (
            <>
              <span className="mt-1 block text-xs text-gray-600 dark:text-gray-400">{leyendaMotivoNCVenta(motivo)}</span>
              <span className="mt-0.5 block text-xs text-gray-600 dark:text-gray-400">{leyendaMercaderiaNCVenta(motivo)}</span>
            </>
          )}
        </label>

        {isLoading ? (
          <div className="flex justify-center py-8">
            <Loader2 className="h-6 w-6 animate-spin text-teal-600" />
          </div>
        ) : nada ? (
          <div className="flex items-center gap-2 rounded-lg border border-yellow-200 bg-yellow-50 p-3 text-sm text-yellow-800 dark:border-yellow-800 dark:bg-yellow-900/20 dark:text-yellow-300">
            <AlertTriangle className="h-4 w-4 shrink-0" />
            No queda nada por acreditar en este pedido.
          </div>
        ) : porMonto ? (
          <div className="space-y-3 rounded-lg border p-3 dark:border-gray-700">
            <fieldset className="flex flex-wrap gap-4 text-sm">
              <legend className="sr-only">Sobre qué va el descuento</legend>
              <label className="flex cursor-pointer items-center gap-2 dark:text-gray-200">
                <input
                  type="radio"
                  name="modo-descuento"
                  checked={modoDescuento === 'boleta'}
                  onChange={() => setModoDescuento('boleta')}
                />
                Sobre toda la boleta
              </label>
              <label className="flex cursor-pointer items-center gap-2 dark:text-gray-200">
                <input
                  type="radio"
                  name="modo-descuento"
                  checked={modoDescuento === 'productos'}
                  onChange={() => setModoDescuento('productos')}
                />
                Sobre productos (avanzado)
              </label>
            </fieldset>
            <p className="text-sm text-gray-600 dark:text-gray-400">
              Queda por acreditar de la boleta: <strong>{formatPrecio(quedaBoleta)}</strong>.
            </p>

            {modoDescuento === 'boleta' ? (
              <>
                <div className="flex flex-wrap items-center gap-2 text-sm">
                  <fieldset className="flex gap-3">
                    <legend className="sr-only">En plata o en porcentaje</legend>
                    <label className="flex cursor-pointer items-center gap-1 dark:text-gray-200">
                      <input type="radio" name="unidad-descuento" checked={!enPorcentaje}
                        onChange={() => { setEnPorcentaje(false); setValorDescuento('') }} />
                      $
                    </label>
                    <label className="flex cursor-pointer items-center gap-1 dark:text-gray-200">
                      <input type="radio" name="unidad-descuento" checked={enPorcentaje}
                        onChange={() => { setEnPorcentaje(true); setValorDescuento('') }} />
                      %
                    </label>
                  </fieldset>
                  <CampoNumero
                    key={enPorcentaje ? 'pct' : 'plata'}
                    sinMiles={enPorcentaje}
                    value={valorDescuento}
                    onChange={setValorDescuento}
                    motivo={motivoValor}
                    aria-label={enPorcentaje ? 'Porcentaje del descuento' : 'Monto del descuento'}
                    className="w-32 rounded border px-2 py-1 text-right dark:border-gray-600 dark:bg-gray-700 dark:text-white"
                  />
                </div>
                {enPorcentaje && pct != null && pct > 0 && !motivoValor && (
                  <p className="text-sm text-gray-700 dark:text-gray-300">{leyendaPorcentajeNC(lineas, pct)}</p>
                )}
                {reparto.length > 0 && (
                  <div className="overflow-x-auto">
                    <p className="mb-1 text-xs font-medium text-gray-600 dark:text-gray-400">Cómo se reparte</p>
                    <table className="w-full text-sm">
                      <tbody className="divide-y dark:divide-gray-700">
                        {reparto.map(r => (
                          <tr key={r.pedidoItemId}>
                            <td className="py-1 text-gray-900 dark:text-white">{r.nombre}</td>
                            <td className="py-1 text-right tabular-nums text-gray-900 dark:text-white">{formatPrecio(r.monto)}</td>
                          </tr>
                        ))}
                      </tbody>
                    </table>
                  </div>
                )}
              </>
            ) : (
              <div className="overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="text-gray-600 dark:text-gray-400">
                    <tr>
                      <th className="px-2 py-1 text-left">Producto</th>
                      <th className="px-2 py-1 text-right">Le queda</th>
                      <th className="px-2 py-1 text-right">A descontar</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y dark:divide-gray-700">
                    {lineas.map(l => (
                      <tr key={l.pedidoItemId}>
                        <td className="px-2 py-1 text-gray-900 dark:text-white">{l.nombre}</td>
                        <td className="px-2 py-1 text-right tabular-nums text-gray-700 dark:text-gray-300">{formatPrecio(l.montoDisponible)}</td>
                        <td className="px-2 py-1 text-right">
                          <CampoNumero
                            value={montosTexto[l.pedidoItemId] ?? ''}
                            onChange={t => setMontosTexto(prev => ({ ...prev, [l.pedidoItemId]: t }))}
                            motivo={motivoMontoNC(montosTexto[l.pedidoItemId] ?? '', l.montoDisponible)}
                            disabled={l.montoDisponible <= 0}
                            aria-label={`Monto a descontar de ${l.nombre}`}
                            className="w-28 rounded border px-2 py-1 text-right dark:border-gray-600 dark:bg-gray-700 dark:text-white"
                          />
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
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
                        {cant > 0 ? formatPrecio(montoUnidadesNC(l, cant)) : '—'}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}

        {motivo && !nada && !isLoading && (
          <p role="status" className="rounded-lg border border-gray-200 bg-gray-50 px-3 py-2 text-sm font-medium text-gray-800 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200">
            {resumenMercaderiaNC(motivo, unidades)}
          </p>
        )}

        <div>
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
          <div className="text-sm text-gray-600 dark:text-gray-400">
            <p>
              Total a acreditar:{' '}
              <strong className="text-lg text-teal-700 dark:text-teal-300">{formatPrecio(total)}</strong>
            </p>
            <p className="text-xs">
              Pedido de origen #{pedido.id} · el crédito se aplica a las boletas abiertas del cliente
            </p>
          </div>
          {/* N4/T2: dice por qué está frenado el Guardar y lleva al campo en rojo. */}
          <AvisoCamposEnRojo className="w-full basis-full" />
          <div className="flex gap-2">
            <Button variant="secondary" onClick={onClose} disabled={crear.isPending}>Cancelar</Button>
            <Button
              onClick={() => { void handleConfirmar() }}
              disabled={crear.isPending || nada || !motivo || total <= 0 || ilegibles.hay}
              className="gap-1"
            >
              {crear.isPending ? <Loader2 className="h-4 w-4 animate-spin" /> : <FileText className="h-4 w-4" />}
              Emitir nota de crédito
            </Button>
          </div>
        </div>
      </div>
    </ModalBase>
    </RegistroIlegiblesContext.Provider>
  )
}
