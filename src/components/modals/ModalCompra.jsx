import React, { useState, useMemo } from 'react'
import { X, ShoppingCart, Plus, Trash2, Package, Building2, FileText, Calculator, Search } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'

const FORMAS_PAGO = [
  { value: 'efectivo', label: 'Efectivo' },
  { value: 'transferencia', label: 'Transferencia' },
  { value: 'cheque', label: 'Cheque' },
  { value: 'cuenta_corriente', label: 'Cuenta Corriente' },
  { value: 'tarjeta', label: 'Tarjeta' }
]

export default function ModalCompra({ productos, proveedores, onSave, onClose, onAgregarProveedor }) {
  const [proveedorId, setProveedorId] = useState('')
  const [proveedorNombre, setProveedorNombre] = useState('')
  const [usarProveedorNuevo, setUsarProveedorNuevo] = useState(false)
  const [numeroFactura, setNumeroFactura] = useState('')
  const [fechaCompra, setFechaCompra] = useState(new Date().toISOString().split('T')[0])
  const [formaPago, setFormaPago] = useState('efectivo')
  const [notas, setNotas] = useState('')
  const [items, setItems] = useState([])
  const [guardando, setGuardando] = useState(false)
  const [error, setError] = useState('')

  // Buscador de productos
  const [busquedaProducto, setBusquedaProducto] = useState('')
  const [mostrarBuscador, setMostrarBuscador] = useState(false)

  // Productos filtrados
  const productosFiltrados = useMemo(() => {
    if (!busquedaProducto.trim()) return productos.slice(0, 10)
    const termino = busquedaProducto.toLowerCase()
    return productos.filter(p =>
      p.nombre?.toLowerCase().includes(termino) ||
      p.codigo?.toLowerCase().includes(termino)
    ).slice(0, 10)
  }, [productos, busquedaProducto])

  // Cálculos con impuestos internos separados
  // Subtotal = suma de (cantidad * costo neto)
  const subtotal = useMemo(() => {
    return items.reduce((sum, item) => sum + (item.cantidad * item.costoUnitario), 0)
  }, [items])

  // IVA se calcula SOLO sobre el subtotal (neto), NO sobre impuestos internos
  const iva = useMemo(() => {
    return items.reduce((sum, item) => {
      const porcentajeIva = item.porcentajeIva ?? 21
      return sum + (item.cantidad * item.costoUnitario * porcentajeIva / 100)
    }, 0)
  }, [items])

  // Impuestos internos totales (no gravados con IVA)
  const impuestosInternos = useMemo(() => {
    return items.reduce((sum, item) => sum + (item.cantidad * (item.impuestosInternos || 0)), 0)
  }, [items])

  // Total = subtotal + IVA (sobre neto) + impuestos internos
  const total = useMemo(() => subtotal + iva + impuestosInternos, [subtotal, iva, impuestosInternos])

  const agregarItem = (producto) => {
    // Verificar si ya existe
    const existente = items.find(i => i.productoId === producto.id)
    if (existente) {
      setItems(items.map(i =>
        i.productoId === producto.id
          ? { ...i, cantidad: i.cantidad + 1 }
          : i
      ))
    } else {
      setItems([...items, {
        productoId: producto.id,
        productoNombre: producto.nombre,
        productoCodigo: producto.codigo,
        cantidad: 1,
        costoUnitario: producto.costo_sin_iva || 0, // Costo neto
        impuestosInternos: producto.impuestos_internos || 0, // Imp internos por unidad
        porcentajeIva: producto.porcentaje_iva ?? 21, // % IVA del producto
        stockActual: producto.stock
      }])
    }
    setBusquedaProducto('')
    setMostrarBuscador(false)
  }

  const actualizarItem = (index, campo, valor) => {
    setItems(items.map((item, i) =>
      i === index ? { ...item, [campo]: valor } : item
    ))
  }

  const eliminarItem = (index) => {
    setItems(items.filter((_, i) => i !== index))
  }

  const handleSubmit = async (e) => {
    e.preventDefault()
    setError('')

    if (items.length === 0) {
      setError('Debe agregar al menos un producto')
      return
    }

    if (!usarProveedorNuevo && !proveedorId && !proveedorNombre.trim()) {
      setError('Debe seleccionar o ingresar un proveedor')
      return
    }

    // Validar items
    for (const item of items) {
      if (item.cantidad <= 0) {
        setError(`La cantidad de "${item.productoNombre}" debe ser mayor a 0`)
        return
      }
    }

    setGuardando(true)
    try {
      await onSave({
        proveedorId: usarProveedorNuevo ? null : (proveedorId || null),
        proveedorNombre: usarProveedorNuevo || !proveedorId ? proveedorNombre : null,
        numeroFactura,
        fechaCompra,
        subtotal,
        iva,
        otrosImpuestos: impuestosInternos, // Impuestos internos van en otrosImpuestos
        total,
        formaPago,
        notas,
        items: items.map(item => ({
          productoId: item.productoId,
          cantidad: parseInt(item.cantidad),
          costoUnitario: parseFloat(item.costoUnitario) || 0,
          impuestosInternos: parseFloat(item.impuestosInternos) || 0,
          porcentajeIva: item.porcentajeIva ?? 21,
          subtotal: item.cantidad * item.costoUnitario
        }))
      })
      onClose()
    } catch (err) {
      setError(err.message || 'Error al registrar la compra')
    } finally {
      setGuardando(false)
    }
  }

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-4xl max-h-[90vh] overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700 shrink-0">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-green-100 dark:bg-green-900/30 rounded-lg">
              <ShoppingCart className="w-5 h-5 text-green-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Nueva Compra</h2>
              <p className="text-sm text-gray-500">Registrar compra a proveedor</p>
            </div>
          </div>
          <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Contenido scrolleable */}
        <form onSubmit={handleSubmit} className="flex-1 overflow-y-auto p-4 space-y-4">
          {/* Sección Proveedor */}
          <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4 space-y-3">
            <div className="flex items-center gap-2 mb-2">
              <Building2 className="w-5 h-5 text-gray-500" />
              <h3 className="font-medium text-gray-800 dark:text-white">Proveedor</h3>
            </div>

            <div className="flex items-center gap-4 mb-2">
              <label className="flex items-center gap-2 cursor-pointer">
                <input
                  type="radio"
                  checked={!usarProveedorNuevo}
                  onChange={() => setUsarProveedorNuevo(false)}
                  className="text-green-600"
                />
                <span className="text-sm">Seleccionar existente</span>
              </label>
              <label className="flex items-center gap-2 cursor-pointer">
                <input
                  type="radio"
                  checked={usarProveedorNuevo}
                  onChange={() => setUsarProveedorNuevo(true)}
                  className="text-green-600"
                />
                <span className="text-sm">Ingresar nombre</span>
              </label>
            </div>

            {!usarProveedorNuevo ? (
              <select
                value={proveedorId}
                onChange={e => setProveedorId(e.target.value)}
                className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
              >
                <option value="">Seleccionar proveedor...</option>
                {proveedores.map(p => (
                  <option key={p.id} value={p.id}>{p.nombre} {p.cuit ? `(${p.cuit})` : ''}</option>
                ))}
              </select>
            ) : (
              <input
                type="text"
                value={proveedorNombre}
                onChange={e => setProveedorNombre(e.target.value)}
                placeholder="Nombre del proveedor"
                className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
              />
            )}
          </div>

          {/* Datos de la compra */}
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                N° Factura / Remito
              </label>
              <input
                type="text"
                value={numeroFactura}
                onChange={e => setNumeroFactura(e.target.value)}
                placeholder="Ej: 0001-00012345"
                className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Fecha de Compra *
              </label>
              <input
                type="date"
                value={fechaCompra}
                onChange={e => setFechaCompra(e.target.value)}
                className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
                required
              />
            </div>
            <div>
              <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
                Forma de Pago
              </label>
              <select
                value={formaPago}
                onChange={e => setFormaPago(e.target.value)}
                className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
              >
                {FORMAS_PAGO.map(fp => (
                  <option key={fp.value} value={fp.value}>{fp.label}</option>
                ))}
              </select>
            </div>
          </div>

          {/* Productos */}
          <div className="bg-gray-50 dark:bg-gray-900 rounded-lg p-4 space-y-3">
            <div className="flex items-center justify-between">
              <div className="flex items-center gap-2">
                <Package className="w-5 h-5 text-gray-500" />
                <h3 className="font-medium text-gray-800 dark:text-white">Productos</h3>
              </div>
            </div>

            {/* Buscador de productos */}
            <div className="relative">
              <div className="flex items-center gap-2">
                <div className="relative flex-1">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
                  <input
                    type="text"
                    value={busquedaProducto}
                    onChange={e => {
                      setBusquedaProducto(e.target.value)
                      setMostrarBuscador(true)
                    }}
                    onFocus={() => setMostrarBuscador(true)}
                    placeholder="Buscar producto por nombre o código..."
                    className="w-full pl-10 pr-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
                  />
                </div>
              </div>

              {/* Dropdown de resultados */}
              {mostrarBuscador && (
                <div className="absolute z-10 w-full mt-1 bg-white dark:bg-gray-800 border dark:border-gray-600 rounded-lg shadow-lg max-h-48 overflow-y-auto">
                  {productosFiltrados.length > 0 ? (
                    productosFiltrados.map(p => (
                      <button
                        key={p.id}
                        type="button"
                        onClick={() => agregarItem(p)}
                        className="w-full px-4 py-2 text-left hover:bg-gray-100 dark:hover:bg-gray-700 flex items-center justify-between"
                      >
                        <div>
                          <p className="font-medium text-gray-800 dark:text-white">{p.nombre}</p>
                          <p className="text-xs text-gray-500">
                            {p.codigo && `Código: ${p.codigo} • `}
                            Stock: {p.stock}
                          </p>
                        </div>
                        <Plus className="w-4 h-4 text-green-600" />
                      </button>
                    ))
                  ) : (
                    <p className="px-4 py-2 text-sm text-gray-500">No se encontraron productos</p>
                  )}
                  <button
                    type="button"
                    onClick={() => setMostrarBuscador(false)}
                    className="w-full px-4 py-2 text-sm text-gray-500 hover:bg-gray-100 dark:hover:bg-gray-700 border-t dark:border-gray-600"
                  >
                    Cerrar
                  </button>
                </div>
              )}
            </div>

            {/* Lista de items */}
            {items.length > 0 ? (
              <div className="space-y-2">
                <div className="grid grid-cols-12 gap-2 text-xs font-medium text-gray-500 uppercase px-2">
                  <div className="col-span-4">Producto</div>
                  <div className="col-span-1 text-center">Cant.</div>
                  <div className="col-span-2 text-center">Neto</div>
                  <div className="col-span-2 text-center">Imp.Int.</div>
                  <div className="col-span-2 text-right">Subtotal</div>
                  <div className="col-span-1"></div>
                </div>
                {items.map((item, index) => (
                  <div key={index} className="grid grid-cols-12 gap-2 items-center bg-white dark:bg-gray-800 p-2 rounded-lg border dark:border-gray-600">
                    <div className="col-span-4">
                      <p className="font-medium text-gray-800 dark:text-white text-sm">{item.productoNombre}</p>
                      <p className="text-xs text-gray-500">
                        Stock: {item.stockActual} | IVA: {item.porcentajeIva}%
                      </p>
                    </div>
                    <div className="col-span-1">
                      <input
                        type="number"
                        min="1"
                        value={item.cantidad}
                        onChange={e => actualizarItem(index, 'cantidad', parseInt(e.target.value) || 0)}
                        className="w-full px-1 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
                      />
                    </div>
                    <div className="col-span-2">
                      <input
                        type="number"
                        min="0"
                        step="0.01"
                        value={item.costoUnitario}
                        onChange={e => actualizarItem(index, 'costoUnitario', parseFloat(e.target.value) || 0)}
                        className="w-full px-1 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
                        title="Costo neto (sin IVA)"
                      />
                    </div>
                    <div className="col-span-2">
                      <input
                        type="number"
                        min="0"
                        step="0.01"
                        value={item.impuestosInternos || 0}
                        onChange={e => actualizarItem(index, 'impuestosInternos', parseFloat(e.target.value) || 0)}
                        className="w-full px-1 py-1 text-center border dark:border-gray-600 rounded focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white text-sm"
                        title="Impuestos internos (no gravados)"
                      />
                    </div>
                    <div className="col-span-2 text-right font-medium text-gray-800 dark:text-white text-sm">
                      {formatPrecio(item.cantidad * item.costoUnitario)}
                    </div>
                    <div className="col-span-1 text-right">
                      <button
                        type="button"
                        onClick={() => eliminarItem(index)}
                        className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded"
                      >
                        <Trash2 className="w-4 h-4" />
                      </button>
                    </div>
                  </div>
                ))}
              </div>
            ) : (
              <div className="text-center py-8 text-gray-500">
                <Package className="w-12 h-12 mx-auto mb-2 opacity-50" />
                <p>No hay productos agregados</p>
                <p className="text-sm">Use el buscador para agregar productos</p>
              </div>
            )}
          </div>

          {/* Totales */}
          {items.length > 0 && (
            <div className="bg-green-50 dark:bg-green-900/20 rounded-lg p-4">
              <div className="flex items-center gap-2 mb-3">
                <Calculator className="w-5 h-5 text-green-600" />
                <h3 className="font-medium text-gray-800 dark:text-white">Resumen</h3>
              </div>

              <div className="space-y-2">
                <div className="flex justify-between text-sm">
                  <span className="text-gray-600 dark:text-gray-400">Subtotal Neto:</span>
                  <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(subtotal)}</span>
                </div>
                <div className="flex justify-between text-sm">
                  <span className="text-gray-600 dark:text-gray-400">IVA (sobre neto):</span>
                  <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(iva)}</span>
                </div>
                {impuestosInternos > 0 && (
                  <div className="flex justify-between text-sm">
                    <span className="text-gray-600 dark:text-gray-400">Impuestos Internos:</span>
                    <span className="font-medium text-gray-800 dark:text-white">{formatPrecio(impuestosInternos)}</span>
                  </div>
                )}
                <div className="flex justify-between text-lg font-bold pt-2 border-t dark:border-gray-600">
                  <span className="text-gray-800 dark:text-white">Total:</span>
                  <span className="text-green-600">{formatPrecio(total)}</span>
                </div>
                <p className="text-xs text-gray-500 pt-1">
                  Costo real (neto + imp.int. sin IVA): {formatPrecio(subtotal + impuestosInternos)}
                </p>
              </div>
            </div>
          )}

          {/* Notas */}
          <div>
            <label className="block text-sm font-medium text-gray-700 dark:text-gray-300 mb-1">
              <FileText className="w-4 h-4 inline mr-1" />
              Notas (opcional)
            </label>
            <textarea
              value={notas}
              onChange={e => setNotas(e.target.value)}
              placeholder="Observaciones adicionales..."
              rows={2}
              className="w-full px-4 py-2 border dark:border-gray-600 rounded-lg focus:ring-2 focus:ring-green-500 dark:bg-gray-700 dark:text-white"
            />
          </div>

          {/* Error */}
          {error && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
            </div>
          )}
        </form>

        {/* Footer con botones */}
        <div className="flex gap-3 p-4 border-t dark:border-gray-700 shrink-0">
          <button
            type="button"
            onClick={onClose}
            className="flex-1 px-4 py-2 border dark:border-gray-600 rounded-lg hover:bg-gray-50 dark:hover:bg-gray-700 transition-colors"
          >
            Cancelar
          </button>
          <button
            onClick={handleSubmit}
            disabled={guardando || items.length === 0}
            className="flex-1 px-4 py-2 bg-green-600 hover:bg-green-700 disabled:bg-green-400 text-white rounded-lg transition-colors flex items-center justify-center gap-2"
          >
            {guardando ? (
              <>
                <span className="animate-spin">...</span>
                Registrando...
              </>
            ) : (
              <>
                <ShoppingCart className="w-4 h-4" />
                Registrar Compra
              </>
            )}
          </button>
        </div>
      </div>
    </div>
  )
}
