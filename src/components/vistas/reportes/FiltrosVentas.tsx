/**
 * Filtros compartidos por las pestañas "Por Cliente" y "Por Zona":
 * preventista + período. El estado vive en VistaReportes y los dos reportes
 * consumen el mismo hook con los mismos parámetros, así que React Query
 * resuelve las dos pestañas con un solo viaje.
 */
import React from 'react';
import { Calendar, User } from 'lucide-react';
import { useVentasPorClienteQuery } from '../../../hooks/queries/useVentasPorClienteQuery';
import { formatCurrencyCompact } from '../../../utils/formatters';
import { presetsVentas, type PeriodoPreset } from '../../../utils/periodosReporte';
import type { FiltrosVentasValue } from './filtrosVentasState';

export interface FiltrosVentasProps {
  value: FiltrosVentasValue;
  onChange: (value: FiltrosVentasValue) => void;
}

const inputCls =
  'px-3 py-2 border dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 text-sm text-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500';

export function FiltrosVentas({ value, onChange }: FiltrosVentasProps): React.ReactElement {
  // Con preventistaId = null a propósito: es la lista completa de quien vendió
  // en el período, y no se achica al elegir a alguien. Con el filtro en "Todos"
  // comparte la query key con el reporte, así que no agrega un viaje.
  const { data } = useVentasPorClienteQuery(value.desde, value.hasta, null);
  const vendedores = data?.vendedores ?? [];
  const presets: PeriodoPreset[] = presetsVentas();

  // Si el elegido no vendió nada en el período nuevo, la opción desaparecería y
  // el <select> se vería en "Todos" mientras el filtro sigue aplicado. Se
  // mantiene visible y dice por qué la tabla está vacía.
  const elegidoSinVentas =
    value.preventistaId != null &&
    vendedores.length > 0 &&
    !vendedores.some((v) => v.id === value.preventistaId);

  const elegirPreset = (presetId: string): void => {
    if (presetId === 'custom') {
      onChange({ ...value, presetId });
      return;
    }
    const p = presets.find((x) => x.id === presetId);
    if (p) onChange({ ...value, presetId, desde: p.desde, hasta: p.hasta });
  };

  return (
    <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4 space-y-3">
      <div className="flex flex-wrap gap-3 items-end">
        <div>
          <label
            htmlFor="ventas-preventista"
            className="block text-xs font-medium mb-1 text-gray-600 dark:text-gray-400"
          >
            <User className="w-3 h-3 inline mr-1" />
            Vendedor
          </label>
          <select
            id="ventas-preventista"
            value={value.preventistaId ?? ''}
            onChange={(e) => onChange({ ...value, preventistaId: e.target.value || null })}
            className={inputCls}
          >
            <option value="">Todos</option>
            {elegidoSinVentas && (
              <option value={value.preventistaId as string}>Sin ventas en el período</option>
            )}
            {vendedores.map((v) => (
              <option key={v.id} value={v.id}>
                {v.nombre} — {formatCurrencyCompact(v.total)}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label
            htmlFor="ventas-periodo"
            className="block text-xs font-medium mb-1 text-gray-600 dark:text-gray-400"
          >
            <Calendar className="w-3 h-3 inline mr-1" />
            Período
          </label>
          <select
            id="ventas-periodo"
            value={value.presetId}
            onChange={(e) => elegirPreset(e.target.value)}
            className={inputCls}
          >
            {presets.map((p) => (
              <option key={p.id} value={p.id}>
                {p.label}
              </option>
            ))}
            <option value="custom">Personalizado…</option>
          </select>
        </div>

        {value.presetId === 'custom' && (
          <>
            <div>
              <label
                htmlFor="ventas-desde"
                className="block text-xs font-medium mb-1 text-gray-600 dark:text-gray-400"
              >
                Desde
              </label>
              <input
                id="ventas-desde"
                type="date"
                value={value.desde}
                max={value.hasta}
                onChange={(e) => onChange({ ...value, desde: e.target.value })}
                className={inputCls}
              />
            </div>
            <div>
              <label
                htmlFor="ventas-hasta"
                className="block text-xs font-medium mb-1 text-gray-600 dark:text-gray-400"
              >
                Hasta
              </label>
              <input
                id="ventas-hasta"
                type="date"
                value={value.hasta}
                min={value.desde}
                onChange={(e) => onChange({ ...value, hasta: e.target.value })}
                className={inputCls}
              />
            </div>
          </>
        )}
      </div>

      <p className="text-xs text-gray-500 dark:text-gray-400">
        Venta = pedidos <strong>entregados</strong>, por fecha del pedido, atribuidos a quien lo
        cargó. No cuenta cancelados ni cambios/devoluciones.
      </p>
    </div>
  );
}
