/**
 * ModalComisionReglas
 *
 * Reglas de comisión (mig 150). El caso guiado que pidió el dueño es
 * "% base y % reducido cuando hay descuento por volumen", por preventista:
 *   · regla SIN origen  → el % base, aplica a todo lo que no matchee otra cosa
 *   · regla con 'mayorista' → el % de las ventas con descuento por volumen
 *
 * Sin ninguna regla, el cálculo usa el 2% por defecto, que es lo que la
 * pantalla venía aplicando a mano. Activar esto no cambia ningún número hasta
 * que se carga la primera regla.
 *
 * La baja es lógica: el cálculo se resuelve contra la fecha del pedido, así que
 * borrar una regla de verdad reescribiría meses ya liquidados.
 */
import { useMemo, useState } from 'react'
import { Plus, Trash2, Percent, AlertTriangle } from 'lucide-react'
import ModalBase from './ModalBase'
import NumberInput from '../ui/NumberInput'
import {
  useComisionReglasQuery,
  useGuardarComisionReglaMutation,
  useDesactivarComisionReglaMutation,
} from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import { etiquetaOrigen } from '../../utils/origenPrecio'
import { fechaLocalISO } from '../../utils/formatters'
import type { OrigenPrecio } from '../../utils/origenPrecio'

export interface PreventistaOption {
  id: string
  nombre: string
}

export interface ModalComisionReglasProps {
  preventistas: PreventistaOption[]
  comisionDefault: number
  onClose: () => void
}

/** Los orígenes que tiene sentido usar como regla en la fase 1. */
const ORIGENES_REGLA: Array<{ value: '' | OrigenPrecio; label: string }> = [
  { value: '', label: 'Cualquiera (% base)' },
  { value: 'mayorista', label: etiquetaOrigen('mayorista') },
  { value: 'desc_cliente', label: etiquetaOrigen('desc_cliente') },
  { value: 'desc_categoria', label: etiquetaOrigen('desc_categoria') },
  { value: 'manual', label: etiquetaOrigen('manual') },
  { value: 'lista', label: etiquetaOrigen('lista') },
]

export default function ModalComisionReglas({
  preventistas,
  comisionDefault,
  onClose,
}: ModalComisionReglasProps) {
  const notify = useNotification()
  const { data: reglas = [], isLoading } = useComisionReglasQuery()
  const guardar = useGuardarComisionReglaMutation()
  const desactivar = useDesactivarComisionReglaMutation()

  const [preventistaId, setPreventistaId] = useState<string>('')
  const [origen, setOrigen] = useState<'' | OrigenPrecio>('')
  const [porcentaje, setPorcentaje] = useState<number>(2)
  const [vigenteDesde, setVigenteDesde] = useState<string>(fechaLocalISO())

  const nombrePreventista = useMemo(() => {
    const map = new Map(preventistas.map(p => [p.id, p.nombre]))
    return (id: string | null): string => (id ? map.get(id) ?? 'Preventista' : 'Todos')
  }, [preventistas])

  /**
   * Trampa de la precedencia, verificada contra la DB: la regla propia de un
   * preventista (score 8) le gana a la general por origen (score 1). O sea que
   * cargarle un % base propio le APAGA en silencio el % reducido por volumen
   * que exista a nivel general. Se avisa en vez de dejar que aparezca como una
   * comisión mal liquidada tres meses después.
   */
  const sombreados = useMemo(() => {
    const activas = reglas.filter(r => r.activo)
    const origenesGenerales = new Set(
      activas.filter(r => !r.preventista_id && r.origen_precio).map(r => r.origen_precio as string),
    )
    if (origenesGenerales.size === 0) return []

    const conBase = activas.filter(r => r.preventista_id && !r.origen_precio)
    return conBase
      .map(r => {
        const propios = new Set(
          activas
            .filter(o => o.preventista_id === r.preventista_id && o.origen_precio)
            .map(o => o.origen_precio as string),
        )
        const faltantes = [...origenesGenerales].filter(o => !propios.has(o))
        return { preventistaId: r.preventista_id as string, faltantes }
      })
      .filter(x => x.faltantes.length > 0)
  }, [reglas])

  const handleAgregar = async (): Promise<void> => {
    if (!(porcentaje >= 0 && porcentaje <= 100)) {
      notify.error('El porcentaje debe estar entre 0 y 100')
      return
    }
    try {
      await guardar.mutateAsync({
        preventistaId: preventistaId || null,
        origenPrecio: origen || null,
        porcentaje,
        vigenteDesde,
      })
      notify.success('Regla agregada')
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo guardar la regla')
    }
  }

  const handleBaja = async (id: number): Promise<void> => {
    try {
      await desactivar.mutateAsync(id)
      notify.success('Regla dada de baja')
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo dar de baja la regla')
    }
  }

  return (
    <ModalBase
      title="Reglas de comisión"
      description="Porcentaje por preventista y por origen del precio"
      onClose={onClose}
      maxWidth="max-w-3xl"
    >
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        <div className="flex items-start gap-3 p-3 rounded-lg bg-stone-50 dark:bg-gray-900/40 border border-stone-200 dark:border-gray-700">
          <Percent className="w-5 h-5 shrink-0 mt-0.5 text-indigo-600" aria-hidden="true" />
          <p className="text-xs text-stone-600 dark:text-gray-300">
            Gana la regla más específica que coincida. Sin ninguna regla que aplique se usa el{' '}
            <strong>{comisionDefault}%</strong>. Cargá una regla con origen «Cualquiera» para el %
            base del preventista y otra con «{etiquetaOrigen('mayorista')}» para el % reducido.
          </p>
        </div>

        {sombreados.length > 0 && (
          <div className="flex items-start gap-3 p-3 rounded-lg border border-amber-300 dark:border-amber-700/60 bg-amber-50 dark:bg-amber-900/20">
            <AlertTriangle className="w-5 h-5 shrink-0 mt-0.5 text-amber-600" aria-hidden="true" />
            <div className="min-w-0 text-xs text-amber-800 dark:text-amber-200">
              <p className="font-medium">Hay reglas por origen que no se están aplicando</p>
              <ul className="mt-1 space-y-0.5">
                {sombreados.map(s => (
                  <li key={s.preventistaId}>
                    <strong>{nombrePreventista(s.preventistaId)}</strong> tiene un % base propio, así
                    que la regla general de{' '}
                    {s.faltantes.map(o => etiquetaOrigen(o)).join(', ')} no le aplica. Cargale una
                    regla propia para ese origen si querés que le corresponda.
                  </li>
                ))}
              </ul>
            </div>
          </div>
        )}

        {/* Alta */}
        <div className="rounded-lg border dark:border-gray-700 p-3 space-y-3">
          <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
            <div>
              <label htmlFor="regla-preventista" className="block text-sm font-medium mb-1">Preventista</label>
              <select
                id="regla-preventista"
                value={preventistaId}
                onChange={(e) => setPreventistaId(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-800 dark:border-gray-600"
              >
                <option value="">Todos</option>
                {preventistas.map(p => (
                  <option key={p.id} value={p.id}>{p.nombre}</option>
                ))}
              </select>
            </div>
            <div>
              <label htmlFor="regla-origen" className="block text-sm font-medium mb-1">Origen del precio</label>
              <select
                id="regla-origen"
                value={origen}
                onChange={(e) => setOrigen(e.target.value as '' | OrigenPrecio)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-800 dark:border-gray-600"
              >
                {ORIGENES_REGLA.map(o => (
                  <option key={o.value} value={o.value}>{o.label}</option>
                ))}
              </select>
            </div>
            <div>
              <label htmlFor="regla-pct" className="block text-sm font-medium mb-1">Porcentaje</label>
              <NumberInput
                id="regla-pct"
                min={0}
                max={100}
                emptyValue={0}
                value={porcentaje}
                onChange={setPorcentaje}
                commitOnChange
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-800 dark:border-gray-600"
              />
            </div>
            <div>
              <label htmlFor="regla-desde" className="block text-sm font-medium mb-1">Vigente desde</label>
              <input
                id="regla-desde"
                type="date"
                value={vigenteDesde}
                onChange={(e) => setVigenteDesde(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-800 dark:border-gray-600"
              />
              <p className="text-xs text-gray-500 mt-1">
                Los pedidos anteriores a esta fecha no se recalculan.
              </p>
            </div>
          </div>
          <div className="flex justify-end">
            <button
              type="button"
              onClick={() => void handleAgregar()}
              disabled={guardar.isPending}
              className="inline-flex items-center gap-1.5 px-4 py-2 rounded-lg bg-indigo-600 text-white text-sm font-medium disabled:opacity-50"
            >
              <Plus className="w-4 h-4" aria-hidden="true" />
              {guardar.isPending ? 'Guardando…' : 'Agregar regla'}
            </button>
          </div>
        </div>

        {/* Listado */}
        {isLoading ? (
          <p className="text-sm text-stone-500">Cargando reglas…</p>
        ) : reglas.length === 0 ? (
          <p className="text-sm text-stone-500 dark:text-gray-400">
            No hay reglas cargadas: todo se comisiona al {comisionDefault}%.
          </p>
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-stone-50 dark:bg-gray-700/50">
                <tr>
                  <th className="px-3 py-2 text-left font-medium">Preventista</th>
                  <th className="px-3 py-2 text-left font-medium">Origen</th>
                  <th className="px-3 py-2 text-right font-medium">%</th>
                  <th className="px-3 py-2 text-left font-medium">Vigencia</th>
                  <th className="px-3 py-2" />
                </tr>
              </thead>
              <tbody className="divide-y dark:divide-gray-700">
                {reglas.map(r => (
                  <tr key={r.id} className={r.activo ? '' : 'opacity-50'}>
                    <td className="px-3 py-2">{nombrePreventista(r.preventista_id)}</td>
                    <td className="px-3 py-2">
                      {r.origen_precio ? etiquetaOrigen(r.origen_precio) : 'Cualquiera'}
                    </td>
                    <td className="px-3 py-2 text-right font-semibold tabular-nums">{r.porcentaje}%</td>
                    <td className="px-3 py-2 text-xs text-stone-500">
                      desde {r.vigente_desde}
                      {r.vigente_hasta ? ` hasta ${r.vigente_hasta}` : ''}
                      {!r.activo && ' · dada de baja'}
                    </td>
                    <td className="px-3 py-2 text-right">
                      {r.activo && (
                        <button
                          type="button"
                          onClick={() => void handleBaja(r.id)}
                          disabled={desactivar.isPending}
                          className="text-rose-600 hover:text-rose-700 disabled:opacity-50"
                          aria-label={`Dar de baja la regla ${r.id}`}
                        >
                          <Trash2 className="w-4 h-4" aria-hidden="true" />
                        </button>
                      )}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <div className="flex justify-end p-4 border-t dark:border-gray-700">
        <button
          type="button"
          onClick={onClose}
          className="px-4 py-2 rounded-lg border dark:border-gray-600 text-sm dark:text-gray-200"
        >
          Cerrar
        </button>
      </div>
    </ModalBase>
  )
}
