/**
 * VistaGruposPrecio
 *
 * Vista admin para gestionar grupos de precios mayoristas por volumen.
 * Muestra lista de grupos con sus productos y escalas de precio.
 */
import React from 'react'
import { Plus, Edit2, Trash2, ToggleLeft, ToggleRight, Package, Tag } from 'lucide-react'
import { formatPrecio } from '../../utils/formatters'
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
          <h1 className="text-2xl font-bold dark:text-white">Precios Mayoristas</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400 mt-1">
            Configura grupos de productos con precios por volumen
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

      {/* Lista de grupos */}
      {grupos.length === 0 ? (
        <div className="text-center py-16 bg-white dark:bg-gray-800 rounded-xl border dark:border-gray-700">
          <Tag className="w-12 h-12 text-gray-300 mx-auto mb-4" />
          <h3 className="text-lg font-medium text-gray-500 dark:text-gray-400">Sin grupos de precio</h3>
          <p className="text-sm text-gray-400 dark:text-gray-500 mt-1">
            Crea un grupo para definir precios mayoristas por volumen
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
          {grupos.map(grupo => (
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
                    .sort((a, b) => a.cantidad_minima - b.cantidad_minima)
                    .map(escala => (
                      <div
                        key={escala.id}
                        className="flex items-center gap-2 px-3 py-1.5 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg"
                      >
                        <span className="text-sm font-medium text-green-700 dark:text-green-300">
                          {escala.cantidad_minima}+ unidades
                        </span>
                        <span className="text-sm font-bold text-green-800 dark:text-green-200">
                          {formatPrecio(Number(escala.precio_unitario))}
                        </span>
                        {escala.etiqueta && (
                          <span className="text-xs px-1.5 py-0.5 bg-green-200 dark:bg-green-800 text-green-700 dark:text-green-200 rounded">
                            {escala.etiqueta}
                          </span>
                        )}
                      </div>
                    ))}
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
