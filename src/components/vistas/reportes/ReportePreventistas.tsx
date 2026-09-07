/**
 * Componente para mostrar el reporte de ventas por preventista
 */
import React, { useState } from 'react';
import { TrendingUp, Download, Loader2 } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import type { ReportePreventista } from '../../../types';

export interface ReportePreventistasProps {
  reportePreventistas: ReportePreventista[];
  loading: boolean;
  formatPrecio: (precio: number) => string;
  /** Sólo para el nombre del archivo: '' = sin filtro de fecha. */
  desde?: string;
  hasta?: string;
}

export function ReportePreventistas({
  reportePreventistas,
  loading,
  formatPrecio,
  desde = '',
  hasta = ''
}: ReportePreventistasProps): React.ReactElement {
  const [exportando, setExportando] = useState(false);

  const totales = {
    ventas: reportePreventistas.reduce((s, p) => s + p.totalVentas, 0),
    pedidos: reportePreventistas.reduce((s, p) => s + p.cantidadPedidos, 0),
    pagado: reportePreventistas.reduce((s, p) => s + p.totalPagado, 0),
    pendiente: reportePreventistas.reduce((s, p) => s + p.totalPendiente, 0)
  };

  // Sin filtro de fecha el reporte es de todo el histórico, y el archivo tiene
  // que decirlo: 'todo' y no un rango inventado.
  const periodo = desde || hasta ? `${desde || 'inicio'}_${hasta || 'hoy'}` : 'todo';

  const exportar = async (): Promise<void> => {
    if (reportePreventistas.length === 0) return;
    setExportando(true);
    try {
      const filas = reportePreventistas.map((p) => ({
        Preventista: p.nombre,
        Email: p.email ?? '',
        'Total ventas': p.totalVentas,
        Pedidos: p.cantidadPedidos,
        Pagado: p.totalPagado,
        Pendiente: p.totalPendiente
      }));
      // La fila TOTAL viaja en el Excel porque está en la pantalla: un archivo
      // que no la trae obliga a rehacer la suma para confirmar que es el mismo
      // reporte.
      filas.push({
        Preventista: 'TOTAL',
        Email: '',
        'Total ventas': totales.ventas,
        Pedidos: totales.pedidos,
        Pagado: totales.pagado,
        Pendiente: totales.pendiente
      });

      const { createMultiSheetExcel } = await import('../../../utils/excel');
      await createMultiSheetExcel(
        [{ name: 'Por preventista', data: filas, columnWidths: [28, 30, 16, 10, 16, 16] }],
        `ventas-por-preventista-${periodo}`
      );
    } finally {
      setExportando(false);
    }
  };

  if (loading) return <LoadingSpinner />;

  if (reportePreventistas.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500 dark:text-gray-400 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm">
        <TrendingUp className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p className="font-semibold">No hay datos para mostrar</p>
      </div>
    );
  }

  return (
    <div className="space-y-3">
      <div className="flex justify-end">
        <button
          onClick={exportar}
          disabled={exportando}
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
    </div>
  );
}
