/**
 * Componente para mostrar el reporte de rentabilidad por producto
 */
import React from 'react';
import { Package } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import type { ReporteRentabilidad } from '../../../types';

export interface ReporteRentabilidadProps {
  reporte: ReporteRentabilidad;
  loading: boolean;
  formatPrecio: (precio: number) => string;
}

export function ReporteRentabilidadSection({
  reporte,
  loading,
  formatPrecio
}: ReporteRentabilidadProps): React.ReactElement {
  if (loading) return <LoadingSpinner />;

  const { productos, totales } = reporte;

  return (
    <div className="space-y-4">
      {/* Resumen */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        <div className="bg-blue-50 dark:bg-blue-900/20 p-4 rounded-lg">
          <p className="text-sm text-blue-600">Ingresos</p>
          <p className="text-xl font-bold text-blue-700">
            {formatPrecio(totales.ingresosTotales || 0)}
          </p>
        </div>
        <div className="bg-red-50 dark:bg-red-900/20 p-4 rounded-lg">
          <p className="text-sm text-red-600">Costos</p>
          <p className="text-xl font-bold text-red-700">
            {formatPrecio(totales.costosTotales || 0)}
          </p>
        </div>
        <div className="bg-green-50 dark:bg-green-900/20 p-4 rounded-lg">
          <p className="text-sm text-green-600">Margen</p>
          <p className="text-xl font-bold text-green-700">
            {formatPrecio(totales.margenTotal || 0)}
          </p>
        </div>
        <div className="bg-purple-50 dark:bg-purple-900/20 p-4 rounded-lg">
          <p className="text-sm text-purple-600">% Margen</p>
          <p className="text-xl font-bold text-purple-700">
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
              {productos.slice(0, 20).map((p, i) => (
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
        </div>
      )}
    </div>
  );
}
