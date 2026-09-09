/**
 * Reporte de valuación de inventario (mig 131).
 *
 * Stock valuado a COSTO PROMEDIO PONDERADO (mig 127) con comparativa a costo
 * de reposición (última compra). Autocontenido: trae los datos con su propio
 * hook (RPC reporte_valuacion_inventario, consolidado de las sucursales del
 * usuario) y filtra por sucursal/categoría del lado del cliente.
 */
import React, { useMemo, useState } from 'react';
import { Package, AlertTriangle, Download, Loader2 } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import {
  useValuacionInventarioQuery,
  type ValuacionProducto,
} from '../../../hooks/queries/useValuacionInventarioQuery';

export interface ReporteValuacionInventarioProps {
  formatPrecio: (precio: number) => string;
}

export function ReporteValuacionInventario({
  formatPrecio,
}: ReporteValuacionInventarioProps): React.ReactElement {
  const { data, isLoading, error } = useValuacionInventarioQuery(null);
  const [sucursalFiltro, setSucursalFiltro] = useState<number | 'todas'>('todas');
  const [categoriaFiltro, setCategoriaFiltro] = useState<string>('todas');

  const productosFiltrados = useMemo<ValuacionProducto[]>(() => {
    let rows = data?.productos ?? [];
    if (sucursalFiltro !== 'todas') rows = rows.filter((p) => p.sucursal_id === sucursalFiltro);
    if (categoriaFiltro !== 'todas') rows = rows.filter((p) => p.categoria === categoriaFiltro);
    return rows;
  }, [data, sucursalFiltro, categoriaFiltro]);

  // Totales del filtro activo (los del RPC son globales)
  const totalesFiltro = useMemo(() => {
    return productosFiltrados.reduce(
      (acc, p) => ({
        unidades: acc.unidades + Math.max(p.stock, 0),
        promedio: acc.promedio + (p.valuacion_promedio || 0),
        reposicion: acc.reposicion + (p.valuacion_reposicion || 0),
      }),
      { unidades: 0, promedio: 0, reposicion: 0 }
    );
  }, [productosFiltrados]);

  const [exportando, setExportando] = useState(false);

  const exportar = async (): Promise<void> => {
    if (!data) return;
    setExportando(true);
    try {
      const nombreSucursal =
        sucursalFiltro === 'todas'
          ? 'Todas'
          : (data.sucursales.find((x) => x.sucursal_id === sucursalFiltro)?.sucursal_nombre ??
             String(sucursalFiltro));

      // El filtro es EN CLIENTE: exportar data.productos crudo ignoraría los
      // filtros que el usuario tiene puestos en pantalla y el archivo no
      // coincidiría con lo que está mirando. Por eso van los FILTRADOS, y el
      // filtro aplicado queda escrito en la hoja de metadatos: fuera de la app,
      // nadie puede saber si este archivo es de una sucursal o de todas.
      const meta = [
        { Campo: 'Generado', Valor: data.meta.generado_at },
        { Campo: 'Criterio', Valor: data.meta.criterio },
        { Campo: 'Sucursal (filtro aplicado)', Valor: nombreSucursal },
        { Campo: 'Categoría (filtro aplicado)', Valor: categoriaFiltro === 'todas' ? 'Todas' : categoriaFiltro },
        { Campo: 'Productos en este archivo', Valor: productosFiltrados.length },
        { Campo: 'Productos en el reporte completo', Valor: data.productos.length },
        { Campo: 'Unidades', Valor: totalesFiltro.unidades },
        { Campo: 'Valuación a costo promedio', Valor: totalesFiltro.promedio },
        { Campo: 'Valuación a costo de reposición', Valor: totalesFiltro.reposicion },
        { Campo: 'Diferencia', Valor: totalesFiltro.reposicion - totalesFiltro.promedio },
        { Campo: 'Productos con stock negativo', Valor: data.calidad_datos.stock_negativo },
        { Campo: 'Productos sin costo', Valor: data.calidad_datos.sin_costo },
      ];

      const filas = productosFiltrados.map((p) => ({
        Producto: p.nombre,
        Categoría: p.categoria,
        Sucursal: p.sucursal_nombre,
        Stock: p.stock,
        'Costo promedio': p.costo_promedio ?? '',
        'Costo reposición': p.costo_reposicion ?? '',
        'Última compra': p.ultimo_tipo_compra ?? '',
        'Valuación promedio': p.valuacion_promedio,
        'Valuación reposición': p.valuacion_reposicion,
        Diferencia: p.diferencia,
      }));

      // Las categorías del RPC son GLOBALES: con un filtro puesto no cuadrarían
      // con el detalle. Se recalculan sobre lo filtrado, que es lo que el
      // usuario está viendo.
      const porCategoria = new Map<string, { productos: number; unidades: number; promedio: number; reposicion: number }>();
      for (const p of productosFiltrados) {
        const acc = porCategoria.get(p.categoria) ?? { productos: 0, unidades: 0, promedio: 0, reposicion: 0 };
        acc.productos += 1;
        acc.unidades += Math.max(p.stock, 0);
        acc.promedio += p.valuacion_promedio || 0;
        acc.reposicion += p.valuacion_reposicion || 0;
        porCategoria.set(p.categoria, acc);
      }
      const categoriasFilas = [...porCategoria.entries()]
        .map(([categoria, v]) => ({
          Categoría: categoria,
          Productos: v.productos,
          Unidades: v.unidades,
          'Valuación promedio': v.promedio,
          'Valuación reposición': v.reposicion,
          Diferencia: v.reposicion - v.promedio,
        }))
        .sort((a, b) => b['Valuación promedio'] - a['Valuación promedio']);

      const { createMultiSheetExcel } = await import('../../../utils/excel');
      await createMultiSheetExcel(
        [
          { name: 'Info', data: meta, columnWidths: [34, 26] },
          { name: 'Por categoría', data: categoriasFilas, columnWidths: [28, 11, 11, 20, 20, 16] },
          { name: 'Detalle', data: filas, columnWidths: [40, 24, 18, 9, 16, 17, 14, 20, 20, 16] },
        ],
        `valuacion-inventario-${nombreSucursal}-${data.meta.generado_at.slice(0, 10)}`.replace(/\s+/g, '_')
      );
    } finally {
      setExportando(false);
    }
  };

  if (isLoading) return <LoadingSpinner />;
  if (error) {
    return (
      <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4 text-red-700 dark:text-red-300 text-sm">
        No se pudo cargar la valuación: {(error as Error).message}
      </div>
    );
  }
  if (!data) return <LoadingSpinner />;

  const categorias = Array.from(new Set((data.productos ?? []).map((p) => p.categoria))).sort();
  const diferencia = totalesFiltro.reposicion - totalesFiltro.promedio;

  return (
    <div className="space-y-4">
      <div className="flex justify-end">
        <button
          onClick={exportar}
          disabled={exportando || productosFiltrados.length === 0}
          className="flex items-center gap-2 px-3 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50 text-sm transition-colors"
        >
          {exportando ? (
            <Loader2 className="w-4 h-4 animate-spin" />
          ) : (
            <Download className="w-4 h-4" />
          )}
          Exportar a Excel
        </button>
      </div>

      {/* KPIs */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div className="bg-blue-50 dark:bg-blue-900/20 p-4 rounded-lg">
          <p className="text-sm text-blue-600 dark:text-blue-400">Stock valuado (promedio)</p>
          <p className="text-xl font-bold text-blue-700 dark:text-blue-300">
            {formatPrecio(totalesFiltro.promedio)}
          </p>
          <p className="text-xs text-blue-600/70 dark:text-blue-400/70 mt-1">
            Lo que costó la mercadería en stock (CPP)
          </p>
        </div>
        <div className="bg-indigo-50 dark:bg-indigo-900/20 p-4 rounded-lg">
          <p className="text-sm text-indigo-600 dark:text-indigo-400">A costo de reposición</p>
          <p className="text-xl font-bold text-indigo-700 dark:text-indigo-300">
            {formatPrecio(totalesFiltro.reposicion)}
          </p>
          <p className="text-xs text-indigo-600/70 dark:text-indigo-400/70 mt-1">
            Cuánto saldría reponer todo hoy
          </p>
        </div>
        <div className={`p-4 rounded-lg ${diferencia >= 0 ? 'bg-green-50 dark:bg-green-900/20' : 'bg-red-50 dark:bg-red-900/20'}`}>
          <p className={`text-sm ${diferencia >= 0 ? 'text-green-600 dark:text-green-400' : 'text-red-600 dark:text-red-400'}`}>Diferencia</p>
          <p className={`text-xl font-bold ${diferencia >= 0 ? 'text-green-700 dark:text-green-300' : 'text-red-700 dark:text-red-300'}`}>
            {formatPrecio(diferencia)}
          </p>
          <p className="text-xs text-gray-500 mt-1">
            {diferencia >= 0 ? 'Reponer cuesta más que lo pagado' : 'El stock está valuado por encima de reposición'}
          </p>
        </div>
        <div className="bg-gray-50 dark:bg-gray-800 p-4 rounded-lg border dark:border-gray-700">
          <p className="text-sm text-gray-600 dark:text-gray-400">Productos / Unidades</p>
          <p className="text-xl font-bold text-gray-700 dark:text-gray-200">
            {productosFiltrados.length} / {totalesFiltro.unidades}
          </p>
        </div>
      </div>

      {/* Calidad de datos */}
      {(data.calidad_datos.stock_negativo > 0 || data.calidad_datos.sin_costo > 0) && (
        <div className="flex items-start gap-2 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg p-3 text-sm text-amber-800 dark:text-amber-200">
          <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
          <div>
            {data.calidad_datos.stock_negativo > 0 && (
              <p>
                {data.calidad_datos.stock_negativo} producto(s) con stock negativo (excluidos de la
                valuación):{' '}
                {data.calidad_datos.detalle_stock_negativo
                  .map((p) => `${p.nombre} (${p.stock})`)
                  .join(', ')}
              </p>
            )}
            {data.calidad_datos.sin_costo > 0 && (
              <p>{data.calidad_datos.sin_costo} producto(s) sin costo cargado (valuados en $0).</p>
            )}
          </div>
        </div>
      )}

      {/* Filtros */}
      <div className="flex flex-wrap gap-3">
        {data.sucursales.length > 1 && (
          <select
            aria-label="Sucursal"
            value={sucursalFiltro}
            onChange={(e) => setSucursalFiltro(e.target.value === 'todas' ? 'todas' : Number(e.target.value))}
            className="px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-sm text-gray-900 dark:text-white"
          >
            <option value="todas">Todas las sucursales</option>
            {data.sucursales.map((s) => (
              <option key={s.sucursal_id} value={s.sucursal_id}>{s.sucursal_nombre}</option>
            ))}
          </select>
        )}
        <select
          aria-label="Categoría"
          value={categoriaFiltro}
          onChange={(e) => setCategoriaFiltro(e.target.value)}
          className="px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-sm text-gray-900 dark:text-white"
        >
          <option value="todas">Todas las categorías</option>
          {categorias.map((c) => (
            <option key={c} value={c}>{c}</option>
          ))}
        </select>
      </div>

      {/* Por categoría (solo sin filtro de categoría) */}
      {categoriaFiltro === 'todas' && sucursalFiltro === 'todas' && data.categorias.length > 0 && (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-hidden">
          <h3 className="font-semibold text-gray-700 dark:text-gray-200 px-4 pt-4">Por categoría</h3>
          <div className="overflow-x-auto p-4">
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-gray-500 dark:text-gray-400 border-b dark:border-gray-700">
                  <th className="py-2 pr-4">Categoría</th>
                  <th className="py-2 pr-4 text-right">Productos</th>
                  <th className="py-2 pr-4 text-right">Unidades</th>
                  <th className="py-2 pr-4 text-right">Valuación (CPP)</th>
                  <th className="py-2 pr-4 text-right">A reposición</th>
                  <th className="py-2 text-right">Dif.</th>
                </tr>
              </thead>
              <tbody>
                {data.categorias.map((c) => (
                  <tr key={c.categoria} className="border-b dark:border-gray-700/50 last:border-0">
                    <td className="py-2 pr-4 text-gray-800 dark:text-gray-100">{c.categoria}</td>
                    <td className="py-2 pr-4 text-right">{c.productos}</td>
                    <td className="py-2 pr-4 text-right">{c.unidades}</td>
                    <td className="py-2 pr-4 text-right font-semibold">{formatPrecio(c.valuacion_promedio)}</td>
                    <td className="py-2 pr-4 text-right">{formatPrecio(c.valuacion_reposicion)}</td>
                    <td className={`py-2 text-right ${c.diferencia >= 0 ? 'text-green-600' : 'text-red-600'}`}>
                      {formatPrecio(c.diferencia)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {/* Detalle por producto */}
      <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-hidden">
        <h3 className="font-semibold text-gray-700 dark:text-gray-200 px-4 pt-4 flex items-center gap-2">
          <Package className="w-4 h-4" /> Detalle por producto
        </h3>
        <div className="overflow-x-auto p-4">
          {productosFiltrados.length === 0 ? (
            <p className="text-sm text-gray-500 py-4">Sin productos con stock para el filtro elegido.</p>
          ) : (
            <table className="w-full text-sm">
              <thead>
                <tr className="text-left text-gray-500 dark:text-gray-400 border-b dark:border-gray-700">
                  <th className="py-2 pr-4">Producto</th>
                  <th className="py-2 pr-4 text-right">Stock</th>
                  <th className="py-2 pr-4 text-right">Costo prom.</th>
                  <th className="py-2 pr-4 text-right">Reposición</th>
                  <th className="py-2 pr-4 text-right">Valuación (CPP)</th>
                  <th className="py-2 text-right">Dif.</th>
                </tr>
              </thead>
              <tbody>
                {productosFiltrados.map((p) => (
                  <tr key={`${p.sucursal_id}-${p.producto_id}`} className="border-b dark:border-gray-700/50 last:border-0">
                    <td className="py-2 pr-4 text-gray-800 dark:text-gray-100">
                      {p.nombre}
                      {p.ultimo_tipo_compra && (
                        <span className="ml-2 text-[10px] font-semibold px-1.5 py-0.5 rounded bg-gray-100 dark:bg-gray-700 text-gray-500 dark:text-gray-300">
                          {p.ultimo_tipo_compra}
                        </span>
                      )}
                      {sucursalFiltro === 'todas' && data.sucursales.length > 1 && (
                        <span className="ml-2 text-xs text-gray-400">{p.sucursal_nombre}</span>
                      )}
                    </td>
                    <td className="py-2 pr-4 text-right">{p.stock}</td>
                    <td className="py-2 pr-4 text-right">{p.costo_promedio != null ? formatPrecio(p.costo_promedio) : '—'}</td>
                    <td className="py-2 pr-4 text-right">{p.costo_reposicion != null ? formatPrecio(p.costo_reposicion) : '—'}</td>
                    <td className="py-2 pr-4 text-right font-semibold">{formatPrecio(p.valuacion_promedio)}</td>
                    <td className={`py-2 text-right ${p.diferencia >= 0 ? 'text-green-600' : 'text-red-600'}`}>
                      {formatPrecio(p.diferencia)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>

      <p className="text-xs text-gray-500">
        Valuación al costo promedio ponderado de las compras (criterio de gestión). La columna
        "reposición" usa el costo de la última compra (FC: neto + imp. internos · ZZ: total pagado).
      </p>
    </div>
  );
}
