/**
 * Ventas totalizadas por cliente, con la zona que el cliente tiene en su ficha.
 *
 * Responde a "quiero ver a quiénes le vendió cada preventista y de qué zona son
 * esos clientes": la columna Zona hace visible la venta fuera de zona, que es
 * la lectura que el informe viene a dar.
 *
 * Los datos salen del RPC `reporte_ventas_por_cliente` (mig 197), no de una
 * agregación en el navegador: la versión anterior se comía el límite de 1.000
 * filas de PostgREST y además sumaba pedidos cancelados.
 */
import React, { useMemo, useState } from 'react';
import { Users, Download, Loader2 } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import { useVentasPorClienteQuery } from '../../../hooks/queries/useVentasPorClienteQuery';
import { labelMes } from '../../../utils/periodosReporte';

export interface ReporteVentasClientesProps {
  desde: string;
  hasta: string;
  preventistaId: string | null;
  formatPrecio: (precio: number) => string;
  onVerCliente?: (clienteId: string) => void;
}

export function ReporteVentasClientes({
  desde,
  hasta,
  preventistaId,
  formatPrecio,
  onVerCliente,
}: ReporteVentasClientesProps): React.ReactElement {
  const { data, isLoading, error } = useVentasPorClienteQuery(desde, hasta, preventistaId);
  const [verMeses, setVerMeses] = useState(false);
  const [exportando, setExportando] = useState(false);

  const meses = useMemo(() => data?.meses ?? [], [data]);
  const mostrarMeses = verMeses && meses.length > 1;

  const exportar = async (): Promise<void> => {
    if (!data) return;
    setExportando(true);
    try {
      const porCliente = data.clientes.map((c, i) => ({
        '#': i + 1,
        Cliente: c.nombre,
        Zona: c.zona,
        Pedidos: c.pedidos,
        Total: c.total,
        '% del total': data.totales.total ? c.total / data.totales.total : 0,
        ...Object.fromEntries(meses.map((m) => [labelMes(m), c.por_mes?.[m] ?? 0])),
      }));
      const porZona = data.zonas.map((z) => ({
        Zona: z.zona,
        Clientes: z.clientes,
        Pedidos: z.pedidos,
        Total: z.total,
        '% del total': data.totales.total ? z.total / data.totales.total : 0,
        'Ticket promedio': z.ticket_promedio,
      }));

      const { createMultiSheetExcel } = await import('../../../utils/excel');
      await createMultiSheetExcel(
        [
          { name: 'Por cliente', data: porCliente, columnWidths: [5, 42, 22, 10, 15, 12] },
          { name: 'Por zona', data: porZona, columnWidths: [24, 10, 10, 15, 12, 15] },
        ],
        `ventas-por-cliente-${data.meta.preventista_nombre}-${desde}_${hasta}`.replace(/\s+/g, '_')
      );
    } finally {
      setExportando(false);
    }
  };

  if (isLoading) return <LoadingSpinner />;

  if (error) {
    return (
      <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4 text-red-700 dark:text-red-300 text-sm">
        No se pudo cargar el reporte: {(error as Error).message}
      </div>
    );
  }

  if (!data || data.clientes.length === 0) {
    return (
      <div className="text-center py-12 text-gray-500 bg-white dark:bg-gray-800 rounded-lg">
        <Users className="w-12 h-12 mx-auto mb-3 opacity-50" />
        <p>No hay ventas entregadas en el período elegido</p>
      </div>
    );
  }

  const { totales } = data;

  return (
    <div className="space-y-3">
      {/* Resumen + export */}
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap gap-3 text-sm">
          <span className="px-3 py-1.5 rounded-lg bg-blue-50 dark:bg-blue-900/20 text-blue-700 dark:text-blue-300">
            <strong>{totales.clientes}</strong> clientes
          </span>
          <span className="px-3 py-1.5 rounded-lg bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-200">
            <strong>{totales.pedidos}</strong> pedidos
          </span>
          <span className="px-3 py-1.5 rounded-lg bg-green-50 dark:bg-green-900/20 text-green-700 dark:text-green-300">
            <strong>{formatPrecio(totales.total)}</strong>
          </span>
        </div>
        <div className="flex items-center gap-3">
          {meses.length > 1 && (
            <label className="flex items-center gap-2 text-sm text-gray-600 dark:text-gray-300 cursor-pointer">
              <input
                type="checkbox"
                checked={verMeses}
                onChange={(e) => setVerMeses(e.target.checked)}
                className="rounded border-gray-300 dark:border-gray-600"
              />
              Desglose por mes
            </label>
          )}
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
      </div>

      <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg overflow-x-auto">
        <table className="w-full text-sm">
          <thead className="bg-gray-50 dark:bg-gray-700/50">
            <tr>
              <th className="px-3 py-3 text-left font-medium w-10">#</th>
              <th className="px-3 py-3 text-left font-medium">Cliente</th>
              <th className="px-3 py-3 text-left font-medium">Zona (ficha)</th>
              <th className="px-3 py-3 text-right font-medium">Pedidos</th>
              <th className="px-3 py-3 text-right font-medium">Total</th>
              <th className="px-3 py-3 text-right font-medium">% Total</th>
              {mostrarMeses &&
                meses.map((m) => (
                  <th key={m} className="px-3 py-3 text-right font-medium whitespace-nowrap">
                    {labelMes(m)}
                  </th>
                ))}
              <th className="px-3 py-3 text-center font-medium">Acciones</th>
            </tr>
          </thead>
          <tbody className="divide-y dark:divide-gray-700">
            {data.clientes.map((c, i) => (
              <tr
                key={c.cliente_id ?? `sin-cliente-${i}`}
                className="hover:bg-gray-50 dark:hover:bg-gray-700/50"
              >
                <td className="px-3 py-2 text-gray-400">{i + 1}</td>
                <td className="px-3 py-2 font-medium text-gray-800 dark:text-gray-100">
                  {c.nombre}
                </td>
                <td className="px-3 py-2">
                  <span
                    className={
                      c.zona === 'SIN ZONA'
                        ? 'text-amber-600 dark:text-amber-400'
                        : 'text-gray-600 dark:text-gray-300'
                    }
                  >
                    {c.zona}
                  </span>
                </td>
                <td className="px-3 py-2 text-right">{c.pedidos}</td>
                <td className="px-3 py-2 text-right font-bold text-blue-600 dark:text-blue-400 whitespace-nowrap">
                  {formatPrecio(c.total)}
                </td>
                <td className="px-3 py-2 text-right text-gray-500">
                  {totales.total ? ((c.total / totales.total) * 100).toFixed(1) : '0.0'}%
                </td>
                {mostrarMeses &&
                  meses.map((m) => (
                    <td
                      key={m}
                      className="px-3 py-2 text-right text-gray-600 dark:text-gray-300 whitespace-nowrap"
                    >
                      {c.por_mes?.[m] ? formatPrecio(c.por_mes[m]) : '—'}
                    </td>
                  ))}
                <td className="px-3 py-2 text-center">
                  {c.cliente_id != null ? (
                    <button
                      onClick={() => onVerCliente?.(String(c.cliente_id))}
                      className="text-blue-600 hover:text-blue-700 dark:text-blue-400"
                    >
                      Ver ficha
                    </button>
                  ) : (
                    <span className="text-gray-400 text-xs">sin ficha</span>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
          <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
            <tr>
              <td className="px-3 py-3" />
              <td className="px-3 py-3">TOTAL ({totales.clientes} clientes)</td>
              <td />
              <td className="px-3 py-3 text-right">{totales.pedidos}</td>
              <td className="px-3 py-3 text-right text-blue-600 dark:text-blue-400 whitespace-nowrap">
                {formatPrecio(totales.total)}
              </td>
              <td className="px-3 py-3 text-right">100%</td>
              {mostrarMeses &&
                meses.map((m) => (
                  <td key={m} className="px-3 py-3 text-right whitespace-nowrap">
                    {formatPrecio(
                      data.clientes.reduce((s, c) => s + (c.por_mes?.[m] ?? 0), 0)
                    )}
                  </td>
                ))}
              <td />
            </tr>
          </tfoot>
        </table>
      </div>

      {data.clientes.some((c) => c.cliente_id == null) && (
        <p className="text-xs text-amber-700 dark:text-amber-400">
          La fila "(sin cliente asignado)" agrupa pedidos entregados que quedaron sin cliente en la
          base. Se muestran para que el total del informe coincida con el total de ventas.
        </p>
      )}
    </div>
  );
}
