/**
 * ModalLiquidar — liquidar el período pendiente más viejo de un empleado (entrega 4 de gastos).
 *
 * La liquidación suma a su cuenta el sueldo, las comisiones y los ajustes, y registra el pago en
 * la misma acción. El sueldo viene del arreglo vigente al empezar el período y se corrige a mano,
 * con motivo. Las comisiones las calcula el server y quedan congeladas al confirmar. El front manda
 * lo que vio (`a_pagar_esperado`): si algo cambió en el medio el server rechaza, y el modal vuelve
 * a pedir la vista previa para que se vean los números nuevos.
 *
 * Se renderiza DENTRO de los children del `ModalBase` de la cuenta: como hermano quedaría detrás
 * del overlay de Radix y fallaría en silencio.
 */
import React, { useId, useState } from 'react'
import type { FormEvent, ReactNode } from 'react'
import { AlertTriangle, Check, Info, Loader2 } from 'lucide-react'
import { z } from 'zod'
import ModalBase from './ModalBase'
import SelectorPlata from './SelectorPlata'
import QueryErrorState from '../layout/QueryErrorState'
import { Button } from '../ui/Button'
import { cn } from '../../lib/utils'
import {
  useLiquidarEmpleadoMutation,
  useVistaPreviaLiquidacionQuery,
} from '../../hooks/queries/usePersonalQuery'
import { useNotification } from '../../contexts/NotificationContext'
import { getErrorMessage } from '../../utils/errorHandling'
import { formatCurrency, formatPrecio } from '../../utils/formatters'
import {
  MENSAJE_MONTO_ILEGIBLE,
  MENSAJE_SIN_RENDICION_DEL_PAGO,
  MENSAJE_SIN_SUELDO,
  PLATA_OFICINA,
  aPagar,
  conceptoDeMovimiento,
  errorDePago,
  errorDeSueldo,
  etiquetaPuesto,
  fechaCompleta,
  parseMonto,
  textoPeriodo,
} from '../../utils/personal'
import type {
  AvisoLiquidacion,
  Empleado,
  LiquidarPayload,
  PlataDelPago,
  VistaPreviaLiquidacion,
} from '../../types/personal'

const MENSAJE_RENDICION_FUTURA = 'La rendición no puede ser de un día que todavía no llegó'
const MENSAJE_SIN_PAGO = 'Escribí cuánto le pagás: 0 si no le pagás nada'
const MENSAJE_PERIODO_CAMBIO = 'El período cambió mientras estaba abierta: cerrá y volvé a abrir la liquidación'

// Schema CO-LOCADO a propósito (no en lib/schemas.ts): ver ModalCambioProducto.tsx
// para el incidente de chunk desincronizado que motivó la regla.
// Los campos de texto son los del formulario; `hoy`, `propuesto` y `vista` son el contexto que
// las reglas necesitan (el tope del pago depende del sueldo tipeado).
// eslint-disable-next-line react-refresh/only-export-components
export const modalLiquidarSchema = z
  .object({
    sueldo: z.string(),
    motivo_sueldo: z.string(),
    pago: z.string(),
    fecha_pago: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, { message: 'Elegí la fecha del pago' }),
    origen_pago: z.enum(['oficina', 'rendicion']),
    rendicion_transportista_id: z.string().nullable(),
    rendicion_fecha: z.string().nullable(),
    hoy: z.string(),
    propuesto: z.number(),
    vista: z.custom<Parameters<typeof aPagar>[0]>(v => typeof v === 'object' && v !== null),
  })
  .superRefine((f, ctx) => {
    const sueldo = f.sueldo.trim() ? parseMonto(f.sueldo) : null
    if (sueldo === null) {
      const mensaje = f.sueldo.trim() ? MENSAJE_MONTO_ILEGIBLE : MENSAJE_SIN_SUELDO
      ctx.addIssue({ code: 'custom', message: mensaje, path: ['sueldo'] })
      return
    }
    const errorSueldo = errorDeSueldo(sueldo, f.propuesto, f.motivo_sueldo)
    if (errorSueldo) {
      ctx.addIssue({ code: 'custom', message: errorSueldo, path: ['motivo_sueldo'] })
      return
    }

    // En blanco no es 0: pagar nada se escribe. Lo que no se entiende también se avisa.
    const pago = f.pago.trim() ? parseMonto(f.pago) : null
    if (pago === null) {
      const mensaje = f.pago.trim() ? MENSAJE_MONTO_ILEGIBLE : MENSAJE_SIN_PAGO
      ctx.addIssue({ code: 'custom', message: mensaje, path: ['pago'] })
      return
    }
    const errorDelPago = errorDePago(pago, aPagar(f.vista, sueldo), f.fecha_pago, f.hoy)
    if (errorDelPago) {
      ctx.addIssue({ code: 'custom', message: errorDelPago, path: ['pago'] })
      return
    }

    if (pago > 0 && f.origen_pago === 'rendicion') {
      if (!f.rendicion_transportista_id || !f.rendicion_fecha) {
        ctx.addIssue({ code: 'custom', message: MENSAJE_SIN_RENDICION_DEL_PAGO, path: ['rendicion_transportista_id'] })
      } else if (f.rendicion_fecha > f.hoy) {
        ctx.addIssue({ code: 'custom', message: MENSAJE_RENDICION_FUTURA, path: ['rendicion_fecha'] })
      }
    }
  })

export interface ModalLiquidarProps {
  empleado: Pick<Empleado, 'id' | 'nombre' | 'puesto' | 'sucursal_id' | 'de_las_dos'>
  nombreSucursal: (id: number) => string
  transportistas: Array<{ id: string; nombre: string }>
  hoy: string
  onClose: () => void
}

const CLASE_INPUT =
  'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white'
const CLASE_ETIQUETA = 'block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1'

const requerido = <span className="text-red-500">*</span>

const AVISOS: Record<AvisoLiquidacion, string> = {
  comisiona_sin_usuario: 'Comisiona, pero no tiene un usuario vinculado: no se le pueden calcular pedidos.',
  arreglo_cambia: 'El arreglo cambia en este período: revisá el sueldo.',
  periodo_parcial: 'Entró o se fue en este período: revisá el sueldo.',
}

/** El importe como lo muestra un campo: '994.560,00'. */
const textoMonto = (n: number): string => formatCurrency(n, false)

/** '+$1.000,00' o '−$1.000,00'. */
const conSigno = (n: number): string => `${n < 0 ? '−' : '+'}${formatPrecio(Math.abs(n))}`

const colorImporte = (n: number): string =>
  n > 0 ? 'text-emerald-700 dark:text-emerald-300' : n < 0 ? 'text-rose-700 dark:text-rose-300' : 'text-stone-500'

const diaYMes = (f: string): string => `${f.slice(8, 10)}/${f.slice(5, 7)}`

function Fila({
  titulo, detalle, importe, children,
}: { titulo: ReactNode; detalle?: ReactNode; importe: ReactNode; children?: ReactNode }) {
  return (
    <div className="px-4 py-3">
      <div className="flex items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="font-medium text-gray-900 dark:text-white">{titulo}</div>
          {detalle && <div className="text-xs text-gray-500 dark:text-gray-400">{detalle}</div>}
        </div>
        <div className="whitespace-nowrap">{importe}</div>
      </div>
      {children}
    </div>
  )
}

export default function ModalLiquidar({
  empleado, nombreSucursal, transportistas, hoy, onClose,
}: ModalLiquidarProps): React.ReactElement {
  const id = useId()
  const notify = useNotification()
  const { data: vista, isLoading, isError, refetch } = useVistaPreviaLiquidacionQuery(empleado.id)
  const liquidar = useLiquidarEmpleadoMutation()

  // `null` = sin tocar: el sueldo es el propuesto y el pago sigue a «A pagar».
  const [sueldoTxt, setSueldoTxt] = useState<string | null>(null)
  const [motivoSueldo, setMotivoSueldo] = useState('')
  const [pagoTxt, setPagoTxt] = useState<string | null>(null)
  const [plata, setPlata] = useState<PlataDelPago>(PLATA_OFICINA)
  const [fechaPago, setFechaPago] = useState(hoy)
  const [verPedidos, setVerPedidos] = useState(false)
  // El período que se mostró al abrir. Un refetch (tras un rechazo, por ejemplo) puede traer el
  // siguiente en este mismo modal, con lo tipeado para el anterior: ahí no se deja confirmar.
  const [periodoAbierto, setPeriodoAbierto] = useState<{ desde: string; hasta: string } | null>(null)
  if (vista && periodoAbierto === null) {
    setPeriodoAbierto({ desde: vista.periodo.desde, hasta: vista.periodo.hasta })
  }
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  const handleEscapeKeyDown = (event: KeyboardEvent) => {
    // Radix escucha Escape en captura, antes que el buscador: con la lista
    // abierta, Escape tiene que cerrar sólo la lista (ver ModalCompra).
    const enfocado = document.activeElement
    const comboboxAbierto = enfocado?.getAttribute('role') === 'combobox' &&
      enfocado.getAttribute('aria-expanded') === 'true'
    if (comboboxAbierto) event.preventDefault()
  }

  let cuerpo: ReactNode
  if (isLoading) {
    cuerpo = (
      <div className="flex items-center justify-center gap-2 py-16 text-sm text-gray-500">
        <Loader2 className="w-5 h-5 animate-spin" aria-hidden="true" />
        Cargando liquidación…
      </div>
    )
  } else if (isError && !vista) {
    cuerpo = <QueryErrorState onRetry={() => { void refetch() }} />
  } else if (!vista) {
    cuerpo = <p className="py-12 text-center text-sm text-gray-500">No hay nada para liquidar.</p>
  } else {
    cuerpo = renderFormulario(vista)
  }

  function renderFormulario(v: VistaPreviaLiquidacion): ReactNode {
    const { periodo } = v
    const propuesto = v.sueldo.propuesto
    const textoSueldo = sueldoTxt ?? textoMonto(propuesto)
    // Mientras se tipea algo ilegible, «A pagar» no salta: sigue con el último sueldo entendible.
    const sueldoLeido = textoSueldo.trim() ? parseMonto(textoSueldo) : null
    const sueldo = sueldoLeido ?? propuesto
    const difiere = sueldoLeido !== null && Math.abs(sueldoLeido - propuesto) >= 0.005

    const total = aPagar(v, sueldo)
    const debe = total < 0
    const sinPagar = total <= 0.005
    const textoPago = sinPagar ? textoMonto(0) : (pagoTxt ?? textoMonto(total))
    const pagoLeido = textoPago.trim() ? parseMonto(textoPago) : 0
    const hayPago = pagoLeido === null || pagoLeido > 0
    const periodoCambio = periodoAbierto !== null
      && (periodoAbierto.desde !== periodo.desde || periodoAbierto.hasta !== periodo.hasta)

    const pedidos = v.comisiones.detalle
    const hayPedidos = pedidos.length > 0
    const n = pedidos.length

    const handleSubmit = async (e: FormEvent<HTMLFormElement>) => {
      e.preventDefault()
      if (periodoCambio) return
      setError('')

      const conRendicion = plata.origen_pago === 'rendicion'
      const fecha = conRendicion ? (plata.rendicion_fecha ?? '') : fechaPago
      const resultado = modalLiquidarSchema.safeParse({
        sueldo: textoSueldo,
        motivo_sueldo: motivoSueldo,
        pago: textoPago,
        // Sin pago el campo no se ve: la fecha no se valida ni se manda.
        fecha_pago: hayPago ? fecha : hoy,
        origen_pago: plata.origen_pago,
        rendicion_transportista_id: plata.rendicion_transportista_id,
        rendicion_fecha: plata.rendicion_fecha,
        hoy,
        propuesto,
        vista: v,
      })
      if (!resultado.success) {
        setError(resultado.error.issues[0]?.message ?? 'Revisá los datos de la liquidación')
        return
      }

      // El schema ya garantizó que los dos se entienden.
      const sueldoFinal = parseMonto(textoSueldo) as number
      const pagoFinal = parseMonto(textoPago) as number
      const sale: PlataDelPago = pagoFinal > 0 && conRendicion ? plata : PLATA_OFICINA
      const liquidacion: LiquidarPayload = {
        desde: periodo.desde,
        hasta: periodo.hasta,
        sueldo: sueldoFinal,
        motivo_sueldo: Math.abs(sueldoFinal - propuesto) >= 0.005 ? motivoSueldo.trim() : null,
        pago: pagoFinal,
        fecha_pago: pagoFinal === 0 ? hoy : conRendicion ? (plata.rendicion_fecha as string) : fechaPago,
        a_pagar_esperado: aPagar(v, sueldoFinal),
        ...sale,
      }

      setGuardando(true)
      try {
        await liquidar.mutateAsync({ empleadoId: empleado.id, liquidacion })
      } catch (err) {
        // getErrorMessage, no `err instanceof Error`: el error de supabase-js es un objeto plano.
        setError(getErrorMessage(err))
        // «Algo cambió…» se resuelve viendo los números nuevos.
        void refetch()
        return
      } finally {
        setGuardando(false)
      }
      notify.success('Liquidación registrada')
      onClose()
    }

    return (
      <form
        onSubmit={handleSubmit}
        // Confirmar es sólo con el botón: Enter en un campo no registra un pago (que sale de una
        // rendición que después se puede cerrar). El buscador de choferes elige con su propio Enter.
        onKeyDown={ev => { if (ev.key === 'Enter' && ev.target instanceof HTMLInputElement) ev.preventDefault() }}
      >
        <p className="px-4 pt-3 text-sm text-gray-500 dark:text-gray-400">
          {`${etiquetaPuesto(empleado.puesto)} · ${empleado.de_las_dos ? 'Las dos' : nombreSucursal(empleado.sucursal_id)} · se le paga por ${periodo.frecuencia === 'semanal' ? 'semana' : 'mes'}`}
        </p>

        <div className="p-4 space-y-4">
          <div>
            <span className={CLASE_ETIQUETA}>Período</span>
            <p className="text-gray-800 dark:text-gray-100 font-medium">
              {`${textoPeriodo(periodo)} · ${diaYMes(periodo.desde)} al ${diaYMes(periodo.hasta)}`}
            </p>
            {periodo.mas_vencidos > 0 && (
              <p className="mt-1 text-xs text-gray-500">
                {`Quedan ${periodo.mas_vencidos} ${periodo.mas_vencidos === 1 ? 'período' : 'períodos'} más sin liquidar.`}
              </p>
            )}
            {v.en_curso && (
              <p className="mt-1 text-xs text-gray-500">
                Este período todavía no terminó: lo que se entregue después entra en el siguiente.
              </p>
            )}
          </div>

          {v.avisos.map(a => (
            <div
              key={a}
              role="status"
              className="flex items-start gap-3 p-3 rounded-xl border border-amber-200 bg-amber-50 dark:bg-amber-900/20 dark:border-amber-800"
            >
              <AlertTriangle className="w-5 h-5 shrink-0 mt-0.5 text-amber-600" aria-hidden="true" />
              <p className="text-sm text-amber-800 dark:text-amber-200">{AVISOS[a]}</p>
            </div>
          ))}

          <div className="rounded-xl border border-gray-200 dark:border-gray-700 overflow-hidden">
            <div className="divide-y divide-gray-200 dark:divide-gray-700 text-sm">
              <Fila
                titulo={<label htmlFor={`${id}-sueldo`}>Sueldo fijo</label>}
                detalle={v.sueldo.arreglo_desde ? `Arreglo vigente desde el ${fechaCompleta(v.sueldo.arreglo_desde)}` : undefined}
                importe={(
                  <div className="relative w-40">
                    <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" aria-hidden="true">$</span>
                    <input
                      id={`${id}-sueldo`}
                      type="text"
                      inputMode="decimal"
                      autoComplete="off"
                      value={textoSueldo}
                      onChange={ev => setSueldoTxt(ev.target.value)}
                      className={cn(CLASE_INPUT, 'pl-7 text-right')}
                    />
                  </div>
                )}
              >
                {difiere && (
                  <div className="mt-2">
                    <label htmlFor={`${id}-motivo`} className={CLASE_ETIQUETA}>
                      Por qué cambia el sueldo {requerido}
                    </label>
                    <input
                      id={`${id}-motivo`}
                      type="text"
                      autoComplete="off"
                      value={motivoSueldo}
                      onChange={ev => setMotivoSueldo(ev.target.value)}
                      className={CLASE_INPUT}
                    />
                  </div>
                )}
              </Fila>

              {hayPedidos && (
                <Fila
                  titulo="Comisiones"
                  detalle={(
                    <>
                      {`${n} ${n === 1 ? 'pedido entregado' : 'pedidos entregados'} sin liquidar · base ${formatPrecio(v.comisiones.base)} · `}
                      <button
                        type="button"
                        onClick={() => setVerPedidos(o => !o)}
                        aria-expanded={verPedidos}
                        className="text-brand-600 dark:text-brand-400 font-medium hover:underline"
                      >
                        {verPedidos ? 'ocultar pedidos' : 'ver pedidos'}
                      </button>
                    </>
                  )}
                  importe={<span className={cn('font-medium', colorImporte(v.comisiones.total))}>{conSigno(v.comisiones.total)}</span>}
                >
                  {verPedidos && (
                    <div className="mt-2 rounded-lg border border-gray-200 dark:border-gray-700 overflow-x-auto">
                      <table className="w-full text-xs">
                        <thead className="bg-gray-50 dark:bg-gray-900">
                          <tr>
                            <th scope="col" className="px-3 py-2 text-left font-medium text-gray-700 dark:text-gray-300">Pedido</th>
                            <th scope="col" className="px-3 py-2 text-left font-medium text-gray-700 dark:text-gray-300">Entregado</th>
                            <th scope="col" className="px-3 py-2 text-left font-medium text-gray-700 dark:text-gray-300">Cliente</th>
                            <th scope="col" className="px-3 py-2 text-right font-medium text-gray-700 dark:text-gray-300">Base</th>
                            <th scope="col" className="px-3 py-2 text-right font-medium text-gray-700 dark:text-gray-300">Comisión</th>
                          </tr>
                        </thead>
                        <tbody className="divide-y divide-gray-200 dark:divide-gray-700">
                          {pedidos.map(p => (
                            <tr key={p.pedido_id}>
                              <td className="px-3 py-2 whitespace-nowrap">{`#${p.pedido_id}`}</td>
                              <td className="px-3 py-2 whitespace-nowrap text-gray-500">{fechaCompleta(p.entregado_el)}</td>
                              <td className="px-3 py-2">{p.cliente}</td>
                              <td className="px-3 py-2 text-right tabular-nums whitespace-nowrap">{formatPrecio(p.base)}</td>
                              <td className="px-3 py-2 text-right tabular-nums whitespace-nowrap">{formatPrecio(p.comision)}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  )}
                </Fila>
              )}

              {v.ajustes.detalle.map(a => (
                <Fila
                  key={`${a.pedido_id}-${a.motivo}`}
                  titulo="Ajuste de comisión"
                  detalle={`${a.motivo} · pedido #${a.pedido_id}`}
                  importe={<span className={cn('font-medium', colorImporte(a.comision))}>{conSigno(a.comision)}</span>}
                />
              ))}

              {v.movimientos.map(m => {
                const { titulo, detalle } = conceptoDeMovimiento(m)
                return (
                  <Fila
                    key={m.id}
                    titulo={(
                      <span className="flex items-center gap-2 flex-wrap">
                        {titulo}
                        {m.por_el_mismo && (
                          <span className="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-200">
                            Lo cargó su propio usuario
                          </span>
                        )}
                      </span>
                    )}
                    detalle={detalle ?? undefined}
                    importe={<span className={cn('font-medium', colorImporte(m.monto))}>{conSigno(m.monto)}</span>}
                  />
                )
              })}

              <Fila
                titulo="Saldo anterior"
                detalle={Math.abs(v.saldo_anterior) < 0.005 ? 'Sin saldo pendiente' : undefined}
                importe={<span className="font-medium text-gray-700 dark:text-gray-200">{formatPrecio(v.saldo_anterior)}</span>}
              />

              <div className="flex items-center justify-between gap-3 px-4 py-3 bg-gray-50 dark:bg-gray-900">
                <p className="font-semibold text-gray-900 dark:text-white">{debe ? 'Queda debiendo' : 'A pagar'}</p>
                <p
                  data-testid="a-pagar"
                  className={cn('text-2xl font-bold tabular-nums', debe ? 'text-rose-700 dark:text-rose-300' : 'text-gray-900 dark:text-white')}
                >
                  {formatPrecio(Math.abs(total))}
                </p>
              </div>
            </div>
          </div>

          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label htmlFor={`${id}-pago`} className={CLASE_ETIQUETA}>Monto que se le paga</label>
              <div className="relative">
                <span className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400" aria-hidden="true">$</span>
                <input
                  id={`${id}-pago`}
                  type="text"
                  inputMode="decimal"
                  autoComplete="off"
                  value={textoPago}
                  disabled={sinPagar}
                  onChange={ev => setPagoTxt(ev.target.value)}
                  className={cn(CLASE_INPUT, 'pl-7 text-right font-semibold')}
                />
              </div>
              <p className="mt-1 text-xs text-gray-500">
                Si se le paga menos, lo que falta queda a su favor en la cuenta.
              </p>
            </div>
            {hayPago && plata.origen_pago === 'oficina' && (
              <div>
                <label htmlFor={`${id}-fecha`} className={CLASE_ETIQUETA}>Fecha del pago</label>
                <input
                  id={`${id}-fecha`}
                  type="date"
                  value={fechaPago}
                  max={hoy}
                  onChange={ev => setFechaPago(ev.target.value)}
                  className={CLASE_INPUT}
                />
              </div>
            )}
          </div>

          {hayPago && (
            <SelectorPlata valor={plata} onChange={setPlata} transportistas={transportistas} hoy={hoy} />
          )}

          {hayPedidos && (
            <div className="flex items-start gap-3 p-3 rounded-xl border border-blue-200 bg-blue-50 dark:bg-blue-900/20 dark:border-blue-800">
              <Info className="w-5 h-5 shrink-0 mt-0.5 text-blue-600" aria-hidden="true" />
              <p className="text-xs text-blue-800 dark:text-blue-200">
                {`Al confirmar, las comisiones de esos ${n} pedidos quedan fijas. Un pedido que se entregue después entra en la próxima liquidación, y una salvedad sobre uno ya liquidado entra como ajuste.`}
              </p>
            </div>
          )}

          {periodoCambio && (
            <div role="alert" className="p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
              <p className="text-sm text-amber-800 dark:text-amber-200">{MENSAJE_PERIODO_CAMBIO}</p>
            </div>
          )}

          {error && (
            <div role="alert" className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            </div>
          )}
        </div>

        <div className="flex gap-3 p-4 border-t border-gray-200 dark:border-gray-700">
          <Button type="button" variant="secondary" size="md" onClick={onClose} className="flex-1">
            Cancelar
          </Button>
          <Button type="submit" variant="primary" size="md" loading={guardando} disabled={guardando || periodoCambio} className="flex-1">
            <Check className="w-4 h-4" aria-hidden="true" />
            Confirmar y registrar el pago
          </Button>
        </div>
      </form>
    )
  }

  return (
    <ModalBase
      title={`Liquidar a ${empleado.nombre}`}
      onClose={onClose}
      maxWidth="max-w-2xl"
      onEscapeKeyDown={handleEscapeKeyDown}
    >
      {cuerpo}
    </ModalBase>
  )
}
