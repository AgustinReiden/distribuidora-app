/**
 * Componente para mostrar el reporte de rentabilidad por producto
 */
import React, { useState } from 'react';
import { Package, Download, Loader2 } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import type { ReporteRentabilidad } from '../../../types';

export interface ReporteRentabilidadProps {
  reporte: ReporteRentabilidad;
  loading: boolean;
  formatPrecio: (precio: number) => string;
  /** Sólo para el nombre del archivo: '' = sin filtro de fecha. */
  desde?: string;
  hasta?: string;
}

/** Lo que la tabla muestra en pantalla. El Excel se lleva TODOS. */
const PRODUCTOS_EN_PANTALLA = 20;

export function ReporteRentabilidadSection({
  reporte,
  loading,
  formatPrecio,
  desde = '',
  hasta = ''
}: ReporteRentabilidadProps): React.ReactElement {
  const [exportando, setExportando] = useState(false);
  const { productos, totales } = reporte;
  const periodo = desde || hasta ? `${desde || 'inicio'}_${hasta || 'hoy'}` : 'todo';

  const exportar = async (): Promise<void> => {
    if (productos.length === 0) return;
    setExportando(true);
    try {
      // TODOS los productos, no los 20 de la pantalla. El nombre de la hoja lo
      // dice para que nadie crea que el archivo no coincide con lo que ve.
      const filas = productos.map((p, i) => ({
        '#': i + 1,
        Producto: p.nombre,
        Código: p.codigo ?? '',
        Vendido: p.cantidadVendida ?? 0,
        Ingresos: p.ingresos ?? 0,
        Costos: p.costos ?? 0,
        Margen: p.margen ?? 0,
        '% margen': (p.margenPorcentaje ?? 0) / 100
      }));

      // El desglose fiscal está en la pantalla y no en la tabla: sin esta hoja
      // el Excel perdería el IVA y los impuestos internos, que es lo que separa
      // la venta bruta del ingreso real.
      const resumen = [
        { Concepto: 'Ventas brutas', Monto: totales.ventasBrutas ?? 0 },
        { Concepto: 'IVA discriminado', Monto: totales.ivaDiscriminado ?? 0 },
        { Concepto: 'Impuestos internos', Monto: totales.impuestosInternos ?? 0 },
        { Concepto: 'Ventas netas', Monto: totales.ventasNetas ?? 0 },
        { Concepto: 'Ingresos netos', Monto: totales.ingresosTotales ?? 0 },
        { Concepto: 'Costos', Monto: totales.costosTotales ?? 0 },
        { Concepto: 'Margen', Monto: totales.margenTotal ?? 0 },
        { Concepto: '% margen', Monto: (totales.margenPorcentaje ?? 0) / 100 },
        { Concepto: 'Pedidos', Monto: totales.cantidadPedidos ?? 0 },
        { Concepto: 'Productos en el reporte', Monto: productos.length }
      ];

      const { createMultiSheetExcel } = await import('../../../utils/excel');
      await createMultiSheetExcel(
        [
          { name: 'Resumen', data: resumen, columnWidths: [26, 18] },
          { name: `Productos (todos, ${productos.length})`, data: filas, columnWidths: [5, 40, 14, 10, 16, 16, 16, 11] }
        ],
        `rentabilidad-${periodo}`
      );
    } finally {
      setExportando(false);
    }
  };

  if (loading) return <LoadingSpinner />;

  return (
    <div className="space-y-4">
      <div className="flex justify-end">
        <button
          onClick={exportar}
          disabled={exportando || productos.length === 0}
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

      {/* Desglose Ventas */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div className="bg-indigo-50 dark:bg-indigo-900/20 p-4 rounded-lg">
          <p className="text-sm text-indigo-600 dark:text-indigo-400">Ventas Brutas</p>
          <p className="text-xl font-bold text-indigo-700 dark:text-indigo-300">
            {formatPrecio(totales.ventasBrutas || 0)}
          </p>
        </div>
        <div className="bg-orange-50 dark:bg-orange-900/20 p-4 rounded-lg">
          <p className="text-sm text-orange-600 dark:text-orange-400">IVA Discriminado</p>
          <p className="text-xl font-bold text-orange-700 dark:text-orange-300">
            {formatPrecio(totales.ivaDiscriminado || 0)}
          </p>
        </div>
        <div className="bg-amber-50 dark:bg-amber-900/20 p-4 rounded-lg">
          <p className="text-sm text-amber-600 dark:text-amber-400">Imp. Internos</p>
          <p className="text-xl font-bold text-amber-700 dark:text-amber-300">
            {formatPrecio(totales.impuestosInternos || 0)}
          </p>
        </div>
        <div className="bg-blue-50 dark:bg-blue-900/20 p-4 rounded-lg">
          <p className="text-sm text-blue-600 dark:text-blue-400">Ventas Netas</p>
          <p className="text-xl font-bold text-blue-700 dark:text-blue-300">
            {formatPrecio(totales.ventasNetas || 0)}
          </p>
        </div>
      </div>

      {/* Resumen Rentabilidad */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div className="bg-blue-50 dark:bg-blue-900/20 p-4 rounded-lg">
          <p className="text-sm text-blue-600 dark:text-blue-400">Ingresos Netos</p>
          <p className="text-xl font-bold text-blue-700 dark:text-blue-300">
            {formatPrecio(totales.ingresosTotales || 0)}
          </p>
        </div>
        <div className="bg-red-50 dark:bg-red-900/20 p-4 rounded-lg">
          <p className="text-sm text-red-600 dark:text-red-400">Costos</p>
          <p className="text-xl font-bold text-red-700 dark:text-red-300">
            {formatPrecio(totales.costosTotales || 0)}
          </p>
        </div>
        <div className="bg-green-50 dark:bg-green-900/20 p-4 rounded-lg">
          <p className="text-sm text-green-600 dark:text-green-400">Margen</p>
          <p className="text-xl font-bold text-green-700 dark:text-green-300">
            {formatPrecio(totales.margenTotal || 0)}
          </p>
        </div>
        <div className="bg-purple-50 dark:bg-purple-900/20 p-4 rounded-lg">
          <p className="text-sm text-purple-600 dark:text-purple-400">% Margen</p>
          <p className="text-xl font-bold text-purple-700 dark:text-purple-300">
            {(totales.margenPorcentaje || 0).toFixed(1)}%
          </p>
        </div>
      </div>

      {productos.length === 0 ? (
        <div className="text-center py-12 text-gray-500 bg-white dark:bg-gray-800 rounded-lg">
          <Package className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>No hay datos de rentabilidad</p>
          <p className="text-sm mt-1">Asegúrate de tener costos cargados en los productos</p>
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium">Producto</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Vendido</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Ingresos</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Costos</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Margen</th>
                <th className="px-4 py-3 text-right text-sm font-medium">%</th>
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {productos.slice(0, PRODUCTOS_EN_PANTALLA).map((p, i) => (
                <tr key={i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
                  <td className="px-4 py-3">
                    <p className="font-medium">{p.nombre}</p>
                    {p.codigo && <p className="text-sm text-gray-500">{p.codigo}</p>}
                  </td>
                  <td className="px-4 py-3 text-right">{p.cantidadVendida ?? 0}</td>
                  <td className="px-4 py-3 text-right">{formatPrecio(p.ingresos ?? 0)}</td>
                  <td className="px-4 py-3 text-right text-red-600">{formatPrecio(p.costos ?? 0)}</td>
                  <td className="px-4 py-3 text-right font-bold text-green-600">
                    {formatPrecio(p.margen ?? 0)}
                  </td>
                  <td className="px-4 py-3 text-right">
                    <span
                      className={`px-2 py-1 rounded text-sm ${
                        (p.margenPorcentaje ?? 0) >= 20
                          ? 'bg-green-100 text-green-700'
                          : (p.margenPorcentaje ?? 0) >= 10
                            ? 'bg-yellow-100 text-yellow-700'
                            : 'bg-red-100 text-red-700'
                      }`}
                    >
                      {(p.margenPorcentaje ?? 0).toFixed(1)}%
                    </span>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
          {productos.length > PRODUCTOS_EN_PANTALLA && (
            <p className="px-4 py-3 text-sm text-gray-500 border-t dark:border-gray-700">
              Se muestran los {PRODUCTOS_EN_PANTALLA} de mayor margen. El Excel lleva los{' '}
              {productos.length}.
            </p>
          )}
        </div>
      )}
    </div>
  );
}
