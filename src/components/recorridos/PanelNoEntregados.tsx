/**
 * PanelNoEntregados
 *
 * La métrica que cierra el círculo de la tanda: el ruteo en barridas se armó
 * porque volvían 5-6 pedidos por día sin entregar y "CERRADO" era el 33% de las
 * cancelaciones. Este panel es lo que permite saber si sirvió, en vez de
 * suponerlo.
 *
 * El cruce motivo × barrida es el dato accionable: si "estaba cerrado" sigue
 * concentrado en la barrida 1 —la de los que cierran al mediodía— el umbral de
 * las 14:30 quedó corto. Si se corrió a la 3, el problema es otro.
 */
import { useMemo } from 'react'
import { PackageX } from 'lucide-react'
import { useNoEntregadosQuery } from '../../hooks/queries'
import { LABEL_MOTIVO } from '../../constants/motivosNoEntrega'
import { ETIQUETA_BARRIDA, type Barrida } from '../../utils/barridas'

export interface PanelNoEntregadosProps {
  /** Rango a medir. La vista de recorridos trabaja sobre un día. */
  desde: string
  hasta: string
}

function labelBarrida(b: number | null): string {
  if (b == null) return 'Sin barrida'
  return ETIQUETA_BARRIDA[b as Barrida] ?? `Barrida ${b}`
}

function labelMotivo(m: string): string {
  return m === 'sin_motivo' ? 'Sin motivo cargado' : (LABEL_MOTIVO[m] ?? m)
}

export default function PanelNoEntregados({ desde, hasta }: PanelNoEntregadosProps) {
  const { data, isLoading } = useNoEntregadosQuery(desde, hasta)

  // Barridas presentes, en orden, para armar las columnas del cruce.
  const columnas = useMemo(() => (data?.porBarrida ?? []).map(b => b.barrida), [data])

  if (isLoading) {
    return (
      <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg p-4 text-sm text-stone-500">
        Cargando no entregados…
      </div>
    )
  }

  if (!data || data.total === 0) {
    return (
      <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg p-4">
        <h3 className="text-sm font-medium flex items-center gap-1.5 dark:text-white">
          <PackageX className="w-4 h-4 text-emerald-600" aria-hidden="true" />
          No entregados
        </h3>
        <p className="text-sm text-emerald-700 dark:text-emerald-400 mt-1">
          Ninguno en el período. Todo lo que salió se entregó.
        </p>
      </div>
    )
  }

  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg p-4 space-y-3">
      <div className="flex items-center justify-between gap-2">
        <h3 className="text-sm font-medium flex items-center gap-1.5 dark:text-white">
          <PackageX className="w-4 h-4 text-rose-600" aria-hidden="true" />
          No entregados
        </h3>
        <span className="text-lg font-bold text-rose-600 tabular-nums">{data.total}</span>
      </div>

      {/* Por motivo: el ranking crudo. */}
      <div className="flex flex-wrap gap-1.5">
        {data.porMotivo.map(m => (
          <span
            key={m.motivo}
            className="inline-flex items-center gap-1.5 px-2 py-1 rounded-full text-xs bg-stone-100 dark:bg-gray-700 text-stone-700 dark:text-gray-200"
          >
            {labelMotivo(m.motivo)}
            <strong className="tabular-nums">{m.cantidad}</strong>
          </span>
        ))}
      </div>

      {/* Cruce motivo × barrida. Sólo tiene sentido si hubo más de una barrida. */}
      {columnas.length > 1 && (
        <div className="overflow-x-auto">
          <table className="w-full text-xs">
            <thead>
              <tr className="text-stone-500 dark:text-gray-400">
                <th className="text-left font-medium py-1 pr-3">Motivo</th>
                {columnas.map(b => (
                  <th key={String(b)} className="text-right font-medium py-1 px-2 whitespace-nowrap">
                    {labelBarrida(b)}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {data.porMotivo.map(m => (
                <tr key={m.motivo}>
                  <td className="py-1 pr-3 text-stone-700 dark:text-gray-200">{labelMotivo(m.motivo)}</td>
                  {columnas.map(b => {
                    const celda = data.cruce.find(c => c.motivo === m.motivo && c.barrida === b)
                    return (
                      <td
                        key={String(b)}
                        className={`py-1 px-2 text-right tabular-nums ${
                          celda ? 'text-stone-800 dark:text-gray-100 font-medium' : 'text-stone-300 dark:text-gray-600'
                        }`}
                      >
                        {celda?.cantidad ?? '·'}
                      </td>
                    )
                  })}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <p className="text-xs text-stone-500 dark:text-gray-400">
        Los no entregados vuelven al pool de «Armar ruta»: la venta sigue viva.
      </p>
    </div>
  )
}
