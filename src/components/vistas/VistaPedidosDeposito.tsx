/**
 * /pedidos para depósito (#782): lo que hay que preparar, sin plata.
 *
 * Una tarjeta por hoja de ruta armada (un camión, un día) con el total a cargar
 * agrupado por rubro —la misma cuenta que el Manifiesto de Carga en PDF— y las
 * paradas en orden con sus productos. Abajo, los pedidos que todavía no están
 * en ninguna ruta.
 *
 * Sólo lectura: depósito no mueve estados (decisión del dueño, #726), y
 * permisos.ts no deja mostrar un botón que el servidor rechaza. Los únicos
 * botones mueven la fecha o bajan el manifiesto, que se arma en el navegador.
 */
import { memo, useMemo, type ReactElement } from 'react'
import { ChevronLeft, ChevronRight, ClipboardList, Download, MapPin, Package, StickyNote, Truck } from 'lucide-react'
import Card from '../ui/Card'
import { Badge } from '../ui/Badge'
import { Button } from '../ui/Button'
import CargandoContenido from '../ui/CargandoContenido'
import { Skeleton } from '../ui/Skeleton'
import { ErrorState } from '../ui/EmptyState'
import { toneDeEstadoPedido } from '../../lib/estadoTones'
import { formatFecha, getEstadoLabel } from '../../utils/formatters'
import { lineaItemImpresion } from '../../lib/pdf/utils/lineaItem'
import { consolidarCarga } from '../../utils/manifiestoCarga'
import {
  pedidosACargar,
  sumarDias,
  type HojasDeRutaDeposito,
  type PedidoDeposito,
  type RutaDeposito,
} from '../../utils/hojasDeRutaDeposito'

export interface VistaPedidosDepositoProps {
  datos: HojasDeRutaDeposito | undefined
  cargando: boolean
  error: Error | null
  /** null = volver a la próxima ruta armada (la elige el servidor). */
  onCambiarFecha: (fecha: string | null) => void
  onDescargarManifiesto: (ruta: RutaDeposito, pedidos: PedidoDeposito[]) => void
  onReintentar: () => void
}

function nombreCliente(p: PedidoDeposito): string {
  return p.cliente?.nombre_fantasia || p.cliente?.razon_social || `Pedido #${p.id}`
}

const ParadaDeposito = memo(function ParadaDeposito({ pedido, orden }: { pedido: PedidoDeposito; orden?: number | null }): ReactElement {
  const cambio = pedido.cambio
  return (
    <li className="py-3 first:pt-0 last:pb-0">
      <div className="flex items-start justify-between gap-3">
        <h4 className="font-medium text-gray-900 dark:text-white">
          {orden != null && <span className="text-gray-500 dark:text-gray-400 mr-1.5">{orden}.</span>}
          {nombreCliente(pedido)}
          <span className="sr-only"> · pedido {pedido.id}</span>
        </h4>
        <Badge tone={toneDeEstadoPedido(pedido.estado)}>{getEstadoLabel(pedido.estado)}</Badge>
      </div>
      {pedido.cliente?.direccion && (
        <p className="mt-0.5 flex items-center gap-1 text-sm text-gray-600 dark:text-gray-300">
          <MapPin className="w-3.5 h-3.5 shrink-0" aria-hidden="true" />
          <span>{pedido.cliente.direccion}</span>
          {pedido.cliente.aclaracion_direccion && (
            <span className="text-gray-500 dark:text-gray-400">({pedido.cliente.aclaracion_direccion})</span>
          )}
        </p>
      )}
      {pedido.fecha_entrega_programada && (
        <p className="mt-0.5 text-sm text-gray-600 dark:text-gray-300">
          Entrega programada: {formatFecha(pedido.fecha_entrega_programada)}
        </p>
      )}
      {pedido.notas && (
        <p className="mt-1 flex items-start gap-1 text-sm text-amber-800 dark:text-amber-300">
          <StickyNote className="w-3.5 h-3.5 mt-0.5 shrink-0" aria-hidden="true" />
          <span>{pedido.notas}</span>
        </p>
      )}
      {pedido.items.length > 0 && (
        <ul className="mt-2 space-y-0.5 text-sm text-gray-800 dark:text-gray-200" aria-label={`Productos de ${nombreCliente(pedido)}`}>
          {pedido.items.map((it) => (
            <li key={it.id}>{lineaItemImpresion(it)}</li>
          ))}
        </ul>
      )}
      {cambio && (
        <div className="mt-2 text-sm text-gray-700 dark:text-gray-300">
          {cambio.cantidad_entregada != null && cambio.cantidad_entregada > 0 && (
            <p>Entregar: {cambio.cantidad_entregada}x {cambio.producto_entregado_nombre || 'Producto'}</p>
          )}
          {cambio.cantidad_devuelta != null && cambio.cantidad_devuelta > 0 && (
            <p>Retirar: {cambio.cantidad_devuelta}x {cambio.producto_devuelto_nombre || 'Producto'}</p>
          )}
        </div>
      )}
    </li>
  )
})

function CargaRuta({ ruta, subrubros }: { ruta: RutaDeposito; subrubros: Record<string, string> }): ReactElement {
  const grupos = useMemo(
    () => consolidarCarga(pedidosACargar(ruta), { nombresSubrubro: subrubros }),
    [ruta, subrubros],
  )
  if (grupos.length === 0) {
    return <p className="text-sm text-gray-500 dark:text-gray-400">No hay productos para cargar.</p>
  }
  const linea = (l: { cantidad: number; texto: string }, i: number) => (
    <li key={i} className="flex gap-2 text-sm">
      <span className="w-12 shrink-0 text-right font-semibold tabular-nums text-gray-900 dark:text-white">{l.cantidad}x</span>
      <span className="text-gray-800 dark:text-gray-200">{l.texto}</span>
    </li>
  )
  return (
    <ul className="space-y-3" aria-label={`Para cargar en el camión de ${ruta.transportista.nombre}`}>
      {grupos.map(({ grupo, ventas, bonificados, cambios }) => (
        <li key={`${grupo.rubro}|${grupo.subrubro ?? ''}`}>
          <p className="text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
            {grupo.rubro}{grupo.subrubro ? ` · ${grupo.subrubro}` : ''}
          </p>
          <ul className="mt-1 space-y-0.5">{ventas.map(linea)}</ul>
          {bonificados.length > 0 && (
            <>
              <p className="mt-1.5 text-xs font-medium text-gray-600 dark:text-gray-300">Bonificados (cargar aparte)</p>
              <ul className="space-y-0.5">{bonificados.map(linea)}</ul>
            </>
          )}
          {cambios.length > 0 && (
            <>
              <p className="mt-1.5 text-xs font-medium text-gray-600 dark:text-gray-300">Cambios (cargar aparte)</p>
              <ul className="space-y-0.5">{cambios.map(linea)}</ul>
            </>
          )}
        </li>
      ))}
    </ul>
  )
}

function TarjetaRuta({ ruta, subrubros, onDescargarManifiesto }: {
  ruta: RutaDeposito
  subrubros: Record<string, string>
  onDescargarManifiesto: VistaPedidosDepositoProps['onDescargarManifiesto']
}): ReactElement {
  const titulo = `Camión de ${ruta.transportista.nombre}`
  const idTitulo = `ruta-${ruta.recorridoId}`
  return (
    <Card as="section" aria-labelledby={idTitulo} className="space-y-4">
      <header className="flex flex-wrap items-center justify-between gap-2">
        <h2 id={idTitulo} className="flex items-center gap-2 text-lg font-semibold text-gray-900 dark:text-white">
          <Truck className="w-5 h-5 text-brand-600" aria-hidden="true" />
          {titulo}
          <span className="text-sm font-normal text-gray-500 dark:text-gray-400">
            · {ruta.paradas.length} {ruta.paradas.length === 1 ? 'parada' : 'paradas'}
          </span>
        </h2>
        <Button
          variant="secondary"
          size="sm"
          onClick={() => onDescargarManifiesto(ruta, pedidosACargar(ruta))}
          aria-label={`Descargar el manifiesto de carga del camión de ${ruta.transportista.nombre}`}
        >
          <Download className="w-4 h-4" aria-hidden="true" />
          Manifiesto
        </Button>
      </header>

      <div className="grid gap-4 lg:grid-cols-2">
        <div>
          <h3 className="mb-2 flex items-center gap-1.5 text-sm font-semibold text-gray-700 dark:text-gray-200">
            <Package className="w-4 h-4" aria-hidden="true" /> Para cargar
          </h3>
          <CargaRuta ruta={ruta} subrubros={subrubros} />
        </div>
        <div>
          <h3 className="mb-2 flex items-center gap-1.5 text-sm font-semibold text-gray-700 dark:text-gray-200">
            <MapPin className="w-4 h-4" aria-hidden="true" /> Paradas
          </h3>
          {ruta.paradas.length === 0 ? (
            <p className="text-sm text-gray-500 dark:text-gray-400">La ruta no tiene paradas.</p>
          ) : (
            <ol className="divide-y divide-gray-100 dark:divide-gray-700" aria-label={`Paradas de ${ruta.transportista.nombre}`}>
              {ruta.paradas.map((p) => <ParadaDeposito key={p.id} pedido={p} orden={p.orden_entrega} />)}
            </ol>
          )}
        </div>
      </div>
    </Card>
  )
}

export default function VistaPedidosDeposito({
  datos,
  cargando,
  error,
  onCambiarFecha,
  onDescargarManifiesto,
  onReintentar,
}: VistaPedidosDepositoProps): ReactElement {
  const fecha = datos?.fecha ?? null

  return (
    <div className="space-y-4">
      <header className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold flex items-center gap-2 dark:text-white">
            <ClipboardList className="w-5 h-5 text-brand-600" aria-hidden="true" />
            Hojas de ruta
          </h1>
          <p className="text-sm text-gray-600 dark:text-gray-300">Lo que hay que preparar para cada camión.</p>
        </div>
        {fecha && (
          <div className="flex items-center gap-1.5">
            <Button variant="ghost" size="sm" aria-label="Día anterior" onClick={() => onCambiarFecha(sumarDias(fecha, -1))}>
              <ChevronLeft className="w-4 h-4" aria-hidden="true" />
            </Button>
            <label className="sr-only" htmlFor="fecha-hoja-ruta">Fecha de la hoja de ruta</label>
            <input
              id="fecha-hoja-ruta"
              type="date"
              value={fecha}
              onChange={(e) => { if (e.target.value) onCambiarFecha(e.target.value) }}
              className="h-8 rounded-lg border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-800 px-2 text-sm dark:text-white"
            />
            <Button variant="ghost" size="sm" aria-label="Día siguiente" onClick={() => onCambiarFecha(sumarDias(fecha, 1))}>
              <ChevronRight className="w-4 h-4" aria-hidden="true" />
            </Button>
            <Button variant="secondary" size="sm" onClick={() => onCambiarFecha(null)}>
              Próxima ruta
            </Button>
          </div>
        )}
      </header>

      {error && !datos ? (
        <ErrorState
          title="No se pudieron cargar las hojas de ruta"
          description={error.message}
          action={<Button variant="secondary" onClick={onReintentar}>Reintentar</Button>}
        />
      ) : cargando && !datos ? (
        <CargandoContenido texto="Cargando hojas de ruta...">
          <Skeleton className="h-64 w-full rounded-xl" />
        </CargandoContenido>
      ) : datos ? (
        <>
          {datos.rutas.length === 0 ? (
            <Card>
              <p className="text-sm text-gray-600 dark:text-gray-300">
                No hay hojas de ruta armadas para el {formatFecha(fecha)}.
              </p>
            </Card>
          ) : (
            datos.rutas.map((ruta) => (
              <TarjetaRuta
                key={ruta.recorridoId}
                ruta={ruta}
                subrubros={datos.subrubros}
                onDescargarManifiesto={onDescargarManifiesto}
              />
            ))
          )}

          <Card as="section" aria-labelledby="sin-ruta-titulo">
            <h2 id="sin-ruta-titulo" className="mb-2 text-lg font-semibold text-gray-900 dark:text-white">
              Todavía sin ruta
              <span className="ml-1.5 text-sm font-normal text-gray-500 dark:text-gray-400">· {datos.sinRuta.length}</span>
            </h2>
            {datos.sinRuta.length === 0 ? (
              <p className="text-sm text-gray-500 dark:text-gray-400">No hay pedidos pendientes fuera de una ruta.</p>
            ) : (
              <ul className="divide-y divide-gray-100 dark:divide-gray-700" aria-label="Pedidos sin ruta">
                {datos.sinRuta.map((p) => <ParadaDeposito key={p.id} pedido={p} />)}
              </ul>
            )}
          </Card>
        </>
      ) : null}
    </div>
  )
}
