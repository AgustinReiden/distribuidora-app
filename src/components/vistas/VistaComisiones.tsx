/**
 * VistaComisiones
 *
 * Antes: `ventas × un % tipeado a mano` (`useState(2)`), sobre una base que no
 * filtraba canal y por eso no coincidía con la del reporte gerencial más que de
 * casualidad (COMIS-04). Ahora consume `calcular_comisiones`, que resuelve la
 * regla vigente ítem por ítem y usa exactamente la misma base que
 * `reporte_gerencial.base_comision`.
 */
import React, { useState } from 'react';
import { Percent, TrendingUp, Calendar, Info, Settings2, ChevronRight } from 'lucide-react';
import LoadingSpinner from '../layout/LoadingSpinner';
import { formatPrecio, fechaLocalISO } from '../../utils/formatters';
import { etiquetaOrigen } from '../../utils/origenPrecio';
import type { ComisionesResultado, ComisionPreventista } from '../../hooks/queries/useComisionesQuery';

type PeriodoComision = 'mes' | 'personalizado';

export interface VistaComisionesProps {
  resultado?: ComisionesResultado;
  loading: boolean;
  fechaDesde: string;
  fechaHasta: string;
  onFiltrar: (fechaDesde: string, fechaHasta: string) => void;
  /** Abre el ABM de reglas (solo admin). */
  onAbrirReglas?: () => void;
}

function getPrimerDiaMes(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`;
}

function getHoy(): string {
  return fechaLocalISO();
}

/** % efectivo del preventista: comisión / base. Es el dato que se lee de un vistazo. */
function pctEfectivo(p: ComisionPreventista): number {
  return p.base > 0 ? (p.comision / p.base) * 100 : 0;
}

function FilaPreventista({ p }: { p: ComisionPreventista }) {
  const [abierto, setAbierto] = useState(false);
  const desglosable = p.por_origen.length > 1;

  return (
    <>
      <tr className="hover:bg-gray-50 dark:hover:bg-gray-700/50">
        <td className="px-4 py-3">
          <button
            type="button"
            onClick={() => desglosable && setAbierto(!abierto)}
            className="flex items-center gap-1.5 text-left"
            aria-expanded={desglosable ? abierto : undefined}
          >
            {desglosable && (
              <ChevronRight
                className={`w-4 h-4 text-gray-400 transition-transform ${abierto ? 'rotate-90' : ''}`}
                aria-hidden="true"
              />
            )}
            <span>
              <span className="block font-medium text-gray-800 dark:text-white">{p.nombre}</span>
              <span className="block text-sm text-gray-500 dark:text-gray-400">{p.email}</span>
            </span>
          </button>
        </td>
        <td className="px-4 py-3 text-right font-bold text-blue-600 tabular-nums">{formatPrecio(p.base)}</td>
        <td className="px-4 py-3 text-right dark:text-gray-300 tabular-nums">{p.items}</td>
        <td className="px-4 py-3 text-right dark:text-gray-300 tabular-nums">{pctEfectivo(p).toFixed(2)}%</td>
        <td className="px-4 py-3 text-right font-bold text-green-600 tabular-nums">{formatPrecio(p.comision)}</td>
      </tr>
      {abierto && p.por_origen.map(o => (
        <tr key={o.origen} className="bg-gray-50/60 dark:bg-gray-900/30 text-sm">
          <td className="px-4 py-2 pl-11 text-gray-600 dark:text-gray-400">{etiquetaOrigen(o.origen)}</td>
          <td className="px-4 py-2 text-right text-gray-600 dark:text-gray-400 tabular-nums">{formatPrecio(o.base)}</td>
          <td className="px-4 py-2 text-right text-gray-600 dark:text-gray-400 tabular-nums">{o.items}</td>
          <td className="px-4 py-2 text-right text-gray-600 dark:text-gray-400 tabular-nums">
            {o.base > 0 ? `${((o.comision / o.base) * 100).toFixed(2)}%` : '—'}
          </td>
          <td className="px-4 py-2 text-right text-gray-600 dark:text-gray-400 tabular-nums">{formatPrecio(o.comision)}</td>
        </tr>
      ))}
    </>
  );
}

export default function VistaComisiones({
  resultado,
  loading,
  fechaDesde,
  fechaHasta,
  onFiltrar,
  onAbrirReglas,
}: VistaComisionesProps): React.ReactElement {
  const [periodo, setPeriodo] = useState<PeriodoComision>('mes');
  const [desdeLocal, setDesdeLocal] = useState(fechaDesde);
  const [hastaLocal, setHastaLocal] = useState(fechaHasta);

  const preventistas = resultado?.preventistas ?? [];
  const totales = resultado?.totales;

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

  return (
    <div className="space-y-4">
      {/* Header */}
      <div className="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-3">
        <h1 className="text-2xl font-bold dark:text-white">Comisiones</h1>
        {onAbrirReglas && (
          <button
            type="button"
            onClick={onAbrirReglas}
            className="inline-flex items-center gap-2 px-3 py-2 rounded-lg border dark:border-gray-700 bg-white dark:bg-gray-800 text-sm font-medium shadow-sm dark:text-gray-200"
          >
            <Settings2 className="w-4 h-4 text-indigo-600" aria-hidden="true" />
            Reglas de comisión
          </button>
        )}
      </div>

      {/* Filtros */}
      <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm p-4">
        <div className="flex flex-col sm:flex-row sm:items-end gap-3">
          <div>
            <label htmlFor="comision-periodo" className="block text-sm font-medium mb-1 dark:text-gray-300">Periodo</label>
            <select
              id="comision-periodo"
              value={periodo}
              onChange={e => handlePeriodoChange(e.target.value as PeriodoComision)}
              className="px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            >
              <option value="mes">Mes en curso</option>
              <option value="personalizado">Personalizado</option>
            </select>
          </div>
          <div>
            <label htmlFor="comision-desde" className="block text-sm font-medium mb-1 dark:text-gray-300">
              <Calendar className="w-3.5 h-3.5 inline mr-1" />Desde
            </label>
            <input
              id="comision-desde"
              type="date"
              value={desdeLocal}
              onChange={e => { setDesdeLocal(e.target.value); setPeriodo('personalizado'); }}
              className="px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            />
          </div>
          <div>
            <label htmlFor="comision-hasta" className="block text-sm font-medium mb-1 dark:text-gray-300">
              <Calendar className="w-3.5 h-3.5 inline mr-1" />Hasta
            </label>
            <input
              id="comision-hasta"
              type="date"
              value={hastaLocal}
              onChange={e => { setHastaLocal(e.target.value); setPeriodo('personalizado'); }}
              className="px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            />
          </div>
          <button
            onClick={() => onFiltrar(desdeLocal, hastaLocal)}
            className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 text-sm font-medium"
          >
            Calcular
          </button>
        </div>
      </div>

      {/* Ítems sin desglose: la comisión de esa parte es una estimación al %
          genérico, no un cálculo por origen. Decirlo es la diferencia entre un
          número confiable y uno que sólo parece exacto. */}
      {totales && totales.items_sin_desglose > 0 && (
        <div className="flex items-start gap-3 p-3 rounded-xl border border-amber-300 dark:border-amber-800/60 bg-amber-50 dark:bg-amber-900/20">
          <Info className="w-5 h-5 shrink-0 mt-0.5 text-amber-600 dark:text-amber-400" aria-hidden="true" />
          <div className="min-w-0">
            <p className="text-sm font-semibold text-amber-800 dark:text-amber-200">
              {totales.items_sin_desglose} de {totales.items} ítems sin desglose de descuento
            </p>
            <p className="text-xs text-amber-700 dark:text-amber-300 mt-0.5">
              Son ventas anteriores a que se empezara a registrar por qué se cobró cada precio
              ({formatPrecio(totales.base_sin_desglose)} de base). Para esos ítems la comisión sale
              de la regla genérica, no del origen real del descuento.
            </p>
          </div>
        </div>
      )}

      {/* Tabla */}
      {loading ? (
        <LoadingSpinner />
      ) : preventistas.length === 0 ? (
        <div className="text-center py-12 text-gray-500 dark:text-gray-400 bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm">
          <TrendingUp className="w-12 h-12 mx-auto mb-3 opacity-50" />
          <p className="font-semibold">No hay datos para el periodo seleccionado</p>
        </div>
      ) : (
        <div className="bg-white dark:bg-gray-800 border dark:border-gray-700 rounded-lg shadow-sm overflow-x-auto">
          <table className="w-full">
            <thead className="bg-gray-50 dark:bg-gray-700/50">
              <tr>
                <th className="px-4 py-3 text-left text-sm font-medium text-gray-700 dark:text-gray-300">Preventista</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Base</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Ítems</th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">
                  <Percent className="w-3.5 h-3.5 inline mr-1" />efectivo
                </th>
                <th className="px-4 py-3 text-right text-sm font-medium text-gray-700 dark:text-gray-300">Comisión</th>
              </tr>
            </thead>
            <tbody className="divide-y dark:divide-gray-700">
              {preventistas.map(p => <FilaPreventista key={p.id} p={p} />)}
            </tbody>
            {totales && (
              <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-bold">
                <tr>
                  <td className="px-4 py-3 dark:text-white">TOTAL</td>
                  <td className="px-4 py-3 text-right text-blue-600 tabular-nums">{formatPrecio(totales.base)}</td>
                  <td className="px-4 py-3 text-right dark:text-gray-300 tabular-nums">{totales.items}</td>
                  <td className="px-4 py-3 text-right dark:text-gray-300 tabular-nums">
                    {totales.base > 0 ? `${((totales.comision / totales.base) * 100).toFixed(2)}%` : '—'}
                  </td>
                  <td className="px-4 py-3 text-right text-green-600 tabular-nums">{formatPrecio(totales.comision)}</td>
                </tr>
              </tfoot>
            )}
          </table>
        </div>
      )}

      {resultado && (
        <p className="text-xs text-gray-500 dark:text-gray-400">
          Base: pedidos no cancelados del canal app, sin bonificaciones — la misma que usa el
          reporte gerencial. Sin regla que aplique se comisiona al {resultado.comision_default}%.
        </p>
      )}
    </div>
  );
}
