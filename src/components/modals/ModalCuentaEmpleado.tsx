/**
 * ModalCuentaEmpleado — la cuenta corriente del empleado (entrega 3 de gastos). Sólo admin.
 *
 * Encabezado con la ficha y sus vínculos, el saldo (positivo: la empresa le debe), el arreglo
 * vigente y tres pestañas: los movimientos, las liquidaciones y los arreglos. Desde acá se liquida
 * el período pendiente más viejo, se anula la última liquidación, se carga un movimiento manual,
 * se cambia el arreglo y se revierte un adelanto, un pago suelto o un ajuste. La mercadería, el
 * reintegro, el sueldo y las comisiones entran solos desde su origen y no se tocan acá. Quién puede qué lo
 * decide el server; el modal sólo esconde lo que no corresponde: en la cuenta propia no se
 * carga nada (la carga otro admin).
 *
 * `ModalLiquidar`, `ModalMovimientoEmpleado` y `ModalArregloEmpleado` se renderizan DENTRO de los children del
 * `ModalBase`: como hermanos quedarían detrás del overlay de Radix y fallarían en silencio.
 */
import React, { useMemo, useState } from 'react'
import { Car, HandCoins, History, IdCard, List, Loader2, Pencil, Plus, Store, UserRound } from 'lucide-react'
import ModalBase from './ModalBase'
import ModalLiquidar from './ModalLiquidar'
import ModalMovimientoEmpleado from './ModalMovimientoEmpleado'
import ModalArregloEmpleado from './ModalArregloEmpleado'
import QueryErrorState from '../layout/QueryErrorState'
import { Button } from '../ui/Button'
import { Tabs } from '../ui/Tabs'
import { cn } from '../../lib/utils'
import {
  useAnularLiquidacionMutation,
  useCuentaEmpleadoQuery,
  useGuardarArregloMutation,
  useLiquidacionQuery,
  useRegistrarMovimientoEmpleadoMutation,
  useRevertirMovimientoEmpleadoMutation,
  useVistaPreviaLiquidacionQuery,
} from '../../hooks/queries/usePersonalQuery'
import { useTransportistasQuery } from '../../hooks/queries/useUsuariosQuery'
import { useNotification } from '../../contexts/NotificationContext'
import { getErrorMessage } from '../../utils/errorHandling'
import { formatPrecio } from '../../utils/formatters'
import {
  conceptoDeMovimiento,
  estadoSaldo,
  etiquetaPuesto,
  fechaCompleta,
  formatCuil,
  textoArregloAnterior,
  textoArregloLargo,
  textoPeriodo,
} from '../../utils/personal'
import type {
  ArregloEmpleado,
  Empleado,
  GuardarArregloPayload,
  LiquidacionResumen,
  MovimientoEmpleado,
  MovimientoManualPayload,
} from '../../types/personal'

export interface ModalCuentaEmpleadoProps {
  empleadoId: number
  nombreSucursal: (id: number) => string
  hoy: string
  onEditar: (e: Empleado) => void
  onClose: () => void
}

type Pestana = 'movimientos' | 'liquidaciones' | 'arreglos'

const PESTANAS = [
  { value: 'movimientos', label: 'Movimientos', icon: List },
  { value: 'liquidaciones', label: 'Liquidaciones', icon: HandCoins },
  { value: 'arreglos', label: 'Arreglos', icon: History },
] as const

const CLASE_INPUT =
  'w-full px-3 py-2 border border-gray-300 dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-brand-500 dark:bg-gray-700 dark:text-white text-sm'

/** 'YYYY-MM-DD' -> 'dd/mm'. */
const fechaCorta = (f: string): string => `${f.slice(8, 10)}/${f.slice(5, 7)}`

const COLOR_SALDO = {
  a_favor: 'text-emerald-700 dark:text-emerald-300',
  debe: 'text-rose-700 dark:text-rose-300',
  al_dia: 'text-stone-500 dark:text-stone-400',
} as const

const TEXTO_SALDO = {
  a_favor: 'A su favor: la empresa le debe',
  debe: 'Debe: le debe a la empresa',
  al_dia: 'Al día',
} as const

/** Cuándo rige un arreglo: 'vigente' es sólo el del empleado; uno que todavía no empezó dice cuándo. */
function textoVigenciaArreglo(a: ArregloEmpleado, vigenteId: number | null, hoy: string): string {
  if (a.vigente_desde > hoy) return `empieza el ${fechaCompleta(a.vigente_desde)}`
  if (a.vigente_hasta) return `hasta el ${fechaCompleta(a.vigente_hasta)}`
  return a.id === vigenteId ? 'vigente' : ''
}

const colorImporte = (n: number): string =>
  n > 0 ? 'text-emerald-700 dark:text-emerald-300' : n < 0 ? 'text-rose-700 dark:text-rose-300' : 'text-stone-500'

/**
 * El adelanto, el ajuste, el pago suelto y la rotura de una baja de stock se revierten. La
 * mercadería y el reintegro tienen su propio origen, y lo de una liquidación (sueldo, comisión, su
 * pago) se deshace anulándola; la rotura de una salvedad, anulando la salvedad.
 */
const sePuedeRevertir = (m: MovimientoEmpleado): boolean =>
  (m.tipo === 'adelanto' || m.tipo === 'ajuste' || (m.tipo === 'pago' && m.liquidacion === null)
    || (m.tipo === 'rotura' && m.merma_id !== null))
  && !m.revertido && m.revierte_id === null

/** 'Pagado $X el dd/mm/aaaa', más «de $Y» si se pagó menos y de qué rendición salió. */
function textoPagado(l: LiquidacionResumen): string {
  const menos = l.pagado < l.a_pagar - 0.005 ? ` de ${formatPrecio(l.a_pagar)}` : ''
  const rendicion = l.rendicion
    ? ` · de la rendición de ${l.rendicion.transportista_nombre} del ${fechaCorta(l.rendicion.fecha)}`
    : ''
  return `Pagado ${formatPrecio(l.pagado)} el ${fechaCompleta(l.fecha_pago)}${menos}${rendicion}`
}

const textoSueldoYComision = (l: LiquidacionResumen): string =>
  `Sueldo ${formatPrecio(l.sueldo)} · Comisión ${formatPrecio(l.comision)}`
  + (Math.abs(l.ajuste) >= 0.005 ? ` · Ajuste ${formatPrecio(l.ajuste)}` : '')

export default function ModalCuentaEmpleado({
  empleadoId, nombreSucursal, hoy, onEditar, onClose,
}: ModalCuentaEmpleadoProps): React.ReactElement {
  const notify = useNotification()
  const { data: cuenta, isLoading, refetch } = useCuentaEmpleadoQuery(empleadoId)
  const guardarArreglo = useGuardarArregloMutation()
  const registrarMovimiento = useRegistrarMovimientoEmpleadoMutation()
  const revertir = useRevertirMovimientoEmpleadoMutation()
  const { data: vista } = useVistaPreviaLiquidacionQuery(empleadoId)
  const anular = useAnularLiquidacionMutation()
  const { data: perfilesTransportistas = [] } = useTransportistasQuery()
  const transportistas = useMemo(
    () => perfilesTransportistas.map(t => ({ id: t.id, nombre: t.nombre })),
    [perfilesTransportistas],
  )

  const [pestana, setPestana] = useState<Pestana>('movimientos')
  const [anidado, setAnidado] = useState<'movimiento' | 'arreglo' | 'liquidar' | null>(null)
  // La fila que está pidiendo el motivo de la reversión.
  const [revirtiendoId, setRevirtiendoId] = useState<number | null>(null)
  const [motivo, setMotivo] = useState('')
  const [errorReversion, setErrorReversion] = useState('')
  const [revirtiendo, setRevirtiendo] = useState(false)
  // La liquidación que está pidiendo el motivo de la anulación, y la que tiene el detalle abierto.
  const [anulandoId, setAnulandoId] = useState<number | null>(null)
  const [motivoAnulacion, setMotivoAnulacion] = useState('')
  const [errorAnulacion, setErrorAnulacion] = useState('')
  const [anulando, setAnulando] = useState(false)
  const [detalleId, setDetalleId] = useState<number | null>(null)
  const { data: detalle, isError: detalleConError, refetch: reintentarDetalle } = useLiquidacionQuery(detalleId)

  const empleado = cuenta?.empleado
  const arreglos = useMemo(
    () => [...(cuenta?.arreglos ?? [])].sort((a, b) => b.vigente_desde.localeCompare(a.vigente_desde)),
    [cuenta],
  )
  const anterior = useMemo(() => {
    const vigente = empleado?.arreglo
    if (!vigente) return null
    return arreglos.find(a => a.id !== vigente.id && a.vigente_desde < vigente.vigente_desde) ?? null
  }, [arreglos, empleado])

  const abrirReversion = (id: number) => {
    setRevirtiendoId(id)
    setMotivo('')
    setErrorReversion('')
  }
  const cerrarReversion = () => {
    setRevirtiendoId(null)
    setMotivo('')
    setErrorReversion('')
  }

  const confirmarReversion = async () => {
    if (revirtiendoId === null) return
    const texto = motivo.trim()
    if (!texto) {
      setErrorReversion('Escribí por qué se revierte')
      return
    }
    setErrorReversion('')
    setRevirtiendo(true)
    try {
      await revertir.mutateAsync({ movimientoId: revirtiendoId, motivo: texto })
    } catch (err) {
      setErrorReversion(getErrorMessage(err))
      return
    } finally {
      setRevirtiendo(false)
    }
    notify.success('Movimiento revertido')
    cerrarReversion()
  }

  const abrirAnulacion = (id: number) => {
    setAnulandoId(id)
    setMotivoAnulacion('')
    setErrorAnulacion('')
  }
  const cerrarAnulacion = () => {
    setAnulandoId(null)
    setMotivoAnulacion('')
    setErrorAnulacion('')
  }

  const confirmarAnulacion = async () => {
    if (anulandoId === null) return
    const texto = motivoAnulacion.trim()
    if (!texto) {
      setErrorAnulacion('Escribí por qué se anula')
      return
    }
    setErrorAnulacion('')
    setAnulando(true)
    try {
      await anular.mutateAsync({ liquidacionId: anulandoId, motivo: texto })
    } catch (err) {
      setErrorAnulacion(getErrorMessage(err))
      return
    } finally {
      setAnulando(false)
    }
    notify.success('Liquidación anulada')
    cerrarAnulacion()
  }

  // Los errores suben al modal anidado, que los muestra y se queda abierto.
  const handleGuardarMovimiento = async (movimiento: MovimientoManualPayload) => {
    await registrarMovimiento.mutateAsync({ empleadoId, movimiento })
    notify.success('Movimiento registrado')
  }
  const handleGuardarArreglo = async (arreglo: GuardarArregloPayload) => {
    await guardarArreglo.mutateAsync({ empleadoId, arreglo })
    notify.success('Arreglo guardado')
  }

  let cuerpo: React.ReactNode
  if (isLoading) {
    cuerpo = (
      <div className="flex items-center justify-center gap-2 py-16 text-sm text-gray-500">
        <Loader2 className="w-5 h-5 animate-spin" aria-hidden="true" />
        Cargando cuenta…
      </div>
    )
  } else if (!cuenta || !empleado) {
    // Estado de error sólo sin datos: un refetch en segundo plano que falla no pisa la cuenta que ya se ve.
    cuerpo = <QueryErrorState onRetry={() => { void refetch() }} />
  } else {
    const estado = estadoSaldo(empleado.saldo)
    const propio = empleado.es_propio
    const ultimo = arreglos[0] ?? empleado.arreglo
    const datosPersonales = [
      empleado.cuil ? `CUIL ${formatCuil(empleado.cuil)}` : null,
      empleado.fecha_ingreso ? `ingresó el ${fechaCompleta(empleado.fecha_ingreso)}` : null,
    ].filter((t): t is string => t !== null)
    // "CUIL x · ingresó el y"; si falta el CUIL, el tramo que queda empieza con mayúscula.
    const lineaDatos = datosPersonales.join(' · ')
    const lineaDatosVisible = empleado.cuil || !lineaDatos
      ? lineaDatos
      : lineaDatos.charAt(0).toUpperCase() + lineaDatos.slice(1)

    cuerpo = (
      <div>
        {/* Encabezado */}
        <div className="px-5 pt-4 pb-5 border-b border-gray-200 dark:border-gray-700">
          <div className="flex items-center gap-3 flex-wrap">
            <h3 className="text-2xl font-bold text-gray-900 dark:text-white break-words">{empleado.nombre}</h3>
            <span className="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold bg-stone-100 text-stone-700 dark:bg-gray-700 dark:text-gray-200">
              {etiquetaPuesto(empleado.puesto)}
            </span>
            <span className="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold bg-brand-100 text-brand-700 dark:bg-brand-900/30 dark:text-brand-300">
              {empleado.de_las_dos ? 'Las dos' : nombreSucursal(empleado.sucursal_id)}
            </span>
            {!empleado.activo && (
              <span className="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold bg-stone-200 text-stone-700 dark:bg-gray-700 dark:text-stone-300">
                Inactivo
              </span>
            )}
          </div>
          {lineaDatosVisible && (
            <p className="mt-1 text-sm text-gray-600 dark:text-gray-300">{lineaDatosVisible}</p>
          )}
          <div className="flex items-center gap-x-4 gap-y-1 mt-2 text-sm text-gray-500 dark:text-gray-400 flex-wrap">
            <span className="flex items-center gap-1">
              {empleado.usuario
                ? <IdCard className="w-4 h-4" aria-hidden="true" />
                : <UserRound className="w-4 h-4" aria-hidden="true" />}
              {empleado.usuario ? `Usuario ${empleado.usuario.nombre}` : 'Sin usuario en la app'}
            </span>
            {empleado.cliente && (
              <span className="flex items-center gap-1">
                <Store className="w-4 h-4" aria-hidden="true" />
                {`Cliente “${empleado.cliente.nombre_fantasia}”`}
              </span>
            )}
            {empleado.vehiculo && (
              <span className="flex items-center gap-1">
                <Car className="w-4 h-4" aria-hidden="true" />
                {`${empleado.vehiculo.descripcion} ${empleado.vehiculo.patente}`}
              </span>
            )}
            <button
              type="button"
              onClick={() => onEditar(empleado)}
              className="text-brand-600 dark:text-brand-400 font-medium hover:underline"
            >
              Editar vínculos
            </button>
          </div>
          {propio && (
            <p className="mt-2 text-xs text-amber-700 dark:text-amber-300">
              Es tu cuenta: los movimientos y el arreglo los carga otro admin.
            </p>
          )}

          <div className="mt-4 grid md:grid-cols-[1.25fr_1fr] gap-3">
            {/* Saldo */}
            <div className="p-4 rounded-xl bg-brand-50 dark:bg-brand-900/20">
              <p className="text-sm text-gray-600 dark:text-gray-300">Saldo de la cuenta</p>
              <p className={cn('text-3xl font-bold tabular-nums', COLOR_SALDO[estado])}>
                {formatPrecio(Math.abs(empleado.saldo))}
              </p>
              <p className={cn('text-sm font-medium', COLOR_SALDO[estado])}>{TEXTO_SALDO[estado]}</p>
              {vista && (
                <p className="mt-2 text-sm text-gray-700 dark:text-gray-200">
                  {vista.a_pagar < 0
                    ? `Próxima liquidación: ${textoPeriodo(vista.periodo)}. Queda debiendo, estimado: ${formatPrecio(Math.abs(vista.a_pagar))}.`
                    : `Próxima liquidación: ${textoPeriodo(vista.periodo)}. A pagar, estimado: ${formatPrecio(vista.a_pagar)}.`}
                </p>
              )}
              {!propio && (
                <div className="mt-3 flex gap-2 flex-wrap">
                  {vista?.puede_liquidar && (
                    <Button type="button" variant="primary" size="md" onClick={() => setAnidado('liquidar')}>
                      <HandCoins className="w-4 h-4" aria-hidden="true" />
                      {vista.periodo.frecuencia === 'semanal' ? 'Liquidar semana' : 'Liquidar mes'}
                    </Button>
                  )}
                  <Button type="button" variant="secondary" size="md" onClick={() => setAnidado('movimiento')}>
                    <Plus className="w-4 h-4" aria-hidden="true" />
                    Movimiento
                  </Button>
                </div>
              )}
            </div>

            {/* Arreglo */}
            <div className="p-4 rounded-xl bg-stone-50 dark:bg-gray-900 border border-stone-200 dark:border-gray-700">
              <p className="text-sm text-gray-600 dark:text-gray-300">Arreglo vigente</p>
              {empleado.arreglo ? (
                <>
                  <p className="text-xl font-semibold text-gray-900 dark:text-white">
                    {formatPrecio(empleado.arreglo.sueldo)}{' '}
                    <span className="text-base font-normal text-gray-500">
                      {empleado.arreglo.frecuencia === 'semanal' ? 'por semana' : 'por mes'}
                    </span>
                  </p>
                  <p className="text-sm text-gray-500">
                    {`${empleado.arreglo.comisiona ? 'Comisiona' : 'No comisiona'} · desde el ${fechaCompleta(empleado.arreglo.vigente_desde)}`}
                  </p>
                  {anterior && <p className="mt-1 text-xs text-gray-400">{textoArregloAnterior(anterior)}</p>}
                </>
              ) : (
                <p className="text-sm text-gray-500">Todavía no tiene arreglo.</p>
              )}
              {!propio && empleado.activo && (
                <Button type="button" variant="secondary" size="sm" className="mt-3" onClick={() => setAnidado('arreglo')}>
                  <Pencil className="w-4 h-4" aria-hidden="true" />
                  Cambiar arreglo
                </Button>
              )}
            </div>
          </div>
        </div>

        {/* Pestañas */}
        <div className="px-5 py-4">
          <Tabs value={pestana} onValueChange={setPestana} tabs={PESTANAS} etiqueta="Cuenta del empleado">
            {pestana === 'movimientos' ? (
              cuenta.movimientos.length === 0 ? (
                <p className="py-8 text-center text-sm text-gray-500">Sin movimientos todavía.</p>
              ) : (
                <div className="rounded-lg border border-gray-200 dark:border-gray-700 overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead className="bg-gray-50 dark:bg-gray-900">
                      <tr>
                        <th scope="col" className="px-4 py-3 text-left font-medium text-gray-700 dark:text-gray-300">Fecha</th>
                        <th scope="col" className="px-4 py-3 text-left font-medium text-gray-700 dark:text-gray-300">Concepto</th>
                        <th scope="col" className="px-4 py-3 text-right font-medium text-gray-700 dark:text-gray-300">Importe</th>
                        <th scope="col" className="px-4 py-3 text-right font-medium text-gray-700 dark:text-gray-300">Saldo</th>
                      </tr>
                    </thead>
                    <tbody className="divide-y divide-gray-200 dark:divide-gray-700">
                      {cuenta.movimientos.map(m => {
                        const { titulo, detalle } = conceptoDeMovimiento(m)
                        const revertible = !propio && sePuedeRevertir(m)
                        return (
                          <React.Fragment key={m.id}>
                            <tr className={m.revertido ? 'opacity-60' : undefined}>
                              <td className="px-4 py-3 text-gray-500 whitespace-nowrap">{fechaCompleta(m.fecha)}</td>
                              <td className="px-4 py-3">
                                <div className="flex items-center gap-2 flex-wrap">
                                  <p className="font-medium text-gray-900 dark:text-white">{titulo}</p>
                                  {m.revertido && (
                                    <span className="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold bg-stone-200 text-stone-700 dark:bg-gray-700 dark:text-stone-300">
                                      Revertido
                                    </span>
                                  )}
                                  {revertible && revirtiendoId !== m.id && (
                                    <button
                                      type="button"
                                      onClick={() => abrirReversion(m.id)}
                                      aria-label={`Revertir ${titulo} del ${fechaCorta(m.fecha)}`}
                                      className="text-xs text-brand-600 dark:text-brand-400 font-medium hover:underline"
                                    >
                                      Revertir
                                    </button>
                                  )}
                                  {/* Un faltante de rendición no se revierte suelto: se deshace con la resolución entera. */}
                                  {!propio && m.tipo === 'faltante' && !m.revertido && m.revierte_id === null && (
                                    <span className="text-xs text-gray-500">Se deshace desde la rendición</span>
                                  )}
                                  {/* La rotura de una salvedad se deshace anulándola: el server rechaza revertirla suelta. */}
                                  {!propio && m.tipo === 'rotura' && m.salvedad_id !== null && !m.revertido && m.revierte_id === null && (
                                    <span className="text-xs text-gray-500">Se deshace anulando la salvedad</span>
                                  )}
                                </div>
                                {detalle && <p className="text-xs text-gray-500">{detalle}</p>}
                              </td>
                              <td className={cn('px-4 py-3 text-right font-medium tabular-nums whitespace-nowrap', colorImporte(m.monto))}>
                                {`${m.monto < 0 ? '−' : '+'}${formatPrecio(Math.abs(m.monto))}`}
                              </td>
                              <td className={cn('px-4 py-3 text-right tabular-nums whitespace-nowrap', colorImporte(m.saldo))}>
                                {formatPrecio(m.saldo)}
                              </td>
                            </tr>
                            {revirtiendoId === m.id && (
                              <tr>
                                <td colSpan={4} className="px-4 py-3 bg-gray-50 dark:bg-gray-900">
                                  <div className="space-y-2">
                                    <label htmlFor={`motivo-${m.id}`} className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                                      Por qué se revierte <span className="text-red-500">*</span>
                                    </label>
                                    <input
                                      id={`motivo-${m.id}`}
                                      type="text"
                                      autoComplete="off"
                                      value={motivo}
                                      onChange={ev => setMotivo(ev.target.value)}
                                      className={CLASE_INPUT}
                                    />
                                    {errorReversion && (
                                      <p role="alert" className="text-sm text-red-600 dark:text-red-400">{errorReversion}</p>
                                    )}
                                    <div className="flex gap-2">
                                      <Button type="button" variant="danger" size="sm" loading={revirtiendo} disabled={revirtiendo} onClick={() => { void confirmarReversion() }}>
                                        Revertir
                                      </Button>
                                      <Button type="button" variant="secondary" size="sm" onClick={cerrarReversion}>
                                        Cancelar
                                      </Button>
                                    </div>
                                  </div>
                                </td>
                              </tr>
                            )}
                          </React.Fragment>
                        )
                      })}
                    </tbody>
                  </table>
                </div>
              )
            ) : pestana === 'liquidaciones' ? (
              cuenta.liquidaciones.length === 0 ? (
                <p className="py-8 text-center text-sm text-gray-500">Todavía no se le liquidó nada.</p>
              ) : (
                <ul className="divide-y divide-gray-200 dark:divide-gray-700 rounded-lg border border-gray-200 dark:border-gray-700">
                  {cuenta.liquidaciones.map(l => {
                    const anulada = l.anulada_at !== null
                    const puedeAnular = !propio && l.es_la_ultima && !anulada
                    const abierto = detalleId === l.id
                    return (
                      <li key={l.id} className={cn('px-4 py-3 text-sm', anulada && 'opacity-70')}>
                        <div className="flex items-start justify-between gap-3 flex-wrap">
                          <div className="min-w-0">
                            <div className="flex items-center gap-2 flex-wrap">
                              <p className="font-medium text-gray-900 dark:text-white">{textoPeriodo(l)}</p>
                              {anulada && (
                                <span className="inline-flex items-center rounded-full px-2 py-0.5 text-xs font-semibold bg-stone-200 text-stone-700 dark:bg-gray-700 dark:text-stone-300">
                                  Anulada
                                </span>
                              )}
                            </div>
                            <p className="text-xs text-gray-500">{textoPagado(l)}</p>
                            <p className="text-xs text-gray-500">{textoSueldoYComision(l)}</p>
                            {anulada && l.motivo_anulacion && (
                              <p className="text-xs text-gray-500">{l.motivo_anulacion}</p>
                            )}
                          </div>
                          <div className="flex items-center gap-3">
                            <button
                              type="button"
                              onClick={() => setDetalleId(abierto ? null : l.id)}
                              aria-expanded={abierto}
                              aria-label={abierto ? 'Ocultar detalle' : 'Ver detalle'}
                              className="text-xs text-brand-600 dark:text-brand-400 font-medium hover:underline"
                            >
                              {abierto ? 'Ocultar detalle' : 'Ver detalle'}
                            </button>
                            {puedeAnular && anulandoId !== l.id && (
                              <button
                                type="button"
                                onClick={() => abrirAnulacion(l.id)}
                                aria-label={`Anular ${textoPeriodo(l)}`}
                                className="text-xs text-rose-700 dark:text-rose-300 font-medium hover:underline"
                              >
                                Anular
                              </button>
                            )}
                          </div>
                        </div>

                        {abierto && (
                          <div className="mt-3 rounded-lg bg-gray-50 dark:bg-gray-900 p-3 space-y-2 text-xs">
                            {!detalle && detalleConError ? (
                              <QueryErrorState onRetry={() => { void reintentarDetalle() }} />
                            ) : !detalle ? (
                              <p className="flex items-center gap-2 text-gray-500">
                                <Loader2 className="w-4 h-4 animate-spin" aria-hidden="true" />
                                Cargando detalle…
                              </p>
                            ) : (
                              <>
                                <p className="text-gray-700 dark:text-gray-200">
                                  {Math.abs(detalle.sueldo - detalle.sueldo_propuesto) >= 0.005
                                    ? `Sueldo ${formatPrecio(detalle.sueldo)} (el arreglo daba ${formatPrecio(detalle.sueldo_propuesto)})${detalle.motivo_sueldo ? `: ${detalle.motivo_sueldo}` : ''}`
                                    : `Sueldo ${formatPrecio(detalle.sueldo)}`}
                                </p>
                                {detalle.pedidos.length > 0 && (
                                  <table className="w-full">
                                    <thead>
                                      <tr className="text-left text-gray-500">
                                        <th scope="col" className="py-1 pr-2 font-medium">Pedido</th>
                                        <th scope="col" className="py-1 pr-2 font-medium">Entregado</th>
                                        <th scope="col" className="py-1 pr-2 font-medium">Cliente</th>
                                        <th scope="col" className="py-1 pr-2 font-medium text-right">Base</th>
                                        <th scope="col" className="py-1 font-medium text-right">Comisión</th>
                                      </tr>
                                    </thead>
                                    <tbody>
                                      {detalle.pedidos.map(p => (
                                        <tr key={p.pedido_id}>
                                          <td className="py-1 pr-2 whitespace-nowrap">{`#${p.pedido_id}`}</td>
                                          <td className="py-1 pr-2 whitespace-nowrap">{fechaCompleta(p.entregado_el)}</td>
                                          <td className="py-1 pr-2">{p.cliente}</td>
                                          <td className="py-1 pr-2 text-right tabular-nums whitespace-nowrap">{formatPrecio(p.base)}</td>
                                          <td className="py-1 text-right tabular-nums whitespace-nowrap">{formatPrecio(p.comision)}</td>
                                        </tr>
                                      ))}
                                    </tbody>
                                  </table>
                                )}
                                {detalle.ajustes.map(a => (
                                  <p key={`${a.pedido_id}-${a.motivo}`} className="flex justify-between gap-3 text-gray-700 dark:text-gray-200">
                                    <span>{`${a.motivo} · pedido #${a.pedido_id}`}</span>
                                    <span className="tabular-nums whitespace-nowrap">{formatPrecio(a.comision)}</span>
                                  </p>
                                ))}
                              </>
                            )}
                          </div>
                        )}

                        {anulandoId === l.id && (
                          <div className="mt-3 rounded-lg bg-gray-50 dark:bg-gray-900 p-3 space-y-2">
                            <p className="text-xs text-gray-600 dark:text-gray-300">
                              Se revierten sus movimientos y sus pedidos vuelven a quedar sin liquidar. Si el pago salió de una rendición ya cerrada, ese pago queda.
                            </p>
                            <label htmlFor={`anular-${l.id}`} className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                              Por qué se anula <span className="text-red-500">*</span>
                            </label>
                            <input
                              id={`anular-${l.id}`}
                              type="text"
                              autoComplete="off"
                              value={motivoAnulacion}
                              onChange={ev => setMotivoAnulacion(ev.target.value)}
                              className={CLASE_INPUT}
                            />
                            {errorAnulacion && (
                              <p role="alert" className="text-sm text-red-600 dark:text-red-400">{errorAnulacion}</p>
                            )}
                            <div className="flex gap-2">
                              <Button type="button" variant="danger" size="sm" loading={anulando} disabled={anulando} onClick={() => { void confirmarAnulacion() }}>
                                Anular liquidación
                              </Button>
                              <Button type="button" variant="secondary" size="sm" onClick={cerrarAnulacion}>
                                Cancelar
                              </Button>
                            </div>
                          </div>
                        )}
                      </li>
                    )
                  })}
                </ul>
              )
            ) : (
              <ul className="divide-y divide-gray-200 dark:divide-gray-700 rounded-lg border border-gray-200 dark:border-gray-700">
                {arreglos.length === 0 ? (
                  <li className="px-4 py-6 text-center text-sm text-gray-500">Todavía no tiene arreglos.</li>
                ) : arreglos.map(a => (
                  <li key={a.id} className="flex items-start justify-between gap-3 px-4 py-3 text-sm">
                    <p className="text-gray-900 dark:text-white">{textoArregloLargo(a)}</p>
                    <p className="text-gray-500 whitespace-nowrap">
                      {textoVigenciaArreglo(a, empleado.arreglo?.id ?? null, hoy)}
                    </p>
                  </li>
                ))}
              </ul>
            )}
          </Tabs>

          <p className="mt-3 text-xs text-gray-500">
            Saldo positivo: la empresa le debe. Negativo: él le debe a la empresa. La mercadería entra sola desde el pago con «adelanto de sueldo» en su ficha de cliente, y el reintegro desde el gasto pagado con plata propia. El sueldo y las comisiones entran al liquidar.
          </p>
        </div>

        {/* Modales anidados: DENTRO del ModalBase, o quedan detrás del overlay. */}
        {anidado === 'liquidar' && (
          <ModalLiquidar
            empleado={{
              id: empleado.id,
              nombre: empleado.nombre,
              puesto: empleado.puesto,
              sucursal_id: empleado.sucursal_id,
              de_las_dos: empleado.de_las_dos,
            }}
            nombreSucursal={nombreSucursal}
            transportistas={transportistas}
            hoy={hoy}
            onClose={() => setAnidado(null)}
          />
        )}
        {anidado === 'movimiento' && (
          <ModalMovimientoEmpleado
            empleado={{ id: empleado.id, nombre: empleado.nombre }}
            hoy={hoy}
            transportistas={transportistas}
            onSave={handleGuardarMovimiento}
            onClose={() => setAnidado(null)}
          />
        )}
        {anidado === 'arreglo' && (
          <ModalArregloEmpleado
            empleado={{ id: empleado.id, nombre: empleado.nombre }}
            vigente={ultimo}
            hoy={hoy}
            onSave={handleGuardarArreglo}
            onClose={() => setAnidado(null)}
          />
        )}
      </div>
    )
  }

  return (
    <ModalBase
      title="Cuenta del empleado"
      description={empleado?.nombre}
      onClose={onClose}
      maxWidth="max-w-4xl"
    >
      {cuerpo}
    </ModalBase>
  )
}
