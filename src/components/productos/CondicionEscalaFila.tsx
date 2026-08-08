/**
 * Una escala (precio por cantidad) dentro de la ficha del producto: se ve el
 * margen que deja y se puede editar o borrar sin salir del producto.
 *
 * La confirmación de borrado es inline y no un ModalConfirmacion: la ficha ya
 * es un modal Radix y un diálogo hermano queda detrás del overlay.
 */
import { useState } from 'react'
import { Pencil, Trash2 } from 'lucide-react'
import { useNotification } from '../../contexts/NotificationContext'
import {
  useActualizarEscalaMutation,
  useEliminarEscalaMutation,
} from '../../hooks/queries'
import { formatPrecio } from '../../utils/formatters'
import { margenesEscala, descuentoSobreLista } from './margenEscala'
import FormEscalaMayorista from './FormEscalaMayorista'
import type { ValoresEscala } from './FormEscalaMayorista'
import type { EscalaDeProducto } from '../../utils/condicionesMayoristas'

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

export interface CondicionEscalaFilaProps {
  escala: EscalaDeProducto
  /** Regla en texto humano, ya armada por `describirReglaEscala`. */
  regla: string
  precioLista: number
  costoTotal: number
  costoReal: number
  porcentajeIva: number
  /** Cuántos productos comparten la condición: define el alcance del cambio. */
  cantidadProductosGrupo: number
  puedeEditar: boolean
}

export default function CondicionEscalaFila({
  escala,
  regla,
  precioLista,
  costoTotal,
  costoReal,
  porcentajeIva,
  cantidadProductosGrupo,
  puedeEditar,
}: CondicionEscalaFilaProps) {
  const notify = useNotification()
  const actualizar = useActualizarEscalaMutation()
  const eliminar = useEliminarEscalaMutation()
  const [modo, setModo] = useState<'ver' | 'editar' | 'confirmar'>('ver')

  const { bruto, neto } = margenesEscala(escala.precioEfectivo, costoTotal, costoReal, porcentajeIva)
  const descuento = descuentoSobreLista(escala.precioEfectivo, precioLista)

  // El precio de la escala lo comparten todos los productos de la condición.
  // Decirlo antes de guardar evita el cambio sorpresa en los otros sabores.
  const afectaAlGrupo = cantidadProductosGrupo > 1

  const guardar = async (valores: ValoresEscala): Promise<void> => {
    try {
      await actualizar.mutateAsync({
        escalaId: escala.escalaId,
        cantidadMinima: valores.cantidadMinima,
        precioUnitario: valores.precioUnitario,
        etiqueta: valores.etiqueta,
      })
      notify.success(
        afectaAlGrupo
          ? `Escala actualizada (${cantidadProductosGrupo} productos)`
          : 'Escala actualizada',
      )
      setModo('ver')
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo actualizar la escala')
    }
  }

  const borrar = async (): Promise<void> => {
    try {
      await eliminar.mutateAsync({ escalaId: escala.escalaId })
      notify.success('Escala eliminada')
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo eliminar la escala')
      setModo('ver')
    }
  }

  if (modo === 'editar') {
    return (
      <li className="px-3 py-2.5">
        {afectaAlGrupo && (
          <p className="text-[11px] text-amber-700 dark:text-amber-400 mb-2">
            Esta escala la comparten {cantidadProductosGrupo} productos: el cambio los alcanza a todos.
          </p>
        )}
        <FormEscalaMayorista
          inicial={{
            cantidadMinima: escala.cantidadMinima,
            precioUnitario: escala.precioEfectivo,
            etiqueta: escala.escala.etiqueta,
          }}
          precioLista={precioLista}
          costoTotal={costoTotal}
          costoReal={costoReal}
          porcentajeIva={porcentajeIva}
          guardando={actualizar.isPending}
          textoGuardar="Guardar"
          onGuardar={valores => void guardar(valores)}
          onCancelar={() => setModo('ver')}
        />
      </li>
    )
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
                  {descuento >= 0
                    ? `${descuento.toFixed(1)}% bajo lista`
                    : `${Math.abs(descuento).toFixed(1)}% sobre lista`}
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
          {modo === 'confirmar' ? (
            <div className="flex items-center gap-2 justify-end">
              <span className="text-xs text-stone-600 dark:text-gray-300">¿Borrar esta escala?</span>
              <button
                type="button"
                onClick={() => setModo('ver')}
                className="px-2 py-1 text-xs rounded border dark:border-gray-600 dark:text-gray-200"
              >
                No
              </button>
              <button
                type="button"
                onClick={() => void borrar()}
                disabled={eliminar.isPending}
                className="px-2 py-1 text-xs rounded bg-rose-600 text-white disabled:opacity-50"
              >
                {eliminar.isPending ? 'Borrando…' : 'Sí, borrar'}
              </button>
            </div>
          ) : (
            <div className="inline-flex items-center gap-2">
              <span className="text-sm font-semibold tabular-nums text-stone-700 dark:text-gray-200">
                {formatPrecio(escala.precioEfectivo)}
              </span>
              {puedeEditar && (
                <>
                  <button
                    type="button"
                    onClick={() => setModo('editar')}
                    className="p-1 rounded text-blue-600 dark:text-blue-400 hover:bg-blue-50 dark:hover:bg-blue-900/20"
                    aria-label={`Editar la escala de ${escala.cantidadMinima} unidades`}
                    title="Editar cantidad, precio o etiqueta"
                  >
                    <Pencil className="w-3.5 h-3.5" aria-hidden="true" />
                  </button>
                  <button
                    type="button"
                    onClick={() => setModo('confirmar')}
                    className="p-1 rounded text-rose-600 dark:text-rose-400 hover:bg-rose-50 dark:hover:bg-rose-900/20"
                    aria-label={`Eliminar la escala de ${escala.cantidadMinima} unidades`}
                    title="Eliminar esta escala"
                  >
                    <Trash2 className="w-3.5 h-3.5" aria-hidden="true" />
                  </button>
                </>
              )}
            </div>
          )}
        </div>
      </div>
    </li>
  )
}
