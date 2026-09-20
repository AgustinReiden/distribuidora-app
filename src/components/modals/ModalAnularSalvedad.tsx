/**
 * Modal de ANULACION de una salvedad (mig 244, decision #621).
 *
 * Anular no es resolver. Las seis resoluciones de ModalResolverSalvedad sólo
 * dicen quien se hace cargo del monto; esto deshace la salvedad entera:
 *
 *   · la linea vuelve a su cantidad original y el pedido a su total → el
 *     cliente vuelve a pagar lo que la salvedad le habia sacado;
 *   · si la salvedad habia devuelto stock, se vuelve a descontar;
 *   · si era por dañado o vencido, la merma que dejo queda anulada.
 *
 * Por eso la confirmacion es explicita y esta ACA ADENTRO, no como un segundo
 * modal hermano: el aviso de lo que se mueve y el boton que lo mueve tienen que
 * verse juntos.
 *
 * El schema Zod va CO-LOCADO en este archivo, no importado de `lib/schemas`
 * (CLAUDE.md): esta vista es lazy, y un bundle viejo del PWA validando contra
 * un schema desincronizado tira "Invalid input" sin ningun error de chunk.
 */
import React, { useState, FormEvent, ChangeEvent } from 'react'
import { X, AlertTriangle, FileText, Undo2 } from 'lucide-react'
import { z } from 'zod'
import { Button } from '../ui/Button'
import { MOTIVOS_SALVEDAD_LABELS } from '../../lib/schemas'
import { formatPrecio } from '../../utils/formatters'
import type { SalvedadItemDBExtended } from '../../types'

/** Las notas son obligatorias: mueve stock y plata, tiene que quedar el por que. */
// eslint-disable-next-line react-refresh/only-export-components
export const anularSalvedadSchema = z.object({
  notas: z.string().trim().min(5, 'Escribí por qué se anula (mínimo 5 caracteres)')
})

export type AnularSalvedadFormData = z.infer<typeof anularSalvedadSchema>

/** Los dos motivos que dejan una fila en `mermas_stock` (mig 234). */
const MOTIVOS_CON_MERMA = ['producto_danado', 'producto_vencido'] as const

export interface ModalAnularSalvedadProps {
  salvedad: SalvedadItemDBExtended;
  onAnular: (notas: string) => Promise<void>;
  onClose: () => void;
}

export default function ModalAnularSalvedad({
  salvedad,
  onAnular,
  onClose
}: ModalAnularSalvedadProps): React.ReactElement {
  const [notas, setNotas] = useState<string>('')
  const [guardando, setGuardando] = useState<boolean>(false)
  const [error, setError] = useState<string>('')

  const dejoMerma = (MOTIVOS_CON_MERMA as readonly string[]).includes(salvedad.motivo)

  const handleSubmit = async (e: FormEvent<HTMLFormElement>): Promise<void> => {
    e.preventDefault()
    setError('')

    const parsed = anularSalvedadSchema.safeParse({ notas })
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? 'Datos inválidos')
      return
    }

    setGuardando(true)
    try {
      await onAnular(parsed.data.notas)
      onClose()
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo anular la salvedad')
    } finally {
      setGuardando(false)
    }
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-lg max-h-[90vh] overflow-y-auto">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-red-100 dark:bg-red-900/30 rounded-lg">
              <Undo2 className="w-5 h-5 text-red-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Anular salvedad</h2>
              <p className="text-sm text-gray-500">ID: {salvedad.id}</p>
            </div>
          </div>
          <Button variant="ghost" size="iconSm" onClick={onClose} aria-label="Cerrar">
            <X className="w-5 h-5" />
          </Button>
        </div>

        <form onSubmit={handleSubmit} className="p-4 space-y-4">
          {/* Que se esta anulando */}
          <div className="p-3 bg-gray-50 dark:bg-gray-900 rounded-lg text-sm space-y-1">
            <p className="font-medium text-gray-800 dark:text-white">
              {salvedad.producto_nombre || salvedad.producto?.nombre || 'Producto'}
            </p>
            <p className="text-gray-600 dark:text-gray-400">
              {MOTIVOS_SALVEDAD_LABELS[salvedad.motivo]} · {salvedad.cantidad_afectada} u. ·{' '}
              {formatPrecio(salvedad.monto_afectado)}
            </p>
            <p className="text-gray-600 dark:text-gray-400">
              Cliente: {salvedad.cliente_nombre || '-'}
            </p>
          </div>

          {/* La confirmacion: que mueve, en concreto */}
          <div className="p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
            <div className="flex items-start gap-2">
              <AlertTriangle className="w-5 h-5 text-amber-600 flex-shrink-0 mt-0.5" />
              <div className="text-sm text-amber-800 dark:text-amber-300 space-y-2">
                <p className="font-medium">Anular mueve stock y plata. Se va a:</p>
                <ul className="list-disc pl-4 space-y-1">
                  <li>
                    devolver la línea a {salvedad.cantidad_original} u. y recalcular el total del
                    pedido: el cliente vuelve a pagar {formatPrecio(salvedad.monto_afectado)}
                  </li>
                  {salvedad.stock_devuelto && (
                    <li>
                      volver a descontar {salvedad.cantidad_afectada} u. de stock, que la salvedad
                      había devuelto
                    </li>
                  )}
                  {dejoMerma && (
                    <li>
                      anular la merma de {salvedad.cantidad_afectada} u. que dejó esta salvedad:
                      deja de contar como pérdida en los reportes
                    </li>
                  )}
                </ul>
                <p>No se puede deshacer.</p>
              </div>
            </div>
          </div>

          {/* Notas */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <FileText className="w-4 h-4 inline mr-1" />
              Por qué se anula *
            </label>
            <textarea
              value={notas}
              onChange={(e: ChangeEvent<HTMLTextAreaElement>) => setNotas(e.target.value)}
              placeholder="Ej: se cargó por error, la mercadería llegó bien"
              rows={3}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-red-500 dark:bg-gray-700 dark:text-white"
              required
            />
          </div>

          {error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            </div>
          )}

          <div className="flex gap-3 pt-2">
            <Button type="button" variant="secondary" size="md" onClick={onClose} className="flex-1">
              Cancelar
            </Button>
            <Button
              type="submit"
              variant="danger"
              size="md"
              disabled={guardando || notas.trim().length < 5}
              className="flex-1"
            >
              <Undo2 className="w-4 h-4" />
              {guardando ? 'Anulando...' : 'Anular salvedad'}
            </Button>
          </div>
        </form>
      </div>
    </div>
  )
}
