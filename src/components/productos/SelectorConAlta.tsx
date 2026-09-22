/**
 * Selector de categoría o marca que deja dar de alta una nueva sin salir del
 * formulario del producto. Lo usan la ficha y las dos altas rápidas de la compra.
 *
 * No crea nada: lo tipeado sube como `nuevo` y lo crea quien guarda el producto
 * (`useAsegurarCatalogo`), en el mismo click. Un botón "Crear" propio, al lado del
 * campo, dejaba un camino para perderlo: escribir el nombre, seguir con el resto
 * de la ficha y guardar sin haberlo apretado. Así funcionaba ya la categoría, y
 * así se sigue escribiendo.
 */
import { useId } from 'react'

export interface OpcionCatalogo {
  valor: string
  texto: string
}

export interface SelectorConAltaProps {
  /** Arma el label y los textos: "+ Nueva marca", "Sin marca". */
  sustantivo: 'categoría' | 'marca'
  opciones: OpcionCatalogo[]
  /** Lo elegido en la lista ('' = ninguna). */
  valor: string
  onValor: (valor: string) => void
  /** null = eligiendo de la lista; un string = escribiendo una nueva. */
  nuevo: string | null
  onNuevo: (nuevo: string | null) => void
  /** Tamaño de las altas rápidas de la compra. */
  compacto?: boolean
}

export default function SelectorConAlta({
  sustantivo,
  opciones,
  valor,
  onValor,
  nuevo,
  onNuevo,
  compacto = false,
}: SelectorConAltaProps) {
  const id = useId()
  const titulo = sustantivo.charAt(0).toUpperCase() + sustantivo.slice(1)
  const escribiendo = nuevo !== null

  const claseLabel = compacto
    ? 'block text-xs text-gray-500'
    : 'block text-sm font-medium'
  const claseToggle = compacto
    ? 'text-xs text-blue-600 hover:text-blue-700 dark:text-blue-400'
    : 'text-sm text-blue-600 hover:text-blue-700'
  const claseCampo = compacto
    ? 'w-full px-3 py-1.5 text-sm border dark:border-gray-600 rounded focus:ring-2 focus:ring-blue-500 dark:bg-gray-700 dark:text-white'
    : 'w-full px-3 py-2 border rounded-lg'

  return (
    <div>
      <div className="flex justify-between items-center gap-2 mb-1">
        <label htmlFor={id} className={claseLabel}>{titulo}</label>
        <button
          type="button"
          onClick={() => onNuevo(escribiendo ? null : '')}
          className={claseToggle}
        >
          {escribiendo ? 'Elegir existente' : `+ Nueva ${sustantivo}`}
        </button>
      </div>
      {escribiendo ? (
        <>
          <input
            id={id}
            type="text"
            value={nuevo}
            onChange={e => onNuevo(e.target.value)}
            // Se guarda en mayúsculas, como el resto del catálogo: que se vea así
            // desde que se escribe.
            className={`${claseCampo} uppercase`}
            placeholder={`Nombre de la nueva ${sustantivo}`}
            autoFocus
          />
          <p className="text-xs text-gray-500 mt-1">
            Se crea al guardar el producto. Si ya existe, se usa la que está.
          </p>
        </>
      ) : (
        <select
          id={id}
          value={valor}
          onChange={e => onValor(e.target.value)}
          className={claseCampo}
        >
          <option value="">Sin {sustantivo}</option>
          {opciones.map(o => (
            <option key={o.valor} value={o.valor}>{o.texto}</option>
          ))}
        </select>
      )}
    </div>
  )
}
