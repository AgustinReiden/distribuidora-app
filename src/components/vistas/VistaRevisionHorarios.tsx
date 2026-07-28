/**
 * VistaRevisionHorarios
 *
 * Los horarios en texto libre que el backfill (mig 141) no pudo convertir solo.
 * No es cosmética: un cliente sin horario canónico cae en la barrida 2 —"sin
 * horario cargado"—, o sea que el ruteo por horarios no lo puede acomodar, que
 * es justamente lo que se construyó para dejar de perder entregas por llegar
 * cuando el local está cerrado.
 *
 * Dos grupos, porque piden trabajo distinto:
 *  · confianza alta  → se aceptan en bloque, sin leer una por una.
 *  · dudosas         → alguien decide. "24 HS" puede ser 00:00-24:00 o puede
 *                      ser que el preventista escribió cualquier cosa; el
 *                      parser no puede saberlo y no debe adivinar.
 */
import { useMemo, useState } from 'react'
import { Clock, Check, AlertTriangle } from 'lucide-react'
import LoadingSpinner from '../layout/LoadingSpinner'
import FranjasHorariasEditor from '../ui/FranjasHorariasEditor'
import { serializarFranjas, parsearFranjas, type FranjaHoraria } from '../../utils/horariosCliente'
import type { ClienteHorarioPendiente, HorarioMasivoItem } from '../../hooks/queries/useRevisionHorariosQuery'

export interface VistaRevisionHorariosProps {
  pendientes: ClienteHorarioPendiente[]
  loading: boolean
  guardando: boolean
  onGuardar: (items: HorarioMasivoItem[]) => Promise<void>
}

function Fila({
  cliente,
  edicion,
  onEdicion,
}: {
  cliente: ClienteHorarioPendiente
  edicion: string | undefined
  onEdicion: (texto: string) => void
}) {
  const franjas = useMemo(
    (): FranjaHoraria[] => parsearFranjas(edicion ?? cliente.propuestaTexto),
    [edicion, cliente.propuestaTexto],
  )

  return (
    <div className="px-3 py-2.5 border-b dark:border-gray-700 last:border-b-0">
      <div className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-2">
        <div className="min-w-0 sm:flex-1">
          <p className="text-sm font-medium dark:text-white truncate">{cliente.nombre}</p>
          <p className="text-xs text-stone-500 dark:text-gray-400">
            Cargado: «{cliente.original}»
          </p>
          {cliente.propuesta.motivo && (
            <p className="text-xs text-amber-700 dark:text-amber-400 mt-0.5">
              {cliente.propuesta.motivo}
            </p>
          )}
        </div>
        <div className="sm:w-72 shrink-0">
          <FranjasHorariasEditor
            franjas={franjas}
            onChange={(f) => onEdicion(serializarFranjas(f))}
          />
        </div>
      </div>
    </div>
  )
}

export default function VistaRevisionHorarios({
  pendientes,
  loading,
  guardando,
  onGuardar,
}: VistaRevisionHorariosProps) {
  /** productoId → texto canónico editado a mano. */
  const [ediciones, setEdiciones] = useState<Record<string, string>>({})

  const { altas, dudosas, sinPropuesta } = useMemo(() => {
    const altas: ClienteHorarioPendiente[] = []
    const dudosas: ClienteHorarioPendiente[] = []
    const sinPropuesta: ClienteHorarioPendiente[] = []
    for (const c of pendientes) {
      if (!c.propuestaTexto) sinPropuesta.push(c)
      else if (c.propuesta.confianza === 'alta') altas.push(c)
      else dudosas.push(c)
    }
    return { altas, dudosas, sinPropuesta }
  }, [pendientes])

  const itemDe = (c: ClienteHorarioPendiente): HorarioMasivoItem => ({
    cliente_id: c.id,
    horarios_atencion: ediciones[c.id] ?? c.propuestaTexto,
    dias_atencion: c.propuesta.dias,
  })

  const aceptarAltas = async (): Promise<void> => {
    if (altas.length === 0) return
    await onGuardar(altas.map(itemDe))
  }

  const guardarRevisadas = async (): Promise<void> => {
    // Sólo lo que tenga franjas: guardar un vacío borraría el texto original
    // sin poner nada en su lugar.
    const items = [...dudosas, ...sinPropuesta]
      .map(itemDe)
      .filter(i => i.horarios_atencion)
    if (items.length === 0) return
    await onGuardar(items)
  }

  const editadasCount = [...dudosas, ...sinPropuesta].filter(
    c => (ediciones[c.id] ?? c.propuestaTexto).length > 0,
  ).length

  if (loading) return <LoadingSpinner />

  return (
    <div className="space-y-4">
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <div>
          <h1 className="text-2xl font-bold dark:text-white">Horarios a revisar</h1>
          <p className="text-sm text-stone-500 dark:text-gray-400">
            Sin horario en formato estándar, el cliente entra en la barrida «sin horario» y el
            ruteo no lo puede acomodar.
          </p>
        </div>
      </div>

      {pendientes.length === 0 ? (
        <div className="text-center py-12 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg">
          <Clock className="w-12 h-12 mx-auto mb-3 opacity-40 text-emerald-600" />
          <p className="font-semibold dark:text-white">No queda ningún horario en texto libre</p>
          <p className="text-sm text-stone-500 dark:text-gray-400 mt-1">
            Todos los clientes con horario cargado lo tienen en formato estándar.
          </p>
        </div>
      ) : (
        <>
          {altas.length > 0 && (
            <section className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg">
              <div className="flex items-center justify-between gap-2 px-3 py-2 border-b dark:border-gray-700">
                <h2 className="text-sm font-medium flex items-center gap-1.5 dark:text-white">
                  <Check className="w-4 h-4 text-emerald-600" aria-hidden="true" />
                  Se entendieron bien ({altas.length})
                </h2>
                <button
                  type="button"
                  onClick={() => void aceptarAltas()}
                  disabled={guardando}
                  className="px-3 py-1.5 rounded-lg bg-emerald-600 text-white text-xs font-medium disabled:opacity-50"
                >
                  {guardando ? 'Guardando…' : `Aceptar las ${altas.length}`}
                </button>
              </div>
              <ul className="divide-y dark:divide-gray-700">
                {altas.map(c => (
                  <li key={c.id} className="px-3 py-2 flex flex-wrap items-baseline gap-x-2 text-sm">
                    <span className="font-medium dark:text-white truncate max-w-[16rem]">{c.nombre}</span>
                    <span className="text-xs text-stone-500 dark:text-gray-400">«{c.original}»</span>
                    <span className="text-stone-400">→</span>
                    <span className="font-medium text-emerald-700 dark:text-emerald-400 tabular-nums">
                      {c.propuestaTexto}
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          )}

          {(dudosas.length > 0 || sinPropuesta.length > 0) && (
            <section className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg">
              <div className="flex items-center justify-between gap-2 px-3 py-2 border-b dark:border-gray-700">
                <h2 className="text-sm font-medium flex items-center gap-1.5 dark:text-white">
                  <AlertTriangle className="w-4 h-4 text-amber-600" aria-hidden="true" />
                  Hay que decidirlas ({dudosas.length + sinPropuesta.length})
                </h2>
                <button
                  type="button"
                  onClick={() => void guardarRevisadas()}
                  disabled={guardando || editadasCount === 0}
                  className="px-3 py-1.5 rounded-lg bg-indigo-600 text-white text-xs font-medium disabled:opacity-50"
                >
                  {guardando ? 'Guardando…' : `Guardar ${editadasCount}`}
                </button>
              </div>
              <div>
                {[...dudosas, ...sinPropuesta].map(c => (
                  <Fila
                    key={c.id}
                    cliente={c}
                    edicion={ediciones[c.id]}
                    onEdicion={(texto) => setEdiciones(prev => ({ ...prev, [c.id]: texto }))}
                  />
                ))}
              </div>
            </section>
          )}
        </>
      )}
    </div>
  )
}
