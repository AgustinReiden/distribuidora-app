import { useState, memo } from 'react'
import { Loader2, AlertTriangle } from 'lucide-react'
import ModalBase from './ModalBase'
import { formatPrecio } from '../../utils/formatters'
import { MOTIVOS_NO_ENTREGA, MOTIVOS_CANCELACION_ADMIN } from '../../constants/motivosNoEntrega'
import type { PedidoDB } from '../../types'

export interface ModalCancelarPedidoProps {
  pedido: PedidoDB
  /** `motivo` es el texto que se guarda como nota; `tipo` es el valor tipificado. */
  onConfirm: (motivo: string, tipo: string) => Promise<void>
  onClose: () => void
  guardando: boolean
}

/** Motivos elegibles al cancelar: los logísticos + los administrativos (mig 143). */
const OPCIONES = [
  ...MOTIVOS_NO_ENTREGA.filter(m => m.valor !== 'otro').map(m => ({ valor: m.valor as string, label: m.label })),
  ...MOTIVOS_CANCELACION_ADMIN.map(m => ({ valor: m.valor as string, label: m.label })),
  { valor: 'otro', label: 'Otro' },
]

const ModalCancelarPedido = memo(function ModalCancelarPedido({
  pedido,
  onConfirm,
  onClose,
  guardando,
}: ModalCancelarPedidoProps) {
  const [tipo, setTipo] = useState('')
  const [nota, setNota] = useState('')

  // "Otro" sin explicación es el que después nadie puede interpretar: se exige nota.
  const faltaNota = tipo === 'otro' && nota.trim().length < 3
  const canConfirm = tipo !== '' && !faltaNota && !guardando

  const confirmar = (): void => {
    const label = OPCIONES.find(o => o.valor === tipo)?.label ?? tipo
    // El texto queda legible en el histórico (y compatible con lo ya cargado).
    const texto = nota.trim() ? `${label} — ${nota.trim()}` : label
    void onConfirm(texto, tipo)
  }

  return (
    <ModalBase title="Cancelar Pedido" onClose={onClose}>
      <div className="p-4 space-y-4">
        {/* Warning */}
        <div className="flex items-start gap-3 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
          <AlertTriangle className="w-5 h-5 text-red-600 dark:text-red-400 flex-shrink-0 mt-0.5" />
          <div>
            <p className="text-sm font-medium text-red-800 dark:text-red-300">
              Esta accion cancelara el pedido y restaurara el stock de los productos.
              El pedido permanecera visible con estado "Cancelado".
            </p>
          </div>
        </div>

        {/* Pedido info */}
        <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
          <p className="text-sm text-gray-600 dark:text-gray-400">Pedido #{pedido.id}</p>
          <p className="font-medium text-gray-800 dark:text-white">
            {pedido.cliente?.nombre_fantasia || 'Sin cliente'}
          </p>
          <p className="text-lg font-bold text-blue-600 mt-1">{formatPrecio(pedido.total)}</p>
        </div>

        {/* Motivo: lista cerrada. Antes era texto libre y el histórico quedó
            con "CERRADO", "SIN PLATA", "Prueba" y decenas de variantes, así que
            no se podía medir nada. */}
        <div>
          <label htmlFor="motivo-cancelacion" className="block text-sm font-medium mb-1 text-gray-700 dark:text-gray-300">
            Motivo de cancelación <span className="text-red-500">*</span>
          </label>
          <select
            id="motivo-cancelacion"
            value={tipo}
            onChange={e => setTipo(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          >
            <option value="">Elegí un motivo…</option>
            {OPCIONES.map(o => (
              <option key={o.valor} value={o.valor}>{o.label}</option>
            ))}
          </select>
        </div>

        {tipo !== '' && (
          <div>
            <label htmlFor="nota-cancelacion" className="block text-sm font-medium mb-1 text-gray-700 dark:text-gray-300">
              {tipo === 'otro' ? 'Contá qué pasó *' : 'Aclaración (opcional)'}
            </label>
            <textarea
              id="nota-cancelacion"
              value={nota}
              onChange={e => setNota(e.target.value)}
              rows={2}
              className="w-full px-3 py-2 border rounded-lg resize-none dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
            {faltaNota && nota.length > 0 && (
              <p className="text-xs text-red-500 mt-1">Escribí al menos 3 caracteres</p>
            )}
          </div>
        )}
      </div>

      {/* Footer */}
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <button
          onClick={onClose}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg"
        >
          Volver
        </button>
        <button
          onClick={() => canConfirm && confirmar()}
          disabled={!canConfirm}
          className="px-4 py-2 bg-red-600 text-white rounded-lg hover:bg-red-700 disabled:opacity-50 disabled:cursor-not-allowed flex items-center"
        >
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
          Cancelar Pedido
        </button>
      </div>
    </ModalBase>
  )
})

export default ModalCancelarPedido
