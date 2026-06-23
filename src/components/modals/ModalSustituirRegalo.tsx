/**
 * ModalSustituirRegalo
 *
 * Permite a un admin/encargado cambiar el producto de un item bonificacion
 * en un pedido (regalo de una promocion). Justifica con motivo y autoriza
 * la operacion.
 *
 * Diseno didactico (rediseno mig 063):
 *   - Solo 3 campos visibles: producto nuevo, cantidad, motivo.
 *   - Banner explica en lenguaje de negocio con NUMEROS REALES del caso
 *     (nombres de productos, barra de progreso actual y proyectada). Sin
 *     jerga tecnica "Modo A/B", "fardo", "acumulador", "contenedor" en
 *     la vista principal.
 *   - El campo "contenedor del sustituto" se esconde en "Configuracion
 *     avanzada" (collapsible). Default: el propio producto sustituto
 *     (auto-inferido por el RPC con mig 063 si se manda NULL).
 *
 * Llama a la RPC `sustituir_regalo_pedido` via useSustituirRegaloMutation.
 * Maneja idempotencia (UUID generado en el primer render).
 */
import { useMemo, useState, memo } from 'react'
import { Loader2, Gift, AlertTriangle, ChevronDown, ChevronUp, Info } from 'lucide-react'
import ModalBase from './ModalBase'
import NumberInput from '../ui/NumberInput'
import { useProductosQuery, usePromoAcumuladorQuery } from '../../hooks/queries'
import { useSustituirRegaloMutation } from '../../hooks/queries/useSustituirRegaloMutation'
import { useNotification } from '../../contexts/NotificationContext'
import type { ProductoDB } from '../../types'

export interface ModalSustituirRegaloProps {
  pedidoItemId: string
  productoOriginal: ProductoDB
  cantidadOriginal: number
  /** Modo de la promo. true = stock por unidad, false = ajuste por bloque. */
  regaloMueveStock: boolean
  /** Promo asociada al regalo. Necesaria para cargar el acumulador. */
  promocionId?: string | number | null
  /** Unidades por bloque de la promo (modo B). Para mostrar X/N en banner. */
  unidadesPorBloque?: number | null
  /** Contenedor configurado en la promo original. Se muestra en avanzado. */
  ajusteProductoIdOriginal?: string | null
  onClose: () => void
  /** Callback al confirmar exitosamente (para que el caller refresque). */
  onSustituido?: () => void
}

const ModalSustituirRegalo = memo(function ModalSustituirRegalo({
  pedidoItemId,
  productoOriginal,
  cantidadOriginal,
  regaloMueveStock,
  promocionId = null,
  unidadesPorBloque = null,
  ajusteProductoIdOriginal = null,
  onClose,
  onSustituido,
}: ModalSustituirRegaloProps) {
  const notify = useNotification()
  const { data: productos = [] } = useProductosQuery()
  const sustituirMut = useSustituirRegaloMutation()

  // Acumuladores para mostrar barras "antes" y proyeccion "despues" (modo B)
  const { data: acumuladorOriginal } = usePromoAcumuladorQuery(
    !regaloMueveStock ? promocionId : null,
    productoOriginal.id,
  )

  // UUID estable por instancia del modal para idempotencia
  const clientRequestId = useMemo(() => crypto.randomUUID(), [])

  const [productoNuevoId, setProductoNuevoId] = useState<string>('')
  const [cantidadNueva, setCantidadNueva] = useState<string>(String(cantidadOriginal))
  const [motivo, setMotivo] = useState<string>('')
  const [error, setError] = useState<string>('')
  const [avanzadoOpen, setAvanzadoOpen] = useState<boolean>(false)
  // Contenedor del sustituto. Default vacio = el RPC infiere automaticamente
  // (mig 063): usa el propio producto sustituto como su contenedor. El admin
  // solo lo cambia si abre "Configuracion avanzada" y elige otro fardo.
  const [ajusteProductoIdNuevo, setAjusteProductoIdNuevo] = useState<string>('')

  const productoNuevo = useMemo(
    () => productos.find(p => String(p.id) === String(productoNuevoId)) ?? null,
    [productos, productoNuevoId]
  )

  // Acumulador del sustituto (puede no existir aun)
  const { data: acumuladorSustituto } = usePromoAcumuladorQuery(
    !regaloMueveStock && productoNuevoId ? promocionId : null,
    productoNuevoId || null,
  )

  // Productos ordenados, excluyendo el original
  const productosOpciones = useMemo(
    () => productos
      .filter(p => String(p.id) !== String(productoOriginal.id))
      .slice()
      .sort((a, b) => (a.nombre || '').localeCompare(b.nombre || '')),
    [productos, productoOriginal.id]
  )

  const cantidadNum = parseFloat(cantidadNueva) || 0
  // Modo A descuenta stock inmediato → validar stock disponible.
  // Modo B no mueve stock unitario → no se valida.
  const stockSuficiente = !regaloMueveStock
    || productoNuevo == null
    || (productoNuevo.stock ?? 0) >= cantidadNum
  const puedeConfirmar = !!productoNuevoId
    && cantidadNum > 0
    && motivo.trim().length > 0
    && stockSuficiente
    && !sustituirMut.isPending

  // Calculos para el banner didactico (modo B)
  const usosOrigAntes = Number(acumuladorOriginal?.usos_pendientes ?? 0)
  const usosOrigDespues = usosOrigAntes - cantidadOriginal
  const usosSustAntes = Number(acumuladorSustituto?.usos_pendientes ?? 0)
  const usosSustDespues = usosSustAntes + cantidadNum
  const bloque = unidadesPorBloque ?? acumuladorOriginal?.unidades_por_bloque ?? 1
  // Defensa display: los acumuladores pueden venir fuera de rango (bug backend de bloques).
  // Clampeamos los valores que se muestran al usuario a [0, bloque].
  const clampBloque = (n: number) => Math.max(0, Math.min(n, bloque))
  const dispOrigAntes = clampBloque(usosOrigAntes)
  const dispOrigDespues = clampBloque(usosOrigDespues)
  const dispSustAntes = clampBloque(usosSustAntes)
  const dispSustDespues = clampBloque(usosSustDespues)
  const cruzaAbajo = Math.floor(usosOrigDespues / bloque) < Math.floor(usosOrigAntes / bloque)
  const cruzaArriba = Math.floor(usosSustDespues / bloque) > Math.floor(usosSustAntes / bloque)

  const handleConfirmar = async () => {
    setError('')
    if (!puedeConfirmar) return
    try {
      const result = await sustituirMut.mutateAsync({
        pedidoItemId,
        productoNuevoId,
        cantidadNueva: cantidadNum,
        motivo: motivo.trim(),
        // Si el admin no abrio avanzado o no eligio nada, mandamos null y
        // el RPC (mig 063) auto-infiere = productoSustitutoId. Si lo eligio
        // explicito, mandamos su eleccion.
        ajusteProductoIdNuevo: regaloMueveStock
          ? null
          : (ajusteProductoIdNuevo || null),
        clientRequestId,
      })
      notify.success(
        result.idempotentReplay
          ? 'Sustitucion ya estaba registrada'
          : 'Regalo cambiado correctamente'
      )
      onSustituido?.()
      onClose()
    } catch (err) {
      const msg = err instanceof Error ? err.message : 'Error al cambiar el regalo'
      setError(msg)
    }
  }

  return (
    <ModalBase title="Cambiar regalo" onClose={onClose} maxWidth="max-w-md">
      <div className="p-4 space-y-4">
        {/* Header: regalo actual */}
        <div className="bg-emerald-50 dark:bg-emerald-900/15 border border-emerald-200 dark:border-emerald-800 rounded-lg p-3">
          <p className="text-xs text-emerald-700 dark:text-emerald-300 mb-1 flex items-center gap-1">
            <Gift className="w-3 h-3" /> Regalo actual
          </p>
          <p className="font-semibold text-emerald-900 dark:text-emerald-100">
            {productoOriginal.nombre}
          </p>
          <p className="text-sm text-emerald-700 dark:text-emerald-300">
            Cantidad: <span className="font-medium">{cantidadOriginal}</span>
          </p>
        </div>

        {/* Producto sustituto */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Cambiarlo por *
          </label>
          <select
            value={productoNuevoId}
            onChange={e => setProductoNuevoId(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          >
            <option value="">Elegir producto nuevo...</option>
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
            Cantidad *
          </label>
          <NumberInput
            min={0}
            emptyValue={0}
            commitOnChange
            value={Number(cantidadNueva) || 0}
            onChange={(n) => setCantidadNueva(String(n))}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          />
          {productoNuevo && regaloMueveStock && !stockSuficiente && (
            <p className="text-xs text-red-600 mt-1 flex items-center gap-1">
              <AlertTriangle className="w-3 h-3" />
              No hay stock suficiente del nuevo producto ({productoNuevo.stock ?? 0} disponible)
            </p>
          )}
        </div>

        {/* Motivo */}
        <div>
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
            Motivo del cambio *
          </label>
          <textarea
            value={motivo}
            onChange={e => setMotivo(e.target.value)}
            rows={2}
            placeholder="Ej: el cliente prefiere otro sabor, no hay stock del original..."
            className="w-full px-3 py-2 border rounded-lg resize-none dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
          />
        </div>

        {/* Banner didactico: que va a pasar cuando confirmes */}
        {productoNuevo && cantidadNum > 0 && (
          <div className="flex items-start gap-2 p-3 rounded-lg bg-blue-50 dark:bg-blue-900/15 border border-blue-200 dark:border-blue-800 text-sm">
            <Info className="w-4 h-4 mt-0.5 flex-shrink-0 text-blue-600 dark:text-blue-400" />
            <div className="space-y-1 text-blue-900 dark:text-blue-100">
              <p className="font-medium">Cuando confirmes:</p>
              {regaloMueveStock ? (
                <>
                  <p>✓ Se devolveran <b>{cantidadOriginal} de {productoOriginal.nombre}</b> al stock.</p>
                  <p>✓ Se descontaran <b>{cantidadNum} de {productoNuevo.nombre}</b> del stock.</p>
                </>
              ) : (
                <>
                  <p>
                    ✓ El contador de <b>{productoOriginal.nombre}</b> baja
                    de <b>{dispOrigAntes}/{bloque}</b> a <b>{dispOrigDespues}/{bloque}</b>.
                  </p>
                  {cruzaAbajo && (
                    <p className="text-emerald-700 dark:text-emerald-300 ml-3">
                      → Se devolvera 1 fardo de {productoOriginal.nombre} al stock.
                    </p>
                  )}
                  <p>
                    ✓ El contador de <b>{productoNuevo.nombre}</b> sube
                    de <b>{dispSustAntes}/{bloque}</b> a <b>{dispSustDespues}/{bloque}</b>.
                  </p>
                  {cruzaArriba ? (
                    <p className="text-orange-700 dark:text-orange-300 ml-3">
                      → Se descontara 1 fardo de {productoNuevo.nombre} del stock ahora.
                    </p>
                  ) : (
                    <p className="text-gray-600 dark:text-gray-300 ml-3 text-xs">
                      → El stock no cambia ahora. Cuando el contador llegue a {bloque} se descontara 1 fardo de {productoNuevo.nombre} automaticamente.
                    </p>
                  )}
                </>
              )}
            </div>
          </div>
        )}

        {/* Configuracion avanzada — colapsada por default. Solo modo B. */}
        {!regaloMueveStock && (
          <div className="border-t border-gray-200 dark:border-gray-700 pt-3">
            <button
              type="button"
              onClick={() => setAvanzadoOpen(v => !v)}
              className="flex items-center gap-1 text-xs text-gray-500 dark:text-gray-400 hover:text-gray-700 dark:hover:text-gray-200"
            >
              {avanzadoOpen ? <ChevronUp className="w-3 h-3" /> : <ChevronDown className="w-3 h-3" />}
              Configuracion avanzada (opcional)
            </button>
            {avanzadoOpen && (
              <div className="mt-3 space-y-2">
                <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
                  Producto donde descontar el sustituto
                </label>
                <select
                  value={ajusteProductoIdNuevo}
                  onChange={e => setAjusteProductoIdNuevo(e.target.value)}
                  className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
                >
                  <option value="">
                    Automatico — usar el mismo producto sustituto (recomendado)
                  </option>
                  {productosOpciones.map(p => (
                    <option key={`cont-${p.id}`} value={p.id}>
                      {p.nombre}
                      {ajusteProductoIdOriginal && String(p.id) === String(ajusteProductoIdOriginal)
                        ? ' · era el de la promo original'
                        : ''}
                    </option>
                  ))}
                </select>
                <p className="text-xs text-gray-500 dark:text-gray-400">
                  Por defecto el sistema usa el mismo producto sustituto como su propio
                  fardo (que es lo que tienen la mayoria de las promos). Cambialo solo
                  si el sustituto se descuenta de OTRO fardo distinto.
                </p>
              </div>
            )}
          </div>
        )}

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
          Cambiar regalo
        </button>
      </div>
    </ModalBase>
  )
})

export default ModalSustituirRegalo
