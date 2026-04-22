/**
 * ModalGrupoPrecio
 *
 * Modal para crear/editar una condicion mayorista (grupo de precio).
 * Incluye:
 *   - Nombre y descripcion.
 *   - Selector de productos con cantidad minima de pedido (MOQ) por producto.
 *   - Editor de escalas de precio por volumen.
 *   - Por escala: toggle "Requiere combinacion" que habilita minimos por
 *     producto y minimo de productos distintos (activacion combinada).
 *   - Preview humano de cada escala.
 */
import { useMemo, useState, useEffect } from 'react'
import { X, Plus, Trash2, Search, Copy, ChevronDown, ChevronRight, Layers } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import { parsePrecio } from '../../utils/calculations'
import { describirReglaEscala } from '../../utils/describirReglaEscala'
import type { EscalaPrecio } from '../../utils/precioMayorista'
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
  /** UI: si el toggle "Requiere combinacion" esta activo. */
  combinada: boolean
  /** UI: expandido o colapsado */
  expandido: boolean
  minProductosDistintos: string
  /** productoId -> cantidad minima individual (string para controlar el input). */
  minimosPorProducto: Record<string, string>
}

function escalaDesdeGrupo(
  escalaDB: GrupoPrecioConDetalles['escalas'][number],
  minimosDB: Record<string, number>
): EscalaForm {
  const combinada = Object.keys(minimosDB).length > 0 || (escalaDB.min_productos_distintos ?? 1) > 1
  return {
    cantidadMinima: String(escalaDB.cantidad_minima),
    precioUnitario: String(escalaDB.precio_unitario),
    etiqueta: escalaDB.etiqueta || '',
    combinada,
    expandido: combinada,
    minProductosDistintos: String(escalaDB.min_productos_distintos ?? 1),
    minimosPorProducto: Object.fromEntries(
      Object.entries(minimosDB).map(([pid, v]) => [pid, String(v)])
    ),
  }
}

function escalaVacia(): EscalaForm {
  return {
    cantidadMinima: '',
    precioUnitario: '',
    etiqueta: '',
    combinada: false,
    expandido: false,
    minProductosDistintos: '1',
    minimosPorProducto: {},
  }
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
  const [escalas, setEscalas] = useState<EscalaForm[]>(() => {
    if (!grupo) return [escalaVacia()]
    return grupo.escalas.map(e => {
      const minimosDB: Record<string, number> = {}
      for (const m of grupo.escalaMinimos?.[String(e.id)] || []) {
        minimosDB[String(m.producto_id)] = Number(m.cantidad_minima_por_item)
      }
      return escalaDesdeGrupo(e, minimosDB)
    })
  })
  const [moqPorProducto, setMoqPorProducto] = useState<Map<string, string>>(() => {
    const map = new Map<string, string>()
    if (grupo?.productos) {
      for (const p of grupo.productos) {
        if (p.cantidad_minima_pedido && p.cantidad_minima_pedido > 0) {
          map.set(String(p.producto_id), String(p.cantidad_minima_pedido))
        }
      }
    }
    return map
  })
  const [moqGlobal, setMoqGlobal] = useState('')
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

  const productosDelGrupo = useMemo(
    () => productos.filter(p => productoIds.has(String(p.id))),
    [productos, productoIds]
  )

  const nombresProductos = useMemo(() => {
    const map: Record<string, string> = {}
    for (const p of productos) map[String(p.id)] = p.nombre
    return map
  }, [productos])

  // Si se quita un producto del grupo, limpiar los minimos asociados en cada escala
  useEffect(() => {
    setEscalas(prev => prev.map(e => {
      const nuevosMinimos: Record<string, string> = {}
      for (const [pid, v] of Object.entries(e.minimosPorProducto)) {
        if (productoIds.has(pid)) nuevosMinimos[pid] = v
      }
      if (Object.keys(nuevosMinimos).length === Object.keys(e.minimosPorProducto).length) {
        return e
      }
      return { ...e, minimosPorProducto: nuevosMinimos }
    }))
  }, [productoIds])

  const toggleProducto = (id: string) => {
    setProductoIds(prev => {
      const next = new Set(prev)
      if (next.has(id)) {
        next.delete(id)
        setMoqPorProducto(prev => { const m = new Map(prev); m.delete(id); return m })
      } else {
        next.add(id)
      }
      return next
    })
  }

  const actualizarMoqProducto = (productoId: string, value: string) => {
    setMoqPorProducto(prev => {
      const next = new Map(prev)
      if (!value || value === '0') {
        next.delete(productoId)
      } else {
        next.set(productoId, value)
      }
      return next
    })
  }

  const aplicarMoqATodos = () => {
    if (!moqGlobal || parseInt(moqGlobal) <= 0) return
    setMoqPorProducto(() => {
      const next = new Map<string, string>()
      for (const pid of productoIds) {
        next.set(pid, moqGlobal)
      }
      return next
    })
  }

  const agregarEscala = () => {
    setEscalas(prev => [...prev, escalaVacia()])
  }

  const eliminarEscala = (index: number) => {
    setEscalas(prev => prev.filter((_, i) => i !== index))
  }

  const actualizarEscala = (index: number, patch: Partial<EscalaForm>) => {
    setEscalas(prev => prev.map((e, i) => (i === index ? { ...e, ...patch } : e)))
  }

  const toggleCombinada = (index: number) => {
    setEscalas(prev => prev.map((e, i) => {
      if (i !== index) return e
      const nueva = !e.combinada
      return {
        ...e,
        combinada: nueva,
        expandido: nueva,
        minProductosDistintos: nueva ? (e.minProductosDistintos || '2') : '1',
        // Al desactivar combinada, vaciar minimos por producto
        minimosPorProducto: nueva ? e.minimosPorProducto : {},
      }
    }))
  }

  const actualizarMinimoProducto = (escalaIdx: number, productoId: string, value: string) => {
    setEscalas(prev => prev.map((e, i) => {
      if (i !== escalaIdx) return e
      const next = { ...e.minimosPorProducto }
      if (!value || value === '0' || parseInt(value) <= 0) {
        delete next[productoId]
      } else {
        next[productoId] = value
      }
      return { ...e, minimosPorProducto: next }
    }))
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
      const price = parsePrecio(e.precioUnitario)
      if (isNaN(qty) || qty <= 0) {
        setError('Las cantidades minimas deben ser mayores a 0')
        return
      }
      if (isNaN(price) || price <= 0) {
        setError('Los precios deben ser mayores a 0')
        return
      }

      if (e.combinada) {
        const k = parseInt(e.minProductosDistintos)
        if (isNaN(k) || k < 2) {
          setError(`Con "Requiere combinacion" activo, el minimo de productos distintos debe ser >= 2 (escala ${qty}u)`)
          return
        }
        const minimosActivos = Object.entries(e.minimosPorProducto).filter(([, v]) => parseInt(v) > 0)
        if (minimosActivos.length < k) {
          setError(`La escala ${qty}u requiere ${k} productos distintos pero solo ${minimosActivos.length} tienen minimo configurado.`)
          return
        }
        // Coherencia: suma de los K minimos mas bajos debe ser <= cantidad_minima total
        const minimosOrdenados = minimosActivos
          .map(([, v]) => parseInt(v))
          .sort((a, b) => a - b)
        const sumaMinima = minimosOrdenados.slice(0, k).reduce((s, n) => s + n, 0)
        if (sumaMinima > qty) {
          setError(
            `Regla inalcanzable en escala ${qty}u: sumando los ${k} minimos mas bajos da ${sumaMinima}, que excede ${qty}.`
          )
          return
        }
      }
    }

    // Check duplicates in cantidad_minima
    const cantidades = escalasValidas.map(e => parseInt(e.cantidadMinima))
    if (new Set(cantidades).size !== cantidades.length) {
      setError('No puede haber dos escalas con la misma cantidad minima')
      return
    }

    setGuardando(true)
    try {
      const cantidadesMinimas: Record<string, number | null> = {}
      for (const [pid, val] of moqPorProducto) {
        const parsed = parseInt(val)
        cantidadesMinimas[pid] = !isNaN(parsed) && parsed > 0 ? parsed : null
      }

      const result = await onSave({
        nombre: nombre.trim(),
        descripcion: descripcion.trim() || null,
        productoIds: Array.from(productoIds),
        cantidadesMinimas,
        escalas: escalasValidas.map(e => {
          const base = {
            cantidadMinima: parseInt(e.cantidadMinima),
            precioUnitario: parsePrecio(e.precioUnitario),
            etiqueta: e.etiqueta.trim() || null,
            minProductosDistintos: e.combinada ? parseInt(e.minProductosDistintos) : 1,
          }
          if (!e.combinada) return base
          const minimos: Record<string, number> = {}
          for (const [pid, v] of Object.entries(e.minimosPorProducto)) {
            const n = parseInt(v)
            if (!isNaN(n) && n > 0 && productoIds.has(pid)) minimos[pid] = n
          }
          return { ...base, minimosPorProducto: minimos }
        }),
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
            {isEditing ? 'Editar Condicion Mayorista' : 'Nueva Condicion Mayorista'}
          </h2>
          <button onClick={onClose}>
            <X className="w-6 h-6 text-gray-500 dark:text-gray-400" />
          </button>
        </div>

        {/* Body */}
        <div className="flex-1 overflow-y-auto p-4 space-y-5">
          {/* Nombre y descripcion */}
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
              <label className="block text-sm font-medium mb-1 dark:text-gray-200">Descripcion</label>
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
                      className={`flex items-center justify-between p-2.5 border-b dark:border-gray-700 transition-colors ${
                        isSelected
                          ? 'bg-blue-50 dark:bg-blue-900/20'
                          : 'hover:bg-gray-50 dark:hover:bg-gray-700'
                      }`}
                    >
                      <div className="flex items-center gap-2 cursor-pointer flex-1" onClick={() => toggleProducto(String(p.id))}>
                        <div className={`w-4 h-4 rounded border-2 flex items-center justify-center flex-shrink-0 ${
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
                      <div className="flex items-center gap-2">
                        {isSelected && (
                          <input
                            type="number"
                            inputMode="numeric"
                            step="1"
                            min="1"
                            value={moqPorProducto.get(String(p.id)) || ''}
                            onChange={e => actualizarMoqProducto(String(p.id), e.target.value)}
                            onClick={e => e.stopPropagation()}
                            className="w-16 px-2 py-1 border rounded text-xs text-center dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                            placeholder="Min"
                            title="Cantidad minima de pedido"
                          />
                        )}
                        <span className="text-sm text-gray-500 w-20 text-right">{formatPrecio(p.precio)}</span>
                      </div>
                    </div>
                  )
                })
              )}
            </div>

            {/* Aplicar cantidad minima a todos */}
            {productoIds.size > 0 && (
              <div className="flex items-center gap-2 mt-2">
                <input
                  type="number"
                  inputMode="numeric"
                  step="1"
                  min="1"
                  value={moqGlobal}
                  onChange={e => setMoqGlobal(e.target.value)}
                  className="w-24 px-2 py-1.5 border rounded-lg text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                  placeholder="Cant. min"
                />
                <button
                  onClick={aplicarMoqATodos}
                  disabled={!moqGlobal || parseInt(moqGlobal) <= 0}
                  className="flex items-center gap-1 text-sm text-blue-600 hover:text-blue-700 disabled:text-gray-400"
                >
                  <Copy className="w-3 h-3" /> Aplicar a todos
                </button>
                <span className="text-xs text-gray-400">Cantidad minima de pedido</span>
              </div>
            )}
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
              {escalas.map((escala, index) => {
                const previewEscala: EscalaPrecio = {
                  cantidadMinima: parseInt(escala.cantidadMinima) || 0,
                  precioUnitario: parsePrecio(escala.precioUnitario) || 0,
                  etiqueta: escala.etiqueta || null,
                  minProductosDistintos: escala.combinada ? parseInt(escala.minProductosDistintos) || 1 : 1,
                  minimosPorProducto: new Map(
                    Object.entries(escala.minimosPorProducto)
                      .map(([pid, v]) => [pid, parseInt(v) || 0] as const)
                      .filter(([, n]) => n > 0)
                  ),
                }

                return (
                  <div key={index} className="border dark:border-gray-700 rounded-lg p-2 space-y-2">
                    <div className="flex items-center gap-2">
                      <input
                        type="number"
                        inputMode="numeric"
                        step="1"
                        min="1"
                        value={escala.cantidadMinima}
                        onChange={e => actualizarEscala(index, { cantidadMinima: e.target.value })}
                        className="flex-1 px-3 py-2 border rounded-lg text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                        placeholder="Cant. minima total"
                      />
                      <div className="flex-1 relative">
                        <span className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 text-sm">$</span>
                        <input
                          type="number"
                          inputMode="decimal"
                          min="0.01"
                          step="0.01"
                          value={escala.precioUnitario}
                          onChange={e => actualizarEscala(index, { precioUnitario: e.target.value })}
                          className="w-full pl-7 pr-3 py-2 border rounded-lg text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                          placeholder="Precio c/u"
                        />
                      </div>
                      <input
                        type="text"
                        value={escala.etiqueta}
                        onChange={e => actualizarEscala(index, { etiqueta: e.target.value })}
                        className="flex-1 px-3 py-2 border rounded-lg text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                        placeholder="Etiqueta (ej: Fardo)"
                      />
                      {escalas.length > 1 && (
                        <button
                          onClick={() => eliminarEscala(index)}
                          className="p-2 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded-lg"
                          aria-label="Eliminar escala"
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      )}
                    </div>

                    {/* Toggle combinacion + panel */}
                    <div className="flex items-center justify-between gap-2 pl-1">
                      <label className="flex items-center gap-2 text-xs text-gray-700 dark:text-gray-300 cursor-pointer">
                        <input
                          type="checkbox"
                          checked={escala.combinada}
                          onChange={() => toggleCombinada(index)}
                          className="rounded"
                        />
                        <Layers className="w-3.5 h-3.5" />
                        Requiere combinacion de productos
                      </label>
                      {escala.combinada && (
                        <button
                          onClick={() => actualizarEscala(index, { expandido: !escala.expandido })}
                          className="text-xs text-gray-500 hover:text-gray-700 dark:hover:text-gray-300 flex items-center gap-1"
                        >
                          {escala.expandido ? <ChevronDown className="w-3 h-3" /> : <ChevronRight className="w-3 h-3" />}
                          {escala.expandido ? 'Colapsar' : 'Configurar minimos'}
                        </button>
                      )}
                    </div>

                    {escala.combinada && escala.expandido && (
                      <div className="pl-1 pb-2 space-y-2 border-l-2 border-purple-300 dark:border-purple-700 ml-2 pl-3">
                        <div className="flex items-center gap-2">
                          <label className="text-xs text-gray-600 dark:text-gray-400 whitespace-nowrap">
                            Mínimo de productos distintos:
                          </label>
                          <input
                            type="number"
                            inputMode="numeric"
                            min="2"
                            step="1"
                            value={escala.minProductosDistintos}
                            onChange={e => actualizarEscala(index, { minProductosDistintos: e.target.value })}
                            className="w-16 px-2 py-1 border rounded text-xs text-center dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                          />
                        </div>

                        <div>
                          <p className="text-xs text-gray-500 dark:text-gray-400 mb-1">
                            Cantidad mínima por producto (solo los productos marcados cuentan hacia la combinación):
                          </p>
                          {productosDelGrupo.length === 0 ? (
                            <p className="text-xs text-gray-400 italic">Primero agregá productos al grupo.</p>
                          ) : (
                            <div className="space-y-1 max-h-40 overflow-y-auto border dark:border-gray-600 rounded p-1">
                              {productosDelGrupo.map(p => (
                                <div key={p.id} className="flex items-center justify-between gap-2 text-xs">
                                  <span className="truncate dark:text-gray-200">{p.nombre}</span>
                                  <input
                                    type="number"
                                    inputMode="numeric"
                                    min="1"
                                    step="1"
                                    value={escala.minimosPorProducto[String(p.id)] || ''}
                                    onChange={e => actualizarMinimoProducto(index, String(p.id), e.target.value)}
                                    className="w-16 px-2 py-1 border rounded text-center dark:bg-gray-700 dark:border-gray-600 dark:text-white"
                                    placeholder="Min"
                                  />
                                </div>
                              ))}
                            </div>
                          )}
                        </div>
                      </div>
                    )}

                    {/* Preview humano por escala */}
                    {escala.cantidadMinima && escala.precioUnitario && (
                      <p className="text-xs text-gray-600 dark:text-gray-400 italic px-1">
                        💬 {describirReglaEscala(previewEscala, { nombresProductos: nombresProductos })}
                      </p>
                    )}
                  </div>
                )
              })}
            </div>
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
              {isEditing ? 'Guardar cambios' : 'Crear condicion'}
            </button>
          </div>
        </div>
      </div>
    </div>
  )
}
