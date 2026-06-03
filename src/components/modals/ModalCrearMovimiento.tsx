/**
 * ModalCrearMovimiento — la sucursal origen crea una "salida" hacia otra
 * sucursal. Queda pendiente de aprobación; NO mueve stock todavía.
 */
import { memo, useMemo, useState } from 'react'
import { Loader2, Search, Plus, Trash2, Building2 } from 'lucide-react'
import ModalBase from './ModalBase'
import type { ProductoDB, SucursalDB } from '../../types'

interface LineaItem {
  productoId: string
  nombre: string
  cantidad: number
  stock: number
}

export interface ModalCrearMovimientoProps {
  sucursales: SucursalDB[]
  productos: ProductoDB[]
  guardando: boolean
  onClose: () => void
  onConfirmar: (payload: {
    sucursalDestinoId: number
    notas?: string
    items: Array<{ producto_id: number; cantidad: number }>
  }) => Promise<void>
}

const ModalCrearMovimiento = memo(function ModalCrearMovimiento({
  sucursales, productos, guardando, onClose, onConfirmar,
}: ModalCrearMovimientoProps) {
  const [destino, setDestino] = useState<string>('')
  const [notas, setNotas] = useState<string>('')
  const [busqueda, setBusqueda] = useState<string>('')
  const [lineas, setLineas] = useState<LineaItem[]>([])
  const [error, setError] = useState<string>('')

  const resultados = useMemo(() => {
    const term = busqueda.trim().toLowerCase()
    if (!term) return []
    return productos
      .filter(p => p.nombre.toLowerCase().includes(term) || (p.codigo || '').toLowerCase().includes(term))
      .slice(0, 20)
  }, [productos, busqueda])

  const agregar = (p: ProductoDB) => {
    setLineas(prev => prev.some(l => l.productoId === p.id)
      ? prev
      : [...prev, { productoId: p.id, nombre: p.nombre, cantidad: 1, stock: p.stock || 0 }])
    setBusqueda('')
  }

  const setCantidad = (id: string, cant: number) =>
    setLineas(prev => prev.map(l => l.productoId === id ? { ...l, cantidad: cant } : l))

  const quitar = (id: string) => setLineas(prev => prev.filter(l => l.productoId !== id))

  const handleSubmit = async () => {
    setError('')
    if (!destino) { setError('Elegí la sucursal destino.'); return }
    const items = lineas.filter(l => l.cantidad > 0).map(l => ({ producto_id: Number(l.productoId), cantidad: l.cantidad }))
    if (items.length === 0) { setError('Agregá al menos un producto con cantidad.'); return }
    try {
      await onConfirmar({ sucursalDestinoId: Number(destino), notas: notas.trim() || undefined, items })
    } catch (e) {
      setError((e as Error).message || 'Error al crear el movimiento')
    }
  }

  return (
    <ModalBase title="Nueva salida de stock" description="Enviá productos a otra sucursal. Queda pendiente hasta que la sucursal destino lo acepte." onClose={onClose} maxWidth="max-w-xl">
      <div className="p-4 space-y-4 max-h-[70vh] overflow-y-auto">
        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
            <Building2 className="w-4 h-4" /> Sucursal destino
          </label>
          <select
            value={destino}
            onChange={e => setDestino(e.target.value)}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          >
            <option value="">Seleccionar sucursal...</option>
            {sucursales.map(s => <option key={s.id} value={s.id}>{s.nombre}</option>)}
          </select>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Agregar productos</label>
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
            <input
              type="text" value={busqueda} onChange={e => setBusqueda(e.target.value)}
              placeholder="Buscar por nombre o código..."
              className="w-full pl-9 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
          </div>
          {resultados.length > 0 && (
            <div className="mt-1 border rounded-lg divide-y dark:border-gray-600 dark:divide-gray-600 max-h-48 overflow-y-auto">
              {resultados.map(p => (
                <button
                  key={p.id} type="button" onClick={() => agregar(p)}
                  className="w-full flex items-center justify-between px-3 py-2 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-700/50"
                >
                  <span className="truncate dark:text-white">{p.nombre}</span>
                  <span className="text-xs text-gray-400 flex-shrink-0 ml-2">stock {p.stock ?? 0}</span>
                </button>
              ))}
            </div>
          )}
        </div>

        {lineas.length > 0 && (
          <div className="border rounded-lg divide-y dark:border-gray-600 dark:divide-gray-600">
            {lineas.map(l => (
              <div key={l.productoId} className="flex items-center gap-2 px-3 py-2">
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium dark:text-white truncate">{l.nombre}</p>
                  <p className="text-xs text-gray-400">stock disponible: {l.stock}</p>
                </div>
                <input
                  type="number" min="1" inputMode="numeric" value={l.cantidad}
                  onChange={e => setCantidad(l.productoId, Math.max(0, parseInt(e.target.value) || 0))}
                  className="w-20 px-2 py-1 text-sm border rounded dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                />
                <button type="button" onClick={() => quitar(l.productoId)} className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded">
                  <Trash2 className="w-4 h-4" />
                </button>
              </div>
            ))}
          </div>
        )}

        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Notas (opcional)</label>
          <textarea
            value={notas} onChange={e => setNotas(e.target.value)} rows={2}
            className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            placeholder="Observaciones del envío..."
          />
        </div>

        {error && (
          <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg text-sm text-red-600 dark:text-red-400">
            {error}
          </div>
        )}
      </div>

      <div className="flex justify-end gap-2 p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <button onClick={onClose} className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg">
          Cancelar
        </button>
        <button
          onClick={() => { void handleSubmit() }}
          disabled={guardando}
          className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 flex items-center disabled:opacity-50"
        >
          {guardando && <Loader2 className="w-4 h-4 mr-2 animate-spin" />}
          Crear salida
        </button>
      </div>
    </ModalBase>
  )
})

export default ModalCrearMovimiento
