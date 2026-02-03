/**
 * Componente para mostrar el reporte de ventas por preventista
 */
import React from 'react';
import { TrendingUp } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import type { ReportePreventista } from '../../../types';

export interface ReportePreventistasProps {
  reportePreventistas: ReportePreventista[];
  loading: boolean;
  formatPrecio: (precio: number) => string;
}

export function ReportePreventistas({
  reportePreventistas,
  loading,
  formatPrecio
}: ReportePreventistasProps): React.ReactElement {
  if (loading) return <LoadingSpinner />;

  if (reportePreventistas.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500 dark:text-gray-400 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm">
        <TrendingUp className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p className="font-semibold">No hay datos para mostrar</p>
      </div>
    );
  }

  const totales = {
    ventas: reportePreventistas.reduce((s, p) => s + p.totalVentas, 0),
    pedidos: reportePreventistas.reduce((s, p) => s + p.cantidadPedidos, 0),
    pagado: reportePreventistas.reduce((s, p) => s + p.totalPagado, 0),
    pendiente: reportePreventistas.reduce((s, p) => s + p.totalPendiente, 0)
  };

  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-x-auto">
      <table className="w-full">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">
              Preventista
            </th>
            <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">
              Total Ventas
            </th>
            <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">
              Pedidos
            </th>
            <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">
              Pagado
            </th>
            <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">
              Pendiente
            </th>
          </tr>
        </thead>
        <tbody className="divide-y dark:divide-gray-700">
          {reportePreventistas.map((p, i) => (
            <tr key={p.id || i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
              <td className="px-4 py-3">
                <p className="font-medium text-gray-800 dark:text-white">{p.nombre}</p>
                <p className="text-sm text-gray-500">{p.email}</p>
              </td>
              <td className="px-4 py-3 text-right font-bold text-blue-600">
                {formatPrecio(p.totalVentas)}
              </td>
              <td className="px-4 py-3 text-right">{p.cantidadPedidos}</td>
              <td className="px-4 py-3 text-right text-green-600">{formatPrecio(p.totalPagado)}</td>
              <td className="px-4 py-3 text-right text-red-600">{formatPrecio(p.totalPendiente)}</td>
            </tr>
          ))}
        </tbody>
        <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
          <tr>
            <td className="px-4 py-3">TOTAL</td>
            <td className="px-4 py-3 text-right text-blue-600">{formatPrecio(totales.ventas)}</td>
            <td className="px-4 py-3 text-right">{totales.pedidos}</td>
            <td className="px-4 py-3 text-right text-green-600">{formatPrecio(totales.pagado)}</td>
            <td className="px-4 py-3 text-right text-red-600">{formatPrecio(totales.pendiente)}</td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
