/**
 * ModalSustituirRegalo
 *
 * Permite a un admin/encargado cambiar el producto de un item bonificacion
 * en un pedido (regalo de una promocion). Justifica con motivo y autoriza
 * la operacion.
 *
 * Llama a la RPC `sustituir_regalo_pedido` (mig 058) via
 * useSustituirRegaloMutation. Maneja:
 *   - Idempotencia (UUID generado en el primer render).
 *   - Modo A vs Modo B con banner visual explicativo.
 *   - Validacion basica: cantidad > 0, producto seleccionado, motivo no vacio.
 */
import { useMemo, useState, memo } from 'react'
import { Loader2, Gift, AlertTriangle, Check } from 'lucide-react'
import ModalBase from './ModalBase'
import { useProductosQuery } from '../../hooks/queries'
import { useSustituirRegaloMutation } from '../../hooks/queries/useSustituirRegaloMutation'
import { useNotification } from '../../contexts/NotificationContext'
import type { ProductoDB } from '../../types'

export interface ModalSustituirRegaloProps {
  pedidoItemId: string
  productoOriginal: ProductoDB
  cantidadOriginal: number
  /** Modo de la promo. true = Modo A (stock unitario), false = Modo B (bloques). */
  regaloMueveStock: boolean
  onClose: () => void
  /** Callback al confirmar exitosamente (para que el caller refresque). */
  onSustituido?: () => void
}

const ModalSustituirRegalo = memo(function ModalSustituirRegalo({
  pedidoItemId,
  productoOriginal,
  cantidadOriginal,
  regaloMueveStock,
  onClose,
  onSustituido,
}: ModalSustituirRegaloProps) {
  const notify = useNotification()
  const { data: productos = [] } = useProductosQuery()
  const sustituirMut = useSustituirRegaloMutation()

  // UUID estable por instancia del modal para idempotencia (mismo UUID en
  // reintento desde el cliente devuelve la misma sustitucion sin duplicar).
  const clientRequestId = useMemo(() => crypto.randomUUID(), [])

  const [productoNuevoId, setProductoNuevoId] = useState<string>('')
  const [cantidadNueva, setCantidadNueva] = useState<string>(String(cantidadOriginal))
  const [motivo, setMotivo] = useState<string>('')
  const [error, setError] = useState<string>('')

  const productoNuevo = useMemo(
    () => productos.find(p => String(p.id) === String(productoNuevoId)) ?? null,
    [productos, productoNuevoId]
  )

  // Productos disponibles ordenados, excluyendo el original para que no
  // "sustituyan por el mismo".
  const productosOpciones = useMemo(
    () => productos
      .filter(p => String(p.id) !== String(productoOriginal.id))
      .slice()
      .sort((a, b) => (a.nombre || '').localeCompare(b.nombre || '')),
    [productos, productoOriginal.id]
  )

  const cantidadNum = parseFloat(cantidadNueva) || 0
  const stockSuficiente = productoNuevo == null || (productoNuevo.stock ?? 0) >= cantidadNum
  const puedeConfirmar = !!productoNuevoId
    && cantidadNum > 0
    && motivo.trim().length > 0
    && stockSuficiente
    && !sustituirMut.isPending

  const handleConfirmar = async () => {
    setError('')
    if (!puedeConfirmar) return
    try {
      const result = await sustituirMut.mutateAsync({
        pedidoItemId,
        productoNuevoId,
        cantidadNueva: cantidadNum,
        motivo: motivo.trim(),
        clientRequestId,
      })
      notify.success(
        result.idempotentReplay
          ? 'Sustitucion ya registrada'
          : `Regalo sustituido (Modo ${result.modo})`
      )
      onSustituido?.()
      onClose()
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al sustituir el regalo'
      setError(msg)
    }
  }

  return (
    <ModalBase title="Sustituir regalo de promocion" onClose={onClose} maxWidth="max-w-lg">
      <div className="p-4 space-y-4">
        {/* Contexto del regalo original */}
        <div className="bg-gray-50 dark:bg-gray-700/50 rounded-lg p-3">
          <p className="text-xs text-gray-500 dark:text-gray-400 mb-1 flex items-center gap-1">
            <Gift className="w-3 h-3" /> Regalo actual
          </p>
          <p className="font-semibold text-gray-800 dark:text-white">
            {productoOriginal.nombre}
          </p>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Cantidad: <span className="font-medium">{cantidadOriginal}</span>
          </p>
        </div>

        {/* Banner segun modo de la promo */}
        {regaloMueveStock ? (
          <div className="flex items-start gap-2 p-3 rounded-lg bg-emerald-50 dark:bg-emerald-900/20 border border-emerald-200 dark:border-emerald-800 text-sm text-emerald-800 dark:text-emerald-200">
            <Check className="w-4 h-4 mt-0.5 flex-shrink-0" />
            <p>
              Esta promo descuenta stock por unidad. La sustitucion va a
              <b> devolver {cantidadOriginal} de {productoOriginal.nombre}</b> al
              deposito y descontar la cantidad del producto sustituto.
            </p>
          </div>
        ) : (
          <div className="flex items-start gap-2 p-3 rounded-lg bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 text-sm text-amber-800 dark:text-amber-200">
            <AlertTriangle className="w-4 h-4 mt-0.5 flex-shrink-0" />
            <p>
              Esta promo se ajusta por bloque del producto contenedor. La
              sustitucion va a descontar el stock del nuevo producto pero
              <b> NO va a reponer el contenedor original</b>. El bloque ya
              consumido por la promo se mantiene.
            </p>
          </div>
        )}

        {/* Producto sustituto */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Producto sustituto *
          </label>
          <select
            value={productoNuevoId}
            onChange={e => setProductoNuevoId(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          >
            <option value="">Elegir...</option>
            {productosOpciones.map(p => (
              <option key={p.id} value={p.id}>
                {p.nombre} {(p.stock ?? 0) > 0 ? `· stock ${p.stock}` : '· sin stock'}
              </option>
            ))}
          </select>
        </div>

        {/* Cantidad */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Cantidad nueva *
          </label>
          <input
            type="number"
            inputMode="decimal"
            step="0.01"
            min="0"
            value={cantidadNueva}
            onChange={e => setCantidadNueva(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          />
          <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
            Se acepta fraccion (ej. 0.5). Por defecto se asume la misma
            cantidad que el regalo original.
          </p>
          {productoNuevo && !stockSuficiente && (
            <p className="text-xs text-red-600 mt-1 flex items-center gap-1">
              <AlertTriangle className="w-3 h-3" />
              Stock insuficiente del producto sustituto ({productoNuevo.stock ?? 0} disponible)
            </p>
          )}
        </div>

        {/* Motivo */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Motivo de la sustitucion *
          </label>
          <textarea
            value={motivo}
            onChange={e => setMotivo(e.target.value)}
            rows={2}
            placeholder="Ej: cliente pide cambiar Naranja por Pomelo, sin stock del original, etc."
            className="w-full px-3 py-2 border rounded-lg resize-none dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
          />
        </div>

        {error && (
          <div className="flex items-start gap-2 p-3 rounded-lg bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-sm text-red-700 dark:text-red-300">
            <AlertTriangle className="w-4 h-4 mt-0.5 flex-shrink-0" />
            <p>{error}</p>
          </div>
        )}
      </div>

      <div className="flex justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <button
          onClick={onClose}
          disabled={sustituirMut.isPending}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg disabled:opacity-50"
        >
          Cancelar
        </button>
        <button
          onClick={handleConfirmar}
          disabled={!puedeConfirmar}
          className="flex items-center gap-2 px-4 py-2 bg-blue-600 hover:bg-blue-700 text-white rounded-lg disabled:opacity-50"
        >
          {sustituirMut.isPending && <Loader2 className="w-4 h-4 animate-spin" />}
          Sustituir regalo
        </button>
      </div>
    </ModalBase>
  )
})

export default ModalSustituirRegalo
