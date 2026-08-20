/**
 * Ventas por zona geográfica (la zona de la ficha del cliente).
 *
 * Lee el MISMO hook que "Por Cliente" con los mismos parámetros: React Query
 * comparte la entrada de cache, así que cambiar de pestaña no dispara otro
 * viaje. Antes esta pestaña agregaba en el navegador y arrastraba los mismos
 * dos bugs que la de clientes (contaba cancelados y se cortaba en 1.000 filas).
 */
import React from 'react';
import { MapPin } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import { useVentasPorClienteQuery } from '../../../hooks/queries/useVentasPorClienteQuery';

export interface ReporteVentasZonasProps {
  desde: string;
  hasta: string;
  preventistaId: string | null;
  formatPrecio: (precio: number) => string;
}

export function ReporteVentasZonas({
  desde,
  hasta,
  preventistaId,
  formatPrecio,
}: ReporteVentasZonasProps): React.ReactElement {
  const { data, isLoading, error } = useVentasPorClienteQuery(desde, hasta, preventistaId);

  if (isLoading) return <LoadingSpinner />;

  if (error) {
    return (
      <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4 text-red-700 dark:text-red-300 text-sm">
        No se pudo cargar el reporte: {(error as Error).message}
      </div>
    );
  }

  if (!data || data.zonas.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500 bg-white dark:bg-gray-800 rounded-lg">
        <MapPin className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p>No hay ventas entregadas en el período elegido</p>
      </div>
    );
  }

  const { totales, zonas } = data;

  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg overflow-x-auto">
      <table className="w-full">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className="px-4 py-3 text-left text-sm font-medium">Zona (ficha)</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Clientes</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Pedidos</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Total</th>
            <th className="px-4 py-3 text-right text-sm font-medium">Ticket Prom.</th>
            <th className="px-4 py-3 text-right text-sm font-medium">% Total</th>
          </tr>
        </thead>
        <tbody className="divide-y dark:divide-gray-700">
          {zonas.map((z) => (
            <tr key={z.zona} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
              <td
                className={`px-4 py-3 font-medium ${
                  z.zona === 'SIN ZONA' ? 'text-amber-600 dark:text-amber-400' : ''
                }`}
              >
                {z.zona}
              </td>
              <td className="px-4 py-3 text-right">{z.clientes}</td>
              <td className="px-4 py-3 text-right">{z.pedidos}</td>
              <td className="px-4 py-3 text-right font-bold text-blue-600 dark:text-blue-400">
                {formatPrecio(z.total)}
              </td>
              <td className="px-4 py-3 text-right text-gray-600 dark:text-gray-300">
                {formatPrecio(z.ticket_promedio)}
              </td>
              <td className="px-4 py-3 text-right">
                <div className="flex items-center justify-end gap-2">
                  <div className="w-16 bg-gray-200 dark:bg-gray-600 rounded-full h-2">
                    <div
                      className="bg-blue-600 h-2 rounded-full"
                      style={{
                        width: `${totales.total ? (z.total / totales.total) * 100 : 0}%`,
                      }}
                    />
                  </div>
                  <span className="text-sm">
                    {totales.total ? ((z.total / totales.total) * 100).toFixed(1) : '0.0'}%
                  </span>
                </div>
              </td>
            </tr>
          ))}
        </tbody>
        <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
          <tr>
            <td className="px-4 py-3">TOTAL</td>
            <td className="px-4 py-3 text-right">{totales.clientes}</td>
            <td className="px-4 py-3 text-right">{totales.pedidos}</td>
            <td className="px-4 py-3 text-right text-blue-600 dark:text-blue-400">
              {formatPrecio(totales.total)}
            </td>
            <td className="px-4 py-3 text-right">
              {formatPrecio(totales.total / Math.max(1, totales.pedidos))}
            </td>
            <td className="px-4 py-3 text-right">100%</td>
          </tr>
        </tfoot>
      </table>
    </div>
  );
}
