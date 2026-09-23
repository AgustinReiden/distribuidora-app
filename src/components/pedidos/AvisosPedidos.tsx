/**
 * AvisosPedidos
 *
 * Los dos paneles de alerta de /pedidos —`PanelPedidosNoEntregados` y
 * `PanelPedidosTrabados`— plegados detrás de una línea de resumen (#714). Iban
 * antes del título de la vista y ocupaban varias líneas cada vez que tenían
 * datos; ahora se ve "2 avisos: …" y un clic los despliega tal cual son.
 *
 * Los conteos salen de las MISMAS queries que usan los paneles, llamadas con
 * los mismos argumentos: misma queryKey, así que React Query las deduplica y el
 * resumen no agrega requests. Y el criterio para contar es el mismo con el que
 * cada panel decide ocultarse (cargando, lista vacía, o `enabled` en falso para
 * los trabados): la línea nunca promete un panel que al desplegarse no aparece.
 */
import { useId, useState } from 'react'
import { AlertTriangle, ChevronDown } from 'lucide-react'
import { usePedidosTrabadosQuery } from '../../hooks/queries/usePedidosTrabadosQuery'
import { usePedidosSinResolverQuery } from '../../hooks/queries'
import { resumenAvisosPedidos, etiquetaTotalAvisos } from '../../utils/resumenAvisosPedidos'
import { cn } from '../../lib/utils'
import Card from '../ui/Card'
import { IconBadge } from '../ui/IconBadge'
import PanelPedidosNoEntregados from './PanelPedidosNoEntregados'
import PanelPedidosTrabados, { type PanelPedidosTrabadosProps } from './PanelPedidosTrabados'

export type AvisosPedidosProps = PanelPedidosTrabadosProps

export default function AvisosPedidos({ enabled, onVolverAPendiente }: AvisosPedidosProps) {
  const trabadosQuery = usePedidosTrabadosQuery(enabled)
  const noEntregadosQuery = usePedidosSinResolverQuery()
  const [expandido, setExpandido] = useState(false)
  const idPaneles = useId()

  // Una query deshabilitada no está cargando nada que esperar: sin este gate,
  // el aviso de no entregados quedaría rehén de una query que no va a correr.
  const cargando = noEntregadosQuery.isLoading || (enabled && trabadosQuery.isLoading)
  const resumen = resumenAvisosPedidos({
    // Sin `enabled` el panel de trabados no se dibuja aunque la cache tenga
    // datos (los sembró otro, o quedaron de antes): tampoco se cuentan.
    trabados: enabled ? (trabadosQuery.data?.length ?? 0) : 0,
    noEntregados: noEntregadosQuery.data?.length ?? 0,
  })

  if (cargando || !resumen) return null

  return (
    <div className="mb-3">
      {/* Sin `overflow-hidden` en la Card, a propósito: el botón la llena de
          borde a borde, y en alto contraste el foco es un `outline` con
          `outline-offset: 2px` (high-contrast.css), o sea que cae entero FUERA
          del botón: la Card lo recortaba completo y el foco no se veía. Las
          esquinas del hover las respeta el propio botón heredando el radio.
          El anillo es amber-700 y no 500: 500 sobre blanco da ~2,1:1 y el
          indicador de foco pide 3:1 (WCAG 1.4.11). */}
      <Card padding="none" accent="warning">
        <button
          type="button"
          onClick={() => setExpandido(v => !v)}
          aria-expanded={expandido}
          aria-controls={idPaneles}
          className="w-full rounded-[inherit] flex items-center gap-3 px-3 py-2 text-left hover:bg-amber-50 dark:hover:bg-amber-900/20 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-amber-700 dark:focus-visible:ring-amber-400 transition-colors"
        >
          <IconBadge icon={AlertTriangle} tone="warning" size="sm" />
          <span className="min-w-0 flex-1 text-sm">
            <span className="font-semibold text-amber-800 dark:text-amber-300">
              {etiquetaTotalAvisos(resumen.total)}
            </span>
            <span className="text-gray-700 dark:text-gray-300">: {resumen.partes.join(' · ')}</span>
          </span>
          <ChevronDown
            className={cn(
              'w-4 h-4 shrink-0 text-amber-700 dark:text-amber-300 transition-transform motion-reduce:transition-none',
              expandido && 'rotate-180',
            )}
            aria-hidden="true"
          />
        </button>
      </Card>

      {/* Los paneles van sin envoltorio: el que no tiene datos devuelve null y
          no deja un hueco, y `space-y-3` pone entre los dos el mismo mb-3 que
          tenían sueltos en el container. */}
      {expandido && (
        <div id={idPaneles} className="mt-3 space-y-3">
          <PanelPedidosNoEntregados />
          <PanelPedidosTrabados enabled={enabled} onVolverAPendiente={onVolverAPendiente} />
        </div>
      )}
    </div>
  )
}
