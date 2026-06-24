/**
 * ModalDetalleMovimiento — detalle de un movimiento entre sucursales.
 *
 * Lo pueden ver AMBOS lados (origen y destino) en cualquier estado
 * (pendiente/aceptado/denegado). Muestra el encabezado (origen → destino,
 * estado, fecha, creador, notas, motivo de rechazo) y la lista de productos
 * con cantidades. En los aceptados indica cómo se resolvió cada item
 * (matcheado a un producto del destino o creado nuevo).
 */
import { memo, useMemo } from 'react'
import { Loader2, ArrowRight, Check, PlusCircle } from 'lucide-react'
import ModalBase from './ModalBase'
import { formatPrecio, formatDateTime } from '../../utils/formatters'
import type { ProductoDB } from '../../types'
import type { MovimientoSucursalDB, MovimientoItemDB, EstadoMovimiento } from '../../hooks/queries'

const ESTADO_BADGE: Record<EstadoMovimiento, string> = {
  pendiente: 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-400',
  aceptada: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-400',
  denegada: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-400',
}

export interface ModalDetalleMovimientoProps {
  movimiento: MovimientoSucursalDB
  items: MovimientoItemDB[]
  loadingItems: boolean
  /** Productos de la sucursal activa, para resolver el nombre del destino. */
  productos?: ProductoDB[]
  onClose: () => void
}

const ModalDetalleMovimiento = memo(function ModalDetalleMovimiento({
  movimiento, items, loadingItems, productos = [], onClose,
}: ModalDetalleMovimientoProps) {
  const productosPorId = useMemo(() => {
    const m = new Map<string, ProductoDB>()
    for (const p of productos) m.set(String(p.id), p)
    return m
  }, [productos])

  const totalUnidades = items.reduce((s, it) => s + (it.cantidad || 0), 0)

  return (
    <ModalBase
      title={`Movimiento #${movimiento.id}`}
      onClose={onClose}
      maxWidth="max-w-2xl"
    >
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        {/* Encabezado: origen → destino + estado */}
        <div className="flex items-center justify-between gap-3 flex-wrap">
          <div className="flex items-center gap-2 text-sm font-medium text-gray-900 dark:text-white">
            <span>{movimiento.origen?.nombre || 'Origen'}</span>
            <ArrowRight className="w-4 h-4 text-gray-400" />
            <span>{movimiento.destino?.nombre || 'Destino'}</span>
          </div>
          <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${ESTADO_BADGE[movimiento.estado]}`}>
            {movimiento.estado}
          </span>
        </div>

        <div className="text-xs text-gray-500 space-y-0.5">
          {movimiento.created_at && <p>Creado: {formatDateTime(movimiento.created_at)}{movimiento.creador?.nombre ? ` · ${movimiento.creador.nombre}` : ''}</p>}
          {movimiento.resuelto_at && <p>Resuelto: {formatDateTime(movimiento.resuelto_at)}</p>}
          {movimiento.notas && <p className="italic text-gray-600 dark:text-gray-400">Nota: {movimiento.notas}</p>}
          {movimiento.estado === 'denegada' && movimiento.motivo_rechazo && (
            <p className="text-red-500">Motivo del rechazo: {movimiento.motivo_rechazo}</p>
          )}
        </div>

        {/* Items */}
        <div>
          <div className="flex items-center justify-between mb-2">
            <p className="text-xs font-semibold uppercase tracking-wide text-gray-500">
              Productos ({items.length})
            </p>
            <p className="text-xs text-gray-500">{totalUnidades} unidades</p>
          </div>

          {loadingItems ? (
            <div className="flex items-center justify-center py-8 text-gray-500">
              <Loader2 className="w-5 h-5 animate-spin text-blue-600" /><span className="ml-2">Cargando items...</span>
            </div>
          ) : items.length === 0 ? (
            <p className="text-sm text-gray-500 py-4 text-center">Sin items.</p>
          ) : (
            <div className="space-y-2">
              {items.map(it => {
                const destProd = it.producto_destino_id != null
                  ? productosPorId.get(String(it.producto_destino_id))
                  : undefined
                return (
                  <div key={it.id} className="border dark:border-gray-700 rounded-lg p-3">
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0">
                        <p className="font-medium text-gray-900 dark:text-white truncate">{it.origen_nombre}</p>
                        <p className="text-xs text-gray-500">
                          {it.cantidad} u
                          {it.origen_codigo ? ` · cód ${it.origen_codigo}` : ''}
                          {it.origen_costo_con_iva != null ? ` · costo ${formatPrecio(it.origen_costo_con_iva)}` : ''}
                        </p>
                      </div>
                      <span className="text-sm font-semibold text-gray-700 dark:text-gray-300 flex-shrink-0">
                        {it.cantidad} u
                      </span>
                    </div>

                    {/* Resolución (solo en aceptados) */}
                    {it.resolucion === 'match_existente' && (
                      <p className="mt-1.5 text-xs flex items-center gap-1 text-green-700 dark:text-green-400">
                        <Check className="w-3.5 h-3.5" />
                        Matcheado{destProd ? ` a "${destProd.nombre}"` : ' a un producto del destino'}
                      </p>
                    )}
                    {it.resolucion === 'creado_nuevo' && (
                      <p className="mt-1.5 text-xs flex items-center gap-1 text-blue-700 dark:text-blue-400">
                        <PlusCircle className="w-3.5 h-3.5" />
                        Producto creado en el destino
                      </p>
                    )}
                  </div>
                )
              })}
            </div>
          )}
        </div>

        <div className="flex items-center justify-between pt-2 border-t dark:border-gray-700">
          <span className="text-sm text-gray-500">Costo total</span>
          <span className="font-bold text-gray-900 dark:text-white">{formatPrecio(movimiento.total_costo || 0)}</span>
        </div>
      </div>

      <div className="flex justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg">
          Cerrar
        </button>
      </div>
    </ModalBase>
  )
})

export default ModalDetalleMovimiento
