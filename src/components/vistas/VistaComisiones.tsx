import React, { useState, useMemo } from 'react';
import { Percent, TrendingUp, Calendar } from 'lucide-react';
import LoadingSpinner from '../layout/LoadingSpinner';
import { formatPrecio } from '../../utils/formatters';
import type { ReportePreventista } from '../../types';

type PeriodoComision = 'mes' | 'personalizado';

export interface VistaComisionesProps {
  reporte: ReportePreventista[];
  loading: boolean;
  fechaDesde: string;
  fechaHasta: string;
  onFiltrar: (fechaDesde: string, fechaHasta: string) => void;
}

function getPrimerDiaMes(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`;
}

function getHoy(): string {
  return new Date().toISOString().split('T')[0];
}

export default function VistaComisiones({
  reporte,
  loading,
  fechaDesde,
  fechaHasta,
  onFiltrar,
}: VistaComisionesProps): React.ReactElement {
  const [porcentaje, setPorcentaje] = useState(2);
  const [periodo, setPeriodo] = useState<PeriodoComision>('mes');
  const [desdeLocal, setDesdeLocal] = useState(fechaDesde);
  const [hastaLocal, setHastaLocal] = useState(fechaHasta);

  const totales = useMemo(() => {
    const ventas = reporte.reduce((s, p) => s + p.totalVentas, 0);
    const pedidos = reporte.reduce((s, p) => s + p.cantidadPedidos, 0);
    return { ventas, pedidos, comision: ventas * (porcentaje / 100) };
  }, [reporte, porcentaje]);

  const handlePeriodoChange = (p: PeriodoComision) => {
    setPeriodo(p);
    if (p === 'mes') {
      const desde = getPrimerDiaMes();
      const hasta = getHoy();
      setDesdeLocal(desde);
      setHastaLocal(hasta);
      onFiltrar(desde, hasta);
    }
  };

  const handleCalcular = () => {
    onFiltrar(desdeLocal, hastaLocal);
  };

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <h1 className="text-2xl font-bold dark:text-white">Comisiones</h1>
        <div className="flex items-center gap-2 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg px-3 py-2 shadow-sm">
          <Percent className="w-4 h-4 text-gray-500" />
          <label className="text-sm font-medium dark:text-gray-300">Comision:</label>
          <input
            type="number"
            min="0"
            max="100"
            step="0.5"
            value={porcentaje}
            onChange={e => setPorcentaje(parseFloat(e.target.value) || 0)}
            className="w-16 px-2 py-1 border rounded text-center text-sm font-semibold dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          />
          <span className="text-sm font-medium dark:text-gray-300">%</span>
        </div>
      </div>

      {/* Filtros */}
      <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4">
        <div className="flex flex-col sm:flex-row sm:items-end gap-3">
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-300">Periodo</label>
            <select
              value={periodo}
              onChange={e => handlePeriodoChange(e.target.value as PeriodoComision)}
              className="px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            >
              <option value="mes">Mes en curso</option>
              <option value="personalizado">Personalizado</option>
            </select>
          </div>
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-300">
              <Calendar className="w-3.5 h-3.5 inline mr-1" />Desde
            </label>
            <input
              type="date"
              value={desdeLocal}
              onChange={e => { setDesdeLocal(e.target.value); setPeriodo('personalizado'); }}
              className="px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-300">
              <Calendar className="w-3.5 h-3.5 inline mr-1" />Hasta
            </label>
            <input
              type="date"
              value={hastaLocal}
              onChange={e => { setHastaLocal(e.target.value); setPeriodo('personalizado'); }}
              className="px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            />
          </div>
          <button
            onClick={handleCalcular}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 text-sm font-medium"
          >
            Calcular
          </button>
        </div>
      </div>

      {/* Tabla */}
      {loading ? (
        <LoadingSpinner />
      ) : reporte.length === 0 ? (
        <div className="text-center py-12 text-gray-500 dark:text-gray-400 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm">
          <TrendingUp className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p className="font-semibold">No hay datos para el periodo seleccionado</p>
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Usuario</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Ventas Brutas</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Pedidos</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">
                  Comision ({porcentaje}%)
                </th>
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {reporte.map((p, i) => (
                <tr key={p.id || i} className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
                  <td className="px-4 py-3">
                    <p className="font-medium text-gray-800 dark:text-white">{p.nombre}</p>
                    <p className="text-sm text-gray-500 dark:text-gray-400">{p.email}</p>
                  </td>
                  <td className="px-4 py-3 text-right font-bold text-blue-600">
                    {formatPrecio(p.totalVentas)}
                  </td>
                  <td className="px-4 py-3 text-right dark:text-gray-300">{p.cantidadPedidos}</td>
                  <td className="px-4 py-3 text-right font-bold text-green-600">
                    {formatPrecio(p.totalVentas * (porcentaje / 100))}
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
              <tr>
                <td className="px-4 py-3 dark:text-white">TOTAL</td>
                <td className="px-4 py-3 text-right text-blue-600">{formatPrecio(totales.ventas)}</td>
                <td className="px-4 py-3 text-right dark:text-gray-300">{totales.pedidos}</td>
                <td className="px-4 py-3 text-right text-green-600">{formatPrecio(totales.comision)}</td>
              </tr>
            </tfoot>
          </table>
        </div>
      )}
    </div>
  );
}
