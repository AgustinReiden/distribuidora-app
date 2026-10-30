/**
 * ModalFichaVehiculo — el gasto de un vehículo por mes y rubro, sus cargas de
 * combustible y sus lecturas de km. Los km por litro y el costo por km aparecen
 * sólo cuando hay datos para calcularlos.
 */
import React, { useId, useMemo, useState } from 'react'
import type { FormEvent } from 'react'
import { z } from 'zod'
import ModalBase from './ModalBase'
import { Button } from '../ui/Button'
import { Badge } from '../ui/Badge'
import Card from '../ui/Card'
import { getErrorMessage } from '../../utils/errorHandling'
import { formatPrecio } from '../../utils/formatters'
import { etiquetaMes } from '../../utils/gastos'
import { armarFichaVehiculo, type LecturaKm } from '../../utils/vehiculos'
import type { Gasto, Vehiculo } from '../../types/gastos'

// Schema CO-LOCADO a propósito (ver ModalCambioProducto.tsx).
// eslint-disable-next-line react-refresh/only-export-components
export const lecturaKmSchema = z.object({
  fecha: z.string().regex(/^\d{4}-\d{2}-\d{2}$/, { message: 'La fecha es obligatoria' }),
  km: z.coerce
    .number({ error: 'Escribí los km del tablero' })
    .int({ message: 'Los km del tablero tienen que ser un número entero' })
    .min(0, { message: 'Los km del tablero no pueden ser negativos' })
    .max(9999999, { message: 'Los km del tablero no pueden pasar de 9.999.999' }),
})

export interface ModalFichaVehiculoProps {
  vehiculo: Vehiculo
  /** Gastos de los últimos 12 meses, sin anulados. */
  gastos: Gasto[]
  lecturas: LecturaKm[]
  loading: boolean
  /** Mes en curso (primer día). */
  mes: string
  /** Nombres de los empleados activos que lo tienen como vehículo habitual. */
  usadoPor: string[]
  onRegistrarKm: (fecha: string, km: number) => Promise<void>
  onClose: () => void
}

const ORIGEN: Record<LecturaKm['origen'], string> = { manual: 'Manual', carga: 'Carga', gps: 'GPS' }

const hoyEnTucuman = (): string =>
  new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Tucuman' })

const diaCorto = (iso: string): string => `${iso.slice(8, 10)}/${iso.slice(5, 7)}/${iso.slice(0, 4)}`
const km = (n: number): string => n.toLocaleString('es-AR')

export default function ModalFichaVehiculo({
  vehiculo, gastos, lecturas, loading, mes, usadoPor, onRegistrarKm, onClose,
}: ModalFichaVehiculoProps): React.ReactElement {
  const ficha = useMemo(() => armarFichaVehiculo(gastos, lecturas, mes), [gastos, lecturas, mes])
  const idFecha = useId()
  const idKm = useId()

  const [registrando, setRegistrando] = useState(false)
  const [fecha, setFecha] = useState(hoyEnTucuman)
  const [kmTxt, setKmTxt] = useState('')
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  const guardarLectura = async (e: FormEvent<HTMLFormElement>) => {
    e.preventDefault()
    setError('')
    if (!kmTxt.trim()) {
      setError('Escribí los km del tablero')
      return
    }
    // Los puntos son separadores de miles; la coma, decimal (que el schema rechaza).
    const resultado = lecturaKmSchema.safeParse({ fecha, km: kmTxt.replace(/\./g, '').replace(',', '.') })
    if (!resultado.success) {
      setError(resultado.error.issues[0]?.message ?? 'Revisá la lectura')
      return
    }
    setGuardando(true)
    try {
      await onRegistrarKm(resultado.data.fecha, resultado.data.km)
      setKmTxt('')
      setRegistrando(false)
    } catch (err) {
      setError(getErrorMessage(err))
    } finally {
      setGuardando(false)
    }
  }

  const lecturasOrdenadas = [...lecturas].sort((a, b) => b.fecha.localeCompare(a.fecha) || b.km - a.km)

  return (
    <ModalBase title={`Ficha de ${vehiculo.patente}`} description={vehiculo.descripcion} onClose={onClose} maxWidth="max-w-4xl">
      <div className="p-4 space-y-5">
        <div className="flex flex-wrap items-center gap-2 text-sm text-gray-600 dark:text-gray-300">
          <span className="font-mono font-semibold tracking-wide text-gray-800 dark:text-white">{vehiculo.patente}</span>
          <span>{vehiculo.descripcion}</span>
          {!vehiculo.activo && <Badge tone="neutral">Inactivo</Badge>}
        </div>
        <p className="text-sm text-gray-600 dark:text-gray-300">
          {usadoPor.length > 0
            ? `Lo usan habitualmente: ${usadoPor.join(', ')}`
            : 'Nadie lo tiene como vehículo habitual.'}
        </p>

        {loading ? (
          <p className="text-sm text-gray-500" role="status">Cargando la ficha…</p>
        ) : (
          <>
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
              <Card variant="stat">
                <p className="text-xs text-gray-500">Gasto de {etiquetaMes(mes)}</p>
                <p className="text-lg font-bold text-gray-800 dark:text-white">{formatPrecio(ficha.gastoMes)}</p>
              </Card>
              <Card variant="stat">
                <p className="text-xs text-gray-500">Últimos 12 meses</p>
                <p className="text-lg font-bold text-gray-800 dark:text-white">{formatPrecio(ficha.gasto12Meses)}</p>
              </Card>
              {ficha.kmPorLitro != null && (
                <Card variant="stat">
                  <p className="text-xs text-gray-500">Rendimiento</p>
                  <p className="text-lg font-bold text-gray-800 dark:text-white">
                    {`${ficha.kmPorLitro.toLocaleString('es-AR', { minimumFractionDigits: 1 })} km/l`}
                  </p>
                </Card>
              )}
              {ficha.costoKm != null && (
                <Card variant="stat">
                  <p className="text-xs text-gray-500">Costo por km</p>
                  <p className="text-lg font-bold text-gray-800 dark:text-white">{formatPrecio(ficha.costoKm)}</p>
                </Card>
              )}
            </div>

            <section aria-label="Gasto por mes y rubro">
              <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-200 mb-2">Gasto por mes y rubro</h3>
              {ficha.porRubro.length === 0 ? (
                <p className="text-sm text-gray-500">Sin gastos en los últimos 6 meses.</p>
              ) : (
                <div className="overflow-x-auto">
                  <table className="w-full text-sm">
                    <thead>
                      <tr className="text-left text-xs text-gray-500">
                        <th className="py-1 pr-3 font-medium">Rubro</th>
                        {ficha.meses.map(m => (
                          <th key={m} className="py-1 px-2 text-right font-medium capitalize">{etiquetaMes(m)}</th>
                        ))}
                        <th className="py-1 pl-2 text-right font-medium">Total</th>
                      </tr>
                    </thead>
                    <tbody>
                      {ficha.porRubro.map(r => (
                        <tr key={r.rubro} className="border-t border-gray-100 dark:border-gray-700">
                          <td className="py-1 pr-3 text-gray-800 dark:text-gray-100">{r.rubro}</td>
                          {r.porMes.map((v, i) => (
                            <td key={ficha.meses[i]} className="py-1 px-2 text-right tabular-nums text-gray-600 dark:text-gray-300">
                              {v ? formatPrecio(v) : '—'}
                            </td>
                          ))}
                          <td className="py-1 pl-2 text-right tabular-nums font-medium text-gray-800 dark:text-white">{formatPrecio(r.total)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                </div>
              )}
            </section>

            <section aria-label="Cargas de combustible">
              <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-200 mb-2">Cargas de combustible</h3>
              {ficha.cargas.length === 0 ? (
                <p className="text-sm text-gray-500">Todavía no hay cargas con litros.</p>
              ) : (
                <table className="w-full text-sm">
                  <thead>
                    <tr className="text-left text-xs text-gray-500">
                      <th className="py-1 font-medium">Fecha</th>
                      <th className="py-1 text-right font-medium">Litros</th>
                      <th className="py-1 text-right font-medium">Km</th>
                      <th className="py-1 text-right font-medium">Monto</th>
                    </tr>
                  </thead>
                  <tbody>
                    {ficha.cargas.map((c, i) => (
                      <tr key={i} className="border-t border-gray-100 dark:border-gray-700">
                        <td className="py-1 text-gray-800 dark:text-gray-100">{diaCorto(c.fecha)}</td>
                        <td className="py-1 text-right tabular-nums">{c.litros.toLocaleString('es-AR')}</td>
                        <td className="py-1 text-right tabular-nums">{c.km != null ? km(c.km) : '—'}</td>
                        <td className="py-1 text-right tabular-nums">{formatPrecio(c.monto)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </section>

            <section aria-label="Lecturas de km">
              <div className="flex items-center justify-between mb-2">
                <h3 className="text-sm font-semibold text-gray-700 dark:text-gray-200">Lecturas de km</h3>
                {!registrando && (
                  <button
                    type="button"
                    className="text-sm text-brand-600 dark:text-brand-400 font-medium hover:underline"
                    onClick={() => setRegistrando(true)}
                  >
                    + Registrar km
                  </button>
                )}
              </div>
              {registrando && (
                <form onSubmit={guardarLectura} className="mb-3 flex flex-wrap items-end gap-2">
                  <div>
                    <label htmlFor={idFecha} className="block text-xs text-gray-500 mb-1">Fecha</label>
                    <input
                      id={idFecha}
                      type="date"
                      value={fecha}
                      onChange={e => setFecha(e.target.value)}
                      className="px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-lg text-sm dark:bg-gray-700 dark:text-white"
                    />
                  </div>
                  <div>
                    <label htmlFor={idKm} className="block text-xs text-gray-500 mb-1">Km del tablero</label>
                    <input
                      id={idKm}
                      type="text"
                      inputMode="numeric"
                      value={kmTxt}
                      onChange={e => setKmTxt(e.target.value)}
                      className="w-36 px-3 py-1.5 border border-gray-300 dark:border-gray-600 rounded-lg text-sm text-right dark:bg-gray-700 dark:text-white"
                    />
                  </div>
                  <Button type="submit" variant="primary" size="sm" loading={guardando} disabled={guardando}>
                    Guardar lectura
                  </Button>
                  <Button type="button" variant="ghost" size="sm" onClick={() => { setRegistrando(false); setError('') }}>
                    Cancelar
                  </Button>
                </form>
              )}
              {error && (
                <div className="mb-3 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
                  <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
                </div>
              )}
              {lecturasOrdenadas.length === 0 ? (
                <p className="text-sm text-gray-500">Todavía no hay lecturas de km.</p>
              ) : (
                <ul className="divide-y divide-gray-100 dark:divide-gray-700 text-sm">
                  {lecturasOrdenadas.map((l, i) => (
                    <li key={i} className="flex items-center justify-between py-1.5">
                      <span className="text-gray-700 dark:text-gray-200">{diaCorto(l.fecha)}</span>
                      <span className="tabular-nums text-gray-800 dark:text-white">{km(l.km)} km</span>
                      <Badge tone="neutral">{ORIGEN[l.origen]}</Badge>
                    </li>
                  ))}
                </ul>
              )}
            </section>
          </>
        )}

        <div className="flex justify-end">
          <Button type="button" variant="secondary" size="md" onClick={onClose}>Cerrar</Button>
        </div>
      </div>
    </ModalBase>
  )
}
