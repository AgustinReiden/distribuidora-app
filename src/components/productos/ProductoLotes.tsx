/**
 * ProductoLotes
 *
 * Sección de la ficha que responde "¿qué tengo de este producto y cuándo se me
 * vence?".
 *
 * LA BOLSA "SIN VENCIMIENTO" SE MUESTRA A PROPÓSITO
 * -------------------------------------------------
 * No es un detalle técnico que se pueda esconder: es la parte del stock de la
 * que no se sabe cuándo vence, y crece cada vez que entra mercadería sin fecha
 * cargada. Mostrarla es lo que hace que se note y se corrija — si la ocultáramos
 * la pantalla mostraría dos lotes prolijos y daría la impresión de que el
 * producto está controlado cuando la mitad del stock no lo está.
 *
 * De ahí sale también el botón "Cargar vencimiento": es el camino del stock que
 * ya existía cuando se prendió la feature. No hay inventario inicial que hacer,
 * se etiqueta producto por producto cuando uno pasa al lado de la caja.
 *
 * Vive aparte de ModalProducto a propósito: ese archivo ya tiene 874 líneas.
 */
import { useMemo, useState } from 'react'
import { CalendarClock, Check, Loader2, Package, Pencil, Plus, X } from 'lucide-react'
import {
  useLotesProductoQuery,
  useCrearLoteManualMutation,
  useAjustarLoteMutation,
} from '../../hooks/queries/useLotesQuery'
import { usePoliticasComercialesQuery } from '../../hooks/queries/usePoliticasComercialesQuery'
import { useAuth } from '../../hooks/supabase/useAuth'
import { useNotification } from '../../contexts/NotificationContext'
import { bolsaSinVencimiento, formatearFechaVencimiento } from '../../utils/vencimientos'
import BadgeVencimiento from '../vencimientos/BadgeVencimiento'

export interface ProductoLotesProps {
  /** Producto en edición. Sin id (alta nueva) la sección no se muestra. */
  productoId: number
  /**
   * Stock que la ficha tiene en pantalla. Se usa para la bolsa, así el número
   * se mueve mientras el admin corrige el stock en el form de arriba, sin
   * esperar a que la base responda.
   */
  stock: number
}

export default function ProductoLotes({ productoId, stock }: ProductoLotesProps) {
  const notify = useNotification()
  const { isAdminOrEncargado, perfil } = useAuth()
  const { politicas } = usePoliticasComercialesQuery()
  const { data: lotes = [], isLoading } = useLotesProductoQuery(productoId)

  const crearLote = useCrearLoteManualMutation()
  const ajustarLote = useAjustarLoteMutation()

  // Etiquetar es una tarea de depósito: es quien camina el galpón y ve la caja.
  // Corregir un contador es administración. La RPC vuelve a chequear las dos
  // cosas; esto es solo para no ofrecer un botón que va a fallar.
  const puedeEtiquetar = isAdminOrEncargado || perfil?.rol === 'deposito'
  const puedeCorregir = isAdminOrEncargado

  const [cargando, setCargando] = useState(false)
  const [fechaNueva, setFechaNueva] = useState('')
  const [cantidadNueva, setCantidadNueva] = useState('')
  /** Id del lote con el contador en edición. */
  const [editando, setEditando] = useState<number | null>(null)
  const [restanteEditado, setRestanteEditado] = useState('')

  const asignado = useMemo(
    () => lotes.reduce((acc, l) => acc + (Number(l.cantidad_restante) || 0), 0),
    [lotes],
  )
  const bolsa = bolsaSinVencimiento(stock, asignado)

  async function guardarLoteNuevo() {
    const cantidad = Number(cantidadNueva)
    if (!fechaNueva) {
      notify.error('Falta la fecha de vencimiento')
      return
    }
    if (!Number.isFinite(cantidad) || cantidad <= 0) {
      notify.error('La cantidad tiene que ser mayor a 0')
      return
    }
    if (cantidad > bolsa) {
      notify.error(`Solo hay ${bolsa} u. sin vencimiento cargado`)
      return
    }
    try {
      await crearLote.mutateAsync({ productoId, fecha: fechaNueva, cantidad })
      notify.success(`${cantidad} u. etiquetadas con vencimiento ${formatearFechaVencimiento(fechaNueva)}`)
      setCargando(false)
      setFechaNueva('')
      setCantidadNueva('')
    } catch (e) {
      notify.error(e instanceof Error ? e.message : 'No se pudo cargar el vencimiento')
    }
  }

  async function guardarAjuste(loteId: number) {
    const restante = Number(restanteEditado)
    if (!Number.isFinite(restante) || restante < 0) {
      notify.error('La cantidad no puede ser negativa')
      return
    }
    try {
      await ajustarLote.mutateAsync({ loteId, cantidadRestante: restante })
      notify.success('Contador corregido')
      setEditando(null)
    } catch (e) {
      notify.error(e instanceof Error ? e.message : 'No se pudo corregir el lote')
    }
  }

  return (
    <section className="border-t dark:border-gray-700 pt-4">
      <div className="flex items-center justify-between gap-2 mb-2">
        <h3 className="text-sm font-medium flex items-center gap-1.5 dark:text-white">
          <CalendarClock className="w-4 h-4 text-indigo-600" aria-hidden="true" />
          Vencimientos
        </h3>
        {puedeEtiquetar && !cargando && bolsa > 0 && (
          <button
            type="button"
            onClick={() => setCargando(true)}
            className="inline-flex items-center gap-1 text-sm text-blue-600 hover:text-blue-700"
          >
            <Plus className="w-4 h-4" aria-hidden="true" />
            Cargar vencimiento
          </button>
        )}
      </div>

      {cargando && (
        <div className="mb-3 flex flex-wrap items-end gap-2 p-2 rounded bg-stone-50 dark:bg-gray-800">
          <div>
            {/* Sin `min`: una fecha pasada es un dato legítimo, no un error de
                tipeo. Etiquetar la caja vencida que apareció en el fondo del
                depósito es justo para lo que existe este botón, y el badge la
                pinta en rojo sola. */}
            <label htmlFor="lote-fecha" className="block text-xs text-stone-500 dark:text-gray-400 mb-0.5">
              Vence el
            </label>
            <input
              id="lote-fecha"
              type="date"
              value={fechaNueva}
              onChange={e => setFechaNueva(e.target.value)}
              className="px-2 py-1 border rounded text-sm dark:bg-gray-800 dark:border-gray-600 dark:text-white"
            />
          </div>
          <div>
            <label htmlFor="lote-cantidad" className="block text-xs text-stone-500 dark:text-gray-400 mb-0.5">
              Unidades (hay {bolsa})
            </label>
            <input
              id="lote-cantidad"
              type="number"
              min={1}
              max={bolsa}
              value={cantidadNueva}
              onChange={e => setCantidadNueva(e.target.value)}
              className="w-24 px-2 py-1 border rounded text-sm dark:bg-gray-800 dark:border-gray-600 dark:text-white"
            />
          </div>
          <button
            type="button"
            onClick={() => void guardarLoteNuevo()}
            disabled={crearLote.isPending}
            className="px-3 py-1 bg-blue-600 text-white rounded text-sm hover:bg-blue-700 disabled:opacity-50 inline-flex items-center gap-1"
          >
            {crearLote.isPending && <Loader2 className="w-3 h-3 animate-spin" aria-hidden="true" />}
            Guardar
          </button>
          <button
            type="button"
            onClick={() => { setCargando(false); setFechaNueva(''); setCantidadNueva('') }}
            className="text-xs text-stone-500 hover:text-stone-700 dark:text-gray-400"
          >
            Cancelar
          </button>
        </div>
      )}

      {isLoading ? (
        <p className="flex items-center gap-2 text-xs text-stone-500 dark:text-gray-400">
          <Loader2 className="w-3 h-3 animate-spin" aria-hidden="true" />
          Cargando lotes…
        </p>
      ) : lotes.length === 0 ? (
        <p className="text-xs text-stone-500 dark:text-gray-400">
          Sin vencimientos cargados. Se cargan al registrar la factura de compra, o acá a mano.
        </p>
      ) : (
        <ul className="space-y-1">
          {lotes.map(lote => (
            <li
              key={lote.id}
              className="flex flex-wrap items-center gap-2 text-sm py-1 border-b border-stone-100 dark:border-gray-700 last:border-0"
            >
              <span className="font-mono text-xs text-stone-600 dark:text-gray-300 w-20">
                {formatearFechaVencimiento(lote.fecha_vencimiento)}
              </span>
              <BadgeVencimiento
                fecha={lote.fecha_vencimiento}
                diasAlerta={politicas.diasAlertaVencimiento}
                diasCritico={politicas.diasCriticoVencimiento}
              />
              {editando === lote.id ? (
                <span className="flex items-center gap-1">
                  <input
                    type="number"
                    min={0}
                    max={lote.cantidad}
                    value={restanteEditado}
                    onChange={e => setRestanteEditado(e.target.value)}
                    aria-label="Unidades que quedan"
                    className="w-20 px-2 py-0.5 border rounded text-sm dark:bg-gray-800 dark:border-gray-600 dark:text-white"
                  />
                  <button
                    type="button"
                    onClick={() => void guardarAjuste(lote.id)}
                    disabled={ajustarLote.isPending}
                    aria-label="Guardar corrección"
                    className="p-1 text-green-600 hover:text-green-700 disabled:opacity-50"
                  >
                    <Check className="w-4 h-4" aria-hidden="true" />
                  </button>
                  <button
                    type="button"
                    onClick={() => setEditando(null)}
                    aria-label="Cancelar corrección"
                    className="p-1 text-stone-400 hover:text-stone-600"
                  >
                    <X className="w-4 h-4" aria-hidden="true" />
                  </button>
                </span>
              ) : (
                <span className="ml-auto flex items-center gap-2">
                  <span className="dark:text-white">
                    <strong>{lote.cantidad_restante}</strong>
                    <span className="text-stone-400 dark:text-gray-500"> / {lote.cantidad} u.</span>
                  </span>
                  {lote.origen === 'manual' && (
                    <span className="text-[10px] uppercase tracking-wide text-stone-400 dark:text-gray-500">
                      a mano
                    </span>
                  )}
                  {puedeCorregir && (
                    <button
                      type="button"
                      onClick={() => { setEditando(lote.id); setRestanteEditado(String(lote.cantidad_restante)) }}
                      aria-label={`Corregir el contador del lote que vence el ${formatearFechaVencimiento(lote.fecha_vencimiento)}`}
                      className="p-1 text-stone-400 hover:text-blue-600"
                    >
                      <Pencil className="w-3.5 h-3.5" aria-hidden="true" />
                    </button>
                  )}
                </span>
              )}
            </li>
          ))}
        </ul>
      )}

      {/* La bolsa. Se muestra siempre, incluso en 0: que diga "0" es la
          confirmación de que todo el stock tiene fecha, y esa es justamente la
          información que uno viene a buscar. */}
      <p className="mt-2 flex items-center gap-1.5 text-xs text-stone-500 dark:text-gray-400">
        <Package className="w-3.5 h-3.5" aria-hidden="true" />
        Sin vencimiento cargado: <strong className="text-stone-700 dark:text-gray-200">{bolsa} u.</strong>
        <span className="text-stone-400 dark:text-gray-500">
          (de {stock} en stock). Sale antes que cualquier lote con fecha.
        </span>
      </p>
    </section>
  )
}
