/**
 * Combobox — un input con lista filtrable, para elegir de un catálogo largo.
 *
 * Reemplaza al `<select>` nativo donde la lista ya no se puede recorrer a ojo
 * (los proveedores de la compra). Busca sin tildes y en varios textos por
 * opción —nombre y CUIT— con `filtrarOpciones` (utils), y opcionalmente
 * ofrece al final "crear" con lo tipeado.
 *
 * Patrón ARIA 1.2 de combobox con lista: el foco se queda SIEMPRE en el input y
 * la opción activa se anuncia con `aria-activedescendant`. Las opciones no son
 * tabulables y cancelan el `mousedown`, así el click no le saca el foco al
 * input y el cierre se puede atar al `blur` sin carreras.
 *
 * Por qué NO va sobre ui/Popover: la lista se dibuja en línea (absoluta, debajo
 * del input) y no en un portal. Adentro de un diálogo de Radix un portal queda
 * fuera del `RemoveScroll` del diálogo —la rueda del mouse no scrollea la lista—
 * y ModalBase corta la propagación de `mousedown`, así que el "click afuera" del
 * Popover nunca se enteraría de un click en el resto del modal.
 *
 * Escape: cierra la lista y para la propagación. Ojo que Radix escucha Escape
 * en CAPTURA, antes que este input: el diálogo que lo contenga tiene que mirar
 * `aria-expanded` del elemento con foco para no cerrarse él (ver ModalCompra).
 */
import { useId, useMemo, useState } from 'react'
import type { KeyboardEvent, ReactNode } from 'react'
import { ChevronDown } from 'lucide-react'
import { cn } from '../../lib/utils'
import { filtrarOpciones, hayCoincidenciaExacta } from '../../utils/filtrarOpciones'

export interface ComboboxProps<T> {
  opciones: T[];
  getKey: (opcion: T) => string;
  /** Texto que queda en el input al elegir la opción. */
  getLabel: (opcion: T) => string;
  /** Textos donde se busca. Default: el label. */
  getTextosBusqueda?: (opcion: T) => Array<string | null | undefined>;
  /**
   * Búsqueda propia: recibe lo tipeado (puede ser '') y devuelve las opciones
   * en el orden en que se muestran. Reemplaza a `getTextosBusqueda`. La usa la
   * revisión del escaneo, que ordena con el matcher y no por "contiene".
   */
  filtrar?: (opciones: T[], consulta: string) => T[];
  /** Cómo se dibuja la opción en la lista. Default: el label. */
  renderOpcion?: (opcion: T) => ReactNode;
  /** Key de la opción elegida ('' o null = ninguna). */
  valor: string | null;
  /**
   * Lo que se muestra cuando `valor` no está en `opciones` (ej. un proveedor que
   * vino del escaneo y no está dado de alta). Default: vacío.
   */
  textoSinOpcion?: string;
  onSeleccionar: (opcion: T) => void;
  /** Si está, al final de la lista aparece "crear" con lo tipeado. */
  onCrear?: (texto: string) => void;
  /** Rótulo de esa opción. Default: `+ Crear "texto"`. */
  textoCrear?: (texto: string) => string;
  placeholder?: string;
  /** Nombre accesible del input. Requerido si no hay `aria-labelledby`. */
  'aria-label'?: string;
  'aria-labelledby'?: string;
  id?: string;
  /** Máximo de opciones a dibujar. */
  limite?: number;
  textoSinResultados?: string;
  disabled?: boolean;
  className?: string;
  inputClassName?: string;
  /**
   * Clases extra para la lista desplegada. Por defecto mide lo mismo que el
   * input (`w-full`); la revisión del escaneo la ensancha con un `min-w-*`
   * porque su columna es angosta y los nombres de producto son largos.
   */
  listaClassName?: string;
}

/** Lo que hay en la lista: opciones del catálogo y, al final, el "crear". */
type Entrada<T> = { tipo: 'opcion'; opcion: T } | { tipo: 'crear'; texto: string }

export function Combobox<T>({
  opciones, getKey, getLabel, getTextosBusqueda, filtrar, renderOpcion, valor, textoSinOpcion = '',
  onSeleccionar, onCrear, textoCrear = t => `+ Crear "${t}"`, placeholder,
  'aria-label': ariaLabel, 'aria-labelledby': ariaLabelledby, id, limite = 50,
  textoSinResultados = 'Sin resultados', disabled, className, inputClassName, listaClassName,
}: ComboboxProps<T>) {
  const idBase = useId()
  const inputId = id ?? `${idBase}-input`
  const listaId = `${idBase}-lista`
  const [abierto, setAbierto] = useState(false)
  const [consulta, setConsulta] = useState('')
  const [activo, setActivo] = useState(-1)

  const elegida = useMemo(
    () => (valor ? opciones.find(o => getKey(o) === valor) ?? null : null),
    [opciones, valor, getKey]
  )
  const textoElegido = elegida ? getLabel(elegida) : textoSinOpcion

  const entradas = useMemo<Entrada<T>[]>(() => {
    const filtradas = filtrar
      ? filtrar(opciones, consulta).slice(0, limite)
      : filtrarOpciones(opciones, consulta, getTextosBusqueda ?? (o => [getLabel(o)]), limite)
    const lista: Entrada<T>[] = filtradas.map(opcion => ({ tipo: 'opcion', opcion }))
    const texto = consulta.trim()
    if (onCrear && texto && !hayCoincidenciaExacta(opciones, texto, getLabel)) {
      lista.push({ tipo: 'crear', texto })
    }
    return lista
  }, [opciones, consulta, getTextosBusqueda, filtrar, getLabel, limite, onCrear])

  const idOpcion = (i: number) => `${idBase}-op-${i}`

  const abrir = () => {
    if (disabled) return
    setAbierto(true)
    setConsulta('')
    // Arranca parado en la elegida, así ↓/↑ siguen desde ahí.
    const iniciales = filtrar ? filtrar(opciones, '').slice(0, limite) : opciones.slice(0, limite)
    const i = elegida ? iniciales.indexOf(elegida) : -1
    setActivo(i)
  }

  const cerrar = () => {
    setAbierto(false)
    setConsulta('')
    setActivo(-1)
  }

  const mover = (i: number) => {
    setActivo(i)
    // getElementById y no querySelector: los ids de useId llevan ":".
    document.getElementById(idOpcion(i))?.scrollIntoView?.({ block: 'nearest' })
  }

  const confirmar = (entrada: Entrada<T> | undefined) => {
    if (!entrada) return
    cerrar()
    if (entrada.tipo === 'opcion') onSeleccionar(entrada.opcion)
    else onCrear?.(entrada.texto)
  }

  const onKeyDown = (e: KeyboardEvent<HTMLInputElement>) => {
    switch (e.key) {
      case 'ArrowDown':
        e.preventDefault()
        if (!abierto) { abrir(); return }
        if (entradas.length > 0) mover(Math.min(activo + 1, entradas.length - 1))
        return
      case 'ArrowUp':
        e.preventDefault()
        if (!abierto) { abrir(); return }
        if (entradas.length > 0) mover(Math.max(activo - 1, 0))
        return
      case 'Enter':
        // Siempre: adentro de un <form>, un Enter en el buscador mandaría el
        // formulario entero.
        e.preventDefault()
        if (abierto) confirmar(entradas[activo])
        return
      case 'Escape':
        if (!abierto) return
        e.stopPropagation()
        cerrar()
        return
      default:
    }
  }

  return (
    <div className={cn('relative', className)}>
      <input
        id={inputId}
        type="text"
        role="combobox"
        aria-label={ariaLabel}
        aria-labelledby={ariaLabelledby}
        aria-expanded={abierto}
        aria-controls={listaId}
        aria-autocomplete="list"
        aria-activedescendant={abierto && activo >= 0 ? idOpcion(activo) : undefined}
        autoComplete="off"
        disabled={disabled}
        value={abierto ? consulta : textoElegido}
        placeholder={abierto && textoElegido ? textoElegido : placeholder}
        onFocus={abrir}
        onClick={() => { if (!abierto) abrir() }}
        onBlur={cerrar}
        onChange={e => {
          if (!abierto) setAbierto(true)
          setConsulta(e.target.value)
          // Lo tipeado se puede confirmar con Enter directo: la primera queda activa.
          setActivo(e.target.value.trim() ? 0 : -1)
        }}
        onKeyDown={onKeyDown}
        className={cn(
          'w-full pl-3 pr-9 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500',
          'dark:bg-gray-700 dark:text-white text-sm sm:text-base',
          inputClassName,
        )}
      />
      <ChevronDown aria-hidden="true" className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
      {abierto && (
        <ul
          id={listaId}
          role="listbox"
          aria-label={ariaLabel}
          className={cn(
            'absolute z-20 mt-1 w-full max-h-64 overflow-y-auto rounded-lg border bg-white shadow-lg dark:border-gray-600 dark:bg-gray-800',
            listaClassName,
          )}
        >
          {entradas.length === 0 && (
            <li className="px-3 py-2 text-sm text-gray-500" aria-disabled="true">{textoSinResultados}</li>
          )}
          {entradas.map((entrada, i) => (
            <li
              key={entrada.tipo === 'opcion' ? getKey(entrada.opcion) : '__crear__'}
              id={idOpcion(i)}
              role="option"
              aria-selected={i === activo}
              onMouseDown={e => e.preventDefault()}
              onMouseEnter={() => setActivo(i)}
              onClick={() => confirmar(entrada)}
              className={cn(
                'cursor-pointer px-3 py-2 text-sm',
                i === activo ? 'bg-green-50 dark:bg-green-900/30' : 'hover:bg-gray-50 dark:hover:bg-gray-700',
                entrada.tipo === 'crear'
                  ? 'border-t font-medium text-green-700 dark:border-gray-600 dark:text-green-400'
                  : 'text-gray-800 dark:text-white',
              )}
            >
              {entrada.tipo === 'opcion'
                ? (renderOpcion ? renderOpcion(entrada.opcion) : getLabel(entrada.opcion))
                : textoCrear(entrada.texto)}
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}

export default Combobox
