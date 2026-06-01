import { useState, useMemo, useRef } from 'react';
import type { ChangeEvent } from 'react';
import {
  Package, Edit2, Trash2, Search, Minus,
  ChevronLeft, ChevronRight,
} from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import LoadingSpinner from '../layout/LoadingSpinner';
import Paginacion from '../layout/Paginacion';
import ProductosViewHeader from '../productos/ProductosViewHeader';
import ProductoToolbar from '../productos/ProductoToolbar';
import { cn } from '../../lib/utils';
import type { ProductoDB, ProveedorDBExtended } from '../../types';

const ITEMS_PER_PAGE = 20;

// =============================================================================
// INTERFACES DE PROPS
// =============================================================================

export interface VistaProductosProps {
  productos: ProductoDB[];
  productosStockBajo: ProductoDB[];
  proveedores?: ProveedorDBExtended[];
  loading: boolean;
  isAdmin: boolean;
  /** admin o encargado: habilita stock bajo + control de stock (Excel). */
  puedeControlarStock?: boolean;
  onNuevoProducto: () => void;
  onEditarProducto: (producto: ProductoDB) => void;
  onEliminarProducto: (id: string) => void;
  onBajaStock?: (producto: ProductoDB) => void;
  onVerHistorialMermas?: () => void;
  onActualizacionMasivaPrecios?: () => void;
  onGestionarCategorias?: () => void;
  onCambioProducto?: () => void;
  onControlStock?: () => void;
  onAbrirStockBajo?: () => void;
}

export default function VistaProductos({
  productos,
  productosStockBajo,
  proveedores = [],
  loading,
  isAdmin,
  puedeControlarStock = false,
  onNuevoProducto,
  onEditarProducto,
  onEliminarProducto,
  onBajaStock,
  onVerHistorialMermas,
  onActualizacionMasivaPrecios,
  onGestionarCategorias,
  onCambioProducto,
  onControlStock,
  onAbrirStockBajo,
}: VistaProductosProps) {
  const [busqueda, setBusqueda] = useState<string>('');
  const [filtroCategoria, setFiltroCategoria] = useState<string>('todas');
  const [mostrarSoloStockBajo, setMostrarSoloStockBajo] = useState<boolean>(false);
  const [paginaActual, setPaginaActual] = useState(1);
  const categoriasScrollRef = useRef<HTMLDivElement>(null);

  // Obtener categorías únicas
  const categorias = useMemo((): string[] => {
    const catsSet = new Set<string>(productos.map(p => p.categoria).filter((c): c is string => Boolean(c)));
    return ['todas', ...Array.from(catsSet).sort()];
  }, [productos]);

  // Filtrar productos
  const productosFiltrados = useMemo((): ProductoDB[] => {
    return productos.filter((p: ProductoDB) => {
      const matchBusqueda = !busqueda
        || p.nombre?.toLowerCase().includes(busqueda.toLowerCase())
        || p.codigo?.toLowerCase().includes(busqueda.toLowerCase());

      const matchCategoria = filtroCategoria === 'todas' || p.categoria === filtroCategoria;

      const matchStockBajo = !mostrarSoloStockBajo || p.stock < (p.stock_minimo || 10);

      return matchBusqueda && matchCategoria && matchStockBajo;
    });
  }, [productos, busqueda, filtroCategoria, mostrarSoloStockBajo]);

  // Pagination
  const totalPaginas = Math.ceil(productosFiltrados.length / ITEMS_PER_PAGE);
  const productosPaginados = useMemo(() => {
    const inicio = (paginaActual - 1) * ITEMS_PER_PAGE;
    return productosFiltrados.slice(inicio, inicio + ITEMS_PER_PAGE);
  }, [productosFiltrados, paginaActual]);

  const handleBusqueda = (e: ChangeEvent<HTMLInputElement>) => { setBusqueda(e.target.value); setPaginaActual(1); };
  const handleCategoria = (cat: string) => { setFiltroCategoria(cat); setPaginaActual(1); };
  const handleStockBajoToggle = () => { setMostrarSoloStockBajo(!mostrarSoloStockBajo); setPaginaActual(1); };

  const proveedoresMap = useMemo(() => {
    return new Map(proveedores.map(p => [p.id, p.nombre]));
  }, [proveedores]);

  // Color de la pill de stock — alineado con la paleta de Pedidos (rose/amber/orange/emerald).
  const getStockColor = (producto: ProductoDB): string => {
    const stockMinimo = producto.stock_minimo || 10;
    if (producto.stock === 0) return 'bg-rose-100 dark:bg-rose-900/30 text-rose-700 dark:text-rose-300';
    if (producto.stock < stockMinimo) return 'bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-300';
    if (producto.stock < stockMinimo * 2) return 'bg-orange-100 dark:bg-orange-900/30 text-orange-700 dark:text-orange-300';
    return 'bg-emerald-100 dark:bg-emerald-900/30 text-emerald-700 dark:text-emerald-300';
  };

  return (
    <div className="space-y-4">
      {/* Header con título dinámico + toolbar */}
      <ProductosViewHeader
        busqueda={busqueda}
        categoriaSeleccionada={filtroCategoria}
        mostrarSoloStockBajo={mostrarSoloStockBajo}
        totalCount={productosFiltrados.length}
        loading={loading}
        actions={
          <ProductoToolbar
            isAdmin={isAdmin}
            puedeControlarStock={puedeControlarStock}
            productosStockBajoCount={productosStockBajo.length}
            onGestionarCategorias={onGestionarCategorias}
            onCambioProducto={onCambioProducto}
            onActualizacionMasivaPrecios={onActualizacionMasivaPrecios}
            onControlStock={onControlStock}
            onVerHistorialMermas={onVerHistorialMermas}
            onAbrirStockBajo={onAbrirStockBajo}
            onNuevoProducto={onNuevoProducto}
          />
        }
      />

      {/* Búsqueda — full width */}
      <div className="relative w-full">
        <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-stone-400 dark:text-gray-500 w-4 h-4" aria-hidden="true" />
        <input
          type="text"
          value={busqueda}
          onChange={handleBusqueda}
          className="w-full h-10 pl-10 pr-3 rounded-lg border border-stone-200 dark:border-gray-700 bg-white dark:bg-gray-800 text-sm text-stone-700 dark:text-white placeholder:text-stone-400 focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400"
          placeholder="Buscar por nombre o código…"
          aria-label="Buscar productos"
        />
      </div>

      {/* Filtros de categoría — carrusel horizontal con flechas */}
      {categorias.length > 1 && (
        <div className="relative flex items-center gap-2" role="group" aria-label="Filtrar por categoría">
          <button
            type="button"
            onClick={() => categoriasScrollRef.current?.scrollBy({ left: -200, behavior: 'smooth' })}
            className="hidden sm:flex absolute left-0 top-1/2 -translate-y-1/2 z-10 items-center justify-center w-8 h-8 bg-white/95 dark:bg-gray-800 rounded-full shadow-warm border border-stone-200 dark:border-gray-700 hover:bg-stone-50 dark:hover:bg-gray-700"
            aria-label="Scroll categorías a la izquierda"
          >
            <ChevronLeft className="w-4 h-4 text-stone-600 dark:text-gray-300" />
          </button>
          <div
            ref={categoriasScrollRef}
            className="flex gap-1.5 overflow-x-auto scroll-smooth sm:px-10 py-1 scrollbar-hide flex-1"
          >
            {categorias.map(cat => (
              <button
                key={cat}
                onClick={() => handleCategoria(cat)}
                className={cn(
                  'shrink-0 px-3 py-2 rounded-lg text-sm font-medium transition-colors',
                  filtroCategoria === cat
                    ? 'bg-blue-600 text-white shadow-warm'
                    : 'bg-stone-100 dark:bg-gray-700 text-stone-700 dark:text-gray-300 hover:bg-stone-200 dark:hover:bg-gray-600',
                )}
                aria-pressed={filtroCategoria === cat}
              >
                {cat === 'todas' ? 'Todas' : cat}
              </button>
            ))}
          </div>
          <button
            type="button"
            onClick={() => categoriasScrollRef.current?.scrollBy({ left: 200, behavior: 'smooth' })}
            className="hidden sm:flex absolute right-0 top-1/2 -translate-y-1/2 z-10 items-center justify-center w-8 h-8 bg-white/95 dark:bg-gray-800 rounded-full shadow-warm border border-stone-200 dark:border-gray-700 hover:bg-stone-50 dark:hover:bg-gray-700"
            aria-label="Scroll categorías a la derecha"
          >
            <ChevronRight className="w-4 h-4 text-stone-600 dark:text-gray-300" />
          </button>
        </div>
      )}

      {/* Toggle "Ver solo stock bajo" — chip discreto */}
      {productosStockBajo.length > 0 && (
        <div className="flex items-center justify-end">
          <button
            type="button"
            onClick={handleStockBajoToggle}
            className={cn(
              'inline-flex items-center gap-1.5 px-3 py-1.5 rounded-full text-xs font-medium transition-colors',
              mostrarSoloStockBajo
                ? 'bg-amber-100 dark:bg-amber-900/30 text-amber-800 dark:text-amber-200 border border-amber-300 dark:border-amber-700/50'
                : 'bg-white dark:bg-gray-800 text-stone-600 dark:text-gray-300 border border-stone-200 dark:border-gray-700 hover:bg-stone-50 dark:hover:bg-gray-700/50',
            )}
            aria-pressed={mostrarSoloStockBajo}
          >
            <span
              className={cn(
                'inline-block w-1.5 h-1.5 rounded-full',
                mostrarSoloStockBajo ? 'bg-amber-500' : 'bg-stone-300 dark:bg-gray-600',
              )}
              aria-hidden="true"
            />
            {mostrarSoloStockBajo ? 'Mostrando solo stock bajo' : 'Ver solo stock bajo'}
          </button>
        </div>
      )}

      {/* Tabla de productos */}
      {loading ? <LoadingSpinner /> : productosFiltrados.length === 0 ? (
        <div className="text-center py-12 text-stone-500 dark:text-gray-400">
          <Package className="w-12 h-12 mx-auto mb-3 opacity-50" aria-hidden="true" />
          <p>{busqueda || filtroCategoria !== 'todas' ? 'No se encontraron productos' : 'No hay productos'}</p>
        </div>
      ) : (
        <>
          {/* Tabla — desktop */}
          <div className="hidden md:block bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 rounded-xl shadow-warm overflow-hidden">
            <div className="overflow-x-auto">
              <table className="w-full" role="table">
                <thead className="bg-stone-50/70 dark:bg-gray-700/50 border-b border-stone-200 dark:border-gray-700">
                  <tr>
                    <th scope="col" className="px-4 py-3 text-left text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">Código</th>
                    <th scope="col" className="px-4 py-3 text-left text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">Producto</th>
                    <th scope="col" className="px-4 py-3 text-left text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">Categoría</th>
                    <th scope="col" className="px-4 py-3 text-left text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">Proveedor</th>
                    <th scope="col" className="px-4 py-3 text-right text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">Precio</th>
                    <th scope="col" className="px-4 py-3 text-right text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">Stock</th>
                    {isAdmin && <th scope="col" className="px-4 py-3 text-right text-[11px] font-semibold uppercase tracking-wider text-stone-500 dark:text-gray-400">Acciones</th>}
                  </tr>
                </thead>
                <tbody className="divide-y divide-stone-200 dark:divide-gray-700">
                  {productosPaginados.map(producto => (
                    <tr key={producto.id} className="hover:bg-stone-50/70 dark:hover:bg-gray-700/40 transition-colors">
                      <td className="px-4 py-3 text-stone-500 dark:text-gray-400 text-sm font-mono tabular-nums">
                        {producto.codigo || '-'}
                      </td>
                      <td className="px-4 py-3">
                        <span className="font-medium text-stone-800 dark:text-white">{producto.nombre}</span>
                      </td>
                      <td className="px-4 py-3">
                        <span className={producto.categoria ? 'px-2 py-0.5 bg-stone-100 dark:bg-gray-700 rounded-full text-xs text-stone-700 dark:text-gray-300' : 'text-stone-400 dark:text-gray-500 text-xs'}>
                          {producto.categoria || 'Sin categoría'}
                        </span>
                      </td>
                      <td className="px-4 py-3 text-sm text-stone-600 dark:text-gray-400">
                        {producto.proveedor_id ? (proveedoresMap.get(producto.proveedor_id) || '-') : '-'}
                      </td>
                      <td className="px-4 py-3 text-right font-semibold text-blue-700 dark:text-blue-300 tabular-nums">
                        {formatPrecio(producto.precio)}
                      </td>
                      <td className="px-4 py-3 text-right">
                        <span className={`inline-flex items-center justify-center px-2.5 py-0.5 rounded-full text-sm font-semibold tabular-nums ${getStockColor(producto)}`}>
                          {producto.stock}
                        </span>
                      </td>
                      {isAdmin && (
                        <td className="px-4 py-3 text-right">
                          <div className="flex justify-end gap-1.5">
                            {onBajaStock && producto.stock > 0 && (
                              <button
                                onClick={() => onBajaStock(producto)}
                                className="inline-flex items-center gap-1.5 h-8 px-2.5 rounded-md text-xs font-medium bg-orange-50 dark:bg-orange-900/15 text-orange-700 dark:text-orange-300 border border-orange-200/70 dark:border-orange-800/40 hover:bg-orange-100 dark:hover:bg-orange-900/25 hover:border-orange-300 hover:-translate-y-px active:translate-y-0 transition-[transform,background-color,border-color]"
                                title="Registrar baja de stock"
                                aria-label={`Baja de stock ${producto.nombre}`}
                              >
                                <Minus className="w-3.5 h-3.5" aria-hidden="true" />
                                <span>Baja</span>
                              </button>
                            )}
                            <button
                              onClick={() => onEditarProducto(producto)}
                              className="inline-flex items-center gap-1.5 h-8 px-2.5 rounded-md text-xs font-medium bg-blue-50 dark:bg-blue-900/15 text-blue-700 dark:text-blue-300 border border-blue-200/70 dark:border-blue-800/40 hover:bg-blue-100 dark:hover:bg-blue-900/25 hover:border-blue-300 hover:-translate-y-px active:translate-y-0 transition-[transform,background-color,border-color]"
                              title="Editar"
                              aria-label={`Editar ${producto.nombre}`}
                            >
                              <Edit2 className="w-3.5 h-3.5" aria-hidden="true" />
                              <span>Editar</span>
                            </button>
                            <button
                              onClick={() => onEliminarProducto(producto.id)}
                              className="inline-flex items-center gap-1.5 h-8 px-2.5 rounded-md text-xs font-medium bg-rose-50 dark:bg-rose-900/15 text-rose-700 dark:text-rose-300 border border-rose-200/70 dark:border-rose-800/40 hover:bg-rose-100 dark:hover:bg-rose-900/25 hover:border-rose-300 hover:-translate-y-px active:translate-y-0 transition-[transform,background-color,border-color]"
                              title="Eliminar"
                              aria-label={`Eliminar ${producto.nombre}`}
                            >
                              <Trash2 className="w-3.5 h-3.5" aria-hidden="true" />
                              <span>Borrar</span>
                            </button>
                          </div>
                        </td>
                      )}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          {/* Cards — mobile */}
          <div className="grid gap-3 md:hidden">
            {productosPaginados.map(producto => {
              const stockMinimo = producto.stock_minimo || 10;
              const stockBajo = producto.stock < stockMinimo;
              const proveedorNombre = producto.proveedor_id ? proveedoresMap.get(producto.proveedor_id) : null;
              return (
                <div
                  key={producto.id}
                  className="bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 rounded-xl p-4 shadow-warm hover:shadow-warm-md transition-shadow"
                >
                  <div className="flex justify-between items-start gap-3">
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 flex-wrap">
                        {producto.codigo && (
                          <span className="px-1.5 py-0.5 bg-blue-100 dark:bg-blue-900/30 text-blue-700 dark:text-blue-300 rounded text-xs font-mono font-semibold tabular-nums">
                            #{producto.codigo}
                          </span>
                        )}
                        <h3 className="font-semibold text-stone-800 dark:text-white truncate">
                          {producto.nombre}
                        </h3>
                      </div>
                      {producto.categoria && (
                        <p className="text-sm text-stone-600 dark:text-gray-400 mt-1">
                          {producto.categoria}
                        </p>
                      )}
                      {proveedorNombre && (
                        <p className="text-xs text-stone-500 dark:text-gray-500 mt-0.5">
                          {proveedorNombre}
                        </p>
                      )}
                      <div className="flex items-center gap-4 mt-2 text-sm flex-wrap">
                        <span className="text-stone-800 dark:text-gray-200">
                          <span className="text-stone-500 dark:text-gray-400">Precio:</span>{' '}
                          <span className="font-semibold text-blue-700 dark:text-blue-300 tabular-nums">
                            {formatPrecio(producto.precio)}
                          </span>
                        </span>
                        <span
                          className={cn(
                            'tabular-nums',
                            stockBajo
                              ? 'text-rose-600 dark:text-rose-400 font-semibold'
                              : 'text-stone-800 dark:text-gray-200',
                          )}
                        >
                          <span className="text-stone-500 dark:text-gray-400">Stock:</span> {producto.stock}
                        </span>
                      </div>
                    </div>
                  </div>
                  {isAdmin && (
                    <div className="flex items-center gap-1.5 mt-3 pt-3 border-t border-stone-200 dark:border-gray-700">
                      {onBajaStock && producto.stock > 0 && (
                        <button
                          onClick={() => onBajaStock(producto)}
                          className="inline-flex items-center gap-1.5 h-8 px-2.5 rounded-md text-xs font-medium bg-orange-50 text-orange-700 border border-orange-200/70 hover:bg-orange-100 transition-colors"
                          title="Baja de stock"
                          aria-label={`Baja de stock ${producto.nombre}`}
                        >
                          <Minus className="w-3.5 h-3.5" aria-hidden="true" />
                          <span>Baja</span>
                        </button>
                      )}
                      <button
                        onClick={() => onEditarProducto(producto)}
                        className="inline-flex items-center gap-1.5 h-8 px-2.5 rounded-md text-xs font-medium bg-blue-50 text-blue-700 border border-blue-200/70 hover:bg-blue-100 transition-colors"
                        title="Editar"
                        aria-label={`Editar ${producto.nombre}`}
                      >
                        <Edit2 className="w-3.5 h-3.5" aria-hidden="true" />
                        <span>Editar</span>
                      </button>
                      <button
                        onClick={() => onEliminarProducto(producto.id)}
                        className="inline-flex items-center gap-1.5 h-8 px-2.5 rounded-md text-xs font-medium bg-rose-50 text-rose-700 border border-rose-200/70 hover:bg-rose-100 transition-colors"
                        title="Eliminar"
                        aria-label={`Eliminar ${producto.nombre}`}
                      >
                        <Trash2 className="w-3.5 h-3.5" aria-hidden="true" />
                        <span>Borrar</span>
                      </button>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        </>
      )}

      <Paginacion
        paginaActual={paginaActual}
        totalPaginas={totalPaginas}
        onPageChange={setPaginaActual}
        totalItems={productosFiltrados.length}
        itemsLabel="productos"
      />
    </div>
  );
}
