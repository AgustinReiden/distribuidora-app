/**
 * Cierre en lote del atraso de salvedades (#1198). Sólo admin.
 *
 * Cierra como "Resuelto (Otro)" las salvedades pendientes de la sucursal activa
 * cargadas hasta una fecha, con una nota que dice que fue un cierre en lote y
 * hasta cuándo. No mueve stock ni plata (el stock se movió al registrarlas) y no
 * es anular. Siguen apareciendo en el reporte de Rechazos con su motivo, sus
 * cantidades y su plata.
 *
 * Es un modal Radix (ModalBase), y por eso la confirmación vive ADENTRO, como
 * un segundo paso del mismo contenido: una confirmación hermana en el container
 * queda detrás del overlay y falla en silencio (CLAUDE.md).
 *
 * Antes de confirmar se pide al servidor cuántas cerraría (`p_solo_contar`), así
 * el número que se confirma es el del servidor y no el de la página de la lista.
 */
import React, { useState } from 'react'
import { AlertTriangle, CheckCircle } from 'lucide-react'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { useCerrarSalvedadesEnLoteMutation, useConteoCierreEnLoteQuery } from '../../hooks/queries/useCierreSalvedadesEnLote'
import { fechaHaceDias, fechaLocalISO } from '../../utils/formatters'

export interface ModalCerrarSalvedadesEnLoteProps {
  onClose: () => void
}

function fechaLarga(iso: string): string {
  const [a, m, d] = iso.split('-')
  return `${d}/${m}/${a}`
}

type Paso = 'elegir' | 'confirmar' | 'hecho'

export default function ModalCerrarSalvedadesEnLote({ onClose }: ModalCerrarSalvedadesEnLoteProps): React.ReactElement {
  const hoy = fechaLocalISO()
  // Por defecto queda abierta la última semana, que es la cola de trabajo del
  // panel; el resto es el atraso. Se puede mover.
  const [hasta, setHasta] = useState<string>(() => fechaHaceDias(7))
  const [notas, setNotas] = useState('')
  const [paso, setPaso] = useState<Paso>('elegir')
  const [error, setError] = useState('')
  const [cerradas, setCerradas] = useState(0)

  const fechaValida = /^\d{4}-\d{2}-\d{2}$/.test(hasta) && hasta <= hoy
  const conteo = useConteoCierreEnLoteQuery(hasta, fechaValida && paso !== 'hecho')
  const cerrar = useCerrarSalvedadesEnLoteMutation()
  const cantidad = conteo.data ?? 0

  const confirmar = async (): Promise<void> => {
    setError('')
    try {
      const r = await cerrar.mutateAsync({ hasta, notas })
      setCerradas(r.cerradas)
      setPaso('hecho')
    } catch (e) {
      setError((e as Error).message || 'No se pudo cerrar las salvedades')
    }
  }

  return (
    <ModalBase
      title="Cerrar salvedades atrasadas"
      description="Cierra en un solo paso las salvedades pendientes cargadas hasta una fecha."
      onClose={onClose}
      maxWidth="max-w-lg"
    >
      <div className="space-y-4">
        {paso === 'hecho' ? (
          <div className="space-y-4" role="status">
            <p className="flex items-start gap-2 text-sm text-emerald-700 dark:text-emerald-300">
              <CheckCircle className="w-5 h-5 flex-shrink-0" />
              <span>
                Se cerraron {cerradas.toLocaleString('es-AR')} salvedades como «Resuelto (Otro)». Siguen apareciendo en el
                reporte de Rechazos.
              </span>
            </p>
            <div className="flex justify-end">
              <Button onClick={onClose} variant="primary" size="md">Listo</Button>
            </div>
          </div>
        ) : (
          <>
            <div className="space-y-3">
              <div>
                <label htmlFor="cierre-hasta" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  Cerrar las pendientes cargadas hasta el
                </label>
                <input
                  id="cierre-hasta"
                  type="date"
                  value={hasta}
                  max={hoy}
                  disabled={paso === 'confirmar'}
                  onChange={(e) => setHasta(e.target.value)}
                  className="w-full h-10 px-3 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white disabled:opacity-60"
                />
                {!fechaValida && (
                  <p className="text-xs text-red-600 dark:text-red-400 mt-1">Elegí una fecha que no sea futura.</p>
                )}
              </div>
              <div>
                <label htmlFor="cierre-notas" className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                  Nota (opcional)
                </label>
                <textarea
                  id="cierre-notas"
                  value={notas}
                  maxLength={500}
                  disabled={paso === 'confirmar'}
                  onChange={(e) => setNotas(e.target.value)}
                  rows={2}
                  placeholder="Se suma a la nota del cierre en lote"
                  className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg dark:bg-gray-700 dark:text-white disabled:opacity-60"
                />
              </div>
            </div>

            <ul className="text-xs text-gray-600 dark:text-gray-300 bg-gray-50 dark:bg-gray-800/60 rounded-lg p-3 space-y-1 list-disc pl-6">
              <li>Quedan como «Resuelto (Otro)», con una nota que dice que fue un cierre en lote y hasta qué fecha.</li>
              <li>No mueve stock ni plata, y no es anular: el stock ya se movió al registrarlas.</li>
              <li>Siguen en el reporte de Rechazos con su motivo, sus cantidades y su plata.</li>
            </ul>

            <p className="text-sm text-gray-700 dark:text-gray-200" data-testid="conteo-cierre">
              {!fechaValida ? null
                : conteo.isLoading ? 'Contando…'
                : conteo.isError ? `No se pudo contar: ${(conteo.error as Error).message}`
                : cantidad === 0 ? `No hay salvedades pendientes cargadas hasta el ${fechaLarga(hasta)}.`
                : <>Hay <strong>{cantidad.toLocaleString('es-AR')}</strong> salvedades pendientes cargadas hasta el {fechaLarga(hasta)}.</>}
            </p>

            {error && (
              <p role="alert" className="text-sm text-red-600 dark:text-red-400">{error}</p>
            )}

            {paso === 'confirmar' ? (
              // La confirmación vive dentro del modal Radix (CLAUDE.md).
              <div role="alertdialog" aria-labelledby="cierre-confirmar-titulo"
                className="border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-900/20 rounded-lg p-3 space-y-3">
                <p id="cierre-confirmar-titulo" className="flex items-start gap-2 text-sm text-amber-800 dark:text-amber-200">
                  <AlertTriangle className="w-5 h-5 flex-shrink-0" />
                  <span>
                    ¿Cerrar {cantidad.toLocaleString('es-AR')} salvedades pendientes cargadas hasta el {fechaLarga(hasta)}?
                    No se puede deshacer en lote.
                  </span>
                </p>
                <div className="flex justify-end gap-2">
                  <Button onClick={() => setPaso('elegir')} variant="secondary" size="md" disabled={cerrar.isPending}>
                    Volver
                  </Button>
                  <Button onClick={() => void confirmar()} variant="danger" size="md" loading={cerrar.isPending} disabled={cerrar.isPending}>
                    Sí, cerrar {cantidad.toLocaleString('es-AR')}
                  </Button>
                </div>
              </div>
            ) : (
              <div className="flex justify-end gap-2">
                <Button onClick={onClose} variant="secondary" size="md">Cancelar</Button>
                <Button
                  onClick={() => { setError(''); setPaso('confirmar') }}
                  variant="primary"
                  size="md"
                  disabled={!fechaValida || conteo.isLoading || conteo.isError || cantidad === 0}
                >
                  Cerrar {cantidad > 0 ? cantidad.toLocaleString('es-AR') : ''} salvedades
                </Button>
              </div>
            )}
          </>
        )}
      </div>
    </ModalBase>
  )
}
