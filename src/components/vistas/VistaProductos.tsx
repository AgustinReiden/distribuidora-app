import { useState, useMemo } from 'react';
import type { ChangeEvent } from 'react';
import { Package, Plus, Edit2, Trash2, Search, AlertTriangle, Minus, TrendingDown, FileSpreadsheet } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';
import type { ProductoDB, ProveedorDBExtended } from '../../types';

// =============================================================================
// INTERFACES DE PROPS
// =============================================================================

export interface VistaProductosProps {
  productos: ProductoDB[];
  proveedores?: ProveedorDBExtended[];
  loading: boolean;
  isAdmin: boolean;
  onNuevoProducto: () => void;
  onEditarProducto: (producto: ProductoDB) => void;
  onEliminarProducto: (id: string) => void;
  onBajaStock?: (producto: ProductoDB) => void;
  onVerHistorialMermas?: () => void;
  onImportarPrecios?: () => void;
}

export default function VistaProductos({
  productos,
  proveedores = [],
  loading,
  isAdmin,
  onNuevoProducto,
  onEditarProducto,
  onEliminarProducto,
  onBajaStock,
  onVerHistorialMermas,
  onImportarPrecios
}: VistaProductosProps) {
  const [busqueda, setBusqueda] = useState<string>('');
  const [filtroCategoria, setFiltroCategoria] = useState<string>('todas');
  const [mostrarSoloStockBajo, setMostrarSoloStockBajo] = useState<boolean>(false);

  // Obtener categorías únicas
  const categorias = useMemo((): string[] => {
    const catsSet = new Set<string>(productos.map(p => p.categoria).filter((c): c is string => Boolean(c)));
    return ['todas', ...Array.from(catsSet).sort()];
  }, [productos]);

  // Productos con stock bajo
  const productosStockBajo = useMemo((): ProductoDB[] => {
    return productos.filter((p: ProductoDB) => p.stock < (p.stock_minimo || 10));
  }, [productos]);

  // Filtrar productos
  const productosFiltrados = useMemo((): ProductoDB[] => {
    return productos.filter((p: ProductoDB) => {
      const matchBusqueda = !busqueda ||
        p.nombre?.toLowerCase().includes(busqueda.toLowerCase()) ||
        p.codigo?.toLowerCase().includes(busqueda.toLowerCase());

      const matchCategoria = filtroCategoria === 'todas' || p.categoria === filtroCategoria;

      const matchStockBajo = !mostrarSoloStockBajo || p.stock < (p.stock_minimo || 10);

      return matchBusqueda && matchCategoria && matchStockBajo;
    });
  }, [productos, busqueda, filtroCategoria, mostrarSoloStockBajo]);

  // Mapa de proveedores para lookup rápido
  const proveedoresMap = useMemo(() => {
    return new Map(proveedores.map(p => [p.id, p.nombre]))
  }, [proveedores])

  const getStockColor = (producto: ProductoDB): string => {
    const stockMinimo = producto.stock_minimo || 10;
    if (producto.stock === 0) return 'bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400';
    if (producto.stock < stockMinimo) return 'bg-yellow-100 dark:bg-yellow-900/30 text-yellow-700 dark:text-yellow-400';
    if (producto.stock < stockMinimo * 2) return 'bg-orange-100 dark:bg-orange-900/30 text-orange-700 dark:text-orange-400';
    return 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400';
  };

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row justify-between items-start sm:items-center gap-4">
        <div>
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Productos</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">{productos.length} productos en catálogo</p>
        </div>
        {isAdmin && (
          <div className="flex gap-2">
            {onVerHistorialMermas && (
              <button
                onClick={onVerHistorialMermas}
                className="flex items-center space-x-2 px-4 py-2 bg-red-100 dark:bg-red-900/30 text-red-700 dark:text-red-400 rounded-lg hover:bg-red-200 dark:hover:bg-red-900/50 transition-colors"
              >
                <TrendingDown className="w-5 h-5" />
                <span>Historial Mermas</span>
              </button>
            )}
            {onImportarPrecios && (
              <button
                onClick={onImportarPrecios}
                className="flex items-center space-x-2 px-4 py-2 bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-400 rounded-lg hover:bg-green-200 dark:hover:bg-green-900/50 transition-colors"
              >
                <FileSpreadsheet className="w-5 h-5" />
                <span>Importar Precios</span>
              </button>
            )}
            <button
              onClick={onNuevoProducto}
              className="flex items-center space-x-2 px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 transition-colors"
            >
              <Plus className="w-5 h-5" />
              <span>Nuevo Producto</span>
            </button>
          </div>
        )}
      </div>

      {/* Alerta de stock bajo */}
      {productosStockBajo.length > 0 && (
        <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4" role="alert">
          <div className="flex items-start space-x-3">
            <AlertTriangle className="w-5 h-5 text-red-600 dark:text-red-400 flex-shrink-0 mt-0.5" aria-hidden="true" />
            <div className="flex-1">
              <p className="text-red-700 dark:text-red-300 font-medium">
                {productosStockBajo.length} producto(s) con stock bajo
              </p>
              <div className="mt-2 flex flex-wrap gap-2">
                {productosStockBajo.slice(0, 5).map(p => (
                  <span key={p.id} className="text-xs px-2 py-1 bg-red-100 dark:bg-red-900/40 text-red-700 dark:text-red-300 rounded-full">
                    {p.nombre} ({p.stock})
                  </span>
                ))}
                {productosStockBajo.length > 5 && (
                  <span className="text-xs px-2 py-1 bg-red-100 dark:bg-red-900/40 text-red-700 dark:text-red-300 rounded-full">
                    +{productosStockBajo.length - 5} más
                  </span>
                )}
              </div>
              <button
                onClick={() => setMostrarSoloStockBajo(!mostrarSoloStockBajo)}
                className="mt-2 text-sm text-red-600 dark:text-red-400 hover:underline"
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
          <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 dark:text-gray-500 w-5 h-5" aria-hidden="true" />
          <input
            type="text"
            value={busqueda}
            onChange={(e: ChangeEvent<HTMLInputElement>) => setBusqueda(e.target.value)}
            className="w-full pl-10 pr-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-800 text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500"
            placeholder="Buscar por nombre o código..."
            aria-label="Buscar productos"
          />
        </div>
        {categorias.length > 1 && (
          <div className="flex flex-wrap gap-2" role="group" aria-label="Filtrar por categoría">
            {categorias.map(cat => (
              <button
                key={cat}
                onClick={() => setFiltroCategoria(cat)}
                className={`px-3 py-2 rounded-lg text-sm font-medium transition-colors ${
                  filtroCategoria === cat
                    ? 'bg-blue-600 text-white'
                    : 'bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
                }`}
                aria-pressed={filtroCategoria === cat}
              >
                {cat === 'todas' ? 'Todas' : cat}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Contador de resultados */}
      {(busqueda || filtroCategoria !== 'todas' || mostrarSoloStockBajo) && (
        <div className="text-sm text-gray-600 dark:text-gray-400" aria-live="polite">
          Mostrando {productosFiltrados.length} de {productos.length} productos
        </div>
      )}

      {/* Tabla de productos */}
      {loading ? <LoadingSpinner /> : productosFiltrados.length === 0 ? (
        <div className="text-center py-12 text-gray-500 dark:text-gray-400">
          <Package className="w-12 h-12 mx-auto mb-3 opacity-50" aria-hidden="true" />
          <p>{busqueda || filtroCategoria !== 'todas' ? 'No se encontraron productos' : 'No hay productos'}</p>
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full" role="table">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th scope="col" className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Código</th>
                <th scope="col" className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Producto</th>
                <th scope="col" className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Categoría</th>
                <th scope="col" className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Proveedor</th>
                <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Precio</th>
                <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Stock</th>
                {isAdmin && <th scope="col" className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Acciones</th>}
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {productosFiltrados.map(producto => (
                <tr key={producto.id} className="hover:bg-gray-50 dark:hover:bg-gray-700/50 transition-colors">
                  <td className="px-4 py-3 text-gray-500 dark:text-gray-400 text-sm font-mono">
                    {producto.codigo || '-'}
                  </td>
                  <td className="px-4 py-3">
                    <span className="font-medium text-gray-800 dark:text-white">{producto.nombre}</span>
                  </td>
                  <td className="px-4 py-3">
                    <span className={producto.categoria ? 'px-2 py-1 bg-gray-100 dark:bg-gray-700 rounded-full text-sm text-gray-700 dark:text-gray-300' : 'text-gray-400 dark:text-gray-500'}>
                      {producto.categoria || 'Sin categoría'}
                    </span>
                  </td>
                  <td className="px-4 py-3 text-sm text-gray-600 dark:text-gray-400">
                    {producto.proveedor_id ? (proveedoresMap.get(producto.proveedor_id) || '-') : '-'}
                  </td>
                  <td className="px-4 py-3 text-right font-semibold text-blue-600 dark:text-blue-400">
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
                        {onBajaStock && producto.stock > 0 && (
                          <button
                            onClick={() => onBajaStock(producto)}
                            className="p-2 text-orange-500 hover:bg-orange-50 dark:hover:bg-orange-900/30 rounded-lg transition-colors"
                            title="Baja de stock"
                            aria-label={`Baja de stock ${producto.nombre}`}
                          >
                            <Minus className="w-4 h-4" aria-hidden="true" />
                          </button>
                        )}
                        <button
                          onClick={() => onEditarProducto(producto)}
                          className="p-2 text-blue-500 hover:bg-blue-50 dark:hover:bg-blue-900/30 rounded-lg transition-colors"
                          title="Editar"
                          aria-label={`Editar ${producto.nombre}`}
                        >
                          <Edit2 className="w-4 h-4" aria-hidden="true" />
                        </button>
                        <button
                          onClick={() => onEliminarProducto(producto.id)}
                          className="p-2 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/30 rounded-lg transition-colors"
                          title="Eliminar"
                          aria-label={`Eliminar ${producto.nombre}`}
                        >
                          <Trash2 className="w-4 h-4" aria-hidden="true" />
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
