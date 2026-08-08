/**
 * ProductoCondicionesMayoristas
 *
 * Sección de la ficha que responde "¿a cuánto termino vendiendo esto por mayor,
 * cuánto gano, y con qué otros sabores se combina?".
 *
 * Las condiciones están modeladas al revés de como las mira el dueño: un grupo
 * tiene N productos y M escalas, y él quiere ver, para UN sabor, a qué precio
 * sale en cada escala. Esto invierte la relación sin tocar el modelo.
 *
 * El punto importante es el selector "sumar a una condición": el motor ya suma
 * todo lo que el cliente lleve de los productos de una condición, pero como
 * cargar un sabor nuevo era más fácil creándole condición propia, terminaron
 * 82 de 88 condiciones con un solo producto y el fardo surtido nunca se activa.
 *
 * Vive aparte de ModalProducto a propósito: ese archivo ya tiene 754 líneas.
 */
import { useMemo, useState } from 'react'
import { Loader2, Plus, Tag, X } from 'lucide-react'
import {
  useProductosQuery,
  useGruposPrecioQuery,
  useGruposPrecioPorProductoQuery,
  useAgregarProductoACondicionMutation,
  useQuitarProductoDeCondicionMutation,
  useCrearEscalaMutation,
  useCrearCondicionParaProductoMutation,
} from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import { describirReglaEscala } from '../../utils/describirReglaEscala'
import CondicionEscalaFila from './CondicionEscalaFila'
import FormEscalaMayorista from './FormEscalaMayorista'
import type { ValoresEscala } from './FormEscalaMayorista'

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
  /** Solo admin gestiona condiciones. */
  puedeEditar?: boolean
  /** Abre el modal de condición mayorista con este producto preseleccionado. */
  onCrearCondicion?: () => void
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
  const notify = useNotification()
  const { condiciones, isLoading } = useGruposPrecioPorProductoQuery(productoId)
  const { data: grupos = [] } = useGruposPrecioQuery()
  const { data: productos = [] } = useProductosQuery()

  const agregarACondicion = useAgregarProductoACondicionMutation()
  const quitarDeCondicion = useQuitarProductoDeCondicionMutation()
  const crearEscala = useCrearEscalaMutation()
  const crearCondicionPropia = useCrearCondicionParaProductoMutation()

  /** grupoId con el form de escala nueva abierto. */
  const [agregandoEscalaEn, setAgregandoEscalaEn] = useState<string | null>(null)
  /** grupoId con la confirmación de "quitar de la condición" abierta. */
  const [quitandoDe, setQuitandoDe] = useState<string | null>(null)
  const [sumarAbierto, setSumarAbierto] = useState(false)
  /** Form abierto para darle a este producto su primer precio por cantidad. */
  const [creandoPropia, setCreandoPropia] = useState(false)

  // `describirReglaEscala` nombra los productos de las escalas combinadas; sin
  // el mapa imprime "#123" y la regla se vuelve ilegible.
  const nombresProductos = useMemo(() => {
    const map = new Map<string, string>()
    for (const p of productos) map.set(String(p.id), p.nombre)
    return map
  }, [productos])

  const idsConCondicion = useMemo(
    () => new Set(condiciones.map(c => c.grupoId)),
    [condiciones],
  )

  /** Condiciones activas donde este producto todavía no está. */
  const condicionesDisponibles = useMemo(
    () => grupos
      .filter(g => g.activo !== false && !idsConCondicion.has(String(g.id)))
      .sort((a, b) => a.nombre.localeCompare(b.nombre)),
    [grupos, idsConCondicion],
  )

  const sumarA = async (grupoId: string): Promise<void> => {
    try {
      await agregarACondicion.mutateAsync({ grupoId, productoId })
      const nombre = grupos.find(g => String(g.id) === grupoId)?.nombre ?? 'la condición'
      notify.success(`Este producto ahora entra en "${nombre}"`)
      setSumarAbierto(false)
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo sumar el producto a la condición')
    }
  }

  const quitarDe = async (grupoId: string, nombre: string): Promise<void> => {
    try {
      await quitarDeCondicion.mutateAsync({ grupoId, productoId })
      notify.success(`Este producto salió de "${nombre}"`)
      setQuitandoDe(null)
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo quitar el producto de la condición')
    }
  }

  const crearPropia = async (valores: ValoresEscala): Promise<void> => {
    try {
      await crearCondicionPropia.mutateAsync({
        productoId,
        cantidadMinima: valores.cantidadMinima,
        precioUnitario: valores.precioUnitario,
        etiqueta: valores.etiqueta,
      })
      notify.success('Precio por cantidad cargado')
      setCreandoPropia(false)
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo cargar el precio')
    }
  }

  const agregarEscala = async (grupoId: string, valores: ValoresEscala): Promise<void> => {
    try {
      await crearEscala.mutateAsync({
        grupoId,
        cantidadMinima: valores.cantidadMinima,
        precioUnitario: valores.precioUnitario,
        etiqueta: valores.etiqueta,
      })
      notify.success('Precio por cantidad agregado')
      setAgregandoEscalaEn(null)
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo agregar la escala')
    }
  }

  const selectorSumar = (
    <div className="flex flex-wrap items-center gap-2">
      <label className="sr-only" htmlFor="sumar-a-condicion">Sumar a una condición</label>
      <select
        id="sumar-a-condicion"
        defaultValue=""
        onChange={e => { if (e.target.value) void sumarA(e.target.value) }}
        disabled={agregarACondicion.isPending}
        className="px-2 py-1 border rounded text-sm dark:bg-gray-800 dark:border-gray-600 dark:text-white"
      >
        <option value="">Elegí una condición…</option>
        {condicionesDisponibles.map(g => (
          <option key={g.id} value={String(g.id)}>
            {g.nombre} ({g.productos.length} producto{g.productos.length === 1 ? '' : 's'})
          </option>
        ))}
      </select>
      <button
        type="button"
        onClick={() => setSumarAbierto(false)}
        className="text-xs text-stone-500 hover:text-stone-700 dark:text-gray-400"
      >
        Cancelar
      </button>
    </div>
  )

  return (
    <section className="border-t dark:border-gray-700 pt-4">
      <div className="flex items-center justify-between gap-2 mb-2">
        <h3 className="text-sm font-medium flex items-center gap-1.5 dark:text-white">
          <Tag className="w-4 h-4 text-indigo-600" aria-hidden="true" />
          Condiciones mayoristas
        </h3>
        {puedeEditar && condiciones.length > 0 && condicionesDisponibles.length > 0 && !sumarAbierto && (
          <button
            type="button"
            onClick={() => setSumarAbierto(true)}
            className="inline-flex items-center gap-1 text-sm text-blue-600 hover:text-blue-700"
          >
            <Plus className="w-4 h-4" aria-hidden="true" />
            Sumar a otra condición
          </button>
        )}
      </div>

      {puedeEditar && sumarAbierto && <div className="mb-3">{selectorSumar}</div>}

      {isLoading ? (
        <p className="flex items-center gap-2 text-xs text-stone-500">
          <Loader2 className="w-3.5 h-3.5 animate-spin" aria-hidden="true" />
          Cargando condiciones…
        </p>
      ) : condiciones.length === 0 ? (
        <div className="space-y-2">
          <p className="text-xs text-stone-500 dark:text-gray-400">
            Este producto no está en ninguna condición mayorista: siempre se vende al precio de lista.
          </p>
          {puedeEditar && !sumarAbierto && (
            creandoPropia ? (
              <FormEscalaMayorista
                precioLista={precioLista}
                costoTotal={costoTotal}
                costoReal={costoReal}
                porcentajeIva={porcentajeIva}
                guardando={crearCondicionPropia.isPending}
                textoGuardar="Guardar precio"
                onGuardar={valores => void crearPropia(valores)}
                onCancelar={() => setCreandoPropia(false)}
              />
            ) : (
              <div className="flex flex-wrap items-center gap-2">
                {/* El camino directo: "de este sabor, a partir de 12, $850".
                    La condición se crea por debajo con el nombre del producto;
                    no hay que decidir nada más. */}
                <button
                  type="button"
                  onClick={() => setCreandoPropia(true)}
                  className="inline-flex items-center gap-1 px-2 py-1 text-xs rounded bg-indigo-600 text-white"
                >
                  <Plus className="w-3.5 h-3.5" aria-hidden="true" />
                  Ponerle precio por cantidad
                </button>

                {/* Sumarlo a un fardo que ya existe: es lo que hace que la
                    mezcla entre sabores cuente para el mínimo. */}
                {condicionesDisponibles.length > 0 && (
                  <>
                    <span className="text-xs text-stone-400">o</span>
                    <button
                      type="button"
                      onClick={() => setSumarAbierto(true)}
                      className="text-xs text-blue-600 hover:text-blue-700"
                    >
                      sumarlo a una condición existente
                    </button>
                  </>
                )}

                {onCrearCondicion && (
                  <>
                    <span className="text-xs text-stone-400">o</span>
                    <button
                      type="button"
                      onClick={onCrearCondicion}
                      className="text-xs text-blue-600 hover:text-blue-700"
                    >
                      armar una condición con varios productos
                    </button>
                  </>
                )}
              </div>
            )
          )}
        </div>
      ) : (
        <div className="space-y-3">
          {condiciones.map(cond => {
            const compartida = cond.cantidadProductos > 1
            const otros = grupos
              .find(g => String(g.id) === cond.grupoId)?.productos
              .map(p => nombresProductos.get(String(p.producto_id)))
              .filter((n): n is string => !!n && n !== nombresProductos.get(String(productoId))) ?? []

            return (
              <div
                key={cond.grupoId}
                className={`rounded-lg border dark:border-gray-700 ${cond.activo ? '' : 'opacity-60'}`}
              >
                <div className="px-3 py-2 border-b dark:border-gray-700 bg-stone-50 dark:bg-gray-900/40 rounded-t-lg">
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        <span className="text-sm font-medium dark:text-white">{cond.grupoNombre}</span>
                        <span className="text-xs text-stone-500 dark:text-gray-400">
                          {cond.cantidadProductos} producto{cond.cantidadProductos === 1 ? '' : 's'}
                        </span>
                        {!cond.activo && (
                          <span className="text-xs px-1.5 py-0.5 rounded bg-stone-200 dark:bg-gray-700 text-stone-600 dark:text-gray-300">
                            desactivada
                          </span>
                        )}
                      </div>
                      {/* Con quién se combina: sin esto, el aviso de "afecta a
                          N productos" al editar el precio llega tarde. */}
                      {compartida && otros.length > 0 && (
                        <p className="text-xs text-stone-500 dark:text-gray-400 mt-0.5" title={otros.join(', ')}>
                          Suma con {otros.slice(0, 3).join(', ')}
                          {otros.length > 3 ? ` y ${otros.length - 3} más` : ''}
                        </p>
                      )}
                      {/* Varias condiciones tienen la descripción igual al
                          nombre; repetirla no aporta y ensucia la ficha. */}
                      {cond.descripcion && cond.descripcion.trim() !== cond.grupoNombre.trim() && (
                        <p className="text-xs text-stone-500 dark:text-gray-400 mt-0.5">{cond.descripcion}</p>
                      )}
                    </div>

                    {puedeEditar && (
                      quitandoDe === cond.grupoId ? (
                        <div className="flex items-center gap-1.5 shrink-0">
                          <span className="text-xs text-stone-600 dark:text-gray-300">¿Sacarlo?</span>
                          <button
                            type="button"
                            onClick={() => setQuitandoDe(null)}
                            className="px-2 py-0.5 text-xs rounded border dark:border-gray-600 dark:text-gray-200"
                          >
                            No
                          </button>
                          <button
                            type="button"
                            onClick={() => void quitarDe(cond.grupoId, cond.grupoNombre)}
                            disabled={quitarDeCondicion.isPending}
                            className="px-2 py-0.5 text-xs rounded bg-rose-600 text-white disabled:opacity-50"
                          >
                            Sí
                          </button>
                        </div>
                      ) : (
                        <button
                          type="button"
                          onClick={() => setQuitandoDe(cond.grupoId)}
                          className="shrink-0 p-1 rounded text-stone-400 hover:text-rose-600 hover:bg-rose-50 dark:hover:bg-rose-900/20"
                          aria-label={`Sacar este producto de ${cond.grupoNombre}`}
                          title="Sacar este producto de la condición"
                        >
                          <X className="w-3.5 h-3.5" aria-hidden="true" />
                        </button>
                      )
                    )}
                  </div>
                </div>

                {cond.escalas.length === 0 ? (
                  <p className="px-3 py-2 text-xs text-stone-500 dark:text-gray-400">
                    Sin escalas cargadas: la condición no aplica ningún precio.
                  </p>
                ) : (
                  <ul className="divide-y dark:divide-gray-700">
                    {cond.escalas.map(escala => (
                      <CondicionEscalaFila
                        key={escala.escalaId}
                        escala={escala}
                        regla={describirReglaEscala(escala.escala, { nombresProductos })}
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

                {puedeEditar && (
                  <div className="px-3 py-2 border-t dark:border-gray-700">
                    {agregandoEscalaEn === cond.grupoId ? (
                      <FormEscalaMayorista
                        precioLista={precioLista}
                        costoTotal={costoTotal}
                        costoReal={costoReal}
                        porcentajeIva={porcentajeIva}
                        guardando={crearEscala.isPending}
                        textoGuardar="Agregar"
                        onGuardar={valores => void agregarEscala(cond.grupoId, valores)}
                        onCancelar={() => setAgregandoEscalaEn(null)}
                      />
                    ) : (
                      <button
                        type="button"
                        onClick={() => setAgregandoEscalaEn(cond.grupoId)}
                        className="inline-flex items-center gap-1 text-xs text-blue-600 hover:text-blue-700"
                      >
                        <Plus className="w-3.5 h-3.5" aria-hidden="true" />
                        Agregar precio por cantidad
                      </button>
                    )}
                  </div>
                )}
              </div>
            )
          })}
        </div>
      )}
    </section>
  )
}
