/**
 * Form inline para cargar o editar un precio por cantidad desde la ficha.
 *
 * Va inline y no en un modal a propósito: la ficha del producto ya es un modal
 * y el repo no anida modales (ver ProductosContainer, "Crear condición").
 */
import { useState } from 'react'
import { Loader2 } from 'lucide-react'
import { parsePrecio } from '../../utils/calculations'
import { formatPrecio } from '../../utils/formatters'
import { margenesEscala, descuentoSobreLista } from './margenEscala'

export interface ValoresEscala {
  cantidadMinima: number
  precioUnitario: number
  etiqueta: string | null
}

export interface FormEscalaMayoristaProps {
  /** Valores iniciales al editar. Vacío = alta. */
  inicial?: Partial<ValoresEscala>
  /** Para mostrar el margen en vivo mientras se tipea. */
  precioLista: number
  costoTotal: number
  costoReal: number
  porcentajeIva: number
  guardando?: boolean
  textoGuardar?: string
  onGuardar: (valores: ValoresEscala) => void
  onCancelar: () => void
}

export default function FormEscalaMayorista({
  inicial,
  precioLista,
  costoTotal,
  costoReal,
  porcentajeIva,
  guardando = false,
  textoGuardar = 'Guardar',
  onGuardar,
  onCancelar,
}: FormEscalaMayoristaProps) {
  const [cantidad, setCantidad] = useState(inicial?.cantidadMinima ? String(inicial.cantidadMinima) : '')
  const [precio, setPrecio] = useState(inicial?.precioUnitario ? String(inicial.precioUnitario) : '')
  const [etiqueta, setEtiqueta] = useState(inicial?.etiqueta ?? '')
  const [error, setError] = useState('')

  const precioNum = parsePrecio(precio)
  const { bruto, neto } = margenesEscala(precioNum, costoTotal, costoReal, porcentajeIva)
  const descuento = descuentoSobreLista(precioNum, precioLista)

  const submit = (): void => {
    const cantidadNum = parseInt(cantidad, 10)
    if (!(cantidadNum > 0)) {
      setError('Poné a partir de cuántas unidades aplica')
      return
    }
    if (!(precioNum > 0)) {
      setError('Poné el precio mayorista')
      return
    }
    setError('')
    onGuardar({
      cantidadMinima: cantidadNum,
      precioUnitario: precioNum,
      etiqueta: etiqueta.trim() || null,
    })
  }

  return (
    <div className="rounded-lg border border-dashed border-stone-300 dark:border-gray-600 p-3 space-y-2">
      <div className="flex flex-wrap items-end gap-2">
        <label className="text-xs text-stone-600 dark:text-gray-400">
          Desde
          <input
            type="number"
            inputMode="numeric"
            min="1"
            step="1"
            autoFocus
            value={cantidad}
            onChange={e => setCantidad(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter') submit(); if (e.key === 'Escape') onCancelar() }}
            className="mt-0.5 block w-20 px-2 py-1 border rounded text-sm text-center dark:bg-gray-800 dark:border-gray-600 dark:text-white"
            aria-label="Cantidad mínima"
          />
        </label>
        <span className="pb-1.5 text-xs text-stone-500 dark:text-gray-400">u. a</span>
        <label className="text-xs text-stone-600 dark:text-gray-400">
          Precio c/u
          <input
            type="text"
            inputMode="decimal"
            value={precio}
            onChange={e => setPrecio(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter') submit(); if (e.key === 'Escape') onCancelar() }}
            className="mt-0.5 block w-28 px-2 py-1 border rounded text-sm text-right dark:bg-gray-800 dark:border-gray-600 dark:text-white"
            aria-label="Precio mayorista"
          />
        </label>
        <label className="text-xs text-stone-600 dark:text-gray-400 flex-1 min-w-[7rem]">
          Etiqueta
          <input
            type="text"
            maxLength={100}
            value={etiqueta}
            onChange={e => setEtiqueta(e.target.value)}
            onKeyDown={e => { if (e.key === 'Enter') submit(); if (e.key === 'Escape') onCancelar() }}
            placeholder="Fardo, ½ fardo…"
            className="mt-0.5 block w-full px-2 py-1 border rounded text-sm dark:bg-gray-800 dark:border-gray-600 dark:text-white"
            aria-label="Etiqueta"
          />
        </label>
      </div>

      {/* Margen en vivo: el precio mayorista se decide mirando cuánto queda. */}
      {precioNum > 0 && (
        <p className="text-xs text-stone-500 dark:text-gray-400 tabular-nums">
          {formatPrecio(precioNum)} c/u
          {bruto !== null && <> · Bruto {bruto.toFixed(1)}%</>}
          {neto !== null && <> · Neto {neto.toFixed(1)}%</>}
          {descuento !== null && (
            <> · {descuento >= 0
              ? `${descuento.toFixed(1)}% bajo lista`
              : `${Math.abs(descuento).toFixed(1)}% sobre lista`}</>
          )}
        </p>
      )}

      {error && <p role="alert" className="text-xs text-rose-600 dark:text-rose-400">{error}</p>}

      <div className="flex justify-end gap-2">
        <button
          type="button"
          onClick={onCancelar}
          className="px-2 py-1 text-xs rounded border dark:border-gray-600 dark:text-gray-200"
        >
          Cancelar
        </button>
        <button
          type="button"
          onClick={submit}
          disabled={guardando}
          className="inline-flex items-center gap-1 px-2 py-1 text-xs rounded bg-indigo-600 text-white disabled:opacity-50"
        >
          {guardando && <Loader2 className="w-3 h-3 animate-spin" aria-hidden="true" />}
          {textoGuardar}
        </button>
      </div>
    </div>
  )
}
