/**
 * Todas las condiciones mayoristas en una tabla, para verlas de un pantallazo.
 *
 * Las tarjetas están bien para editar una, pero con 88 condiciones no permiten
 * responder "¿qué tengo configurado?" ni "¿qué sabores suman entre sí?" sin
 * scrollear todo. Esta vista pone una condición por fila, con los productos que
 * combinan y las escalas al lado.
 */
import { Edit2, Trash2, ToggleLeft, ToggleRight } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import { cn } from '../../lib/utils'
import type { GrupoPrecioConDetalles } from '../../types'

export interface TablaCondicionesProps {
  grupos: GrupoPrecioConDetalles[]
  nombreProducto: (productoId: string) => string
  onEditarGrupo: (grupo: GrupoPrecioConDetalles) => void
  onEliminarGrupo: (id: string) => void
  onToggleActivo: (grupo: GrupoPrecioConDetalles) => void
}

export default function TablaCondiciones({
  grupos,
  nombreProducto,
  onEditarGrupo,
  onEliminarGrupo,
  onToggleActivo,
}: TablaCondicionesProps) {
  return (
    <div className="bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 rounded-xl shadow-warm overflow-hidden">
      <div className="overflow-x-auto">
        <table className="w-full" role="table">
          <thead className="bg-stone-50/70 dark:bg-gray-700/50 border-b border-stone-200 dark:border-gray-700">
            <tr>
              <th scope="col" className="px-4 py-3 text-left text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">
                Condición
              </th>
              <th scope="col" className="px-4 py-3 text-left text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">
                Productos que suman entre sí
              </th>
              <th scope="col" className="px-4 py-3 text-left text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">
                Precio por cantidad
              </th>
              <th scope="col" className="px-4 py-3 text-right text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">
                Acciones
              </th>
            </tr>
          </thead>
          <tbody className="divide-y divide-stone-200 dark:divide-gray-700">
            {grupos.map(grupo => {
              const activo = grupo.activo !== false
              const nombres = grupo.productos.map(gpp => nombreProducto(gpp.producto_id))
              const escalas = [...grupo.escalas].sort((a, b) => a.cantidad_minima - b.cantidad_minima)

              return (
                <tr
                  key={grupo.id}
                  className={cn(
                    'hover:bg-stone-50/70 dark:hover:bg-gray-700/40 transition-colors align-top',
                    !activo && 'opacity-60',
                  )}
                >
                  <td className="px-4 py-3">
                    <span className="font-medium text-stone-800 dark:text-white">{grupo.nombre}</span>
                    {!activo && (
                      <span className="ml-2 text-[11px] px-1.5 py-0.5 rounded bg-stone-200 dark:bg-gray-700 text-stone-600 dark:text-gray-300">
                        desactivada
                      </span>
                    )}
                    {/* En prod varias condiciones repiten el nombre en la
                        descripción; mostrarlo dos veces no aporta. */}
                    {grupo.descripcion && grupo.descripcion.trim() !== grupo.nombre.trim() && (
                      <p className="text-xs text-stone-500 dark:text-gray-400 mt-0.5">{grupo.descripcion}</p>
                    )}
                  </td>

                  <td className="px-4 py-3">
                    {nombres.length === 0 ? (
                      <span className="text-xs text-rose-600 dark:text-rose-400">
                        Sin productos: no aplica a nadie
                      </span>
                    ) : (
                      <>
                        <span className="text-xs text-stone-700 dark:text-gray-200">
                          {nombres.join(', ')}
                        </span>
                        {nombres.length > 1 && (
                          <span className="ml-1.5 text-[11px] text-indigo-700 dark:text-indigo-300">
                            ({nombres.length} sabores suman)
                          </span>
                        )}
                      </>
                    )}
                  </td>

                  <td className="px-4 py-3">
                    {escalas.length === 0 ? (
                      <span className="text-xs text-rose-600 dark:text-rose-400">
                        Sin escalas: no aplica ningún precio
                      </span>
                    ) : (
                      <ul className="space-y-0.5">
                        {escalas.map(e => (
                          <li key={e.id} className="text-xs text-stone-700 dark:text-gray-200 tabular-nums">
                            desde {e.cantidad_minima} u. → {formatPrecio(e.precio_unitario)}
                            {e.etiqueta && (
                              <span className="ml-1 text-stone-400 dark:text-gray-500">{e.etiqueta}</span>
                            )}
                          </li>
                        ))}
                      </ul>
                    )}
                  </td>

                  <td className="px-4 py-3 text-right">
                    <div className="flex justify-end gap-1.5">
                      <button
                        onClick={() => onToggleActivo(grupo)}
                        className="p-1.5 rounded-md text-stone-500 hover:bg-stone-100 dark:hover:bg-gray-700"
                        title={activo ? 'Desactivar' : 'Activar'}
                        aria-label={`${activo ? 'Desactivar' : 'Activar'} ${grupo.nombre}`}
                      >
                        {activo
                          ? <ToggleRight className="w-4 h-4 text-emerald-600" aria-hidden="true" />
                          : <ToggleLeft className="w-4 h-4" aria-hidden="true" />}
                      </button>
                      <button
                        onClick={() => onEditarGrupo(grupo)}
                        className="p-1.5 rounded-md text-blue-700 dark:text-blue-300 hover:bg-blue-50 dark:hover:bg-blue-900/20"
                        title="Editar"
                        aria-label={`Editar ${grupo.nombre}`}
                      >
                        <Edit2 className="w-4 h-4" aria-hidden="true" />
                      </button>
                      <button
                        onClick={() => onEliminarGrupo(grupo.id)}
                        className="p-1.5 rounded-md text-rose-700 dark:text-rose-300 hover:bg-rose-50 dark:hover:bg-rose-900/20"
                        title="Eliminar"
                        aria-label={`Eliminar ${grupo.nombre}`}
                      >
                        <Trash2 className="w-4 h-4" aria-hidden="true" />
                      </button>
                    </div>
                  </td>
                </tr>
              )
            })}
          </tbody>
        </table>
      </div>
    </div>
  )
}
