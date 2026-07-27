/**
 * ProductoCondicionesMayoristas
 *
 * Sección de la ficha de producto que responde "¿a cuánto termino vendiendo
 * esto por mayor y cuánto gano?". Hasta ahora las condiciones mayoristas solo
 * se veían desde /grupos-precio, agrupadas al revés: por grupo, con N productos
 * adentro. Para saber el margen de UN sabor había que abrir cada grupo.
 *
 * Vive aparte de ModalProducto a propósito: ese archivo ya tiene 754 líneas.
 *
 * Los márgenes usan exactamente las mismas dos definiciones que los inputs de
 * margen de la ficha (mig 123), para que los números sean comparables:
 *   · bruto = precio final vs costo total con IVA
 *   · neto  = precio neto (sin IVA) vs costo real (neto + II)
 */
import { useMemo, useState } from 'react'
import { Loader2, Pencil, Plus, Tag } from 'lucide-react'
import {
  useProductosQuery,
  useGruposPrecioPorProductoQuery,
  useActualizarPrecioEscalaMutation,
} from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import { describirReglaEscala } from '../../utils/describirReglaEscala'
import { calcularMargenPorcentaje, calcularNetoDesdeTotal, parsePrecio } from '../../utils/calculations'
import { formatPrecio } from '../../utils/formatters'
import type { EscalaDeProducto } from '../../utils/condicionesMayoristas'

export interface ProductoCondicionesMayoristasProps {
  /** Producto en edición. Sin id (alta nueva) la sección no se muestra. */
  productoId: string
  /** Precio de lista actual del form, para calcular el descuento mayorista. */
  precioLista: number
  /** Costo total con IVA (desembolso), para el margen bruto. */
  costoTotal: number
  /** Costo real canónico (neto + II), para el margen neto. */
  costoReal: number
  /** IVA del producto, para bajar el precio mayorista a neto. */
  porcentajeIva: number
  /** Solo admin edita precios de escala. */
  puedeEditar?: boolean
  /** Abre el modal de condición mayorista con este producto preseleccionado. */
  onCrearCondicion?: () => void
}

/** Margen bruto y neto de un precio final, con las definiciones de la ficha. */
function margenes(
  precioFinal: number,
  costoTotal: number,
  costoReal: number,
  porcentajeIva: number,
): { bruto: number | null; neto: number | null } {
  const precioNeto = calcularNetoDesdeTotal(precioFinal, porcentajeIva, 0)
  return {
    bruto: costoTotal > 0 && precioFinal > 0 ? calcularMargenPorcentaje(precioFinal, costoTotal) : null,
    neto: costoReal > 0 && precioNeto > 0 ? calcularMargenPorcentaje(precioNeto, costoReal) : null,
  }
}

function ChipMargen({ label, valor }: { label: string; valor: number | null }) {
  if (valor === null) {
    return <span className="text-xs text-stone-400">{label} —</span>
  }
  const negativo = valor < 0
  return (
    <span
      className={`text-xs font-medium tabular-nums ${
        negativo ? 'text-rose-600 dark:text-rose-400' : 'text-emerald-700 dark:text-emerald-400'
      }`}
    >
      {label} {valor.toFixed(1)}%
    </span>
  )
}

interface FilaEscalaProps {
  escala: EscalaDeProducto
  regla: string
  productoId: string
  precioLista: number
  costoTotal: number
  costoReal: number
  porcentajeIva: number
  cantidadProductosGrupo: number
  puedeEditar: boolean
}

function FilaEscala({
  escala,
  regla,
  productoId,
  precioLista,
  costoTotal,
  costoReal,
  porcentajeIva,
  cantidadProductosGrupo,
  puedeEditar,
}: FilaEscalaProps) {
  const notify = useNotification()
  const mutation = useActualizarPrecioEscalaMutation()
  const [editando, setEditando] = useState(false)
  const [draft, setDraft] = useState('')

  // Mientras se edita, el margen se recalcula con lo tipeado — mismo
  // comportamiento bidireccional que los inputs de margen de la ficha.
  const precioMostrado = editando ? parsePrecio(draft) : escala.precioEfectivo
  const { bruto, neto } = margenes(precioMostrado, costoTotal, costoReal, porcentajeIva)
  const descuento = precioLista > 0 && precioMostrado > 0
    ? (1 - precioMostrado / precioLista) * 100
    : null

  // Un override es propio de este producto; el precio de escala lo comparten
  // todos los del grupo. Decir cuál se está tocando evita el cambio sorpresa.
  const afectaAlGrupo = !escala.esOverride && cantidadProductosGrupo > 1

  const abrirEdicion = (): void => {
    setDraft(String(escala.precioEfectivo))
    setEditando(true)
  }

  const guardar = async (): Promise<void> => {
    const precio = parsePrecio(draft)
    if (!(precio > 0)) {
      notify.error('El precio mayorista debe ser mayor a 0')
      return
    }
    if (precio === escala.precioEfectivo) {
      setEditando(false)
      return
    }
    try {
      await mutation.mutateAsync({
        escalaId: escala.escalaId,
        productoId,
        precio,
        alcance: escala.esOverride ? 'override' : 'grupo',
      })
      notify.success(
        escala.esOverride
          ? 'Precio actualizado para este producto'
          : `Precio de la escala actualizado (${cantidadProductosGrupo} producto${cantidadProductosGrupo === 1 ? '' : 's'})`,
      )
      setEditando(false)
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo actualizar el precio')
    }
  }

  return (
    <li className={`px-3 py-2.5 ${escala.activo ? '' : 'opacity-60'}`}>
      <div className="flex flex-col sm:flex-row sm:items-start sm:justify-between gap-2">
        <div className="min-w-0 sm:flex-1">
          <p className="text-xs text-stone-600 dark:text-gray-300">{regla}</p>
          <div className="flex items-center gap-2 flex-wrap mt-1">
            <ChipMargen label="Bruto" valor={bruto} />
            <span className="text-stone-300">·</span>
            <ChipMargen label="Neto" valor={neto} />
            {descuento !== null && (
              <>
                <span className="text-stone-300">·</span>
                <span className="text-xs text-stone-500 dark:text-gray-400 tabular-nums">
                  {descuento >= 0 ? `${descuento.toFixed(1)}% bajo lista` : `${Math.abs(descuento).toFixed(1)}% sobre lista`}
                </span>
              </>
            )}
            {!escala.activo && (
              <span className="text-xs px-1.5 py-0.5 rounded bg-stone-100 dark:bg-gray-700 text-stone-500">
                escala inactiva
              </span>
            )}
            {escala.esOverride && (
              <span className="text-xs px-1.5 py-0.5 rounded bg-indigo-100 dark:bg-indigo-900/40 text-indigo-700 dark:text-indigo-300">
                precio propio
              </span>
            )}
          </div>
        </div>

        <div className="shrink-0 sm:text-right">
          {editando ? (
            <div className="flex flex-col items-stretch sm:items-end gap-1">
              <input
                type="text"
                inputMode="decimal"
                autoFocus
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter') void guardar()
                  if (e.key === 'Escape') setEditando(false)
                }}
                className="w-28 px-2 py-1 border rounded text-sm text-right dark:bg-gray-800 dark:border-gray-600"
              />
              {afectaAlGrupo && (
                <p className="text-[11px] text-amber-700 dark:text-amber-400 max-w-[16rem]">
                  Afecta a los {cantidadProductosGrupo} productos del grupo.
                </p>
              )}
              <div className="flex gap-1 justify-end">
                <button
                  type="button"
                  onClick={() => setEditando(false)}
                  className="px-2 py-1 text-xs rounded border dark:border-gray-600 dark:text-gray-200"
                >
                  Cancelar
                </button>
                <button
                  type="button"
                  onClick={() => void guardar()}
                  disabled={mutation.isPending}
                  className="px-2 py-1 text-xs rounded bg-indigo-600 text-white disabled:opacity-50"
                >
                  {mutation.isPending ? 'Guardando…' : 'Guardar'}
                </button>
              </div>
            </div>
          ) : (
            <button
              type="button"
              onClick={puedeEditar ? abrirEdicion : undefined}
              disabled={!puedeEditar}
              className={`inline-flex items-center gap-1.5 text-sm font-semibold tabular-nums ${
                puedeEditar
                  ? 'text-blue-600 dark:text-blue-400 hover:underline'
                  : 'text-stone-700 dark:text-gray-200 cursor-default'
              }`}
              title={puedeEditar ? 'Editar el precio de esta escala' : undefined}
            >
              {formatPrecio(escala.precioEfectivo)}
              {puedeEditar && <Pencil className="w-3 h-3" aria-hidden="true" />}
            </button>
          )}
        </div>
      </div>
    </li>
  )
}

export default function ProductoCondicionesMayoristas({
  productoId,
  precioLista,
  costoTotal,
  costoReal,
  porcentajeIva,
  puedeEditar = false,
  onCrearCondicion,
}: ProductoCondicionesMayoristasProps) {
  const { condiciones, isLoading } = useGruposPrecioPorProductoQuery(productoId)
  const { data: productos = [] } = useProductosQuery()

  // `describirReglaEscala` nombra los productos de las escalas combinadas; sin
  // el mapa imprime "#123" y la regla se vuelve ilegible.
  const nombresProductos = useMemo(() => {
    const map = new Map<string, string>()
    for (const p of productos) map.set(String(p.id), p.nombre)
    return map
  }, [productos])

  return (
    <section className="border-t dark:border-gray-700 pt-4">
      <div className="flex items-center justify-between gap-2 mb-2">
        <h3 className="text-sm font-medium flex items-center gap-1.5 dark:text-white">
          <Tag className="w-4 h-4 text-indigo-600" aria-hidden="true" />
          Condiciones mayoristas
        </h3>
        {puedeEditar && onCrearCondicion && (
          <button
            type="button"
            onClick={onCrearCondicion}
            className="inline-flex items-center gap-1 text-sm text-blue-600 hover:text-blue-700"
          >
            <Plus className="w-4 h-4" aria-hidden="true" />
            Crear condición
          </button>
        )}
      </div>

      {isLoading ? (
        <p className="flex items-center gap-2 text-xs text-stone-500">
          <Loader2 className="w-3.5 h-3.5 animate-spin" aria-hidden="true" />
          Cargando condiciones…
        </p>
      ) : condiciones.length === 0 ? (
        <p className="text-xs text-stone-500 dark:text-gray-400">
          Este producto no está en ninguna condición mayorista: siempre se vende al precio de lista.
        </p>
      ) : (
        <div className="space-y-3">
          {condiciones.map(cond => (
            <div
              key={cond.grupoId}
              className={`rounded-lg border dark:border-gray-700 ${cond.activo ? '' : 'opacity-60'}`}
            >
              <div className="px-3 py-2 border-b dark:border-gray-700 bg-stone-50 dark:bg-gray-900/40 rounded-t-lg">
                <div className="flex items-center gap-2 flex-wrap">
                  <span className="text-sm font-medium dark:text-white">{cond.grupoNombre}</span>
                  <span className="text-xs text-stone-500 dark:text-gray-400">
                    {cond.cantidadProductos} producto{cond.cantidadProductos === 1 ? '' : 's'}
                  </span>
                  {cond.moq && (
                    <span className="text-xs px-1.5 py-0.5 rounded bg-amber-100 dark:bg-amber-900/40 text-amber-700 dark:text-amber-300 font-medium">
                      mínimo {cond.moq}
                    </span>
                  )}
                  {!cond.activo && (
                    <span className="text-xs px-1.5 py-0.5 rounded bg-stone-200 dark:bg-gray-700 text-stone-600 dark:text-gray-300">
                      desactivada
                    </span>
                  )}
                </div>
                {cond.descripcion && (
                  <p className="text-xs text-stone-500 dark:text-gray-400 mt-0.5">{cond.descripcion}</p>
                )}
              </div>

              {cond.escalas.length === 0 ? (
                <p className="px-3 py-2 text-xs text-stone-500 dark:text-gray-400">
                  Sin escalas cargadas: la condición no aplica ningún precio.
                </p>
              ) : (
                <ul className="divide-y dark:divide-gray-700">
                  {cond.escalas.map(escala => (
                    <FilaEscala
                      key={escala.escalaId}
                      escala={escala}
                      regla={describirReglaEscala(escala.escala, { nombresProductos })}
                      productoId={productoId}
                      precioLista={precioLista}
                      costoTotal={costoTotal}
                      costoReal={costoReal}
                      porcentajeIva={porcentajeIva}
                      cantidadProductosGrupo={cond.cantidadProductos}
                      puedeEditar={puedeEditar}
                    />
                  ))}
                </ul>
              )}
            </div>
          ))}
        </div>
      )}
    </section>
  )
}
