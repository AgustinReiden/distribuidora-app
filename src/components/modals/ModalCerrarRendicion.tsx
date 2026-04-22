/**
 * Modal para cerrar/confirmar una rendición diaria.
 *
 * Flujo:
 *   1. Admin/encargado elige estado final: "confirmada" o "disconformidad".
 *   2. Opcionalmente agrega observaciones (texto libre).
 *   3. Opcionalmente agrega N gastos (descripción + monto). No mueven caja —
 *      son solo registro auditable por `rendicion_gastos`.
 *   4. Al submit se llama `confirmar_rendicion` (RPC) que hace upsert de
 *      `rendiciones_control` e inserta las filas de gastos en una transacción.
 */
import { useState, memo, useMemo } from 'react'
import { Loader2, Plus, Trash2, CheckCircle2, AlertTriangle, FileText } from 'lucide-react'
import ModalBase from './ModalBase'
import { formatPrecio } from '../../utils/formatters'
import type { RendicionGastoInput } from '../../types'

export interface ModalCerrarRendicionProps {
  /** Fecha de la rendición (YYYY-MM-DD) para mostrar en el header */
  fecha: string
  /** Nombre del transportista para contexto */
  transportistaNombre: string
  /** Total cobrado en esa rendición, para mostrar como referencia */
  totalCobrado: number
  /** Total entregado en esa fecha, para que el usuario compare */
  totalEntregado: number
  /** Observaciones existentes (si la rendición ya tenía) para prellenar */
  observacionesPrevias?: string | null
  /** Callback al confirmar. Recibe estado + observaciones + gastos. */
  onConfirmar: (
    estado: 'confirmada' | 'disconformidad',
    observaciones: string | null,
    gastos: RendicionGastoInput[]
  ) => Promise<void>
  onClose: () => void
  guardando: boolean
}

interface GastoRow {
  descripcion: string
  monto: string
}

function formatFechaCorta(fechaISO: string): string {
  const [y, m, d] = fechaISO.split('-')
  return `${d}/${m}/${y}`
}

const ModalCerrarRendicion = memo(function ModalCerrarRendicion({
  fecha,
  transportistaNombre,
  totalCobrado,
  totalEntregado,
  observacionesPrevias,
  onConfirmar,
  onClose,
  guardando
}: ModalCerrarRendicionProps) {
  const [estado, setEstado] = useState<'confirmada' | 'disconformidad'>('confirmada')
  const [observaciones, setObservaciones] = useState<string>(observacionesPrevias || '')
  const [gastos, setGastos] = useState<GastoRow[]>([])

  const addGasto = (): void => {
    setGastos(prev => [...prev, { descripcion: '', monto: '' }])
  }

  const removeGasto = (idx: number): void => {
    setGastos(prev => prev.filter((_, i) => i !== idx))
  }

  const updateGasto = (idx: number, field: keyof GastoRow, value: string): void => {
    setGastos(prev => prev.map((g, i) => (i === idx ? { ...g, [field]: value } : g)))
  }

  const gastosValidos: RendicionGastoInput[] = useMemo(
    () => gastos
      .map(g => ({ descripcion: g.descripcion.trim(), monto: parseFloat(g.monto) || 0 }))
      .filter(g => g.descripcion.length > 0 && g.monto > 0),
    [gastos]
  )

  const totalGastos = gastosValidos.reduce((sum, g) => sum + g.monto, 0)
  const diferencia = totalCobrado - totalEntregado

  const handleSubmit = async (): Promise<void> => {
    await onConfirmar(
      estado,
      observaciones.trim() || null,
      gastosValidos
    )
  }

  return (
    <ModalBase title="Cerrar rendición" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4">
        {/* Contexto: fecha + transportista */}
        <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Rendición de <span className="font-semibold text-gray-800 dark:text-white">{transportistaNombre}</span>{' '}
            del <span className="font-semibold text-gray-800 dark:text-white">{formatFechaCorta(fecha)}</span>
          </p>
          <div className="grid grid-cols-3 gap-3 mt-3 text-sm">
            <div>
              <p className="text-xs text-gray-500">Cobrado</p>
              <p className="font-bold text-gray-800 dark:text-white">{formatPrecio(totalCobrado)}</p>
            </div>
            <div>
              <p className="text-xs text-gray-500">Entregado</p>
              <p className="font-bold text-gray-800 dark:text-white">{formatPrecio(totalEntregado)}</p>
            </div>
            <div>
              <p className="text-xs text-gray-500">Diferencia</p>
              <p className={`font-bold ${diferencia === 0 ? 'text-gray-800 dark:text-white' : diferencia < 0 ? 'text-red-600' : 'text-emerald-600'}`}>
                {formatPrecio(diferencia)}
              </p>
            </div>
          </div>
        </div>

        {/* Estado final */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
            Resultado de la rendición
          </label>
          <div className="grid grid-cols-2 gap-2">
            <button
              type="button"
              onClick={() => setEstado('confirmada')}
              className={`flex items-center gap-2 px-4 py-3 rounded-lg border-2 transition-colors ${
                estado === 'confirmada'
                  ? 'bg-emerald-50 border-emerald-500 dark:bg-emerald-900/20 dark:border-emerald-600'
                  : 'bg-white border-gray-200 hover:bg-gray-50 dark:bg-gray-700 dark:border-gray-600'
              }`}
            >
              <CheckCircle2 className={`w-5 h-5 ${estado === 'confirmada' ? 'text-emerald-600' : 'text-gray-400'}`} />
              <div className="text-left">
                <p className={`font-medium ${estado === 'confirmada' ? 'text-emerald-700 dark:text-emerald-300' : 'text-gray-700 dark:text-gray-300'}`}>
                  Confirmar
                </p>
                <p className="text-xs text-gray-500">Todo cuadra</p>
              </div>
            </button>
            <button
              type="button"
              onClick={() => setEstado('disconformidad')}
              className={`flex items-center gap-2 px-4 py-3 rounded-lg border-2 transition-colors ${
                estado === 'disconformidad'
                  ? 'bg-red-50 border-red-500 dark:bg-red-900/20 dark:border-red-600'
                  : 'bg-white border-gray-200 hover:bg-gray-50 dark:bg-gray-700 dark:border-gray-600'
              }`}
            >
              <AlertTriangle className={`w-5 h-5 ${estado === 'disconformidad' ? 'text-red-600' : 'text-gray-400'}`} />
              <div className="text-left">
                <p className={`font-medium ${estado === 'disconformidad' ? 'text-red-700 dark:text-red-300' : 'text-gray-700 dark:text-gray-300'}`}>
                  Disconformidad
                </p>
                <p className="text-xs text-gray-500">Hay algo para revisar</p>
              </div>
            </button>
          </div>
        </div>

        {/* Observaciones */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1 flex items-center gap-1">
            <FileText className="w-4 h-4" />
            Observaciones {estado === 'disconformidad' && <span className="text-red-500">*</span>}
          </label>
          <textarea
            value={observaciones}
            onChange={e => setObservaciones(e.target.value)}
            rows={3}
            placeholder={estado === 'disconformidad'
              ? 'Describí qué hay que revisar (ej: faltan $500 en efectivo, cheque rechazado…)'
              : 'Opcional: notas sobre el día…'}
            className="w-full px-3 py-2 border rounded-lg resize-none dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
          />
        </div>

        {/* Gastos */}
        <div>
          <div className="flex items-center justify-between mb-2">
            <label className="text-sm font-medium text-gray-700 dark:text-gray-300">
              Gastos del día
              {gastosValidos.length > 0 && (
                <span className="ml-2 text-xs text-gray-500">
                  ({gastosValidos.length} — total {formatPrecio(totalGastos)})
                </span>
              )}
            </label>
            <button
              type="button"
              onClick={addGasto}
              className="flex items-center gap-1 px-2 py-1 text-xs text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/20 rounded"
            >
              <Plus className="w-3 h-3" />
              Agregar
            </button>
          </div>
          <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
            No mueven caja. Son solo registro para dejar constancia (combustible, peaje, etc.).
          </p>

          {gastos.length === 0 ? (
            <div className="text-center py-4 border border-dashed dark:border-gray-600 rounded-lg text-sm text-gray-400">
              Sin gastos cargados
            </div>
          ) : (
            <div className="space-y-2">
              {gastos.map((g, idx) => (
                <div key={idx} className="flex gap-2 items-start">
                  <input
                    type="text"
                    value={g.descripcion}
                    onChange={e => updateGasto(idx, 'descripcion', e.target.value)}
                    placeholder="Descripción (ej: combustible)"
                    className="flex-1 px-3 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  />
                  <input
                    type="number"
                    inputMode="decimal"
                    step="0.01"
                    min="0"
                    value={g.monto}
                    onChange={e => updateGasto(idx, 'monto', e.target.value)}
                    placeholder="0.00"
                    className="w-28 px-3 py-2 text-sm border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  />
                  <button
                    type="button"
                    onClick={() => removeGasto(idx)}
                    className="p-2 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded"
                    aria-label="Eliminar gasto"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {/* Footer */}
      <div className="flex items-center justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <button
          onClick={onClose}
          disabled={guardando}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg disabled:opacity-50"
        >
          Cancelar
        </button>
        <button
          onClick={handleSubmit}
          disabled={guardando || (estado === 'disconformidad' && !observaciones.trim())}
          className={`px-4 py-2 rounded-lg text-white flex items-center gap-2 disabled:opacity-50 ${
            estado === 'confirmada'
              ? 'bg-emerald-600 hover:bg-emerald-700'
              : 'bg-red-600 hover:bg-red-700'
          }`}
        >
          {guardando && <Loader2 className="w-4 h-4 animate-spin" />}
          {estado === 'confirmada' ? 'Confirmar rendición' : 'Marcar disconformidad'}
        </button>
      </div>
    </ModalBase>
  )
})

export default ModalCerrarRendicion
