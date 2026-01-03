import React, { useState, useMemo } from 'react';
import { Package, Plus, Edit2, Trash2, Search, AlertTriangle } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';

export default function VistaProductos({
  productos,
  loading,
  isAdmin,
  onNuevoProducto,
  onEditarProducto,
  onEliminarProducto
}) {
  const [busqueda, setBusqueda] = useState('');
  const [filtroCategoria, setFiltroCategoria] = useState('todas');
  const [mostrarSoloStockBajo, setMostrarSoloStockBajo] = useState(false);

  // Obtener categorías únicas
  const categorias = useMemo(() => {
    const catsSet = new Set(productos.map(p => p.categoria).filter(Boolean));
    return ['todas', ...Array.from(catsSet).sort()];
  }, [productos]);

  // Productos con stock bajo
  const productosStockBajo = useMemo(() => {
    return productos.filter(p => p.stock < (p.stock_minimo || 10));
  }, [productos]);

  // Filtrar productos
  const productosFiltrados = useMemo(() => {
    return productos.filter(p => {
      const matchBusqueda = !busqueda ||
        p.nombre?.toLowerCase().includes(busqueda.toLowerCase()) ||
        p.codigo?.toLowerCase().includes(busqueda.toLowerCase());

      const matchCategoria = filtroCategoria === 'todas' || p.categoria === filtroCategoria;

      const matchStockBajo = !mostrarSoloStockBajo || p.stock < (p.stock_minimo || 10);

      return matchBusqueda && matchCategoria && matchStockBajo;
    });
  }, [productos, busqueda, filtroCategoria, mostrarSoloStockBajo]);

  const getStockColor = (producto) => {
    const stockMinimo = producto.stock_minimo || 10;
    if (producto.stock === 0) return 'bg-red-100 text-red-700';
    if (producto.stock < stockMinimo) return 'bg-yellow-100 text-yellow-700';
    if (producto.stock < stockMinimo * 2) return 'bg-orange-100 text-orange-700';
    return 'bg-green-100 text-green-700';
  };

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800">Productos</h1>
          <p className="text-sm text-gray-500">{productos.length} productos en catálogo</p>
        </div>
        {isAdmin && (
          <button
            onClick={onNuevoProducto}
            className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
          >
            <Plus className="w-5 h-5" />
            <span>Nuevo Producto</span>
          </button>
        )}
      </div>

      {/* Alerta de stock bajo */}
      {productosStockBajo.length > 0 && (
        <div className="bg-red-50 border border-red-200 rounded-lg p-4">
          <div className="flex items-start space-x-3">
            <AlertTriangle className="w-5 h-5 text-red-600 flex-shrink-0 mt-0.5" />
            <div className="flex-1">
              <p className="text-red-700 font-medium">
                {productosStockBajo.length} producto(s) con stock bajo
              </p>
              <div className="mt-2 flex flex-wrap gap-2">
                {productosStockBajo.slice(0, 5).map(p => (
                  <span key={p.id} className="text-xs px-2 py-1 bg-red-100 text-red-700 rounded-full">
                    {p.nombre} ({p.stock})
                  </span>
                ))}
                {productosStockBajo.length > 5 && (
                  <span className="text-xs px-2 py-1 bg-red-100 text-red-700 rounded-full">
                    +{productosStockBajo.length - 5} más
                  </span>
                )}
              </div>
              <button
                onClick={() => setMostrarSoloStockBajo(!mostrarSoloStockBajo)}
                className="mt-2 text-sm text-red-600 hover:underline"
              >
                {mostrarSoloStockBajo ? 'Mostrar todos' : 'Ver solo productos con stock bajo'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Filtros */}
      <div className="flex flex-col sm:flex-row gap-4">
        <div className="relative flex-1">
          <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5" />
          <input
            type="text"
            value={busqueda}
            onChange={e => setBusqueda(e.target.value)}
            className="w-full pl-10 pr-3 py-2 border rounded-lg focus:ring-2 focus:ring-blue-500"
            placeholder="Buscar por nombre o código..."
          />
        </div>
        {categorias.length > 1 && (
          <div className="flex flex-wrap gap-2">
            {categorias.map(cat => (
              <button
                key={cat}
                onClick={() => setFiltroCategoria(cat)}
                className={`px-3 py-2 rounded-lg text-sm font-medium transition-colors ${
                  filtroCategoria === cat
                    ? 'bg-blue-600 text-white'
                    : 'bg-gray-100 text-gray-700 hover:bg-gray-200'
                }`}
              >
                {cat === 'todas' ? 'Todas' : cat}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Contador de resultados */}
      {(busqueda || filtroCategoria !== 'todas' || mostrarSoloStockBajo) && (
        <div className="text-sm text-gray-600">
          Mostrando {productosFiltrados.length} de {productos.length} productos
        </div>
      )}

      {/* Tabla de productos */}
      {loading ? <LoadingSpinner /> : productosFiltrados.length === 0 ? (
        <div className="text-center py-12 text-gray-500">
          <Package className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>{busqueda || filtroCategoria !== 'todas' ? 'No se encontraron productos' : 'No hay productos'}</p>
        </div>
      ) : (
        <div className="bg-white border rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700">Código</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700">Producto</th>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700">Categoría</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">Precio</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">Stock</th>
                {isAdmin && <th className="px-4 py-3 text-right text-sm font-medium text-gray-700">Acciones</th>}
              </tr>
            </thead>
            <tbody className="divide-y">
              {productosFiltrados.map(producto => (
                <tr key={producto.id} className="hover:bg-gray-50 transition-colors">
                  <td className="px-4 py-3 text-gray-500 text-sm font-mono">
                    {producto.codigo || '-'}
                  </td>
                  <td className="px-4 py-3">
                    <span className="font-medium text-gray-800">{producto.nombre}</span>
                  </td>
                  <td className="px-4 py-3">
                    <span className={producto.categoria ? 'px-2 py-1 bg-gray-100 rounded-full text-sm text-gray-700' : 'text-gray-400'}>
                      {producto.categoria || 'Sin categoría'}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-right font-semibold text-blue-600">
                    {formatPrecio(producto.precio)}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span className={`px-2 py-1 rounded-full text-sm font-medium ${getStockColor(producto)}`}>
                      {producto.stock}
                    </span>
                  </td>
                  {isAdmin && (
                    <td className="px-4 py-3 text-right">
                      <div className="flex justify-end space-x-1">
                        <button
                          onClick={() => onEditarProducto(producto)}
                          className="p-2 text-blue-500 hover:bg-blue-50 rounded-lg transition-colors"
                          title="Editar"
                        >
                          <Edit2 className="w-4 h-4" />
                        </button>
                        <button
                          onClick={() => onEliminarProducto(producto.id)}
                          className="p-2 text-red-500 hover:bg-red-50 rounded-lg transition-colors"
                          title="Eliminar"
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </div>
                    </td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
