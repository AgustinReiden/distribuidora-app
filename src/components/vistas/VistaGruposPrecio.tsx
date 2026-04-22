/**
 * VistaGruposPrecio
 *
 * Vista admin para gestionar grupos de precios mayoristas por volumen.
 * Muestra lista de grupos con sus productos y escalas de precio.
 */
import React, { useMemo, useState } from 'react'
import { Plus, Edit2, Trash2, ToggleLeft, ToggleRight, Package, Tag, Search, Layers } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
import { describirReglaEscala } from '../../utils/describirReglaEscala'
import type { EscalaPrecio } from '../../utils/precioMayorista'
import type { GrupoPrecioConDetalles, ProductoDB } from '../../types'

export interface VistaGruposPrecioProps {
  grupos: GrupoPrecioConDetalles[]
  productos: ProductoDB[]
  loading: boolean
  onNuevoGrupo: () => void
  onEditarGrupo: (grupo: GrupoPrecioConDetalles) => void
  onEliminarGrupo: (id: string) => void
  onToggleActivo: (grupo: GrupoPrecioConDetalles) => void
}

export default function VistaGruposPrecio({
  grupos,
  productos,
  loading,
  onNuevoGrupo,
  onEditarGrupo,
  onEliminarGrupo,
  onToggleActivo,
}: VistaGruposPrecioProps): React.ReactElement {
  const getProductoNombre = (productoId: string): string => {
    const prod = productos.find(p => String(p.id) === String(productoId))
    return prod?.nombre || `Producto #${productoId}`
  }

  const nombresProductos = useMemo(() => {
    const map: Record<string, string> = {}
    for (const p of productos) map[String(p.id)] = p.nombre
    return map
  }, [productos])

  const [busqueda, setBusqueda] = useState('')
  const [mostrarInactivos, setMostrarInactivos] = useState(false)

  const gruposFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase()
    return grupos.filter(g => {
      if (!mostrarInactivos && g.activo === false) return false
      if (!q) return true
      if (g.nombre.toLowerCase().includes(q)) return true
      if ((g.descripcion || '').toLowerCase().includes(q)) return true
      return g.productos.some(gpp => getProductoNombre(gpp.producto_id).toLowerCase().includes(q))
    })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [grupos, busqueda, mostrarInactivos, nombresProductos])

  if (loading) {
    return (
      <div className="flex items-center justify-center py-20">
        <div className="w-8 h-8 border-4 border-blue-600 border-t-transparent rounded-full animate-spin" />
      </div>
    )
  }

  return (
    <div className="space-y-6">
      {/* Header */}
      <div className="flex justify-between items-center">
        <div>
          <h1 className="text-2xl font-bold dark:text-white">Condiciones Mayoristas</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
            Configura precios por volumen y cantidades minimas de pedido
          </p>
        </div>
        <button
          onClick={onNuevoGrupo}
          className="flex items-center gap-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
        >
          <Plus className="w-4 h-4" />
          Nuevo Grupo
        </button>
      </div>

      {/* Buscador + filtro */}
      {grupos.length > 0 && (
        <div className="bg-white dark:bg-gray-800 rounded-lg p-3 border dark:border-gray-700 flex items-center gap-3 flex-wrap">
          <div className="relative flex-1 min-w-[220px]">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-4 h-4" />
            <input
              type="text"
              value={busqueda}
              onChange={e => setBusqueda(e.target.value)}
              placeholder="Buscar por grupo, descripción o producto..."
              className="w-full pl-9 pr-3 py-2 border rounded-lg text-sm dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            />
          </div>
          <label className="flex items-center gap-1.5 text-sm text-gray-600 dark:text-gray-300 cursor-pointer">
            <input
              type="checkbox"
              checked={mostrarInactivos}
              onChange={e => setMostrarInactivos(e.target.checked)}
              className="rounded"
            />
            Mostrar inactivos
          </label>
          <span className="text-xs text-gray-500 dark:text-gray-400">
            {gruposFiltrados.length} de {grupos.length}
          </span>
        </div>
      )}

      {/* Lista de grupos */}
      {grupos.length === 0 ? (
        <div className="text-center py-16 bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700">
          <Tag className="w-12 h-12 text-gray-300 mx-auto mb-4" />
          <h3 className="text-lg font-medium text-gray-500 dark:text-gray-400">Sin condiciones mayoristas</h3>
          <p className="text-sm text-gray-400 dark:text-gray-500 mt-1">
            Crea una condicion para definir precios y cantidades minimas
          </p>
          <button
            onClick={onNuevoGrupo}
            className="mt-4 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 text-sm"
          >
            Crear primer grupo
          </button>
        </div>
      ) : (
        <div className="grid gap-4">
          {gruposFiltrados.length === 0 ? (
            <div className="text-center py-8 text-sm text-gray-500 dark:text-gray-400">
              No hay grupos que coincidan con la búsqueda.
            </div>
          ) : null}
          {gruposFiltrados.map(grupo => (
            <div
              key={grupo.id}
              className={`bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700 p-5 ${
                grupo.activo === false ? 'opacity-60' : ''
              }`}
            >
              {/* Encabezado del grupo */}
              <div className="flex justify-between items-start mb-4">
                <div className="flex-1">
                  <div className="flex items-center gap-2">
                    <h3 className="text-lg font-semibold dark:text-white">{grupo.nombre}</h3>
                    {grupo.activo === false && (
                      <span className="text-xs px-2 py-0.5 bg-gray-200 dark:bg-gray-600 text-gray-600 dark:text-gray-300 rounded-full">
                        Inactivo
                      </span>
                    )}
                  </div>
                  {grupo.descripcion && (
                    <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">{grupo.descripcion}</p>
                  )}
                </div>
                <div className="flex items-center gap-1">
                  <button
                    onClick={() => onToggleActivo(grupo)}
                    className="p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
                    title={grupo.activo !== false ? 'Desactivar' : 'Activar'}
                  >
                    {grupo.activo !== false ? (
                      <ToggleRight className="w-5 h-5 text-green-600" />
                    ) : (
                      <ToggleLeft className="w-5 h-5 text-gray-400" />
                    )}
                  </button>
                  <button
                    onClick={() => onEditarGrupo(grupo)}
                    className="p-2 rounded-lg hover:bg-gray-100 dark:hover:bg-gray-700 transition-colors"
                    title="Editar"
                  >
                    <Edit2 className="w-4 h-4 text-blue-600" />
                  </button>
                  <button
                    onClick={() => onEliminarGrupo(grupo.id)}
                    className="p-2 rounded-lg hover:bg-red-50 dark:hover:bg-red-900/20 transition-colors"
                    title="Eliminar"
                  >
                    <Trash2 className="w-4 h-4 text-red-500" />
                  </button>
                </div>
              </div>

              {/* Productos del grupo */}
              <div className="mb-3">
                <div className="flex items-center gap-1 text-sm font-medium text-gray-600 dark:text-gray-300 mb-2">
                  <Package className="w-4 h-4" />
                  <span>Productos ({grupo.productos.length})</span>
                </div>
                <div className="flex flex-wrap gap-2">
                  {grupo.productos.map(gpp => (
                    <span
                      key={gpp.id}
                      className="text-xs px-2.5 py-1 bg-blue-50 dark:bg-blue-900/20 text-blue-700 dark:text-blue-300 rounded-full"
                    >
                      {getProductoNombre(gpp.producto_id)}
                      {gpp.cantidad_minima_pedido && gpp.cantidad_minima_pedido > 0 && (
                        <span className="ml-1 text-amber-600 dark:text-amber-400 font-medium">
                          (min {gpp.cantidad_minima_pedido})
                        </span>
                      )}
                    </span>
                  ))}
                  {grupo.productos.length === 0 && (
                    <span className="text-xs text-gray-400">Sin productos asignados</span>
                  )}
                </div>
              </div>

              {/* Escalas de precio */}
              <div>
                <div className="flex items-center gap-1 text-sm font-medium text-gray-600 dark:text-gray-300 mb-2">
                  <Tag className="w-4 h-4" />
                  <span>Escalas de precio</span>
                </div>
                <div className="flex flex-wrap gap-2">
                  {grupo.escalas
                    .slice()
                    .sort((a, b) => a.cantidad_minima - b.cantidad_minima)
                    .map(escala => {
                      const minimosRows = grupo.escalaMinimos?.[String(escala.id)] || []
                      const minimosMap = new Map<string, number>()
                      for (const m of minimosRows) {
                        minimosMap.set(String(m.producto_id), Number(m.cantidad_minima_por_item))
                      }
                      const escalaTipada: EscalaPrecio = {
                        cantidadMinima: escala.cantidad_minima,
                        precioUnitario: Number(escala.precio_unitario),
                        etiqueta: escala.etiqueta || null,
                        minProductosDistintos: escala.min_productos_distintos ?? 1,
                        minimosPorProducto: minimosMap,
                      }
                      const esCombinada = minimosMap.size > 0 || (escala.min_productos_distintos ?? 1) > 1
                      const descripcion = describirReglaEscala(escalaTipada, { nombresProductos })
                      const claseCombinada = esCombinada
                        ? 'bg-purple-50 dark:bg-purple-900/20 border-purple-200 dark:border-purple-800'
                        : 'bg-green-50 dark:bg-green-900/20 border-green-200 dark:border-green-800'
                      const colorTexto = esCombinada
                        ? 'text-purple-700 dark:text-purple-300'
                        : 'text-green-700 dark:text-green-300'
                      const colorPrecio = esCombinada
                        ? 'text-purple-800 dark:text-purple-200'
                        : 'text-green-800 dark:text-green-200'
                      return (
                        <div
                          key={escala.id}
                          className={`flex items-center gap-2 px-3 py-1.5 border rounded-lg ${claseCombinada}`}
                          title={descripcion}
                        >
                          {esCombinada && (
                            <Layers className="w-3.5 h-3.5 text-purple-600 dark:text-purple-300" />
                          )}
                          <span className={`text-sm font-medium ${colorTexto}`}>
                            {escala.cantidad_minima}+ unidades
                          </span>
                          <span className={`text-sm font-bold ${colorPrecio}`}>
                            {formatPrecio(Number(escala.precio_unitario))}
                          </span>
                          {escala.etiqueta && (
                            <span className={`text-xs px-1.5 py-0.5 rounded ${
                              esCombinada
                                ? 'bg-purple-200 dark:bg-purple-800 text-purple-700 dark:text-purple-200'
                                : 'bg-green-200 dark:bg-green-800 text-green-700 dark:text-green-200'
                            }`}>
                              {escala.etiqueta}
                            </span>
                          )}
                        </div>
                      )
                    })}
                  {grupo.escalas.length === 0 && (
                    <span className="text-xs text-gray-400">Sin escalas definidas</span>
                  )}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  )
}
