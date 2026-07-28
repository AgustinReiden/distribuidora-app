/**
 * ModalMinimoVentaMasivo
 *
 * "La compra mínima de cada sabor quiero que sea 3 unidades": carga el mínimo
 * de venta a TODOS los productos de una categoría de una sola vez, en vez de
 * abrir la ficha de los 37 fideos uno por uno.
 *
 * Escribe vía el RPC `actualizar_minimo_venta_masivo` (mig 147), que valida el
 * rol y acota el UPDATE a la sucursal activa. La previsualización de acá es
 * informativa: la fuente de verdad del alcance es el RPC.
 */
import { useMemo, useState } from 'react'
import { PackageMinus, AlertTriangle } from 'lucide-react'
import ModalBase from './ModalBase'
import NumberInput from '../ui/NumberInput'
import { useActualizarMinimoVentaMasivoMutation } from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import type { CategoriaDB } from '../../hooks/queries/useCategoriasQuery'
import type { ProductoDB } from '../../types'

const PREVIEW_LIMIT = 8

export interface ModalMinimoVentaMasivoProps {
  productos: ProductoDB[]
  categorias: CategoriaDB[]
  onClose: () => void
}

export default function ModalMinimoVentaMasivo({
  productos,
  categorias,
  onClose,
}: ModalMinimoVentaMasivoProps) {
  const notify = useNotification()
  const mutation = useActualizarMinimoVentaMasivoMutation()

  const [categoriaId, setCategoriaId] = useState<string>('')
  const [cantidad, setCantidad] = useState<number>(3)

  const categoriasActivas = useMemo(
    () => categorias.filter(c => c.activa !== false),
    [categorias],
  )

  const categoriaSeleccionada = useMemo(
    () => categoriasActivas.find(c => c.id === categoriaId) ?? null,
    [categoriasActivas, categoriaId],
  )

  // El RPC actualiza por `categoria_id`, así que el alcance real es ese.
  const afectados = useMemo(
    () => (categoriaId ? productos.filter(p => p.categoria_id === categoriaId) : []),
    [productos, categoriaId],
  )

  // Productos que dicen tener esta categoría por texto pero quedaron sin FK
  // (el trigger de la mig 146 no encontró match). El RPC NO los va a tocar y
  // esconderlo sería justo el problema que la fase venía a resolver.
  const sinVinculo = useMemo(() => {
    if (!categoriaSeleccionada) return []
    const nombre = categoriaSeleccionada.nombre.trim().toLowerCase()
    return productos.filter(
      p => !p.categoria_id && (p.categoria || '').trim().toLowerCase() === nombre,
    )
  }, [productos, categoriaSeleccionada])

  const quitaMinimo = cantidad <= 0
  const puedeAplicar = Boolean(categoriaId) && afectados.length > 0 && !mutation.isPending

  const handleAplicar = async (): Promise<void> => {
    if (!puedeAplicar || !categoriaSeleccionada) return
    try {
      const res = await mutation.mutateAsync({
        categoriaId,
        cantidad: quitaMinimo ? null : cantidad,
      })
      const n = res.actualizados
      notify.success(
        quitaMinimo
          ? `Mínimo de venta quitado en ${n} producto${n === 1 ? '' : 's'} de ${categoriaSeleccionada.nombre}`
          : `Mínimo de ${cantidad} aplicado a ${n} producto${n === 1 ? '' : 's'} de ${categoriaSeleccionada.nombre}`,
      )
      onClose()
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo aplicar el mínimo de venta')
    }
  }

  return (
    <ModalBase
      title="Mínimo de venta por categoría"
      description="Aplica una compra mínima a todos los productos de una categoría"
      onClose={onClose}
      maxWidth="max-w-lg"
    >
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        <div className="flex items-start gap-3 p-3 rounded-lg bg-stone-50 dark:bg-gray-900/40 border border-stone-200 dark:border-gray-700">
          <PackageMinus className="w-5 h-5 shrink-0 mt-0.5 text-indigo-600" aria-hidden="true" />
          <p className="text-xs text-stone-600 dark:text-gray-300">
            El mínimo de venta es lo menos que se puede pedir de cada producto. Bloquea el pedido
            en la app y en el bot. No tiene nada que ver con el stock mínimo de seguridad, que solo
            avisa cuándo reponer.
          </p>
        </div>

        <div>
          <label htmlFor="minimo-categoria" className="block text-sm font-medium mb-1">
            Categoría
          </label>
          <select
            id="minimo-categoria"
            value={categoriaId}
            onChange={(e) => setCategoriaId(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-800 dark:border-gray-600"
          >
            <option value="">Elegí una categoría…</option>
            {categoriasActivas.map(c => (
              <option key={c.id} value={c.id}>{c.nombre}</option>
            ))}
          </select>
        </div>

        <div>
          <label htmlFor="minimo-cantidad" className="block text-sm font-medium mb-1">
            Mínimo de unidades
          </label>
          <NumberInput
            id="minimo-cantidad"
            integer
            min={0}
            emptyValue={0}
            value={cantidad}
            onChange={setCantidad}
            commitOnChange
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-800 dark:border-gray-600"
          />
          <p className="text-xs text-gray-500 mt-1">
            0 quita el mínimo de toda la categoría.
          </p>
        </div>

        {categoriaId && (
          <div className="rounded-lg border border-stone-200 dark:border-gray-700 p-3">
            {afectados.length === 0 ? (
              <p className="text-sm text-stone-600 dark:text-gray-300">
                No hay productos en esta categoría en la sucursal activa.
              </p>
            ) : (
              <>
                <p className="text-sm font-medium dark:text-white">
                  {quitaMinimo
                    ? `Se quitará el mínimo a ${afectados.length} producto${afectados.length === 1 ? '' : 's'}`
                    : `Se aplicará un mínimo de ${cantidad} a ${afectados.length} producto${afectados.length === 1 ? '' : 's'}`}
                </p>
                <ul className="mt-2 space-y-0.5 text-xs text-stone-600 dark:text-gray-300">
                  {afectados.slice(0, PREVIEW_LIMIT).map(p => (
                    <li key={p.id} className="flex justify-between gap-3">
                      <span className="truncate">{p.nombre}</span>
                      <span className="shrink-0 tabular-nums text-stone-400">
                        {p.cantidad_minima_venta ? `min ${p.cantidad_minima_venta}` : 'sin mínimo'}
                      </span>
                    </li>
                  ))}
                </ul>
                {afectados.length > PREVIEW_LIMIT && (
                  <p className="text-xs text-stone-400 mt-1">
                    y {afectados.length - PREVIEW_LIMIT} más…
                  </p>
                )}
              </>
            )}
          </div>
        )}

        {sinVinculo.length > 0 && (
          <div className="flex items-start gap-3 p-3 rounded-lg border border-amber-300 dark:border-amber-700/60 bg-amber-50 dark:bg-amber-900/20">
            <AlertTriangle className="w-5 h-5 shrink-0 mt-0.5 text-amber-600" aria-hidden="true" />
            <div className="min-w-0">
              <p className="text-sm font-medium text-amber-800 dark:text-amber-200">
                {sinVinculo.length} producto{sinVinculo.length === 1 ? '' : 's'} quedan afuera
              </p>
              <p className="text-xs text-amber-700 dark:text-amber-300 mt-0.5">
                Dicen «{categoriaSeleccionada?.nombre}» pero no están vinculados a la categoría.
                Reasignales la categoría desde su ficha para que el mínimo los alcance.
              </p>
            </div>
          </div>
        )}
      </div>

      <div className="flex justify-end gap-2 p-4 border-t dark:border-gray-700">
        <button
          type="button"
          onClick={onClose}
          className="px-4 py-2 rounded-lg border dark:border-gray-600 text-sm dark:text-gray-200"
        >
          Cancelar
        </button>
        <button
          type="button"
          onClick={handleAplicar}
          disabled={!puedeAplicar}
          className="px-4 py-2 rounded-lg bg-indigo-600 text-white text-sm font-medium disabled:opacity-50 disabled:cursor-not-allowed hover:bg-indigo-700"
        >
          {mutation.isPending ? 'Aplicando…' : quitaMinimo ? 'Quitar mínimo' : 'Aplicar mínimo'}
        </button>
      </div>
    </ModalBase>
  )
}
