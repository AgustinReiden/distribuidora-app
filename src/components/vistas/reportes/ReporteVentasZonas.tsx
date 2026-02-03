/**
 * Componente para mostrar el reporte de ventas por zona geográfica
 */
import React from 'react';
import { MapPin } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import type { VentaPorZona } from '../../../types';

export interface ReporteVentasZonasProps {
  reporte: VentaPorZona[];
  loading: boolean;
  formatPrecio: (precio: number) => string;
}

export function ReporteVentasZonas({
  reporte,
  loading,
  formatPrecio
}: ReporteVentasZonasProps): React.ReactElement {
  if (loading) return <LoadingSpinner />;

  if (reporte.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500 bg-white dark:bg-gray-800 rounded-lg">
        <MapPin className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p>No hay datos de ventas por zona</p>
      </div>
    );
  }

  const totalVentas = reporte.reduce((s, r) => s + r.totalVentas, 0);
  const totalClientes = reporte.reduce((s, r) => s + r.cantidadClientes, 0);
  const totalPedidos = reporte.reduce((s, r) => s + r.cantidadPedidos, 0);

  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg overflow-x-auto">
      <table className="w-full">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className="px-4 py-3 text-left text-sm font-medium">Zona</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Clientes</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Pedidos</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Total</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Ticket Prom.</th>
            <th className="px-4 py-3 text-right text-sm font-medium">% Total</th>
          </tr>
        </thead>
        <tbody className="divide-y dark:divide-gray-700">
          {reporte.map((r, i) => (
            <tr key={i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
              <td className="px-4 py-3 font-medium">{r.zona}</td>
              <td className="px-4 py-3 text-right">{r.cantidadClientes}</td>
              <td className="px-4 py-3 text-right">{r.cantidadPedidos}</td>
              <td className="px-4 py-3 text-right font-bold text-blue-600">
                {formatPrecio(r.totalVentas)}
              </td>
              <td className="px-4 py-3 text-right text-gray-600">
                {formatPrecio(r.ticketPromedio)}
              </td>
              <td className="px-4 py-3 text-right">
                <div className="flex items-center justify-end gap-2">
                  <div className="w-16 bg-gray-200 rounded-full h-2">
                    <div
                      className="bg-blue-600 h-2 rounded-full"
                      style={{ width: `${(r.totalVentas / totalVentas) * 100}%` }}
                    />
                  </div>
                  <span className="text-sm">{((r.totalVentas / totalVentas) * 100).toFixed(1)}%</span>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
        <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
          <tr>
            <td className="px-4 py-3">TOTAL</td>
            <td className="px-4 py-3 text-right">{totalClientes}</td>
            <td className="px-4 py-3 text-right">{totalPedidos}</td>
            <td className="px-4 py-3 text-right text-blue-600">{formatPrecio(totalVentas)}</td>
            <td className="px-4 py-3 text-right">
              {formatPrecio(totalVentas / Math.max(1, totalPedidos))}
            </td>
            <td className="px-4 py-3 text-right">100%</td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
