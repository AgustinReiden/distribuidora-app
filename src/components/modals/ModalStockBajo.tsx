/**
 * ModalStockBajo
 *
 * Reemplaza el banner gigante que ocupaba ~80px verticales en la pantalla
 * de Productos. Se accede vía botón de la toolbar (con count badge).
 *
 * Estructura:
 *   - Header: titulo + descripción ("N productos requieren reposición")
 *   - Filtros internos: búsqueda + dropdown de categoría
 *   - Lista ordenada por urgencia (sin stock → stock bajo → bajo de minimo)
 *   - Cada fila: código, nombre, categoría, stock actual / mínimo, % cobertura
 *   - Acción rápida: chip "Editar" que cierra el modal y abre ModalProducto
 *
 * No hace nuevos queries — recibe `productos` ya filtrados desde el container.
 */
import React, { memo, useMemo, useState } from 'react';
import { Edit2, Search, X, AlertTriangle, ChevronDown } from 'lucide-react';
import ModalBase from './ModalBase';
import { cn } from '../../lib/utils';
import type { ProductoDB } from '../../types';

export interface ModalStockBajoProps {
  /** Productos con stock bajo, ya filtrados por el container. */
  productos: ProductoDB[];
  /**
   * Click en "Editar" de una fila: cierra el modal y abre ModalProducto.
   * Si no se provee (ej. rol encargado, solo lectura) no se muestra el botón.
   */
  onEditarProducto?: (producto: ProductoDB) => void;
  /** Cerrar el modal. */
  onClose: () => void;
}

interface ProductoConUrgencia extends ProductoDB {
  stockMinimo: number;
  cobertura: number;
  urgencia: 'sin-stock' | 'bajo' | 'critico';
}

function clasificarUrgencia(producto: ProductoDB): ProductoConUrgencia {
  const stockMinimo = producto.stock_minimo || 10;
  const cobertura = stockMinimo === 0 ? 0 : (producto.stock / stockMinimo) * 100;
  const urgencia: ProductoConUrgencia['urgencia'] =
    producto.stock === 0 ? 'sin-stock' :
    producto.stock < stockMinimo ? 'bajo' :
    'critico';
  return { ...producto, stockMinimo, cobertura, urgencia };
}

const URGENCIA_ORDER: Record<ProductoConUrgencia['urgencia'], number> = {
  'sin-stock': 0,
  'bajo': 1,
  'critico': 2,
};

const URGENCIA_STYLES: Record<ProductoConUrgencia['urgencia'], {
  borderLeft: string;
  badgeBg: string;
  badgeText: string;
  barBg: string;
  label: string;
}> = {
  'sin-stock': {
    borderLeft: 'border-l-rose-500',
    badgeBg: 'bg-rose-100 dark:bg-rose-900/30',
    badgeText: 'text-rose-700 dark:text-rose-300',
    barBg: 'bg-rose-500',
    label: 'Sin stock',
  },
  'bajo': {
    borderLeft: 'border-l-amber-500',
    badgeBg: 'bg-amber-100 dark:bg-amber-900/30',
    badgeText: 'text-amber-700 dark:text-amber-300',
    barBg: 'bg-amber-500',
    label: 'Stock bajo',
  },
  'critico': {
    borderLeft: 'border-l-orange-500',
    badgeBg: 'bg-orange-100 dark:bg-orange-900/30',
    badgeText: 'text-orange-700 dark:text-orange-300',
    barBg: 'bg-orange-500',
    label: 'Bajo del mínimo',
  },
};

const ModalStockBajo = memo(function ModalStockBajo({
  productos,
  onEditarProducto,
  onClose,
}: ModalStockBajoProps): React.ReactElement {
  const [busqueda, setBusqueda] = useState('');
  const [filtroCategoria, setFiltroCategoria] = useState<string>('todas');

  // Categorías disponibles dentro del subset de stock bajo
  const categorias = useMemo<string[]>(() => {
    const set = new Set<string>();
    productos.forEach(p => { if (p.categoria) set.add(p.categoria); });
    return ['todas', ...Array.from(set).sort()];
  }, [productos]);

  // Enriquecer y ordenar por urgencia
  const productosOrdenados = useMemo<ProductoConUrgencia[]>(() => {
    const enriched = productos.map(clasificarUrgencia);
    return enriched.sort((a, b) => {
      const orderDiff = URGENCIA_ORDER[a.urgencia] - URGENCIA_ORDER[b.urgencia];
      if (orderDiff !== 0) return orderDiff;
      return a.cobertura - b.cobertura;
    });
  }, [productos]);

  // Aplicar filtros internos del modal
  const productosFiltrados = useMemo(() => {
    const q = busqueda.trim().toLowerCase();
    return productosOrdenados.filter(p => {
      const matchBusqueda = !q
        || p.nombre?.toLowerCase().includes(q)
        || p.codigo?.toLowerCase().includes(q);
      const matchCategoria = filtroCategoria === 'todas' || p.categoria === filtroCategoria;
      return matchBusqueda && matchCategoria;
    });
  }, [productosOrdenados, busqueda, filtroCategoria]);

  const totalLabel = productos.length === 1
    ? '1 producto requiere reposición'
    : `${productos.length.toLocaleString('es-AR')} productos requieren reposición`;

  return (
    <ModalBase
      title="Productos con stock bajo"
      description={totalLabel}
      onClose={onClose}
      maxWidth="max-w-3xl"
    >
      {/* Filtros internos */}
      <div className="px-5 pt-4 pb-3 flex flex-col sm:flex-row gap-2 border-b border-stone-200 dark:border-gray-700">
        <div className="relative flex-1 min-w-0">
          <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-stone-400 w-4 h-4" aria-hidden="true" />
          <input
            type="text"
            value={busqueda}
            onChange={e => setBusqueda(e.target.value)}
            placeholder="Buscar por nombre o código…"
            className="w-full h-9 pl-9 pr-3 rounded-lg border border-stone-200 dark:border-gray-700 bg-white dark:bg-gray-800 text-sm text-stone-700 dark:text-gray-200 placeholder:text-stone-400 focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400"
          />
        </div>
        {categorias.length > 1 && (
          <div className="relative">
            <select
              value={filtroCategoria}
              onChange={e => setFiltroCategoria(e.target.value)}
              className={cn(
                'h-9 pl-3 pr-9 rounded-lg border text-sm appearance-none cursor-pointer',
                'bg-white dark:bg-gray-800 text-stone-700 dark:text-gray-200',
                'border-stone-200 dark:border-gray-700',
                'focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400',
                filtroCategoria !== 'todas' && 'bg-blue-50 dark:bg-blue-900/20 border-blue-300 text-blue-700',
              )}
            >
              {categorias.map(c => (
                <option key={c} value={c}>{c === 'todas' ? 'Todas las categorías' : c}</option>
              ))}
            </select>
            <ChevronDown className="absolute right-2.5 top-1/2 -translate-y-1/2 w-4 h-4 text-stone-400 pointer-events-none" aria-hidden="true" />
          </div>
        )}
      </div>

      {/* Lista */}
      <div className="flex-1 overflow-y-auto px-5 py-3 space-y-2">
        {productosFiltrados.length === 0 ? (
          <div className="text-center py-12 text-stone-500 dark:text-gray-400">
            <AlertTriangle className="w-10 h-10 mx-auto mb-3 opacity-40" aria-hidden="true" />
            <p className="text-sm">No se encontraron productos con los filtros actuales</p>
          </div>
        ) : (
          productosFiltrados.map(p => {
            const styles = URGENCIA_STYLES[p.urgencia];
            const coberturaWidth = Math.min(100, Math.max(0, p.cobertura));
            return (
              <div
                key={p.id}
                className={cn(
                  'flex items-center gap-3 bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 border-l-4 rounded-lg px-3 py-2.5 shadow-warm hover:shadow-warm-md transition-shadow',
                  styles.borderLeft,
                )}
              >
                <div className="min-w-0 flex-1">
                  <div className="flex items-baseline gap-2 flex-wrap">
                    {p.codigo && (
                      <span className="text-[11px] font-mono font-semibold tabular-nums text-stone-500 dark:text-gray-400">
                        #{p.codigo}
                      </span>
                    )}
                    <span className="font-semibold text-stone-900 dark:text-white text-[14px] truncate">
                      {p.nombre}
                    </span>
                  </div>
                  <div className="flex items-center gap-3 mt-1.5 flex-wrap">
                    {p.categoria && (
                      <span className="text-[11px] text-stone-500 dark:text-gray-400">
                        {p.categoria}
                      </span>
                    )}
                    <span className={cn('text-[11px] font-semibold uppercase tracking-wide px-1.5 py-0.5 rounded', styles.badgeBg, styles.badgeText)}>
                      {styles.label}
                    </span>
                  </div>
                  {/* Mini barra de cobertura */}
                  <div className="mt-2 flex items-center gap-2">
                    <div className="flex-1 h-1.5 rounded-full bg-stone-100 dark:bg-gray-700 overflow-hidden">
                      <div
                        className={cn('h-full rounded-full transition-all', styles.barBg)}
                        style={{ width: `${coberturaWidth}%` }}
                      />
                    </div>
                    <span className="text-[11px] tabular-nums text-stone-600 dark:text-gray-300 font-medium whitespace-nowrap">
                      {p.stock} / {p.stockMinimo}
                    </span>
                  </div>
                </div>
                {onEditarProducto && (
                  <button
                    type="button"
                    onClick={() => { onEditarProducto(p); onClose(); }}
                    className="inline-flex items-center gap-1.5 h-8 px-2.5 rounded-md text-xs font-medium bg-blue-50 dark:bg-blue-900/20 text-blue-700 dark:text-blue-300 border border-blue-200/70 dark:border-blue-800/40 hover:bg-blue-100 dark:hover:bg-blue-900/30 hover:border-blue-300 hover:-translate-y-px active:translate-y-0 transition-[transform,background-color,border-color] flex-shrink-0"
                    title={`Editar ${p.nombre}`}
                  >
                    <Edit2 className="w-3.5 h-3.5" aria-hidden="true" />
                    <span>Editar</span>
                  </button>
                )}
              </div>
            );
          })
        )}
      </div>

      {/* Footer */}
      <div className="px-5 py-3 border-t border-stone-200 dark:border-gray-700 flex items-center justify-between gap-3 bg-stone-50/50 dark:bg-gray-900/40">
        <p className="text-xs text-stone-500 dark:text-gray-400">
          {productosFiltrados.length === productos.length
            ? totalLabel
            : `Mostrando ${productosFiltrados.length} de ${productos.length}`}
        </p>
        <button
          type="button"
          onClick={onClose}
          className="inline-flex items-center gap-1.5 h-9 px-4 rounded-lg text-sm font-medium text-stone-700 dark:text-gray-200 bg-white dark:bg-gray-800 border border-stone-200 dark:border-gray-700 hover:bg-stone-50 dark:hover:bg-gray-700/50 hover:border-stone-300 transition-colors"
        >
          <X className="w-4 h-4" aria-hidden="true" />
          Cerrar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalStockBajo;
