/**
 * Las pestañas, únicas.
 *
 * Hasta acá cada pantalla con pestañas armaba la barra a mano: un `<div>` con un
 * `.map` de `<button>` sin `role`, sin `aria-selected` y con las ocho en el orden
 * de tabulación. Este primitivo es esa barra una sola vez, con el patrón de
 * pestañas de WAI-ARIA.
 *
 * Decisiones que NO son cosméticas:
 *  - Es CONTROLADO. No guarda cuál pestaña está activa: recibe `value` y avisa
 *    con `onValueChange`. Quien lo usa decide dónde vive ese dato. En
 *    `VistaReportes` vive en la URL (`?tab=`), y por eso `linkAReportes` aterriza
 *    en la pestaña correcta, el link se comparte y el back de Android anda. Si
 *    el primitivo tuviera su propio estado, la URL y la pantalla se podrían
 *    desincronizar sin que falle nada. Un clic sólo AVISA: si el padre no
 *    actualiza `value`, la pestaña no cambia.
 *  - El clic avisa SIEMPRE, también sobre la pestaña ya activa. Es lo que hacía
 *    la barra de a mano; filtrar acá lo cambiaría para quien depende de eso.
 *  - Un solo `tabpanel`, el que envuelve a `children`. El contenido de todas las
 *    pestañas es el mismo hueco, así que cada pestaña lo controla
 *    (`aria-controls`) y el panel se rotula con la activa (`aria-labelledby`).
 *    `children` es el contenido de la pestaña activa; lo que se muestra lo
 *    decide el consumidor.
 *  - `tabIndex` móvil: sólo la pestaña activa está en el orden de tabulación,
 *    y las flechas hacen el resto. Las flechas, Home y End mueven el foco Y
 *    activan (la activación sigue al foco, que es lo que conviene cuando
 *    cambiar de pestaña es barato). Con una tecla modificadora no se interviene:
 *    Alt + ← es "volver" del navegador. Si `value` no coincide con ninguna
 *    pestaña, la primera queda tabulable, para que la barra no desaparezca del
 *    teclado.
 *  - No hay scroll de página por culpa de la barra: si las pestañas no entran,
 *    la lista scrollea sola en horizontal (`overflow-x-auto`). Los
 *    `px-1 pt-1 pb-2` no son decoración: el anillo de foco de `Button` sale 4 px
 *    hacia afuera y un contenedor con `overflow` lo recortaría. Al cambiar de
 *    pestaña, la activa se trae a la vista dentro de la lista (en un celular un
 *    deep link a la última pestaña, si no, la dejaría fuera de pantalla).
 *
 * El estilo es el de `Button`: la activa es `primary` (fondo de marca, que
 * `high-contrast.css` ya invierte por `.bg-brand-600`) y las demás `ghost`. Con
 * un subrayado en vez de un relleno, el modo de alto contraste lo perdería: ahí
 * todo `<button>` se pinta con borde de 2 px forzado.
 *
 * `value` tiene que ser seguro como parte de un id (letras, números, `-`, `_`);
 * lo demás se reemplaza por `_`, y dos valores que sólo difieran en eso chocarían.
 */
import { useEffect, useId, useRef, type KeyboardEvent, type ReactElement, type ReactNode } from 'react'
import type { LucideIcon } from 'lucide-react'
import { cn } from '../../lib/utils'
import { Button } from './Button'

export interface TabItem<T extends string = string> {
  /** El id de la pestaña: es lo que viaja en `value` y en `onValueChange`. */
  value: T
  /** El rótulo visible y el nombre accesible. */
  label: string
  /** Ícono decorativo a la izquierda del rótulo. */
  icon?: LucideIcon
}

export interface TabsProps<T extends string = string> {
  /** La pestaña activa. Controlada: este componente no la guarda. */
  value: T
  /** Se llama con el `value` de la pestaña clickeada o a la que llegó el teclado. */
  onValueChange: (value: T) => void
  tabs: readonly TabItem<T>[]
  /** Nombre accesible de la barra (`aria-label` del `tablist`). */
  etiqueta: string
  /** El contenido de la pestaña activa. Va dentro del `tabpanel`. */
  children?: ReactNode
  /** Clases del contenedor de la barra y el panel. Por defecto `space-y-4`. */
  className?: string
  /** Clases de la lista de pestañas (el `tablist`). */
  listClassName?: string
  /** Clases del `tabpanel`. */
  panelClassName?: string
}

const LISTA =
  'flex gap-2 overflow-x-auto px-1 pt-1 pb-2 -mx-1 border-b border-gray-200 dark:border-gray-700'

function idSeguro(value: string): string {
  return value.replace(/[^A-Za-z0-9_-]/g, '_')
}

export function Tabs<T extends string = string>({
  value,
  onValueChange,
  tabs,
  etiqueta,
  children,
  className,
  listClassName,
  panelClassName,
}: TabsProps<T>): ReactElement {
  const base = useId()
  const panelId = `${base}-panel`
  const idDeTab = (v: string): string => `${base}-tab-${idSeguro(v)}`

  const listaRef = useRef<HTMLDivElement | null>(null)
  const botones = useRef<Array<HTMLButtonElement | null>>([])

  const indiceActivo = tabs.findIndex((t) => t.value === value)
  // Sin una activa válida, la primera es la que se alcanza con Tab.
  const indiceTabulable = indiceActivo === -1 ? 0 : indiceActivo

  // Trae la activa a la vista DENTRO de la lista, sin mover la página: el
  // `scrollIntoView` también scrollea los ancestros.
  useEffect(() => {
    const lista = listaRef.current
    const activa = indiceActivo === -1 ? null : botones.current[indiceActivo]
    if (!lista || !activa) return
    const marco = lista.getBoundingClientRect()
    const boton = activa.getBoundingClientRect()
    if (boton.left < marco.left) lista.scrollLeft -= marco.left - boton.left
    else if (boton.right > marco.right) lista.scrollLeft += boton.right - marco.right
  }, [indiceActivo])

  const alTeclado = (e: KeyboardEvent<HTMLButtonElement>, indice: number): void => {
    if (e.altKey || e.ctrlKey || e.metaKey) return
    const n = tabs.length
    let destino: number
    switch (e.key) {
      case 'ArrowRight':
        destino = (indice + 1) % n
        break
      case 'ArrowLeft':
        destino = (indice - 1 + n) % n
        break
      case 'Home':
        destino = 0
        break
      case 'End':
        destino = n - 1
        break
      default:
        return
    }
    e.preventDefault()
    botones.current[destino]?.focus()
    const siguiente = tabs[destino].value
    if (siguiente !== value) onValueChange(siguiente)
  }

  return (
    <div className={cn('space-y-4', className)}>
      <div ref={listaRef} role="tablist" aria-label={etiqueta} className={cn(LISTA, listClassName)}>
        {tabs.map((tab, i) => {
          const activa = i === indiceActivo
          const Icono = tab.icon
          return (
            <Button
              key={tab.value}
              ref={(el) => {
                botones.current[i] = el
              }}
              type="button"
              role="tab"
              id={idDeTab(tab.value)}
              aria-selected={activa}
              aria-controls={panelId}
              tabIndex={i === indiceTabulable ? 0 : -1}
              variant={activa ? 'primary' : 'ghost'}
              onClick={() => onValueChange(tab.value)}
              onKeyDown={(e) => alTeclado(e, i)}
              className="shrink-0 whitespace-nowrap"
            >
              {Icono && <Icono className="w-4 h-4" aria-hidden="true" />}
              {tab.label}
            </Button>
          )
        })}
      </div>
      <div
        role="tabpanel"
        id={panelId}
        aria-labelledby={indiceActivo === -1 ? undefined : idDeTab(value)}
        className={panelClassName}
      >
        {children}
      </div>
    </div>
  )
}
