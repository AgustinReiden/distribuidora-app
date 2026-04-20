/**
 * ModalPromocion
 *
 * Modal para crear/editar una promocion de bonificacion.
 * Incluye: nombre, fechas, selector de productos, reglas (cantidad_compra, cantidad_bonificacion).
 */
import { useState, useMemo } from 'react'
import { X, Search, Gift } from 'lucide-react'
import { fechaLocalISO } from '../../utils/formatters'
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
  const [fechaInicio, setFechaInicio] = useState(promocion?.fecha_inicio || fechaLocalISO())
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
  const [productoRegaloId, setProductoRegaloId] = useState<string>(
    promocion?.producto_regalo_id ? String(promocion.producto_regalo_id) : ''
  )
  const [limiteUsos, setLimiteUsos] = useState<string>(
    promocion?.limite_usos ? String(promocion.limite_usos) : ''
  )
  const [prioridad, setPrioridad] = useState<string>(
    promocion?.prioridad != null ? String(promocion.prioridad) : '0'
  )
  const [regaloMueveStock, setRegaloMueveStock] = useState<boolean>(
    promocion?.regalo_mueve_stock ?? false
  )
  const [busqueda, setBusqueda] = useState('')
  const [busquedaRegalo, setBusquedaRegalo] = useState('')
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

  const productosRegaloFiltrados = useMemo(() => {
    if (!busquedaRegalo.trim()) return productos
    const q = busquedaRegalo.toLowerCase()
    return productos.filter(p =>
      p.nombre.toLowerCase().includes(q) ||
      p.codigo?.toLowerCase().includes(q)
    )
  }, [productos, busquedaRegalo])

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
    const limite = limiteUsos ? parseInt(limiteUsos) : null
    const prio = parseInt(prioridad)
    const result = await onSave({
      nombre: nombre.trim(),
      tipo: 'bonificacion',
      fechaInicio,
      fechaFin: fechaFin || null,
      limiteUsos: limite && limite > 0 ? limite : null,
      productoIds: Array.from(productoIds),
      productoRegaloId: productoRegaloId || null,
      reglas: [
        { clave: 'cantidad_compra', valor: compra },
        { clave: 'cantidad_bonificacion', valor: bonif },
      ],
      prioridad: Number.isFinite(prio) ? prio : 0,
      regaloMueveStock,
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

          {/* Limite de usos (hasta agotar stock) */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Limite de usos (opcional)
            </label>
            <input
              type="number"
              min="1"
              value={limiteUsos}
              onChange={e => setLimiteUsos(e.target.value)}
              placeholder="Sin limite"
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm"
            />
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              Se desactiva automaticamente al alcanzar este numero de bonificaciones entregadas. Dejar vacio para sin limite.
            </p>
          </div>

          {/* Prioridad (para exclusion entre promos) */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Prioridad
            </label>
            <input
              type="number"
              value={prioridad}
              onChange={e => setPrioridad(e.target.value)}
              placeholder="0"
              className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-purple-500 focus:outline-none text-sm"
            />
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              Si dos promos aplican al mismo pedido, gana la de mayor prioridad. Dejar 0 si no hay conflictos.
            </p>
          </div>

          {/* Mueve stock (toggle) */}
          <div className="flex items-start gap-2 p-3 bg-amber-50 dark:bg-amber-900/20 rounded-lg border border-amber-200 dark:border-amber-800">
            <input
              id="regalo-mueve-stock"
              type="checkbox"
              checked={regaloMueveStock}
              onChange={e => setRegaloMueveStock(e.target.checked)}
              className="mt-1 rounded border-gray-300 text-amber-600 focus:ring-amber-500"
            />
            <div className="flex-1">
              <label htmlFor="regalo-mueve-stock" className="block text-sm font-medium text-amber-800 dark:text-amber-200 cursor-pointer">
                El regalo descuenta stock automaticamente
              </label>
              <p className="text-xs text-amber-700 dark:text-amber-300 mt-1">
                Apagalo cuando el regalo es una unidad menor al stock (ej: regalar una botella cuando el stock se lleva por fardo). Vas a ajustar manualmente desde "Ajustar stock" cuando se acumulen suficientes unidades.
              </p>
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

          {/* Producto regalo */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Producto de regalo
            </label>
            <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
              El producto que se entrega gratis al cumplir la condicion
            </p>
            {productoRegaloId && (
              <div className="flex items-center gap-2 mb-2 px-3 py-2 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg">
                <Gift className="w-4 h-4 text-green-600 flex-shrink-0" />
                <span className="text-sm text-green-700 dark:text-green-300 font-medium flex-1">
                  {productos.find(p => String(p.id) === productoRegaloId)?.nombre || `Producto #${productoRegaloId}`}
                </span>
                <button
                  onClick={() => setProductoRegaloId('')}
                  className="text-green-600 hover:text-green-800 text-xs underline"
                >
                  Quitar
                </button>
              </div>
            )}
            <div className="relative mb-2">
              <Search className="absolute left-3 top-2.5 w-4 h-4 text-gray-400" />
              <input
                type="text"
                value={busquedaRegalo}
                onChange={e => setBusquedaRegalo(e.target.value)}
                placeholder="Buscar producto de regalo..."
                className="w-full pl-9 pr-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-green-500 focus:outline-none text-sm"
              />
            </div>
            {busquedaRegalo.trim() && (
              <div className="max-h-32 overflow-y-auto border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700">
                {productosRegaloFiltrados.map(prod => (
                  <button
                    key={prod.id}
                    onClick={() => { setProductoRegaloId(String(prod.id)); setBusquedaRegalo('') }}
                    className={`w-full text-left flex items-center gap-2 px-3 py-2 hover:bg-green-50 dark:hover:bg-green-900/20 text-sm ${
                      String(prod.id) === productoRegaloId ? 'bg-green-50 dark:bg-green-900/20' : ''
                    }`}
                  >
                    <Gift className="w-3.5 h-3.5 text-green-500 flex-shrink-0" />
                    <span className="dark:text-white truncate">{prod.nombre}</span>
                  </button>
                ))}
                {productosRegaloFiltrados.length === 0 && (
                  <p className="text-sm text-gray-400 px-3 py-4 text-center">Sin resultados</p>
                )}
              </div>
            )}
          </div>

          {/* Selector de productos (que activan la promo) */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Productos que activan la promo ({productoIds.size} seleccionados)
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
