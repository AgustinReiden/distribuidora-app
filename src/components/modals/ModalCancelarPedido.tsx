import { useState, memo } from 'react'
import { AlertTriangle } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { formatPrecio } from '../../utils/formatters'
import { MOTIVO_FALTA_STOCK, tieneRegaloConPromo, unidadesQueNoVuelvenAlStock } from '../../utils/cancelacionFaltaStock'
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
  // #827: cancelar por falta de stock NO devuelve la mercaderia (se merma). Es
  // irreversible desde la app, asi que pasa por un segundo paso con la lista de
  // lo que no vuelve y un tilde explicito. Vive DENTRO de este modal (estado
  // interno): un confirm hermano en el container quedaria detras del overlay
  // de Radix y fallaria en silencio.
  const [paso, setPaso] = useState<'motivo' | 'confirmar_falta_stock'>('motivo')
  const [confirmoInexistente, setConfirmoInexistente] = useState(false)

  const esFaltaStock = tipo === MOTIVO_FALTA_STOCK
  const unidades = esFaltaStock ? unidadesQueNoVuelvenAlStock(pedido.items) : []
  // El fardo que abre un regalo depende de usos_pendientes de la promo: el
  // front no lo puede calcular, así que se avisa en vez de listarlo.
  const tieneRegaloDePromo = esFaltaStock && tieneRegaloConPromo(pedido.items)

  // "Otro" sin explicación es el que después nadie puede interpretar: se exige nota.
  const faltaNota = tipo === 'otro' && nota.trim().length < 3
  const motivoValido = tipo !== '' && !faltaNota && !guardando
  const canConfirm = motivoValido && (!esFaltaStock || (paso === 'confirmar_falta_stock' && confirmoInexistente))

  const elegirTipo = (valor: string): void => {
    setTipo(valor)
    setPaso('motivo')
    setConfirmoInexistente(false)
  }

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
              {esFaltaStock
                ? 'Esta acción cancelará el pedido. La mercadería NO vuelve al stock: se registra como merma (error de inventario), porque no existe físicamente.'
                : 'Esta acción cancelará el pedido y restaurará el stock de los productos.'}
              {' '}El pedido permanecerá visible con estado "Cancelado".
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
            onChange={e => elegirTipo(e.target.value)}
            disabled={paso === 'confirmar_falta_stock'}
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

        {esFaltaStock && paso === 'motivo' && (
          <p className="text-xs text-gray-600 dark:text-gray-400">
            Usalo sólo si no hay stock de <strong>ningún</strong> producto del pedido (o es de un
            solo producto). Si falta uno de varios, entregá el pedido con una salvedad
            &quot;Faltante de stock&quot; sobre ese renglón.
          </p>
        )}

        {esFaltaStock && paso === 'confirmar_falta_stock' && (
          <div
            role="alert"
            className="p-3 rounded-lg border-2 border-amber-400 bg-amber-50 dark:bg-amber-900/20 dark:border-amber-700 space-y-3"
          >
            <p className="text-sm font-medium text-amber-900 dark:text-amber-200">
              Esto NO vuelve al stock (se registra como merma):
            </p>
            {unidades.length > 0 ? (
              <ul className="text-sm text-amber-900 dark:text-amber-100 space-y-1" aria-label="Unidades que no vuelven al stock">
                {unidades.map(u => (
                  <li key={u.productoId} className="flex justify-between gap-3">
                    <span>{u.nombre}</span>
                    <span className="font-semibold tabular-nums">{u.cantidad} u.</span>
                  </li>
                ))}
              </ul>
            ) : (
              <p className="text-sm text-amber-900 dark:text-amber-100">
                Ningún renglón de este pedido descontó stock por sí mismo.
              </p>
            )}
            {tieneRegaloDePromo && (
              <p className="text-xs text-amber-900 dark:text-amber-100" data-testid="aviso-fardo-promo">
                Si un regalo de promoción abrió un fardo de alguno de los productos del pedido,
                ese fardo tampoco vuelve al stock: se registra como merma. Los fardos de otros
                productos vuelven como siempre.
              </p>
            )}
            <label className="flex items-start gap-2 text-sm text-amber-900 dark:text-amber-100 cursor-pointer">
              <input
                type="checkbox"
                checked={confirmoInexistente}
                onChange={e => setConfirmoInexistente(e.target.checked)}
                className="mt-0.5"
              />
              <span>Confirmo que la mercadería no existe físicamente</span>
            </label>
          </div>
        )}
      </div>

      {/* Footer */}
      <div className="flex justify-end space-x-3 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <Button
          variant="ghost"
          size="md"
          onClick={() => (paso === 'confirmar_falta_stock' ? elegirTipo(tipo) : onClose())}
        >
          Volver
        </Button>
        {esFaltaStock && paso === 'motivo' ? (
          <Button
            variant="danger"
            size="md"
            onClick={() => motivoValido && setPaso('confirmar_falta_stock')}
            disabled={!motivoValido}
          >
            Continuar
          </Button>
        ) : (
          <Button
            variant="danger"
            size="md"
            onClick={() => canConfirm && confirmar()}
            disabled={!canConfirm}
            loading={guardando}
          >
            Cancelar Pedido
          </Button>
        )}
      </div>
    </ModalBase>
  )
})

export default ModalCancelarPedido
