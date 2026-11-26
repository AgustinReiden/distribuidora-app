/**
 * T4 (#1710) · «Quién cobró»: de qué caja (rendición) es el cobro. Lo elige sólo el admin, como
 * elige quién entregó; sin elegir, el server lo pone en quien carga. `''` en el select es «yo».
 */
import React from 'react'

export interface PersonaQueCobra {
  id: string
  nombre: string
}

export interface CampoQuienCobroProps {
  personas: PersonaQueCobra[]
  /** `null` = yo (quien carga). */
  value: string | null
  onChange: (id: string | null) => void
  /** El id de quien carga, para no repetirlo en la lista. */
  yoId?: string | null
  id?: string
  ayuda?: string
}

export default function CampoQuienCobro({
  personas, value, onChange, yoId, id = 'quien-cobro', ayuda,
}: CampoQuienCobroProps): React.ReactElement {
  const otras = personas.filter(p => p.id !== yoId)
  return (
    <div>
      <label htmlFor={id} className="block text-sm font-medium mb-1 dark:text-gray-200">
        Quién cobró
      </label>
      <select
        id={id}
        value={value ?? ''}
        onChange={e => onChange(e.target.value || null)}
        className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
      >
        <option value="">Yo</option>
        {otras.map(p => (
          <option key={p.id} value={p.id}>{p.nombre}</option>
        ))}
      </select>
      <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {ayuda ?? 'El cobro entra en la rendición de quien lo cobró.'}
      </p>
    </div>
  )
}
