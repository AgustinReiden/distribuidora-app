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
 *
 * Reparto en sabores (mig 275, #831): con "Repartir en otro sabor" se agregan
 * filas y el regalo se reparte en N productos cuya suma tiene que ser la
 * cantidad original, en la misma unidad de la linea. Con dos filas o mas se
 * llama a `dividir_regalo_pedido`; con una sola, es la sustitucion de siempre.
 * La validacion vive en `utils/repartoRegalo`.
 */
import { useMemo, useState, memo } from 'react'
import { Gift, AlertTriangle, ChevronDown, ChevronUp, Info, Plus, Trash2 } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import NumberInput from '../ui/NumberInput'
import { useProductosQuery, usePromoAcumuladorQuery } from '../../hooks/queries'
import { useSustituirRegaloMutation, useDividirRegaloMutation } from '../../hooks/queries/useSustituirRegaloMutation'
import { validarRepartoRegalo, type ParteReparto } from '../../utils/repartoRegalo'
import { nuevoRequestId } from '../../utils/idempotencia'
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
  const dividirMut = useDividirRegaloMutation()
  const enviando = sustituirMut.isPending || dividirMut.isPending

  // Acumuladores para mostrar barras "antes" y proyeccion "despues" (modo B)
  const { data: acumuladorOriginal } = usePromoAcumuladorQuery(
    !regaloMueveStock ? promocionId : null,
    productoOriginal.id,
  )

  // UUID estable por instancia del modal para idempotencia
  // Uno por operacion: sustituir y repartir son RPCs distintas que dedupean
  // contra la misma columna, y un reintento de una no puede devolver el replay
  // de la otra ("El reparto ya estaba registrado" sobre una sustitucion).
  const clientRequestIdSustitucion = useMemo(() => nuevoRequestId(), [])
  const clientRequestIdReparto = useMemo(() => nuevoRequestId(), [])

  // Una fila = sustitucion comun. Dos o mas = reparto en sabores.
  const [filas, setFilas] = useState<ParteReparto[]>([
    { productoId: '', cantidad: cantidadOriginal },
  ])
  const esReparto = filas.length > 1
  const productoNuevoId = filas[0]?.productoId ?? ''
  const actualizarFila = (idx: number, cambio: Partial<ParteReparto>) =>
    setFilas(prev => prev.map((f, i) => (i === idx ? { ...f, ...cambio } : f)))
  const agregarFila = () =>
    setFilas(prev => {
      const asignadas = prev.reduce((acc, f) => acc + (Number(f.cantidad) || 0), 0)
      return [...prev, { productoId: '', cantidad: Math.max(cantidadOriginal - asignadas, 0) }]
    })
  const quitarFila = (idx: number) => setFilas(prev => prev.filter((_, i) => i !== idx))
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
  // En un reparto el cliente se puede quedar con parte del sabor original.
  const opcionesReparto = useMemo(
    () => [productoOriginal, ...productosOpciones],
    [productoOriginal, productosOpciones]
  )

  const cantidadNum = Number(filas[0]?.cantidad) || 0
  const validacion = validarRepartoRegalo(filas, cantidadOriginal, String(productoOriginal.id))
  // Modo A descuenta stock inmediato → validar stock disponible. Lo que vuelve
  // del regalo actual cuenta como disponible para su propio producto.
  // Modo B no mueve stock unitario → no se valida.
  const faltaStock = (fila: ParteReparto): boolean => {
    if (!regaloMueveStock || !fila.productoId) return false
    const prod = productos.find(p => String(p.id) === String(fila.productoId))
    if (!prod) return false
    const vuelve = String(prod.id) === String(productoOriginal.id) ? cantidadOriginal : 0
    return (prod.stock ?? 0) + vuelve < (Number(fila.cantidad) || 0)
  }
  const stockSuficiente = !filas.some(faltaStock)
  const puedeConfirmar = validacion.ok
    && motivo.trim().length > 0
    && stockSuficiente
    && !enviando

  // Calculos para el banner didactico (modo B)
  const usosOrigAntes = Number(acumuladorOriginal?.usos_pendientes ?? 0)
  const usosOrigDespues = usosOrigAntes - cantidadOriginal
  const usosSustAntes = Number(acumuladorSustituto?.usos_pendientes ?? 0)
  const usosSustDespues = usosSustAntes + cantidadNum
  // El factor sale de la promo en vivo: el acumulador ya no guarda copia (issue #535).
  const bloque = unidadesPorBloque ?? 1
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
      if (esReparto) {
        const result = await dividirMut.mutateAsync({
          pedidoItemId,
          partes: filas.map(f => ({ productoId: String(f.productoId), cantidad: Number(f.cantidad) })),
          motivo: motivo.trim(),
          clientRequestId: clientRequestIdReparto,
        })
        notify.success(
          result.idempotentReplay
            ? 'El reparto ya estaba registrado'
            : 'Regalo repartido correctamente'
        )
        onSustituido?.()
        onClose()
        return
      }
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
        clientRequestId: clientRequestIdSustitucion,
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

        {/* Producto(s) nuevo(s). Una fila = sustitucion; varias = reparto. */}
        <div className="space-y-2">
          <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
            {esReparto ? 'Repartirlo en *' : 'Cambiarlo por *'}
          </label>
          {filas.map((fila, idx) => {
            const prodFila = productos.find(p => String(p.id) === String(fila.productoId)) ?? null
            const opciones = esReparto ? opcionesReparto : productosOpciones
            return (
              <div key={idx} className="space-y-1">
                <div className="flex items-center gap-2">
                  <select
                    aria-label={`Producto ${idx + 1}`}
                    value={fila.productoId}
                    onChange={e => actualizarFila(idx, { productoId: e.target.value })}
                    className="flex-1 min-w-0 px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  >
                    <option value="">Elegir producto nuevo...</option>
                    {opciones.map(p => (
                      <option key={p.id} value={p.id}>
                        {p.nombre}
                        {String(p.id) === String(productoOriginal.id)
                          ? ' · el actual'
                          : ((p.stock ?? 0) > 0 ? ` · stock ${p.stock}` : ' · sin stock')}
                      </option>
                    ))}
                  </select>
                  <NumberInput
                    aria-label={`Cantidad ${idx + 1}`}
                    min={0}
                    emptyValue={0}
                    commitOnChange
                    value={Number(fila.cantidad) || 0}
                    onChange={(n) => actualizarFila(idx, { cantidad: n })}
                    className="w-20 px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  />
                  {esReparto && (
                    <Button
                      type="button"
                      onClick={() => quitarFila(idx)}
                      variant="ghost"
                      size="iconSm"
                      aria-label={`Quitar fila ${idx + 1}`}
                      className="text-red-500 dark:text-red-400 hover:bg-red-50 dark:hover:bg-red-900/20"
                    >
                      <Trash2 className="w-4 h-4" />
                    </Button>
                  )}
                </div>
                {prodFila && faltaStock(fila) && (
                  <p className="text-xs text-red-600 flex items-center gap-1">
                    <AlertTriangle className="w-3 h-3" />
                    No hay stock suficiente de {prodFila.nombre} ({prodFila.stock ?? 0} disponible)
                  </p>
                )}
              </div>
            )
          })}
          <div className="flex items-center justify-between gap-2">
            <Button
              type="button"
              onClick={agregarFila}
              variant="ghost"
              size="sm"
              className="gap-1 text-emerald-700 dark:text-emerald-300"
            >
              <Plus className="w-3.5 h-3.5" />
              Repartir en otro sabor
            </Button>
            {esReparto && (
              <p
                className={`text-xs font-medium ${validacion.faltante === 0
                  ? 'text-emerald-700 dark:text-emerald-300'
                  : 'text-amber-700 dark:text-amber-300'}`}
                aria-live="polite"
              >
                Asignado {validacion.asignado} de {cantidadOriginal}
                {validacion.faltante > 0 ? ` · faltan ${validacion.faltante}` : ''}
                {validacion.faltante < 0 ? ` · sobran ${-validacion.faltante}` : ''}
              </p>
            )}
          </div>
          {esReparto && (
            <p className="text-xs text-gray-500 dark:text-gray-400">
              Misma unidad que el regalo actual: la suma tiene que dar {cantidadOriginal}.
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

        {/* Reparto: resumen de lo que va a quedar */}
        {esReparto && validacion.ok && (
          <div className="flex items-start gap-2 p-3 rounded-lg bg-blue-50 dark:bg-blue-900/15 border border-blue-200 dark:border-blue-800 text-sm">
            <Info className="w-4 h-4 mt-0.5 flex-shrink-0 text-blue-600 dark:text-blue-400" />
            <div className="space-y-1 text-blue-900 dark:text-blue-100">
              <p className="font-medium">Cuando confirmes, el regalo queda en:</p>
              {filas.map((f, i) => (
                <p key={i}>
                  ✓ <b>{f.cantidad}</b> de{' '}
                  <b>{productos.find(p => String(p.id) === String(f.productoId))?.nombre ?? '?'}</b>
                </p>
              ))}
              <p className="text-xs text-gray-600 dark:text-gray-300">
                {regaloMueveStock
                  ? 'El stock se mueve por la diferencia de cada producto.'
                  : 'Los contadores de la promo se ajustan por la diferencia de cada sabor.'}
              </p>
            </div>
          </div>
        )}

        {/* Banner didactico: que va a pasar cuando confirmes */}
        {!esReparto && productoNuevo && cantidadNum > 0 && (
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
        {!regaloMueveStock && !esReparto && (
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
        <Button
          onClick={onClose}
          disabled={enviando}
          variant="ghost"
          size="md"
          className="text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600"
        >
          Cancelar
        </Button>
        <Button
          onClick={handleConfirmar}
          disabled={!puedeConfirmar}
          loading={enviando}
          variant="primary"
          size="md"
        >
          {esReparto ? 'Repartir regalo' : 'Cambiar regalo'}
        </Button>
      </div>
    </ModalBase>
  )
})

export default ModalSustituirRegalo
