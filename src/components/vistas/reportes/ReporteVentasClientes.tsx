/**
 * Componente para mostrar el reporte de ventas por cliente
 */
import React from 'react';
import { Users } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import type { ClienteDB, VentaPorCliente } from '../../../types';

export interface ReporteVentasClientesProps {
  reporte: VentaPorCliente[];
  loading: boolean;
  formatPrecio: (precio: number) => string;
  onVerCliente?: (cliente: ClienteDB | null) => void;
}

export function ReporteVentasClientes({
  reporte,
  loading,
  formatPrecio,
  onVerCliente
}: ReporteVentasClientesProps): React.ReactElement {
  if (loading) return <LoadingSpinner />;

  if (reporte.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500 bg-white dark:bg-gray-800 rounded-lg">
        <Users className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p>No hay datos de ventas por cliente</p>
      </div>
    );
  }

  const totalVentas = reporte.reduce((s, r) => s + r.totalVentas, 0);
  const totalPedidos = reporte.reduce((s, r) => s + r.cantidadPedidos, 0);

  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg overflow-x-auto">
      <table className="w-full">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className="px-4 py-3 text-left text-sm font-medium">Cliente</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Pedidos</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Total</th>
            <th className="px-4 py-3 text-right text-sm font-medium">% Total</th>
            <th className="px-4 py-3 text-center text-sm font-medium">Acciones</th>
          </tr>
        </thead>
        <tbody className="divide-y dark:divide-gray-700">
          {reporte.slice(0, 30).map((r, i) => (
            <tr key={i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
              <td className="px-4 py-3">
                <p className="font-medium">{r.cliente?.nombre_fantasia || 'Cliente'}</p>
                <p className="text-sm text-gray-500">{r.cliente?.zona || 'Sin zona'}</p>
              </td>
              <td className="px-4 py-3 text-right">{r.cantidadPedidos}</td>
              <td className="px-4 py-3 text-right font-bold text-blue-600">
                {formatPrecio(r.totalVentas)}
              </td>
              <td className="px-4 py-3 text-right text-gray-600">
                {((r.totalVentas / totalVentas) * 100).toFixed(1)}%
              </td>
              <td className="px-4 py-3 text-center">
                <button
                  onClick={() => onVerCliente?.(r.cliente)}
                  className="text-blue-600 hover:text-blue-700 text-sm"
                >
                  Ver ficha
                </button>
              </td>
            </tr>
          ))}
        </tbody>
        <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
          <tr>
            <td className="px-4 py-3">TOTAL ({reporte.length} clientes)</td>
            <td className="px-4 py-3 text-right">{totalPedidos}</td>
            <td className="px-4 py-3 text-right text-blue-600">{formatPrecio(totalVentas)}</td>
            <td className="px-4 py-3 text-right">100%</td>
            <td></td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
