import React, { useState } from 'react'
import { X, Package, Calendar, User, FileText, TrendingDown, Filter } from 'lucide-react'

export default function ModalHistorialMermas({ mermas = [], productos = [], usuarios = [], onClose }) {
  const [filtroProducto, setFiltroProducto] = useState('')
  const [filtroMotivo, setFiltroMotivo] = useState('')

  const mermasFiltradas = mermas.filter(m => {
    if (filtroProducto && m.producto_id !== filtroProducto) return false
    if (filtroMotivo && m.motivo !== filtroMotivo) return false
    return true
  })

  const getProductoNombre = (productoId) => {
    const producto = productos.find(p => p.id === productoId)
    return producto?.nombre || 'Producto desconocido'
  }

  const getUsuarioNombre = (usuarioId) => {
    const usuario = usuarios.find(u => u.id === usuarioId)
    return usuario?.nombre || 'Usuario desconocido'
  }

  const getMotivoEmoji = (motivo) => {
    const emojis = {
      rotura: '💔',
      vencimiento: '📅',
      robo: '🚨',
      decomiso: '⚠️',
      devolucion: '↩️',
      error_inventario: '📋',
      muestra: '🎁',
      otro: '📝'
    }
    return emojis[motivo] || '📦'
  }

  const getMotivoLabel = (motivo) => {
    const labels = {
      rotura: 'Rotura',
      vencimiento: 'Vencimiento',
      robo: 'Robo/Hurto',
      decomiso: 'Decomiso',
      devolucion: 'Devolución',
      error_inventario: 'Error inventario',
      muestra: 'Muestra',
      otro: 'Otro'
    }
    return labels[motivo] || motivo
  }

  // Calcular totales
  const totalUnidades = mermasFiltradas.reduce((sum, m) => sum + m.cantidad, 0)
  const motivosUnicos = [...new Set(mermas.map(m => m.motivo))]

  return (
    <div className="fixed inset-0 bg-black/50 flex items-center justify-center z-50 p-4">
      <div className="bg-white dark:bg-gray-800 rounded-xl shadow-xl w-full max-w-3xl max-h-[90vh] flex flex-col">
        {/* Header */}
        <div className="flex items-center justify-between p-4 border-b dark:border-gray-700">
          <div className="flex items-center gap-2">
            <div className="p-2 bg-red-100 dark:bg-red-900/30 rounded-lg">
              <TrendingDown className="w-5 h-5 text-red-600" />
            </div>
            <div>
              <h2 className="text-lg font-semibold text-gray-800 dark:text-white">Historial de Mermas</h2>
              <p className="text-sm text-gray-500">Registro de bajas de stock</p>
            </div>
          </div>
          <button onClick={onClose} className="p-2 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
            <X className="w-5 h-5" />
          </button>
        </div>

        {/* Resumen */}
        <div className="p-4 bg-gray-50 dark:bg-gray-900 border-b dark:border-gray-700">
          <div className="grid grid-cols-3 gap-4">
            <div className="text-center">
              <p className="text-2xl font-bold text-red-600">{mermasFiltradas.length}</p>
              <p className="text-xs text-gray-500">Registros</p>
            </div>
            <div className="text-center">
              <p className="text-2xl font-bold text-red-600">{totalUnidades}</p>
              <p className="text-xs text-gray-500">Unidades perdidas</p>
            </div>
            <div className="text-center">
              <p className="text-2xl font-bold text-gray-600">{motivosUnicos.length}</p>
              <p className="text-xs text-gray-500">Motivos diferentes</p>
            </div>
          </div>
        </div>

        {/* Filtros */}
        <div className="p-4 border-b dark:border-gray-700 flex gap-4">
          <div className="flex-1">
            <label className="block text-xs font-medium text-gray-500 mb-1">Filtrar por producto</label>
            <select
              value={filtroProducto}
              onChange={e => setFiltroProducto(e.target.value)}
              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg text-sm dark:bg-gray-700"
            >
              <option value="">Todos los productos</option>
              {productos.map(p => (
                <option key={p.id} value={p.id}>{p.nombre}</option>
              ))}
            </select>
          </div>
          <div className="flex-1">
            <label className="block text-xs font-medium text-gray-500 mb-1">Filtrar por motivo</label>
            <select
              value={filtroMotivo}
              onChange={e => setFiltroMotivo(e.target.value)}
              className="w-full px-3 py-2 border dark:border-gray-600 rounded-lg text-sm dark:bg-gray-700"
            >
              <option value="">Todos los motivos</option>
              {motivosUnicos.map(m => (
                <option key={m} value={m}>{getMotivoLabel(m)}</option>
              ))}
            </select>
          </div>
        </div>

        {/* Lista de mermas */}
        <div className="flex-1 overflow-y-auto p-4">
          {mermasFiltradas.length === 0 ? (
            <div className="text-center py-8 text-gray-500">
              <Package className="w-12 h-12 mx-auto mb-3 opacity-50" />
              <p>No hay mermas registradas</p>
            </div>
          ) : (
            <div className="space-y-3">
              {mermasFiltradas.map(merma => (
                <div
                  key={merma.id}
                  className="p-4 bg-gray-50 dark:bg-gray-900 rounded-lg border dark:border-gray-700"
                >
                  <div className="flex items-start justify-between">
                    <div className="flex items-start gap-3">
                      <div className="text-2xl">{getMotivoEmoji(merma.motivo)}</div>
                      <div>
                        <p className="font-medium text-gray-800 dark:text-white">
                          {getProductoNombre(merma.producto_id)}
                        </p>
                        <div className="flex items-center gap-3 mt-1 text-sm text-gray-500">
                          <span className="flex items-center gap-1">
                            <Calendar className="w-3 h-3" />
                            {new Date(merma.created_at).toLocaleDateString('es-AR')}
                          </span>
                          <span className="flex items-center gap-1">
                            <User className="w-3 h-3" />
                            {getUsuarioNombre(merma.usuario_id)}
                          </span>
                        </div>
                        {merma.observaciones && (
                          <p className="mt-2 text-sm text-gray-600 dark:text-gray-400 flex items-start gap-1">
                            <FileText className="w-3 h-3 mt-0.5 flex-shrink-0" />
                            {merma.observaciones}
                          </p>
                        )}
                      </div>
                    </div>
                    <div className="text-right">
                      <p className="text-lg font-bold text-red-600">-{merma.cantidad}</p>
                      <p className="text-xs text-gray-500">{getMotivoLabel(merma.motivo)}</p>
                      <p className="text-xs text-gray-400 mt-1">
                        {merma.stock_anterior} → {merma.stock_nuevo}
                      </p>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="p-4 border-t dark:border-gray-700">
          <button
            onClick={onClose}
            className="w-full px-4 py-2 bg-gray-100 dark:bg-gray-700 hover:bg-gray-200 dark:hover:bg-gray-600 rounded-lg transition-colors"
          >
            Cerrar
          </button>
        </div>
      </div>
    </div>
  )
}
