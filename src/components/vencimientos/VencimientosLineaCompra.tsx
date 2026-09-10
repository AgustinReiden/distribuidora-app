/**
 * Los vencimientos de UNA línea de factura de compra (migs 223/224).
 *
 * POR QUÉ ES UNA LISTA Y NO UN CAMPO DE FECHA
 * -------------------------------------------
 * Una misma línea puede traer dos lotes: llegan 20 cajas, 12 vencen en marzo y
 * 8 en mayo. Resolverlo cargando dos renglones del mismo producto obligaría a
 * partir también el costo, la bonificación y el II, que son de la línea y no
 * del lote — y el prorrateo de cargos de la mig 192 reparte por línea, así que
 * partirla cambiaría los costos.
 *
 * CARGAR MENOS QUE LA CANTIDAD DE LA LÍNEA ES LEGAL
 * -------------------------------------------------
 * Lo que no se etiqueta queda en la bolsa "sin vencimiento" del producto. Es un
 * estado soportado y visible en la ficha, no un error. Lo que no se permite es
 * lo contrario: etiquetar más unidades de las que entraron.
 *
 * Lo usan el modal de alta y el de edición de compra, que no se conocen entre
 * sí pero tienen que cargar esto igual.
 *
 * La fecha no tiene mínimo a propósito: un proveedor que manda mercadería con
 * el vencimiento encima es exactamente lo que hay que poder registrar, y el
 * panel se encarga de pintarlo en rojo.
 */
import { useState } from 'react'
import { CalendarClock, Plus, X } from 'lucide-react'
import type { VencimientoLinea } from '../modals/ModalCompra.reducer'
import { formatearFechaVencimiento } from '../../utils/vencimientos'

export interface VencimientosLineaCompraProps {
  /** Unidades de la línea: el techo de lo que se puede etiquetar. */
  cantidadLinea: number
  vencimientos: VencimientoLinea[]
  onChange: (vencimientos: VencimientoLinea[]) => void
}

export default function VencimientosLineaCompra({
  cantidadLinea,
  vencimientos,
  onChange,
}: VencimientosLineaCompraProps) {
  const [abierto, setAbierto] = useState(false)

  const asignado = vencimientos.reduce((acc, v) => acc + (Number(v.cantidad) || 0), 0)
  const libre = Math.max(0, (Number(cantidadLinea) || 0) - asignado)
  const excede = asignado > (Number(cantidadLinea) || 0)

  function actualizar(i: number, cambios: Partial<VencimientoLinea>) {
    onChange(vencimientos.map((v, j) => (j === i ? { ...v, ...cambios } : v)))
  }

  function agregar() {
    // Arranca con lo que queda libre: en el caso más común —un solo
    // vencimiento para toda la línea— no hay que tipear la cantidad.
    onChange([...vencimientos, { fecha: '', cantidad: libre > 0 ? libre : 1 }])
    setAbierto(true)
  }

  function quitar(i: number) {
    onChange(vencimientos.filter((_, j) => j !== i))
  }

  const resumen =
    vencimientos.length === 0
      ? 'Sin vencimiento'
      : vencimientos.length === 1 && vencimientos[0].fecha
        ? `Vence ${formatearFechaVencimiento(vencimientos[0].fecha)}`
        : `${vencimientos.length} vencimientos`

  return (
    <div className="mt-2 pt-2 border-t border-dashed dark:border-gray-600">
      <div className="flex flex-wrap items-center gap-2">
        <button
          type="button"
          onClick={() => (vencimientos.length === 0 ? agregar() : setAbierto(!abierto))}
          className={`inline-flex items-center gap-1 text-xs px-2 py-0.5 rounded-full transition-colors ${
            excede
              ? 'bg-red-100 text-red-800 dark:bg-red-900/40 dark:text-red-200'
              : vencimientos.length > 0
                ? 'bg-indigo-100 text-indigo-800 dark:bg-indigo-900/40 dark:text-indigo-200'
                : 'bg-stone-100 text-stone-600 hover:bg-stone-200 dark:bg-gray-700 dark:text-gray-300'
          }`}
        >
          <CalendarClock className="w-3 h-3" aria-hidden="true" />
          {resumen}
        </button>

        {vencimientos.length > 0 && !excede && libre > 0 && (
          <span className="text-xs text-stone-500 dark:text-gray-400">
            {libre} u. sin vencimiento
          </span>
        )}
        {excede && (
          <span className="text-xs text-red-700 dark:text-red-300">
            Etiquetaste {asignado} u. y la línea tiene {cantidadLinea}
          </span>
        )}
      </div>

      {abierto && vencimientos.length > 0 && (
        <div className="mt-2 space-y-1">
          {vencimientos.map((v, i) => (
            <div key={i} className="flex flex-wrap items-center gap-2">
              <input
                type="date"
                value={v.fecha}
                onChange={e => actualizar(i, { fecha: e.target.value })}
                aria-label={`Fecha de vencimiento ${i + 1}`}
                className="px-2 py-1 border rounded text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              />
              <input
                type="number"
                min={1}
                value={v.cantidad}
                onChange={e => actualizar(i, { cantidad: Number(e.target.value) })}
                aria-label={`Unidades del vencimiento ${i + 1}`}
                className="w-20 px-2 py-1 border rounded text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
              />
              <span className="text-xs text-stone-500 dark:text-gray-400">u.</span>
              <button
                type="button"
                onClick={() => quitar(i)}
                aria-label={`Quitar el vencimiento ${i + 1}`}
                className="p-1 text-stone-400 hover:text-red-600"
              >
                <X className="w-3.5 h-3.5" aria-hidden="true" />
              </button>
            </div>
          ))}
          {libre > 0 && (
            <button
              type="button"
              onClick={agregar}
              className="inline-flex items-center gap-1 text-xs text-blue-600 hover:text-blue-700"
            >
              <Plus className="w-3 h-3" aria-hidden="true" />
              Otro vencimiento ({libre} u. libres)
            </button>
          )}
        </div>
      )}
    </div>
  )
}
