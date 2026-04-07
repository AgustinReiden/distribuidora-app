/**
 * ModalPromocion
 *
 * Modal para crear/editar una promocion de bonificacion.
 * Incluye: nombre, fechas, selector de productos, reglas (cantidad_compra, cantidad_bonificacion).
 */
import { useState, useMemo } from 'react'
import { X, Search } from 'lucide-react'
import type { ProductoDB } from '../../types'
import type { PromocionConDetalles, PromocionFormInput } from '../../hooks/queries/usePromocionesQuery'

export interface ModalPromocionProps {
  promocion: PromocionConDetalles | null
  productos: ProductoDB[]
  onSave: (data: PromocionFormInput) => Promise<{ success: boolean; error?: string }>
  onClose: () => void
}

export default function ModalPromocion({
  promocion,
  productos,
  onSave,
  onClose,
}: ModalPromocionProps) {
  const isEditing = !!promocion

  const [nombre, setNombre] = useState(promocion?.nombre || '')
  const [fechaInicio, setFechaInicio] = useState(promocion?.fecha_inicio || new Date().toISOString().split('T')[0])
  const [fechaFin, setFechaFin] = useState(promocion?.fecha_fin || '')
  const [productoIds, setProductoIds] = useState<Set<string>>(
    new Set(promocion?.productos.map(p => String(p.producto_id)) || [])
  )
  const [cantidadCompra, setCantidadCompra] = useState(
    () => {
      const regla = promocion?.reglas.find(r => r.clave === 'cantidad_compra')
      return regla ? String(Number(regla.valor)) : ''
    }
  )
  const [cantidadBonificacion, setCantidadBonificacion] = useState(
    () => {
      const regla = promocion?.reglas.find(r => r.clave === 'cantidad_bonificacion')
      return regla ? String(Number(regla.valor)) : ''
    }
  )
  const [busqueda, setBusqueda] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  const productosFiltrados = useMemo(() => {
    if (!busqueda.trim()) return productos
    const q = busqueda.toLowerCase()
    return productos.filter(p =>
      p.nombre.toLowerCase().includes(q) ||
      p.codigo?.toLowerCase().includes(q)
    )
  }, [productos, busqueda])

  const handleToggleProducto = (id: string) => {
    setProductoIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const handleSubmit = async () => {
    setError(null)

    if (!nombre.trim()) {
      setError('Ingresa un nombre para la promocion')
      return
    }
    if (!fechaInicio) {
      setError('Selecciona una fecha de inicio')
      return
    }
    if (productoIds.size === 0) {
      setError('Selecciona al menos un producto')
      return
    }
    const compra = parseInt(cantidadCompra)
    const bonif = parseInt(cantidadBonificacion)
    if (!compra || compra <= 0) {
      setError('Ingresa la cantidad de compra (mayor a 0)')
      return
    }
    if (!bonif || bonif <= 0) {
      setError('Ingresa la cantidad de bonificacion (mayor a 0)')
      return
    }

    setSaving(true)
    const result = await onSave({
      nombre: nombre.trim(),
      tipo: 'bonificacion',
      fechaInicio,
      fechaFin: fechaFin || null,
      productoIds: Array.from(productoIds),
      reglas: [
        { clave: 'cantidad_compra', valor: compra },
        { clave: 'cantidad_bonificacion', valor: bonif },
      ],
    })
    setSaving(false)

    if (!result.success && result.error) {
      setError(result.error)
    }
  }

  return (
    <div className="fixed inset-0 bg-black/50 z-50 flex items-center justify-center p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-lg max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-5 py-4 border-b dark:border-gray-700">
          <h2 className="text-lg font-semibold dark:text-white">
            {isEditing ? 'Editar Promocion' : 'Nueva Promocion'}
          </h2>
          <button onClick={onClose} className="p-1 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-5 h-5 text-gray-500" />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto px-5 py-4 space-y-4">
          {/* Nombre */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Nombre</label>
            <input
              type="text"
              value={nombre}
              onChange={e => setNombre(e.target.value)}
              placeholder="Ej: Promo Manaos 12+2"
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none"
            />
          </div>

          {/* Fechas */}
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Fecha inicio</label>
              <input
                type="date"
                value={fechaInicio}
                onChange={e => setFechaInicio(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">Fecha fin (opcional)</label>
              <input
                type="date"
                value={fechaFin}
                onChange={e => setFechaFin(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none"
              />
            </div>
          </div>

          {/* Reglas de bonificacion */}
          <div className="p-3 bg-purple-50 dark:bg-purple-900/20 rounded-lg border border-purple-200 dark:border-purple-800">
            <p className="text-sm font-medium text-purple-700 dark:text-purple-300 mb-2">Regla de bonificacion</p>
            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="block text-xs text-purple-600 dark:text-purple-400 mb-1">Cantidad compra</label>
                <input
                  type="number"
                  min="1"
                  value={cantidadCompra}
                  onChange={e => setCantidadCompra(e.target.value)}
                  placeholder="Ej: 12"
                  className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm"
                />
              </div>
              <div>
                <label className="block text-xs text-purple-600 dark:text-purple-400 mb-1">Cantidad gratis</label>
                <input
                  type="number"
                  min="1"
                  value={cantidadBonificacion}
                  onChange={e => setCantidadBonificacion(e.target.value)}
                  placeholder="Ej: 2"
                  className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm"
                />
              </div>
            </div>
            {cantidadCompra && cantidadBonificacion && parseInt(cantidadCompra) > 0 && parseInt(cantidadBonificacion) > 0 && (
              <p className="text-xs text-purple-600 mt-2">
                Cada {cantidadCompra} unidades compradas → {cantidadBonificacion} gratis (acumulable)
              </p>
            )}
          </div>

          {/* Selector de productos */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Productos ({productoIds.size} seleccionados)
            </label>
            <div className="relative mb-2">
              <Search className="absolute left-3 top-2.5 w-4 h-4 text-gray-400" />
              <input
                type="text"
                value={busqueda}
                onChange={e => setBusqueda(e.target.value)}
                placeholder="Buscar producto..."
                className="w-full pl-9 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm"
              />
            </div>
            <div className="max-h-48 overflow-y-auto border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700">
              {productosFiltrados.map(prod => {
                const selected = productoIds.has(String(prod.id))
                return (
                  <label
                    key={prod.id}
                    className={`flex items-center gap-2 px-3 py-2 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700 ${
                      selected ? 'bg-purple-50 dark:bg-purple-900/20' : ''
                    }`}
                  >
                    <input
                      type="checkbox"
                      checked={selected}
                      onChange={() => handleToggleProducto(String(prod.id))}
                      className="rounded border-gray-300 text-purple-600 focus:ring-purple-500"
                    />
                    <span className="text-sm dark:text-white truncate">{prod.nombre}</span>
                    {prod.codigo && (
                      <span className="text-xs text-gray-400 ml-auto shrink-0">{prod.codigo}</span>
                    )}
                  </label>
                )
              })}
              {productosFiltrados.length === 0 && (
                <p className="text-sm text-gray-400 px-3 py-4 text-center">Sin resultados</p>
              )}
            </div>
          </div>

          {error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 text-red-600 dark:text-red-400 text-sm rounded-lg">
              {error}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="flex justify-end gap-2 px-5 py-4 border-t dark:border-gray-700">
          <button
            onClick={onClose}
            className="px-4 py-2 text-sm text-gray-600 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg"
          >
            Cancelar
          </button>
          <button
            onClick={handleSubmit}
            disabled={saving}
            className="px-4 py-2 text-sm bg-purple-600 text-white rounded-lg hover:bg-purple-700 disabled:opacity-50 disabled:cursor-not-allowed"
          >
            {saving ? 'Guardando...' : isEditing ? 'Actualizar' : 'Crear Promocion'}
          </button>
        </div>
      </div>
    </div>
  )
}
