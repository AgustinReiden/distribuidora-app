/**
 * ModalGrupoPrecio
 *
 * Modal para crear/editar un grupo de precio mayorista.
 * Incluye: nombre, descripción, selector de productos, editor de escalas.
 */
import { useState, useMemo } from 'react'
import { X, Plus, Trash2, Search } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import type { GrupoPrecioConDetalles, GrupoPrecioFormInput, ProductoDB } from '../../types'

export interface ModalGrupoPrecioProps {
  grupo: GrupoPrecioConDetalles | null
  productos: ProductoDB[]
  onSave: (data: GrupoPrecioFormInput) => Promise<{ success: boolean; error?: string }>
  onClose: () => void
}

interface EscalaForm {
  cantidadMinima: string
  precioUnitario: string
  etiqueta: string
}

export default function ModalGrupoPrecio({
  grupo,
  productos,
  onSave,
  onClose,
}: ModalGrupoPrecioProps) {
  const isEditing = !!grupo

  const [nombre, setNombre] = useState(grupo?.nombre || '')
  const [descripcion, setDescripcion] = useState(grupo?.descripcion || '')
  const [productoIds, setProductoIds] = useState<Set<string>>(
    new Set(grupo?.productos.map(p => String(p.producto_id)) || [])
  )
  const [escalas, setEscalas] = useState<EscalaForm[]>(
    grupo?.escalas.map(e => ({
      cantidadMinima: String(e.cantidad_minima),
      precioUnitario: String(e.precio_unitario),
      etiqueta: e.etiqueta || '',
    })) || [{ cantidadMinima: '', precioUnitario: '', etiqueta: '' }]
  )
  const [busquedaProducto, setBusquedaProducto] = useState('')
  const [error, setError] = useState('')
  const [guardando, setGuardando] = useState(false)

  const productosFiltrados = useMemo(() => {
    if (!busquedaProducto) return productos.filter(p => p.activo !== false)
    const busqueda = busquedaProducto.toLowerCase()
    return productos.filter(p =>
      p.activo !== false && (
        p.nombre.toLowerCase().includes(busqueda) ||
        p.codigo?.toLowerCase().includes(busqueda) ||
        p.categoria?.toLowerCase().includes(busqueda)
      )
    )
  }, [productos, busquedaProducto])

  const toggleProducto = (id: string) => {
    setProductoIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) {
        next.delete(id)
      } else {
        next.add(id)
      }
      return next
    })
  }

  const agregarEscala = () => {
    setEscalas(prev => [...prev, { cantidadMinima: '', precioUnitario: '', etiqueta: '' }])
  }

  const eliminarEscala = (index: number) => {
    setEscalas(prev => prev.filter((_, i) => i !== index))
  }

  const actualizarEscala = (index: number, field: keyof EscalaForm, value: string) => {
    setEscalas(prev => prev.map((e, i) => i === index ? { ...e, [field]: value } : e))
  }

  const handleSubmit = async () => {
    setError('')

    if (!nombre.trim()) {
      setError('El nombre del grupo es obligatorio')
      return
    }
    if (productoIds.size === 0) {
      setError('Selecciona al menos un producto')
      return
    }

    const escalasValidas = escalas.filter(e => e.cantidadMinima && e.precioUnitario)
    if (escalasValidas.length === 0) {
      setError('Agrega al menos una escala de precio')
      return
    }

    for (const e of escalasValidas) {
      const qty = parseInt(e.cantidadMinima)
      const price = parseFloat(e.precioUnitario)
      if (isNaN(qty) || qty <= 0) {
        setError('Las cantidades mínimas deben ser mayores a 0')
        return
      }
      if (isNaN(price) || price <= 0) {
        setError('Los precios deben ser mayores a 0')
        return
      }
    }

    // Check duplicates in cantidad_minima
    const cantidades = escalasValidas.map(e => parseInt(e.cantidadMinima))
    if (new Set(cantidades).size !== cantidades.length) {
      setError('No puede haber dos escalas con la misma cantidad mínima')
      return
    }

    setGuardando(true)
    try {
      const result = await onSave({
        nombre: nombre.trim(),
        descripcion: descripcion.trim() || null,
        productoIds: Array.from(productoIds),
        escalas: escalasValidas.map(e => ({
          cantidadMinima: parseInt(e.cantidadMinima),
          precioUnitario: parseFloat(e.precioUnitario),
          etiqueta: e.etiqueta.trim() || null,
        })),
      })
      if (!result.success) {
        setError(result.error || 'Error al guardar')
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Error al guardar')
    } finally {
      setGuardando(false)
    }
  }

  return (
    <div className="fixed inset-0 bg-black bg-opacity-50 flex items-center justify-center p-4 z-50">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-2xl max-h-[90vh] overflow-hidden flex flex-col">
        {/* Header */}
        <div className="flex justify-between items-center p-4 border-b dark:border-gray-700">
          <h2 className="text-xl font-semibold dark:text-white">
            {isEditing ? 'Editar Grupo de Precio' : 'Nuevo Grupo de Precio'}
          </h2>
          <button onClick={onClose}>
            <X className="w-6 h-6 text-gray-500 dark:text-gray-400" />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto p-4 space-y-5">
          {/* Nombre y descripción */}
          <div className="space-y-3">
            <div>
              <label className="block text-sm font-medium mb-1 dark:text-gray-200">Nombre del grupo *</label>
              <input
                type="text"
                value={nombre}
                onChange={e => setNombre(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                placeholder="Ej: Papas Fritas"
              />
            </div>
            <div>
              <label className="block text-sm font-medium mb-1 dark:text-gray-200">Descripción</label>
              <input
                type="text"
                value={descripcion}
                onChange={e => setDescripcion(e.target.value)}
                className="w-full px-3 py-2 border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                placeholder="Ej: Todos los sabores de papas fritas"
              />
            </div>
          </div>

          {/* Selector de productos */}
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">
              Productos del grupo * ({productoIds.size} seleccionados)
            </label>
            <div className="relative mb-2">
              <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-4 h-4" />
              <input
                type="text"
                value={busquedaProducto}
                onChange={e => setBusquedaProducto(e.target.value)}
                className="w-full pl-9 pr-3 py-2 border rounded-lg text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                placeholder="Buscar producto..."
              />
            </div>
            <div className="border dark:border-gray-600 rounded-lg max-h-48 overflow-y-auto">
              {productosFiltrados.length === 0 ? (
                <p className="p-3 text-center text-sm text-gray-500">No se encontraron productos</p>
              ) : (
                productosFiltrados.map(p => {
                  const isSelected = productoIds.has(String(p.id))
                  return (
                    <div
                      key={p.id}
                      onClick={() => toggleProducto(String(p.id))}
                      className={`flex items-center justify-between p-2.5 border-b dark:border-gray-700 cursor-pointer transition-colors ${
                        isSelected
                          ? 'bg-blue-50 dark:bg-blue-900/20'
                          : 'hover:bg-gray-50 dark:hover:bg-gray-700'
                      }`}
                    >
                      <div className="flex items-center gap-2">
                        <div className={`w-4 h-4 rounded border-2 flex items-center justify-center ${
                          isSelected
                            ? 'bg-blue-600 border-blue-600'
                            : 'border-gray-300 dark:border-gray-500'
                        }`}>
                          {isSelected && <span className="text-white text-xs font-bold">✓</span>}
                        </div>
                        <div>
                          <span className="text-sm font-medium dark:text-white">{p.nombre}</span>
                          {p.categoria && (
                            <span className="ml-2 text-xs text-gray-400">{p.categoria}</span>
                          )}
                        </div>
                      </div>
                      <span className="text-sm text-gray-500">{formatPrecio(p.precio)}</span>
                    </div>
                  )
                })
              )}
            </div>
          </div>

          {/* Editor de escalas */}
          <div>
            <div className="flex justify-between items-center mb-2">
              <label className="block text-sm font-medium dark:text-gray-200">Escalas de precio *</label>
              <button
                onClick={agregarEscala}
                className="flex items-center gap-1 text-sm text-blue-600 hover:text-blue-700"
              >
                <Plus className="w-3 h-3" /> Agregar escala
              </button>
            </div>
            <div className="space-y-2">
              {escalas.map((escala, index) => (
                <div key={index} className="flex items-center gap-2">
                  <div className="flex-1">
                    <input
                      type="number"
                      min="1"
                      value={escala.cantidadMinima}
                      onChange={e => actualizarEscala(index, 'cantidadMinima', e.target.value)}
                      className="w-full px-3 py-2 border rounded-lg text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                      placeholder="Cant. mínima"
                    />
                  </div>
                  <div className="flex-1">
                    <div className="relative">
                      <span className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 text-sm">$</span>
                      <input
                        type="number"
                        min="0.01"
                        step="0.01"
                        value={escala.precioUnitario}
                        onChange={e => actualizarEscala(index, 'precioUnitario', e.target.value)}
                        className="w-full pl-7 pr-3 py-2 border rounded-lg text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                        placeholder="Precio c/u"
                      />
                    </div>
                  </div>
                  <div className="flex-1">
                    <input
                      type="text"
                      value={escala.etiqueta}
                      onChange={e => actualizarEscala(index, 'etiqueta', e.target.value)}
                      className="w-full px-3 py-2 border rounded-lg text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                      placeholder="Etiqueta (ej: Mayorista)"
                    />
                  </div>
                  {escalas.length > 1 && (
                    <button
                      onClick={() => eliminarEscala(index)}
                      className="p-2 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded-lg"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  )}
                </div>
              ))}
            </div>

            {/* Preview de escalas */}
            {escalas.some(e => e.cantidadMinima && e.precioUnitario) && (
              <div className="mt-3 p-3 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg">
                <p className="text-xs font-medium text-green-700 dark:text-green-300 mb-1">Vista previa:</p>
                <div className="flex flex-wrap gap-2">
                  {escalas
                    .filter(e => e.cantidadMinima && e.precioUnitario)
                    .sort((a, b) => parseInt(a.cantidadMinima) - parseInt(b.cantidadMinima))
                    .map((e, i) => (
                      <span key={i} className="text-sm text-green-800 dark:text-green-200">
                        {e.cantidadMinima}+ = {formatPrecio(parseFloat(e.precioUnitario))}
                        {e.etiqueta && ` (${e.etiqueta})`}
                        {i < escalas.filter(x => x.cantidadMinima && x.precioUnitario).length - 1 && ' · '}
                      </span>
                    ))}
                </div>
              </div>
            )}
          </div>
        </div>

        {/* Footer */}
        <div className="border-t dark:border-gray-700 bg-gray-50 dark:bg-gray-800/50 p-4">
          {error && (
            <p className="text-sm text-red-600 dark:text-red-400 mb-3">{error}</p>
          )}
          <div className="flex justify-end gap-3">
            <button
              onClick={onClose}
              className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg"
            >
              Cancelar
            </button>
            <button
              onClick={handleSubmit}
              disabled={guardando}
              className="px-6 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-blue-400 flex items-center gap-2"
            >
              {guardando && (
                <div className="w-4 h-4 border-2 border-white border-t-transparent rounded-full animate-spin" />
              )}
              {isEditing ? 'Guardar cambios' : 'Crear grupo'}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
