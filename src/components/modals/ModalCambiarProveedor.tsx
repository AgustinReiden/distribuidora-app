/**
 * ModalCambiarProveedor
 *
 * Corrige el proveedor de una compra cargada al proveedor equivocado. En vez de
 * reescribir la fila, dispara el RPC cambiar_proveedor_compra (mig 125) que
 * ANULA la compra vieja y crea una NUEVA idéntica (mismos items, importes,
 * fecha, factura, tipo, forma de pago) con el proveedor nuevo. El stock y los
 * costos NO se modifican.
 *
 * Análogo a ModalCambiarCliente (pedidos) pero mucho más simple: en compras los
 * costos vienen de la factura, no de un motor de precios, así que no hay
 * recálculo de promos/mayorista/descuento.
 */
import { useState, memo, lazy, Suspense } from 'react'
import { Loader2, Building2, Plus, AlertTriangle, ArrowRight } from 'lucide-react'
import ModalBase from './ModalBase'
import { formatPrecio } from '../../utils/formatters'
import type {
  CompraDBExtended,
  ProveedorDBExtended,
  ProveedorFormInputExtended,
  CompraItemDBExtended,
} from '../../types'

const ModalProveedor = lazy(() => import('./ModalProveedor'))

export type CambiarProveedorPayload = {
  nuevoProveedorId: string | null
  nuevoProveedorNombre: string | null
  motivo?: string
}

export interface ModalCambiarProveedorProps {
  compra: CompraDBExtended
  proveedores: ProveedorDBExtended[]
  onConfirmar: (payload: CambiarProveedorPayload) => Promise<void>
  onClose: () => void
  guardando: boolean
  onCrearProveedor?: (data: ProveedorFormInputExtended) => Promise<ProveedorDBExtended>
}

const ModalCambiarProveedor = memo(function ModalCambiarProveedor({
  compra,
  proveedores,
  onConfirmar,
  onClose,
  guardando,
  onCrearProveedor,
}: ModalCambiarProveedorProps) {
  const [nuevoProveedorId, setNuevoProveedorId] = useState<string>('')
  const [modalProveedorOpen, setModalProveedorOpen] = useState(false)

  const proveedorActualId = compra.proveedor_id != null ? String(compra.proveedor_id) : ''
  const proveedorActualNombre = compra.proveedor?.nombre ?? compra.proveedor_nombre ?? 'Sin proveedor'
  const proveedorNuevo = proveedores.find((p) => String(p.id) === nuevoProveedorId)

  const totalItems = (compra.items ?? []).reduce((s: number, i: CompraItemDBExtended) => s + (i.cantidad ?? 0), 0)
  const nItems = (compra.items ?? []).length

  // El nuevo no puede ser el mismo que el actual.
  const mismoProveedor = nuevoProveedorId !== '' && nuevoProveedorId === proveedorActualId
  const puedeConfirmar = nuevoProveedorId !== '' && !mismoProveedor && !guardando

  async function handleConfirmar() {
    if (!puedeConfirmar) return
    await onConfirmar({
      nuevoProveedorId: nuevoProveedorId || null,
      nuevoProveedorNombre: null,
      motivo: 'Cambio de proveedor',
    })
  }

  return (
    <ModalBase title={`Cambiar proveedor · Compra #${compra.id}`} onClose={onClose} maxWidth="max-w-lg">
      <div className="p-4 space-y-4">
        {/* Proveedor actual -> nuevo */}
        <div className="flex items-center gap-3">
          <div className="flex-1 min-w-0">
            <p className="text-xs text-gray-500 dark:text-gray-400">Proveedor actual</p>
            <p className="font-medium dark:text-gray-200 truncate">{proveedorActualNombre}</p>
          </div>
          <ArrowRight className="w-5 h-5 text-gray-400 shrink-0" />
          <div className="flex-1 min-w-0">
            <p className="text-xs text-gray-500 dark:text-gray-400">Proveedor nuevo</p>
            <p className="font-medium text-green-700 dark:text-green-400 truncate">{proveedorNuevo?.nombre ?? '—'}</p>
          </div>
        </div>

        {/* Selector de proveedor */}
        <div>
          <label className="text-sm font-medium text-gray-700 dark:text-gray-300 mb-1 flex items-center gap-2">
            <Building2 className="w-4 h-4 text-gray-500" /> Elegí el proveedor correcto
          </label>
          <div className="flex items-center gap-2">
            <select
              value={nuevoProveedorId}
              onChange={(e) => setNuevoProveedorId(e.target.value)}
              className="flex-1 px-3 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
            >
              <option value="">Seleccionar proveedor...</option>
              {proveedores.map((p) => (
                <option key={p.id} value={p.id} disabled={String(p.id) === proveedorActualId}>
                  {p.nombre} {p.cuit ? `(${p.cuit})` : ''}
                  {String(p.id) === proveedorActualId ? ' — actual' : ''}
                </option>
              ))}
            </select>
            {onCrearProveedor && (
              <button
                type="button"
                onClick={() => setModalProveedorOpen(true)}
                className="flex items-center gap-1 px-3 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 transition-colors whitespace-nowrap text-sm"
                title="Crear proveedor nuevo"
              >
                <Plus className="w-4 h-4" />
                <span className="hidden sm:inline">Nuevo</span>
              </button>
            )}
          </div>
          {mismoProveedor && (
            <p className="text-xs text-amber-600 dark:text-amber-400 mt-1">Es el mismo proveedor actual.</p>
          )}
        </div>

        {/* Resumen read-only de la compra (no cambia) */}
        <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-3 text-sm">
          <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">Estos datos NO cambian:</p>
          <div className="grid grid-cols-2 gap-x-4 gap-y-1">
            <span className="text-gray-500 dark:text-gray-400">Factura</span>
            <span className="text-right dark:text-gray-200">
              {compra.numero_factura ?? '—'} ({compra.tipo_factura ?? 'FC'})
            </span>
            <span className="text-gray-500 dark:text-gray-400">Fecha</span>
            <span className="text-right dark:text-gray-200">{compra.fecha_compra ?? '—'}</span>
            <span className="text-gray-500 dark:text-gray-400">Items</span>
            <span className="text-right dark:text-gray-200">
              {nItems} ({totalItems} u.)
            </span>
            <span className="text-gray-500 dark:text-gray-400">Total</span>
            <span className="text-right font-semibold text-green-600 dark:text-green-400">
              {formatPrecio(compra.total)}
            </span>
          </div>
        </div>

        {/* Advertencia */}
        <div className="bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg p-3 text-xs text-amber-800 dark:text-amber-300 flex items-start gap-2">
          <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
          <span>
            Se anulará la compra #{compra.id} y se creará una nueva idéntica con el proveedor nuevo. El stock y los
            costos no se modifican.
          </span>
        </div>

        {/* Acciones */}
        <div className="flex justify-end gap-2 pt-2 border-t dark:border-gray-700">
          <button
            type="button"
            onClick={onClose}
            disabled={guardando}
            className="px-4 py-2 text-sm rounded-lg border dark:border-gray-600 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700 disabled:opacity-50"
          >
            Cancelar
          </button>
          <button
            type="button"
            onClick={handleConfirmar}
            disabled={!puedeConfirmar}
            className="px-4 py-2 text-sm rounded-lg bg-green-600 text-white hover:bg-green-700 disabled:bg-green-400 disabled:cursor-not-allowed inline-flex items-center gap-2"
          >
            {guardando ? <Loader2 className="w-4 h-4 animate-spin" /> : null}
            Cambiar proveedor
          </button>
        </div>
      </div>

      {/* Modal Proveedor anidado (crear uno nuevo y auto-seleccionarlo) */}
      {modalProveedorOpen && onCrearProveedor && (
        <Suspense fallback={null}>
          <ModalProveedor
            onSave={async (data) => {
              const nuevoProveedor = await onCrearProveedor({
                nombre: data.nombre,
                cuit: data.cuit || null,
                direccion: data.direccion || null,
                latitud: data.latitud || null,
                longitud: data.longitud || null,
                telefono: data.telefono || null,
                email: data.email || null,
                contacto: data.contacto || null,
                notas: data.notas || null,
                activo: true,
              })
              setNuevoProveedorId(String(nuevoProveedor.id))
              setModalProveedorOpen(false)
            }}
            onClose={() => setModalProveedorOpen(false)}
          />
        </Suspense>
      )}
    </ModalBase>
  )
})

export default ModalCambiarProveedor
