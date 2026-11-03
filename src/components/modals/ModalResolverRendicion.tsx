/**
 * Modal para resolver una rendición que está en disconformidad (sólo admin).
 *
 * Flujo:
 *   1. El admin describe cómo se resolvió el problema (texto obligatorio).
 *   2. Opcionalmente imputa la diferencia en líneas, cada una con su monto y su causal:
 *      deuda de un empleado, robo o pérdida (gasto «Faltantes de caja») o un gasto que no se
 *      cargó (el mismo «Registrar gasto» del cierre, en borrador). Lo imputado baja el efectivo
 *      a entregar, y no puede dejarlo en negativo.
 *   3. Al submit se llama `resolver_rendicion` (RPC) con `{lineas, vistos, pagos_personal_visto}`:
 *      todo va en una transacción. Los gastos y los pagos al personal que vio el modal al abrirse
 *      se congelan: el server rechaza la resolución si alguno cambió mientras tanto.
 */
import { useMemo, useRef, useState, memo, Suspense } from 'react'
import { FileText, CheckCircle, Plus, Trash2, Pencil } from 'lucide-react'
import { z } from 'zod'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { Combobox } from '../ui/Combobox'
import { cn } from '../../lib/utils'
import { formatPrecio } from '../../utils/formatters'
import { lazyWithReload } from '../../utils/lazyWithReload'
import { noCerrarConBuscadorAbierto } from '../../utils/escapeConBuscador'
import { gastosVistos } from '../../utils/rendicionGastos'
import { MENSAJE_MONTO_ILEGIBLE, parseMonto } from '../../utils/personal'
import {
  ETIQUETA_CAUSAL,
  MENSAJE_SIN_EMPLEADOS,
  MENSAJE_SUPERA,
  empleadoSugerido,
  empleadosParaFaltante,
  quedaAEntregar,
  totalImputado,
} from '../../utils/faltantesRendicion'
import { usePropsModalGasto } from '../../hooks/usePropsModalGasto'
import { useEmpleadosParaElegirQuery } from '../../hooks/queries/usePersonalQuery'
import type {
  CausalFaltante,
  GastoDeRendicion,
  GastoVisto,
  GuardarGastoPayload,
  LineaResolucion,
  ResolucionRendicion,
} from '../../types/gastos'

const ModalGasto = lazyWithReload(() => import('./ModalGasto'))

export interface ModalResolverRendicionProps {
  fecha: string
  transportistaId: string
  transportistaNombre: string
  observacionesPrevias: string | null
  /** El efectivo a entregar de hoy: de ahí sale lo que se imputa. */
  aEntregar: number
  /** Los gastos vivos de la rendición y lo pagado al personal: se congelan al abrir. */
  gastos: GastoDeRendicion[]
  totalPagosPersonal: number
  onResolver: (observaciones: string, resolucion: ResolucionRendicion) => Promise<void>
  onClose: () => void
  guardando: boolean
}

/** Una línea tal como se edita: el monto es texto hasta que se lee. */
interface LineaEditable {
  clave: string
  causal: CausalFaltante | null
  monto: string
  empleadoId: number | null
  observacion: string
  gasto: GuardarGastoPayload | null
}

const MENSAJE_SIN_CAUSAL = 'Elegí la causal de cada línea'
const MENSAJE_SIN_EMPLEADO = 'Elegí a qué empleado se le carga el faltante'
const MENSAJE_SIN_GASTO = 'Cargá el gasto de cada línea de gasto'
const MENSAJE_MONTO = 'Cada línea lleva un monto mayor a 0'
const MENSAJE_SIN_TEXTO = 'Escribí cómo se resolvió'

// Schema CO-LOCADO a propósito (no en lib/schemas.ts): ver ModalCambioProducto.tsx para el incidente
// de chunk desincronizado que motivó la regla. Las líneas llegan con el monto ya leído (`null` si no
// se entiende); `aEntregar` es el contexto del tope.
// eslint-disable-next-line react-refresh/only-export-components
export const modalResolverRendicionSchema = z
  .object({
    observaciones: z.string().trim().min(1, MENSAJE_SIN_TEXTO),
    aEntregar: z.number(),
    lineas: z.array(
      z.object({
        causal: z.enum(['empleado', 'robo_perdida', 'gasto_no_cargado'], { message: MENSAJE_SIN_CAUSAL }),
        // Nullable a propósito: un monto que falta no tiene que tapar el aviso de lo que falta antes
        // (el empleado, el gasto). Con `z.number()` acá, zod se saltea el refine y sale el del monto.
        monto: z.number().nullable(),
        empleadoId: z.number().nullable(),
        tieneGasto: z.boolean(),
      }).superRefine((l, ctx) => {
        if (l.causal === 'empleado' && l.empleadoId === null) {
          ctx.addIssue({ code: 'custom', message: MENSAJE_SIN_EMPLEADO, path: ['empleadoId'] })
        }
        if (l.causal === 'gasto_no_cargado' && !l.tieneGasto) {
          ctx.addIssue({ code: 'custom', message: MENSAJE_SIN_GASTO, path: ['gasto'] })
          return // el monto de esa línea es el del gasto: sin gasto no hay monto que pedir
        }
        if (l.monto === null || !(l.monto > 0)) {
          ctx.addIssue({ code: 'custom', message: MENSAJE_MONTO, path: ['monto'] })
        }
      }),
    ),
  })
  .superRefine((f, ctx) => {
    const queda = quedaAEntregar(f.aEntregar, f.lineas.map(l => ({ monto: l.monto ?? 0 })))
    if (queda < 0) ctx.addIssue({ code: 'custom', message: MENSAJE_SUPERA, path: ['queda'] })
  })

function formatFechaCorta(fechaISO: string): string {
  const [y, m, d] = fechaISO.split('-')
  return `${d}/${m}/${y}`
}

const CAUSALES: CausalFaltante[] = ['empleado', 'robo_perdida', 'gasto_no_cargado']

const CLASE_INPUT = 'w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm'

/** El monto de una línea: el del gasto cargado, o lo tipeado; `null` si falta o no se entiende. */
function montoDe(l: LineaEditable): number | null {
  if (l.causal === 'gasto_no_cargado') return l.gasto ? l.gasto.monto_total : null
  if (!l.monto.trim()) return null
  return parseMonto(l.monto)
}

const ModalResolverRendicion = memo(function ModalResolverRendicion({
  fecha,
  transportistaId,
  transportistaNombre,
  observacionesPrevias,
  aEntregar,
  gastos,
  totalPagosPersonal,
  onResolver,
  onClose,
  guardando
}: ModalResolverRendicionProps) {
  const [observaciones, setObservaciones] = useState<string>('')
  // Lo que mostró el modal al abrirse, congelado: si se leyera el de un refetch con el modal abierto,
  // el server no tendría nada que comparar (como el cierre).
  const [vistos] = useState<GastoVisto[]>(() => gastosVistos(gastos))
  const [pagosPersonalVisto] = useState(() => totalPagosPersonal)
  const [lineas, setLineas] = useState<LineaEditable[]>([])
  const [editor, setEditor] = useState<{ clave: string } | null>(null)
  const contador = useRef(0)
  const propsGasto = usePropsModalGasto()
  const { data: empleados = [], isLoading: cargandoEmpleados, isError: falloEmpleados, refetch: recargarEmpleados } =
    useEmpleadosParaElegirQuery()
  // «No hay empleados» sólo se dice con la lista cargada y vacía: mientras carga o si falló, no es eso.
  const listaLista = !cargandoEmpleados && !falloEmpleados
  const elegibles = useMemo(
    () => empleadosParaFaltante(empleados, propsGasto.usuarioId ?? null),
    [empleados, propsGasto.usuarioId],
  )
  const sugerido = empleadoSugerido(elegibles, transportistaId)
  const vehiculoHabitual = empleados.find(e => e.activo && e.usuario_id === transportistaId)?.vehiculo_id ?? null

  const montos = lineas.map(montoDe)
  const leidos = montos.map(m => ({ monto: m ?? 0 }))
  const imputado = totalImputado(leidos)
  const queda = quedaAEntregar(aEntregar, leidos)

  const validacion = modalResolverRendicionSchema.safeParse({
    observaciones,
    aEntregar,
    lineas: lineas.map((l, i) => ({
      causal: l.causal,
      monto: montos[i],
      empleadoId: l.empleadoId,
      tieneGasto: l.gasto !== null,
    })),
  })
  // El texto y el tope tienen su propio lugar en pantalla; el resto se dice debajo de las líneas.
  const aviso = validacion.success
    ? null
    : validacion.error.issues.find(i => i.path[0] !== 'observaciones' && i.path[0] !== 'queda')?.message ?? null

  const editada = editor ? lineas.find(l => l.clave === editor.clave) ?? null : null

  const cambiar = (clave: string, cambio: Partial<LineaEditable>): void =>
    setLineas(prev => prev.map(l => (l.clave === clave ? { ...l, ...cambio } : l)))

  const agregarLinea = (): void => {
    contador.current += 1
    setLineas(prev => [...prev, {
      clave: `l${contador.current}`, causal: null, monto: '', empleadoId: null, observacion: '', gasto: null,
    }])
  }

  const elegirCausal = (linea: LineaEditable, causal: CausalFaltante): void => {
    cambiar(linea.clave, {
      causal,
      empleadoId: causal === 'empleado' ? (linea.empleadoId ?? sugerido) : null,
    })
  }

  const guardarGasto = async (payload: GuardarGastoPayload): Promise<void> => {
    if (editor) cambiar(editor.clave, { gasto: payload })
  }

  const rubroDe = (g: GuardarGastoPayload): string =>
    propsGasto.rubros.find(r => r.id === Number(g.rubro_id))?.nombre ?? 'Gasto'

  const handleSubmit = async (): Promise<void> => {
    if (!validacion.success) return
    const resueltas = lineas.map((l, i): LineaResolucion => {
      const monto = montos[i] as number
      const observacion = l.observacion.trim() || null
      if (l.causal === 'empleado') return { causal: 'empleado', monto, empleado_id: l.empleadoId as number, observacion }
      if (l.causal === 'robo_perdida') return { causal: 'robo_perdida', monto, observacion }
      return { causal: 'gasto_no_cargado', monto, gasto: l.gasto as GuardarGastoPayload }
    })
    await onResolver(observaciones.trim(), { lineas: resueltas, vistos, pagos_personal_visto: pagosPersonalVisto })
  }

  return (
    <ModalBase
      title="Resolver disconformidad"
      onClose={onClose}
      maxWidth="max-w-xl"
      onEscapeKeyDown={noCerrarConBuscadorAbierto}
    >
      {/* Mientras se manda, nada se edita: lo que se ve tiene que ser lo que se mandó. */}
      <fieldset disabled={guardando} className="p-4 space-y-4 border-0 m-0 min-w-0">
        <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Rendición de <span className="font-semibold text-gray-800 dark:text-white">{transportistaNombre}</span>{' '}
            del <span className="font-semibold text-gray-800 dark:text-white">{formatFechaCorta(fecha)}</span>
          </p>
        </div>

        {observacionesPrevias && (
          <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-3">
            <p className="text-xs font-medium text-red-700 dark:text-red-300 mb-1 flex items-center gap-1">
              <FileText className="w-3 h-3" />
              Observaciones previas
            </p>
            <p className="text-sm text-red-900 dark:text-red-200 whitespace-pre-wrap">
              {observacionesPrevias}
            </p>
          </div>
        )}

        {/* Diferencia */}
        <div>
          <div className="flex items-center justify-between mb-1">
            <span className="text-sm font-medium text-gray-700 dark:text-gray-300">Diferencia</span>
            <Button
              type="button"
              onClick={agregarLinea}
              disabled={guardando}
              variant="ghost"
              size="sm"
              className="gap-1 text-xs text-blue-600 dark:text-blue-400 hover:bg-blue-50 dark:hover:bg-blue-900/20"
            >
              <Plus className="w-3 h-3" aria-hidden="true" />
              Agregar línea
            </Button>
          </div>
          <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
            Opcional: cargá la plata que faltó y a dónde va.
          </p>

          {lineas.length > 0 && (
            <ul className="space-y-3">
              {lineas.map((l, i) => {
                const sinEmpleados = !listaLista || elegibles.length === 0
                return (
                  <li key={l.clave} className="p-3 border rounded-lg dark:border-gray-600 space-y-2" aria-label={`Línea ${i + 1}`}>
                    <div className="flex items-start justify-between gap-2">
                      <div className="flex flex-wrap gap-2" role="group" aria-label={`Causal de la línea ${i + 1}`}>
                        {CAUSALES.map(c => {
                          const deshabilitada = c === 'empleado' && sinEmpleados
                          return (
                            <button
                              key={c}
                              type="button"
                              aria-pressed={l.causal === c}
                              disabled={deshabilitada}
                              onClick={() => elegirCausal(l, c)}
                              className={cn(
                                'px-3 py-1.5 rounded-lg border text-sm transition-colors',
                                l.causal === c
                                  ? 'bg-blue-50 border-blue-500 text-blue-700 dark:bg-blue-900/20 dark:text-blue-300'
                                  : 'bg-white border-gray-200 text-gray-700 hover:bg-gray-50 dark:bg-gray-700 dark:border-gray-600 dark:text-gray-300',
                                deshabilitada && 'opacity-50 cursor-not-allowed hover:bg-white',
                              )}
                            >
                              {ETIQUETA_CAUSAL[c]}
                            </button>
                          )
                        })}
                      </div>
                      <Button
                        type="button"
                        variant="ghost"
                        size="iconSm"
                        aria-label={`Quitar la línea ${i + 1}`}
                        onClick={() => setLineas(prev => prev.filter(x => x.clave !== l.clave))}
                        className="text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 dark:text-red-400"
                      >
                        <Trash2 className="w-4 h-4" aria-hidden="true" />
                      </Button>
                    </div>

                    {l.causal === 'empleado' && (
                      <div>
                        <label className="block text-xs text-gray-500 mb-1" htmlFor={`${l.clave}-empleado`}>Empleado</label>
                        <Combobox
                          id={`${l.clave}-empleado`}
                          aria-label="Empleado"
                          opciones={elegibles}
                          getKey={e => String(e.id)}
                          getLabel={e => e.nombre}
                          valor={l.empleadoId === null ? null : String(l.empleadoId)}
                          onSeleccionar={e => cambiar(l.clave, { empleadoId: e.id })}
                          placeholder="Empleado"
                          textoSinResultados="No hay empleados"
                        />
                      </div>
                    )}

                    {(l.causal === 'empleado' || l.causal === 'robo_perdida') && (
                      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                        <div>
                          <label className="block text-xs text-gray-500 mb-1" htmlFor={`${l.clave}-monto`}>Monto</label>
                          <input
                            id={`${l.clave}-monto`}
                            type="text"
                            inputMode="decimal"
                            value={l.monto}
                            onChange={e => cambiar(l.clave, { monto: e.target.value })}
                            className={CLASE_INPUT}
                          />
                          {l.monto.trim() !== '' && parseMonto(l.monto) === null && (
                            <p className="text-xs text-red-600 mt-1">{MENSAJE_MONTO_ILEGIBLE}</p>
                          )}
                        </div>
                        <div>
                          <label className="block text-xs text-gray-500 mb-1" htmlFor={`${l.clave}-obs`}>Observación (opcional)</label>
                          <input
                            id={`${l.clave}-obs`}
                            type="text"
                            value={l.observacion}
                            onChange={e => cambiar(l.clave, { observacion: e.target.value })}
                            className={CLASE_INPUT}
                          />
                        </div>
                      </div>
                    )}

                    {l.causal === 'gasto_no_cargado' && (
                      <div className="flex items-center justify-between gap-2">
                        {l.gasto ? (
                          <>
                            <span className="text-sm text-gray-800 dark:text-white">
                              {`${rubroDe(l.gasto)} · ${formatPrecio(l.gasto.monto_total)}`}
                            </span>
                            <Button
                              type="button"
                              variant="ghost"
                              size="sm"
                              className="gap-1"
                              onClick={() => setEditor({ clave: l.clave })}
                            >
                              <Pencil className="w-3 h-3" aria-hidden="true" />
                              Editar
                            </Button>
                          </>
                        ) : (
                          <Button type="button" variant="secondary" size="sm" onClick={() => setEditor({ clave: l.clave })}>
                            Cargar el gasto
                          </Button>
                        )}
                      </div>
                    )}
                  </li>
                )
              })}
            </ul>
          )}

          {lineas.length > 0 && cargandoEmpleados && (
            <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">Cargando empleados…</p>
          )}
          {lineas.length > 0 && falloEmpleados && (
            <div className="mt-2 flex items-center gap-2 text-xs text-red-600">
              <span>No se pudo cargar la lista de empleados.</span>
              <Button type="button" variant="ghost" size="sm" onClick={() => { void recargarEmpleados() }}>
                Reintentar
              </Button>
            </div>
          )}
          {lineas.length > 0 && listaLista && elegibles.length === 0 && (
            <p className="mt-2 text-xs text-amber-600 dark:text-amber-400">{MENSAJE_SIN_EMPLEADOS}</p>
          )}

          {aviso && lineas.length > 0 && (
            <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">{aviso}</p>
          )}

          {lineas.length > 0 && (
            <div className="mt-2 text-sm">
              <p className="text-gray-700 dark:text-gray-300">
                {`A entregar ${formatPrecio(aEntregar)} · imputado ${formatPrecio(imputado)} · queda ${formatPrecio(queda)}`}
              </p>
              {queda < 0 && (
                <p role="alert" className="text-xs text-red-600">{MENSAJE_SUPERA}</p>
              )}
            </div>
          )}
        </div>

        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1" htmlFor="resolver-observaciones">
            ¿Cómo se resolvió? <span className="text-red-500">*</span>
          </label>
          <textarea
            id="resolver-observaciones"
            value={observaciones}
            onChange={e => setObservaciones(e.target.value)}
            rows={4}
            placeholder="Ej: Se cobró el faltante en efectivo al día siguiente / cheque reemplazado por transferencia / …"
            className="w-full px-3 py-2 border rounded-lg resize-none dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
          />
          <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
            El texto se append-ea al historial con tu nombre y la fecha.
          </p>
        </div>
      </fieldset>

      {/* El modal del gasto va ADENTRO de este (regla de Radix): como hermano queda detrás del overlay. */}
      {editor && (
        <Suspense fallback={null}>
          <ModalGasto
            {...propsGasto}
            gasto={null}
            borrador={editada?.gasto ?? null}
            desdeCierre={{ transportistaId, transportistaNombre, fecha }}
            avisoDeGuardado="Se guarda cuando marques la rendición como resuelta."
            {...(editada?.gasto ? {} : { vehiculoInicialId: vehiculoHabitual })}
            onSave={guardarGasto}
            onClose={() => setEditor(null)}
          />
        </Suspense>
      )}

      <div className="flex items-center justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <Button
          onClick={onClose}
          disabled={guardando}
          variant="ghost"
          size="md"
          className="text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600"
        >
          Cancelar
        </Button>
        <Button
          onClick={handleSubmit}
          disabled={guardando || !validacion.success}
          loading={guardando}
          variant="primary"
          size="md"
        >
          {!guardando && <CheckCircle className="w-4 h-4" />}
          Marcar como resuelta
        </Button>
      </div>
    </ModalBase>
  )
})

export default ModalResolverRendicion
