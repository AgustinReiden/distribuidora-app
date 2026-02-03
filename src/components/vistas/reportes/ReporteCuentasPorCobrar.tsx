/**
 * Componente para mostrar el reporte de cuentas por cobrar con aging
 */
import React from 'react';
import { DollarSign } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import type { ClienteDB, ReporteCuentaPorCobrar } from '../../../types';

export interface ReporteCuentasPorCobrarProps {
  reporte: ReporteCuentaPorCobrar[];
  loading: boolean;
  formatPrecio: (precio: number) => string;
  onVerCliente?: (cliente: ClienteDB) => void;
}

export function ReporteCuentasPorCobrar({
  reporte,
  loading,
  formatPrecio,
  onVerCliente
}: ReporteCuentasPorCobrarProps): React.ReactElement {
  if (loading) return <LoadingSpinner />;

  // Totales por aging
  const totalCorriente = reporte.reduce((s, r) => s + r.aging.corriente, 0);
  const total30 = reporte.reduce((s, r) => s + r.aging.vencido30, 0);
  const total60 = reporte.reduce((s, r) => s + r.aging.vencido60, 0);
  const total90 = reporte.reduce((s, r) => s + r.aging.vencido90, 0);
  const totalGeneral = reporte.reduce((s, r) => s + r.saldoPendiente, 0);

  return (
    <div className="space-y-4">
      {/* Resumen Aging */}
      <div className="grid grid-cols-2 md:grid-cols-5 gap-4">
        <div className="bg-green-50 dark:bg-green-900/20 p-4 rounded-lg">
          <p className="text-sm text-green-600 dark:text-green-400">Corriente</p>
          <p className="text-xl font-bold text-green-700 dark:text-green-300">
            {formatPrecio(totalCorriente)}
          </p>
        </div>
        <div className="bg-yellow-50 dark:bg-yellow-900/20 p-4 rounded-lg">
          <p className="text-sm text-yellow-600 dark:text-yellow-400">1-30 días</p>
          <p className="text-xl font-bold text-yellow-700 dark:text-yellow-300">
            {formatPrecio(total30)}
          </p>
        </div>
        <div className="bg-orange-50 dark:bg-orange-900/20 p-4 rounded-lg">
          <p className="text-sm text-orange-600 dark:text-orange-400">31-60 días</p>
          <p className="text-xl font-bold text-orange-700 dark:text-orange-300">
            {formatPrecio(total60)}
          </p>
        </div>
        <div className="bg-red-50 dark:bg-red-900/20 p-4 rounded-lg">
          <p className="text-sm text-red-600 dark:text-red-400">+60 días</p>
          <p className="text-xl font-bold text-red-700 dark:text-red-300">{formatPrecio(total90)}</p>
        </div>
        <div className="bg-gray-100 dark:bg-gray-700 p-4 rounded-lg">
          <p className="text-sm text-gray-600 dark:text-gray-400">Total</p>
          <p className="text-xl font-bold text-gray-900 dark:text-white">
            {formatPrecio(totalGeneral)}
          </p>
        </div>
      </div>

      {reporte.length === 0 ? (
        <div className="text-center py-12 text-gray-500 bg-white dark:bg-gray-800 rounded-lg">
          <DollarSign className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p>No hay cuentas pendientes de cobro</p>
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium">Cliente</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Saldo</th>
                <th className="px-4 py-3 text-right text-sm font-medium">Corriente</th>
                <th className="px-4 py-3 text-right text-sm font-medium">1-30</th>
                <th className="px-4 py-3 text-right text-sm font-medium">31-60</th>
                <th className="px-4 py-3 text-right text-sm font-medium">+60</th>
                <th className="px-4 py-3 text-center text-sm font-medium">Acciones</th>
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {reporte.map((r, i) => (
                <tr key={i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
                  <td className="px-4 py-3">
                    <p className="font-medium">{r.cliente.nombre_fantasia}</p>
                    <p className="text-sm text-gray-500">{r.cliente.zona || 'Sin zona'}</p>
                  </td>
                  <td className="px-4 py-3 text-right font-bold text-red-600">
                    {formatPrecio(r.saldoPendiente)}
                  </td>
                  <td className="px-4 py-3 text-right text-green-600">
                    {r.aging.corriente > 0 ? formatPrecio(r.aging.corriente) : '-'}
                  </td>
                  <td className="px-4 py-3 text-right text-yellow-600">
                    {r.aging.vencido30 > 0 ? formatPrecio(r.aging.vencido30) : '-'}
                  </td>
                  <td className="px-4 py-3 text-right text-orange-600">
                    {r.aging.vencido60 > 0 ? formatPrecio(r.aging.vencido60) : '-'}
                  </td>
                  <td className="px-4 py-3 text-right text-red-600">
                    {r.aging.vencido90 > 0 ? formatPrecio(r.aging.vencido90) : '-'}
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
          </table>
        </div>
      )}
    </div>
  );
}
