/**
 * ModalTransferencia
 *
 * Modal para crear un nuevo envio de stock a una sucursal.
 * Permite seleccionar sucursal, buscar productos, agregar items y registrar la transferencia.
 */
import React, { useState, useMemo } from 'react'
import { X, Search, Trash2, Plus, ArrowRightLeft } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import type { ProductoDB, SucursalDB, TransferenciaFormInput, TipoTransferencia } from '../../types'

interface ModalTransferenciaProps {
  tipo: TipoTransferencia
  productos: ProductoDB[]
  sucursales: SucursalDB[]
  onSave: (data: TransferenciaFormInput) => Promise<void>
  onCrearSucursal: (data: { nombre: string; direccion?: string }) => Promise<SucursalDB>
  onClose: () => void
}

interface ItemTransferencia {
  productoId: string
  nombre: string
  cantidad: number
  costoUnitario: number
  stockDisponible: number
}

function getCosto(producto: ProductoDB): number {
  return producto.costo_con_iva || producto.costo_sin_iva || 0
}

export default function ModalTransferencia({
  tipo,
  productos,
  sucursales,
  onSave,
  onCrearSucursal,
  onClose,
}: ModalTransferenciaProps): React.ReactElement {
  const esIngreso = tipo === 'ingreso'
  // Form state
  const [sucursalId, setSucursalId] = useState('')
  const [fecha, setFecha] = useState(() => new Date().toISOString().split('T')[0])
  const [notas, setNotas] = useState('')
  const [items, setItems] = useState<ItemTransferencia[]>([])
  const [busqueda, setBusqueda] = useState('')
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  // Nueva sucursal inline
  const [mostrarNuevaSucursal, setMostrarNuevaSucursal] = useState(false)
  const [nuevaSucursalNombre, setNuevaSucursalNombre] = useState('')
  const [nuevaSucursalDireccion, setNuevaSucursalDireccion] = useState('')
  const [creandoSucursal, setCreandoSucursal] = useState(false)

  // IDs de productos ya agregados
  const idsAgregados = useMemo(() => new Set(items.map(i => i.productoId)), [items])

  // Productos filtrados por busqueda
  const productosFiltrados = useMemo(() => {
    if (!busqueda.trim()) return []
    const termino = busqueda.toLowerCase()
    return productos
      .filter(p =>
        !idsAgregados.has(p.id) &&
        (esIngreso || p.stock > 0) &&
        (p.nombre.toLowerCase().includes(termino) ||
         (p.categoria && p.categoria.toLowerCase().includes(termino)) ||
         (p.codigo && p.codigo.toLowerCase().includes(termino)))
      )
      .slice(0, 20)
  }, [busqueda, productos, idsAgregados, esIngreso])

  // Total
  const totalCosto = useMemo(
    () => items.reduce((sum, item) => sum + item.cantidad * item.costoUnitario, 0),
    [items]
  )

  // Handlers
  const handleAgregarProducto = (producto: ProductoDB) => {
    const costo = getCosto(producto)
    setItems(prev => [
      ...prev,
      {
        productoId: producto.id,
        nombre: producto.nombre,
        cantidad: 1,
        costoUnitario: costo,
        stockDisponible: producto.stock,
      },
    ])
    setBusqueda('')
  }

  const handleCantidadChange = (productoId: string, cantidad: number) => {
    setItems(prev =>
      prev.map(item =>
        item.productoId === productoId
          ? { ...item, cantidad: esIngreso ? Math.max(1, cantidad) : Math.max(1, Math.min(cantidad, item.stockDisponible)) }
          : item
      )
    )
  }

  const handleEliminarItem = (productoId: string) => {
    setItems(prev => prev.filter(item => item.productoId !== productoId))
  }

  const handleCrearSucursal = async () => {
    if (!nuevaSucursalNombre.trim()) return
    setCreandoSucursal(true)
    try {
      const nueva = await onCrearSucursal({
        nombre: nuevaSucursalNombre.trim(),
        direccion: nuevaSucursalDireccion.trim() || undefined,
      })
      setSucursalId(nueva.id)
      setNuevaSucursalNombre('')
      setNuevaSucursalDireccion('')
      setMostrarNuevaSucursal(false)
    } catch {
      setError('Error al crear sucursal')
    } finally {
      setCreandoSucursal(false)
    }
  }

  const handleGuardar = async () => {
    setError('')

    // Validaciones
    if (!sucursalId) {
      setError('Selecciona una sucursal')
      return
    }
    if (items.length === 0) {
      setError('Agrega al menos un producto')
      return
    }
    const itemInvalido = items.find(i => i.cantidad <= 0 || (!esIngreso && i.cantidad > i.stockDisponible))
    if (itemInvalido) {
      setError(`Cantidad invalida para "${itemInvalido.nombre}"`)
      return
    }

    setGuardando(true)
    try {
      const formData: TransferenciaFormInput = {
        sucursalId,
        fecha,
        notas: notas.trim() || null,
        totalCosto,
        tipo,
        items: items.map(item => ({
          productoId: item.productoId,
          cantidad: item.cantidad,
          costoUnitario: item.costoUnitario,
          subtotal: item.cantidad * item.costoUnitario,
        })),
      }
      await onSave(formData)
      onClose()
    } catch {
      setError('Error al registrar el envio')
    } finally {
      setGuardando(false)
    }
  }

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-2xl w-full max-w-3xl max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between px-6 py-4 border-b dark:border-gray-700">
          <div className="flex items-center gap-3">
            <ArrowRightLeft className="w-5 h-5 text-blue-600" />
            <h2 className="text-lg font-semibold text-gray-800 dark:text-white">
              {esIngreso ? 'Ingreso desde Sucursal' : 'Salida a Sucursal'}
            </h2>
          </div>
          <button
            onClick={onClose}
            className="p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
          >
            <X className="w-5 h-5 text-gray-500 dark:text-gray-400" />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto px-6 py-4 space-y-5">
          {/* Error */}
          {error && (
            <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 text-red-700 dark:text-red-400 px-4 py-2 rounded-lg text-sm">
              {error}
            </div>
          )}

          {/* Sucursal selector */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              {esIngreso ? 'Sucursal origen' : 'Sucursal destino'}
            </label>
            <div className="flex gap-2">
              <select
                value={sucursalId}
                onChange={e => setSucursalId(e.target.value)}
                className="flex-1 border dark:border-gray-600 rounded-lg px-3 py-2 bg-white dark:bg-gray-700 text-gray-800 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
              >
                <option value="">Seleccionar sucursal...</option>
                {sucursales.map(s => (
                  <option key={s.id} value={s.id}>
                    {s.nombre}{s.direccion ? ` - ${s.direccion}` : ''}
                  </option>
                ))}
              </select>
              <button
                type="button"
                onClick={() => setMostrarNuevaSucursal(!mostrarNuevaSucursal)}
                className="px-3 py-2 bg-green-600 hover:bg-green-700 text-white rounded-lg text-sm font-medium flex items-center gap-1 transition-colors whitespace-nowrap"
              >
                <Plus className="w-4 h-4" />
                Nueva
              </button>
            </div>

            {/* Inline nueva sucursal */}
            {mostrarNuevaSucursal && (
              <div className="mt-3 p-3 border dark:border-gray-600 rounded-lg bg-gray-50 dark:bg-gray-700/50 space-y-2">
                <input
                  type="text"
                  placeholder="Nombre de la sucursal"
                  value={nuevaSucursalNombre}
                  onChange={e => setNuevaSucursalNombre(e.target.value)}
                  className="w-full border dark:border-gray-600 rounded-lg px-3 py-2 bg-white dark:bg-gray-700 text-gray-800 dark:text-white text-sm focus:ring-2 focus:ring-blue-500"
                />
                <input
                  type="text"
                  placeholder="Direccion (opcional)"
                  value={nuevaSucursalDireccion}
                  onChange={e => setNuevaSucursalDireccion(e.target.value)}
                  className="w-full border dark:border-gray-600 rounded-lg px-3 py-2 bg-white dark:bg-gray-700 text-gray-800 dark:text-white text-sm focus:ring-2 focus:ring-blue-500"
                />
                <button
                  type="button"
                  onClick={handleCrearSucursal}
                  disabled={creandoSucursal || !nuevaSucursalNombre.trim()}
                  className="px-4 py-2 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 text-white rounded-lg text-sm font-medium transition-colors"
                >
                  {creandoSucursal ? 'Creando...' : 'Crear'}
                </button>
              </div>
            )}
          </div>

          {/* Fecha */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Fecha
            </label>
            <input
              type="date"
              value={fecha}
              onChange={e => setFecha(e.target.value)}
              className="border dark:border-gray-600 rounded-lg px-3 py-2 bg-white dark:bg-gray-700 text-gray-800 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          {/* Product search */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Agregar productos
            </label>
            <div className="relative">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
              <input
                type="text"
                placeholder="Buscar por nombre, categoria o codigo..."
                value={busqueda}
                onChange={e => setBusqueda(e.target.value)}
                className="w-full pl-10 pr-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-gray-800 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
              />
            </div>

            {/* Search results */}
            {productosFiltrados.length > 0 && (
              <div className="mt-2 border dark:border-gray-600 rounded-lg max-h-48 overflow-y-auto bg-white dark:bg-gray-700">
                {productosFiltrados.map(producto => (
                  <button
                    key={producto.id}
                    type="button"
                    onClick={() => handleAgregarProducto(producto)}
                    className="w-full flex items-center justify-between px-4 py-2.5 hover:bg-gray-50 dark:hover:bg-gray-600 transition-colors text-left border-b dark:border-gray-600 last:border-b-0"
                  >
                    <div>
                      <span className="text-sm font-medium text-gray-800 dark:text-white">
                        {producto.nombre}
                      </span>
                      <span className="text-xs text-gray-500 dark:text-gray-400 ml-2">
                        Stock: {producto.stock}
                      </span>
                    </div>
                    <span className="text-sm text-gray-600 dark:text-gray-300">
                      {formatPrecio(getCosto(producto))}
                    </span>
                  </button>
                ))}
              </div>
            )}
          </div>

          {/* Selected items list */}
          {items.length > 0 && (
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-2">
                {esIngreso ? 'Productos a ingresar' : 'Productos a enviar'} ({items.length})
              </label>
              <div className="border dark:border-gray-600 rounded-lg overflow-hidden">
                <div className="hidden sm:grid grid-cols-12 gap-2 px-4 py-2 bg-gray-50 dark:bg-gray-700/50 text-xs font-medium text-gray-500 dark:text-gray-400 uppercase">
                  <div className="col-span-4">Producto</div>
                  <div className="col-span-2 text-center">Cantidad</div>
                  <div className="col-span-2 text-right">Costo Unit.</div>
                  <div className="col-span-3 text-right">Subtotal</div>
                  <div className="col-span-1"></div>
                </div>
                {items.map(item => (
                  <div
                    key={item.productoId}
                    className="grid grid-cols-12 gap-2 px-4 py-3 items-center border-t dark:border-gray-600 first:border-t-0"
                  >
                    <div className="col-span-12 sm:col-span-4">
                      <span className="text-sm font-medium text-gray-800 dark:text-white">
                        {item.nombre}
                      </span>
                      <span className="text-xs text-gray-500 dark:text-gray-400 ml-1 sm:hidden">
                        (stock: {item.stockDisponible})
                      </span>
                    </div>
                    <div className="col-span-4 sm:col-span-2 flex items-center justify-center">
                      <input
                        type="number"
                        min={1}
                        max={esIngreso ? undefined : item.stockDisponible}
                        value={item.cantidad}
                        onChange={e => handleCantidadChange(item.productoId, parseInt(e.target.value) || 1)}
                        className="w-20 text-center border dark:border-gray-600 rounded-lg px-2 py-1 bg-white dark:bg-gray-700 text-gray-800 dark:text-white text-sm focus:ring-2 focus:ring-blue-500"
                      />
                      <span className="text-xs text-gray-400 ml-1 hidden sm:inline">
                        /{item.stockDisponible}
                      </span>
                    </div>
                    <div className="col-span-3 sm:col-span-2 text-right text-sm text-gray-600 dark:text-gray-300">
                      {formatPrecio(item.costoUnitario)}
                    </div>
                    <div className="col-span-4 sm:col-span-3 text-right text-sm font-medium text-gray-800 dark:text-white">
                      {formatPrecio(item.cantidad * item.costoUnitario)}
                    </div>
                    <div className="col-span-1 flex justify-end">
                      <button
                        type="button"
                        onClick={() => handleEliminarItem(item.productoId)}
                        className="p-1.5 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded-lg transition-colors"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Notas */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              Notas (opcional)
            </label>
            <textarea
              value={notas}
              onChange={e => setNotas(e.target.value)}
              rows={2}
              placeholder="Observaciones sobre el envio..."
              className="w-full border dark:border-gray-600 rounded-lg px-3 py-2 bg-white dark:bg-gray-700 text-gray-800 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500 resize-none"
            />
          </div>
        </div>

        {/* Footer */}
        <div className="flex items-center justify-between px-6 py-4 border-t dark:border-gray-700 bg-gray-50 dark:bg-gray-800/50">
          <div className="text-lg font-semibold text-gray-800 dark:text-white">
            Total: {formatPrecio(totalCosto)}
          </div>
          <div className="flex gap-3">
            <button
              type="button"
              onClick={onClose}
              className="px-4 py-2 border dark:border-gray-600 rounded-lg text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors font-medium"
            >
              Cancelar
            </button>
            <button
              type="button"
              onClick={handleGuardar}
              disabled={guardando || items.length === 0 || !sucursalId}
              className="px-6 py-2 bg-blue-600 hover:bg-blue-700 disabled:opacity-50 text-white rounded-lg font-medium transition-colors"
            >
              {guardando ? 'Registrando...' : esIngreso ? 'Registrar Ingreso' : 'Registrar Salida'}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
