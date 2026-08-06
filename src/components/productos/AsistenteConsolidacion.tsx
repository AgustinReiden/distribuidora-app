/**
 * Propone unir las condiciones que en realidad son un solo fardo surtido.
 *
 * No fusiona nada solo: muestra qué quedaría —qué sabores entran, qué escalas
 * resultan y con qué nombre— y espera confirmación caso por caso. El nombre
 * importa: "CODITO 1/2 FARDO" describiría muy mal una condición con 5 sabores.
 */
import { useMemo, useState } from 'react'
import { Layers, Loader2 } from 'lucide-react'
import {
  useProductosQuery,
  useConsolidarCondicionesMutation,
} from '../../hooks/queries'
import { useNotification } from '../../contexts/NotificationContext'
import { detectarConsolidables } from '../../utils/consolidacionCondiciones'
import { formatPrecio } from '../../utils/formatters'
import type { GrupoPrecioConDetalles } from '../../types'

export interface AsistenteConsolidacionProps {
  grupos: GrupoPrecioConDetalles[]
}

export default function AsistenteConsolidacion({ grupos }: AsistenteConsolidacionProps) {
  const notify = useNotification()
  const { data: productos = [] } = useProductosQuery()
  const consolidar = useConsolidarCondicionesMutation()

  const [abierto, setAbierto] = useState(false)
  const [nombres, setNombres] = useState<Record<string, string>>({})
  const [aplicando, setAplicando] = useState<string | null>(null)

  const nombresProductos = useMemo(() => {
    const map = new Map<string, string>()
    for (const p of productos) map.set(String(p.id), p.nombre)
    return map
  }, [productos])

  const consolidables = useMemo(
    () => detectarConsolidables(grupos, nombresProductos),
    [grupos, nombresProductos],
  )

  if (consolidables.length === 0) return null

  const condicionesInvolucradas = consolidables.reduce((n, c) => n + c.condicionesOrigen.length, 0)

  const aplicar = async (firma: string): Promise<void> => {
    const caso = consolidables.find(c => c.firma === firma)
    if (!caso) return

    // La primera sobrevive y absorbe al resto: así al menos sus escalas
    // conservan el id que pedido_items referencia.
    const [destino, ...origen] = caso.condicionesOrigen
    setAplicando(firma)
    try {
      const res = await consolidar.mutateAsync({
        grupoDestino: destino.id,
        gruposOrigen: origen.map(o => o.id),
        nombre: nombres[firma] ?? caso.nombreSugerido,
      })
      notify.success(
        `Quedó una sola condición${res?.items_repuntados ? ` · ${res.items_repuntados} pedidos conservaron su rastro de precio` : ''}`,
      )
    } catch (e) {
      notify.error((e as Error).message || 'No se pudo unificar')
    } finally {
      setAplicando(null)
    }
  }

  return (
    <div className="rounded-xl border border-indigo-300 dark:border-indigo-800/60 bg-indigo-50 dark:bg-indigo-900/20 p-3">
      <div className="flex items-start gap-3">
        <Layers className="w-5 h-5 shrink-0 mt-0.5 text-indigo-600 dark:text-indigo-400" aria-hidden="true" />
        <div className="flex-1 min-w-0">
          <p className="text-sm font-semibold text-indigo-900 dark:text-indigo-100">
            {condicionesInvolucradas} condiciones podrían ser {consolidables.length}
          </p>
          <p className="text-xs text-indigo-800 dark:text-indigo-200 mt-0.5">
            Hay sabores con el mismo precio por cantidad cargados por separado. Mientras estén en
            condiciones distintas, lo que el cliente mezcle entre ellos no suma para llegar al mínimo.
          </p>
        </div>
        <button
          type="button"
          onClick={() => setAbierto(!abierto)}
          className="shrink-0 px-3 py-1.5 rounded-lg text-xs font-medium bg-white dark:bg-gray-800 text-indigo-700 dark:text-indigo-300 border border-indigo-300 dark:border-indigo-700/60 hover:bg-indigo-100 dark:hover:bg-indigo-900/30"
          aria-expanded={abierto}
        >
          {abierto ? 'Ocultar' : 'Ver qué se puede unir'}
        </button>
      </div>

      {abierto && (
        <ul className="mt-3 space-y-2">
          {consolidables.map(caso => {
            const sabores = caso.productoIds
              .map(pid => nombresProductos.get(pid) ?? `#${pid}`)
              .sort((a, b) => a.localeCompare(b))
            const nombre = nombres[caso.firma] ?? caso.nombreSugerido
            const enCurso = aplicando === caso.firma

            return (
              <li
                key={caso.firma}
                className="rounded-lg bg-white dark:bg-gray-800 border border-indigo-200 dark:border-gray-700 p-3 space-y-2"
              >
                <p className="text-xs text-stone-600 dark:text-gray-300">
                  <span className="font-medium">{sabores.length} producto{sabores.length === 1 ? '' : 's'}</span>
                  {' · '}
                  {caso.condicionesOrigen.length} condiciones pasan a ser 1
                </p>
                <p className="text-xs text-stone-500 dark:text-gray-400">{sabores.join(', ')}</p>
                <p className="text-xs text-stone-700 dark:text-gray-200 tabular-nums">
                  {caso.escalas.map(e => `Desde ${e.cantidadMinima} u. ${formatPrecio(e.precioUnitario)}`).join('  ·  ')}
                </p>

                <div className="flex flex-wrap items-end gap-2">
                  <label className="text-xs text-stone-600 dark:text-gray-400 flex-1 min-w-[10rem]">
                    Nombre de la condición
                    <input
                      type="text"
                      maxLength={200}
                      value={nombre}
                      onChange={e => setNombres(prev => ({ ...prev, [caso.firma]: e.target.value }))}
                      className="mt-0.5 block w-full px-2 py-1 border rounded text-sm dark:bg-gray-800 dark:border-gray-600 dark:text-white"
                    />
                  </label>
                  <button
                    type="button"
                    onClick={() => void aplicar(caso.firma)}
                    disabled={enCurso || !nombre.trim()}
                    className="inline-flex items-center gap-1 px-3 py-1.5 rounded-lg text-xs font-medium bg-indigo-600 text-white disabled:opacity-50"
                  >
                    {enCurso && <Loader2 className="w-3 h-3 animate-spin" aria-hidden="true" />}
                    {enCurso ? 'Unificando…' : 'Unificar'}
                  </button>
                </div>
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
