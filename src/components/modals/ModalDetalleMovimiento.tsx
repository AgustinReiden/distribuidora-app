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
import { Loader2, ArrowRight, Check, PlusCircle, PackageMinus } from 'lucide-react'
import ModalBase from './ModalBase'
import { formatPrecio, formatDateTime } from '../../utils/formatters'
import { ESTADO_MOVIMIENTO_BADGE, VERBO_RESOLUCION } from '../../constants/movimientos'
import type { ProductoDB } from '../../types'
import type { MovimientoSucursalDB, MovimientoItemDB } from '../../hooks/queries'

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
          <span className={`px-2 py-0.5 rounded-full text-xs font-medium ${ESTADO_MOVIMIENTO_BADGE[movimiento.estado]}`}>
            {movimiento.estado}
          </span>
        </div>

        {movimiento.estado === 'pendiente' && movimiento.stock_descontado && (
          <div className="flex gap-2 p-3 rounded-lg bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800">
            <PackageMinus className="w-5 h-5 text-amber-600 dark:text-amber-400 shrink-0 mt-0.5" />
            <p className="text-sm text-amber-800 dark:text-amber-200">
              El stock ya salió de {movimiento.origen?.nombre || 'la sucursal origen'}.
              {' '}{movimiento.destino?.nombre || 'La sucursal destino'} todavía no lo ingresó.
            </p>
          </div>
        )}

        <div className="text-xs text-gray-500 space-y-0.5">
          {movimiento.created_at && (
            <p>Creado: {formatDateTime(movimiento.created_at)}{movimiento.creador?.nombre ? ` · por ${movimiento.creador.nombre}` : ''}</p>
          )}
          {movimiento.resuelto_at && (
            <p>
              {VERBO_RESOLUCION[movimiento.estado]}: {formatDateTime(movimiento.resuelto_at)}
              {movimiento.resuelto?.nombre ? ` · por ${movimiento.resuelto.nombre}` : ''}
            </p>
          )}
          {movimiento.editado_at && (
            <p>Editado: {formatDateTime(movimiento.editado_at)}{movimiento.editor?.nombre ? ` · por ${movimiento.editor.nombre}` : ''}</p>
          )}
          {movimiento.notas && <p className="italic text-gray-600 dark:text-gray-400">Nota: {movimiento.notas}</p>}
          {(movimiento.estado === 'denegada' || movimiento.estado === 'cancelada') && movimiento.motivo_rechazo && (
            <p className="text-red-500">
              Motivo de la {movimiento.estado === 'cancelada' ? 'cancelación' : 'denegación'}: {movimiento.motivo_rechazo}
            </p>
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

                    {/* Asiento de stock. El del origen se escribe al crear el
                        envío (mig 139), así que también se ve en los pendientes. */}
                    {(it.stock_origen_anterior != null || it.stock_destino_anterior != null) && (
                      <p className="mt-1 text-xs text-gray-400">
                        {it.stock_origen_anterior != null && (
                          <span>origen {it.stock_origen_anterior} → {it.stock_origen_nuevo}</span>
                        )}
                        {it.stock_origen_anterior != null && it.stock_destino_anterior != null && ' · '}
                        {it.stock_destino_anterior != null && (
                          <span>destino {it.stock_destino_anterior} → {it.stock_destino_nuevo}</span>
                        )}
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
