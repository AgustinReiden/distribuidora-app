/**
 * T4 (#1710) · Corregir un cobro en la rendición: la forma de pago (el chofer marcó
 * transferencia y era efectivo) y, sólo el admin, quién lo cobró. Va con motivo y queda en las
 * notas del pago, en el historial del pedido y en la auditoría. Sin faltante: la rendición se
 * recalcula con la forma corregida.
 */
import React, { useState } from 'react'
import { Button } from '../ui/Button'
import { FORMAS_PAGO_SELECCIONABLES } from '../../constants/formasPago'
import { corregirCobroRendicion } from '../../hooks/supabase/cobrosRendicion'
import CampoQuienCobro, { type PersonaQueCobra } from './CampoQuienCobro'

export interface CorregirCobroProps {
  pagoId: number
  formaActual: string
  esAdmin: boolean
  /** Sólo para el admin: a quién le puede pasar el cobro. */
  personas?: PersonaQueCobra[]
  onHecho: () => void
  onCancelar: () => void
}

export default function CorregirCobro({
  pagoId, formaActual, esAdmin, personas, onHecho, onCancelar,
}: CorregirCobroProps): React.ReactElement {
  const [forma, setForma] = useState(formaActual)
  const [cobradoPor, setCobradoPor] = useState<string | null>(null)
  const [motivo, setMotivo] = useState('')
  const [error, setError] = useState('')
  const [guardando, setGuardando] = useState(false)

  const cambiaForma = forma !== formaActual
  const cambiaQuien = esAdmin && cobradoPor !== null
  const puedeGuardar = (cambiaForma || cambiaQuien) && motivo.trim() !== '' && !guardando

  const guardar = async (): Promise<void> => {
    if (!puedeGuardar) return
    setError('')
    setGuardando(true)
    try {
      await corregirCobroRendicion({
        pagoId,
        formaPago: cambiaForma ? forma : null,
        cobradoPor: cambiaQuien ? cobradoPor : null,
        motivo: motivo.trim(),
      })
      onHecho()
    } catch (e) {
      setError((e as Error).message || 'No se pudo corregir el cobro')
    } finally {
      setGuardando(false)
    }
  }

  return (
    <div className="mt-1 p-2 rounded border border-gray-200 dark:border-gray-700 space-y-2" onClick={e => e.stopPropagation()}>
      <div>
        <label htmlFor={`forma-${pagoId}`} className="block text-xs font-medium mb-1 dark:text-gray-200">Forma de pago</label>
        <select
          id={`forma-${pagoId}`}
          value={forma}
          onChange={e => setForma(e.target.value)}
          className="w-full px-2 py-1 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
        >
          {FORMAS_PAGO_SELECCIONABLES.map(f => (
            <option key={f.value} value={f.value}>{f.label}</option>
          ))}
        </select>
      </div>
      {esAdmin && personas && (
        <CampoQuienCobro
          id={`quien-cobro-${pagoId}`}
          personas={personas}
          value={cobradoPor}
          onChange={setCobradoPor}
          ayuda="Sin elegir, sigue siendo de esta rendición."
        />
      )}
      <div>
        <label htmlFor={`motivo-${pagoId}`} className="block text-xs font-medium mb-1 dark:text-gray-200">Motivo</label>
        <input
          id={`motivo-${pagoId}`}
          value={motivo}
          onChange={e => setMotivo(e.target.value)}
          placeholder="Ej.: marcó transferencia y era efectivo"
          className="w-full px-2 py-1 border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
        />
      </div>
      {error && <p role="alert" className="text-xs text-red-600">{error}</p>}
      <div className="flex gap-2">
        <Button size="sm" variant="primary" disabled={!puedeGuardar} onClick={() => { void guardar() }}>
          {guardando ? 'Guardando…' : 'Corregir'}
        </Button>
        <Button size="sm" variant="secondary" onClick={onCancelar}>Cancelar</Button>
      </div>
    </div>
  )
}
