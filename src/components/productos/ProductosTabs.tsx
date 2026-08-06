/**
 * ProductosTabs
 *
 * Alterna entre el catálogo y las condiciones mayoristas.
 *
 * Las condiciones eran una sección propia del menú, pero son un atributo del
 * catálogo: se deciden mirando el producto, su costo y su margen. Tenerlas
 * aparte obligaba a saltar de pantalla y a recordar de memoria el precio de
 * lista del sabor que se estaba configurando.
 */
import { Package, Tag } from 'lucide-react'
import { cn } from '../../lib/utils'

export type TabProductos = 'productos' | 'condiciones'

/** Id del contenedor que muestra la pestaña activa, para `aria-controls`. */
export const PANEL_PRODUCTOS_ID = 'panel-vista-productos'

export interface ProductosTabsProps {
  value: TabProductos
  onChange: (value: TabProductos) => void
  /** Condiciones cargadas. Se muestra al lado del label si hay alguna. */
  contadorCondiciones?: number
}

const TABS = [
  { id: 'productos' as const, label: 'Productos', icon: Package },
  { id: 'condiciones' as const, label: 'Condiciones mayoristas', icon: Tag },
]

export default function ProductosTabs({
  value,
  onChange,
  contadorCondiciones,
}: ProductosTabsProps) {
  return (
    <div
      role="tablist"
      aria-label="Vista del catálogo"
      className="inline-flex gap-1 p-1 rounded-xl bg-stone-100 dark:bg-gray-800 border border-stone-200 dark:border-gray-700"
    >
      {TABS.map(tab => {
        const activo = value === tab.id
        const Icon = tab.icon
        return (
          <button
            key={tab.id}
            type="button"
            role="tab"
            aria-selected={activo}
            aria-controls={PANEL_PRODUCTOS_ID}
            onClick={() => onChange(tab.id)}
            className={cn(
              'inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-sm font-medium transition-colors',
              activo
                ? 'bg-white dark:bg-gray-700 text-stone-800 dark:text-white shadow-warm'
                : 'text-stone-600 dark:text-gray-300 hover:bg-white/60 dark:hover:bg-gray-700/50',
            )}
          >
            <Icon className="w-4 h-4" aria-hidden="true" />
            {tab.label}
            {tab.id === 'condiciones' && !!contadorCondiciones && (
              <span className="tabular-nums text-xs text-stone-500 dark:text-gray-400">
                {contadorCondiciones}
              </span>
            )}
          </button>
        )
      })}
    </div>
  )
}
