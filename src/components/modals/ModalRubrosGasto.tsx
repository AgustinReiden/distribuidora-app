/**
 * ModalRubrosGasto — el admin renombra los rubros, les cambia el grupo y los
 * activa o desactiva. Los rubros nuevos se crean desde el buscador de
 * `ModalGasto`. Las reglas (el grupo no cambia si el rubro ya tiene gastos, ningún
 * rubro se llama "Sueldos…") las pone el server y su mensaje se muestra tal cual.
 */
import React, { useState } from 'react'
import { Check, Pencil, X } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { Badge } from '../ui/Badge'
import { getErrorMessage } from '../../utils/errorHandling'
import { GRUPOS_GASTO } from '../../utils/gastos'
import type { GuardarRubroGastoInput } from '../../hooks/queries/useRubrosGastoQuery'
import type { GrupoGasto, RubroGasto } from '../../types/gastos'

export interface ModalRubrosGastoProps {
  /** Todos los rubros, activos o no. */
  rubros: RubroGasto[]
  onGuardar: (rubro: GuardarRubroGastoInput) => Promise<RubroGasto>
  onClose: () => void
}

/** El server reemplaza el rubro entero: se manda completo para no borrar sus marcas. */
const comoInput = (r: RubroGasto, cambios: Partial<GuardarRubroGastoInput>): GuardarRubroGastoInput => ({
  id: r.id,
  nombre: r.nombre,
  grupo: r.grupo,
  palabras_busqueda: r.palabras_busqueda,
  activo: r.activo,
  pide_litros_km: r.pide_litros_km,
  reparto_sugerido_meses: r.reparto_sugerido_meses,
  sugiere_mes_anterior: r.sugiere_mes_anterior,
  ...cambios,
})

export default function ModalRubrosGasto({ rubros, onGuardar, onClose }: ModalRubrosGastoProps): React.ReactElement {
  const [editando, setEditando] = useState<{ id: number; nombre: string } | null>(null)
  const [ocupado, setOcupado] = useState<number | null>(null)
  const [error, setError] = useState('')

  const guardar = async (rubro: RubroGasto, cambios: Partial<GuardarRubroGastoInput>): Promise<boolean> => {
    setError('')
    setOcupado(rubro.id)
    try {
      await onGuardar(comoInput(rubro, cambios))
      return true
    } catch (err) {
      setError(getErrorMessage(err))
      return false
    } finally {
      setOcupado(null)
    }
  }

  const confirmarNombre = async (rubro: RubroGasto) => {
    if (!editando) return
    const nombre = editando.nombre.trim()
    if (!nombre) {
      setError('El rubro necesita un nombre')
      return
    }
    if (nombre === rubro.nombre || await guardar(rubro, { nombre })) setEditando(null)
  }

  return (
    <ModalBase
      title="Rubros de gasto"
      description="Los rubros son de toda la red. El grupo decide en qué renglón del resultado cae el gasto."
      onClose={onClose}
      maxWidth="max-w-2xl"
    >
      <div className="p-4 space-y-5">
        {error && (
          <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
            <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
          </div>
        )}

        {GRUPOS_GASTO.map(grupo => {
          const delGrupo = rubros.filter(r => r.grupo === grupo.valor)
          if (delGrupo.length === 0) return null
          return (
            <section key={grupo.valor} aria-label={grupo.etiqueta}>
              <h3 className="text-xs font-mono font-semibold tracking-[0.12em] uppercase text-gray-500 mb-2">
                {grupo.etiqueta}
              </h3>
              <ul className="divide-y divide-gray-100 dark:divide-gray-700 rounded-lg border border-gray-200 dark:border-gray-700">
                {delGrupo.map(r => (
                  <li key={r.id} className="flex flex-wrap items-center gap-2 px-3 py-2">
                    {editando?.id === r.id ? (
                      <>
                        <input
                          type="text"
                          aria-label={`Nombre del rubro ${r.nombre}`}
                          value={editando.nombre}
                          onChange={e => setEditando({ id: r.id, nombre: e.target.value })}
                          className="flex-1 min-w-[10rem] px-2 py-1 border border-gray-300 dark:border-gray-600 rounded-md text-sm dark:bg-gray-700 dark:text-white"
                        />
                        <Button
                          type="button" variant="ghost" size="sm" aria-label="Guardar nombre"
                          disabled={ocupado === r.id} onClick={() => confirmarNombre(r)}
                        >
                          <Check className="w-4 h-4" aria-hidden="true" />
                        </Button>
                        <Button type="button" variant="ghost" size="sm" aria-label="Descartar" onClick={() => setEditando(null)}>
                          <X className="w-4 h-4" aria-hidden="true" />
                        </Button>
                      </>
                    ) : (
                      <>
                        <span className={r.activo ? 'flex-1 text-sm text-gray-800 dark:text-gray-100' : 'flex-1 text-sm text-gray-400 line-through'}>
                          {r.nombre}
                        </span>
                        {!r.activo && <Badge tone="neutral">Inactivo</Badge>}
                        <Button
                          type="button" variant="ghost" size="sm" aria-label={`Renombrar ${r.nombre}`}
                          onClick={() => setEditando({ id: r.id, nombre: r.nombre })}
                        >
                          <Pencil className="w-4 h-4" aria-hidden="true" />
                        </Button>
                      </>
                    )}
                    <select
                      aria-label={`Grupo de ${r.nombre}`}
                      value={r.grupo}
                      disabled={ocupado === r.id}
                      onChange={e => guardar(r, { grupo: e.target.value as GrupoGasto })}
                      className="px-2 py-1 border border-gray-300 dark:border-gray-600 rounded-md text-sm dark:bg-gray-700 dark:text-white"
                    >
                      {GRUPOS_GASTO.map(g => <option key={g.valor} value={g.valor}>{g.etiqueta}</option>)}
                    </select>
                    <Button
                      type="button" variant="secondary" size="sm" disabled={ocupado === r.id}
                      aria-label={`${r.activo ? 'Desactivar' : 'Activar'} ${r.nombre}`}
                      onClick={() => guardar(r, { activo: !r.activo })}
                    >
                      {r.activo ? 'Desactivar' : 'Activar'}
                    </Button>
                  </li>
                ))}
              </ul>
            </section>
          )
        })}

        <div className="flex justify-end pt-2">
          <Button type="button" variant="secondary" size="md" onClick={onClose}>Cerrar</Button>
        </div>
      </div>
    </ModalBase>
  )
}
