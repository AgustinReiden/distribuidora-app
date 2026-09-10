/**
 * Reporte de mermas (mig 226).
 *
 * Reemplaza a `ModalHistorialMermas`, que vivía escondido en el toolbar de
 * Productos. Tres cosas cambian, y las tres importan:
 *
 *  1. La agregación pasó a la base. Antes el navegador bajaba las filas crudas
 *     y sumaba; el corte de 1.000 de PostgREST alimentaba los totales, así que
 *     truncar cambiaba los números EN SILENCIO. Ahora `totales` y `por_motivo`
 *     salen del período completo y sólo la LISTA está acotada.
 *  2. Se puede consolidar la red. Por PostgREST no se podía: la policy
 *     `mt_mermas_stock_select` ata el SELECT a `current_sucursal_id()`.
 *  3. El total cierra EXACTO contra las Mermas del reporte gerencial.
 *
 * Los dos filtros NO son la misma clase de cosa, y por eso se ven distinto:
 * el motivo va al servidor y mueve los totales; la búsqueda sólo achica la
 * lista que se está mirando. Un filtro que cambia el total y otro que no, con
 * el mismo aspecto, es lo que hace que nadie confíe en el número.
 */
import React, { useMemo, useState } from 'react';
import { TrendingDown, AlertTriangle, Download, Loader2, Info, Search } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import { useSucursal } from '../../../contexts/SucursalContext';
import {
  useMermasReporteQuery,
  fetchReporteMermas,
  LIMITE_DETALLE_MERMAS,
  type MermaDetalle,
} from '../../../hooks/queries/useMermasReporteQuery';
import { labelMotivo, labelClasificacion } from '../../../utils/mermasMotivo';
import { presetsVentas, type PeriodoPreset } from '../../../utils/periodosReporte';

export interface ReporteMermasProps {
  formatPrecio: (precio: number) => string;
}

const PRESET_CUSTOM = 'custom';

function fechaCorta(iso?: string | null): string {
  if (!iso) return '';
  return new Date(iso).toLocaleDateString('es-AR');
}

export function ReporteMermas({ formatPrecio }: ReporteMermasProps): React.ReactElement {
  const presets = useMemo(() => presetsVentas(), []);
  const [preset, setPreset] = useState<PeriodoPreset>(presets[0]);
  const [presetId, setPresetId] = useState<string>(presets[0].id);
  const [desde, setDesde] = useState<string>(presets[0].desde);
  const [hasta, setHasta] = useState<string>(presets[0].hasta);
  const [motivo, setMotivo] = useState<string>('todos');
  const [busqueda, setBusqueda] = useState<string>('');
  const [exportando, setExportando] = useState(false);

  const { sucursales, hasMultipleSucursales } = useSucursal();
  const [sucursalSel, setSucursalSel] = useState<number | null>(null);

  const opcionesSucursal = useMemo(() => {
    const list = sucursales.map((s) => ({ id: s.id as number | null, nombre: s.nombre }));
    return hasMultipleSucursales ? [{ id: null, nombre: 'Red (consolidado)' }, ...list] : list;
  }, [sucursales, hasMultipleSucursales]);

  const motivoParam = motivo === 'todos' ? null : motivo;
  const { data, isLoading, error } = useMermasReporteQuery(sucursalSel, desde, hasta, motivoParam);

  const elegirPreset = (id: string): void => {
    setPresetId(id);
    if (id === PRESET_CUSTOM) return;
    const p = presets.find((x) => x.id === id);
    if (!p) return;
    setPreset(p);
    setDesde(p.desde);
    setHasta(p.hasta);
  };

  // La búsqueda es SÓLO sobre la lista renderizada: no toca ningún total.
  const detalleVisible = useMemo<MermaDetalle[]>(() => {
    const filas = data?.detalle ?? [];
    const q = busqueda.trim().toLowerCase();
    if (!q) return filas;
    return filas.filter(
      (f) =>
        f.producto_nombre?.toLowerCase().includes(q) ||
        f.producto_codigo?.toLowerCase().includes(q) ||
        f.observaciones?.toLowerCase().includes(q),
    );
  }, [data, busqueda]);

  const exportar = async (): Promise<void> => {
    if (!data) return;
    setExportando(true);
    try {
      // Se re-consulta con el tope máximo: la pantalla muestra una lista
      // acotada, pero un Excel truncado en silencio es justo lo que este
      // reporte vino a arreglar.
      const completo = data.detalle_truncado
        ? await fetchReporteMermas(sucursalSel, desde, hasta, motivoParam, LIMITE_DETALLE_MERMAS)
        : data;

      const t = completo.totales;
      const meta: Record<string, unknown>[] = [
        { Campo: 'Sucursal', Valor: completo.meta.sucursal_nombre },
        { Campo: 'Desde', Valor: completo.meta.desde },
        { Campo: 'Hasta', Valor: completo.meta.hasta },
        { Campo: 'Criterio', Valor: completo.meta.criterio },
        { Campo: 'Filtro motivo', Valor: motivoParam ? labelMotivo(motivoParam) : 'Todos' },
        { Campo: 'Búsqueda en el detalle', Valor: busqueda.trim() || '(sin filtro)' },
        { Campo: 'Generado', Valor: completo.meta.generado_at },
        { Campo: 'Registros en el período', Valor: completo.detalle_total },
        { Campo: 'Registros en este archivo', Valor: completo.detalle.length },
        { Campo: 'Detalle recortado', Valor: completo.detalle_truncado ? 'Sí' : 'No' },
        { Campo: 'Pérdida a costo', Valor: t.costo },
        { Campo: 'Unidades', Valor: t.unidades },
        { Campo: 'A precio de venta de hoy', Valor: t.precio },
        { Campo: 'De los cuales, pérdida', Valor: t.costo_perdida },
        { Campo: 'De los cuales, ajustes', Valor: t.costo_ajuste },
        { Campo: 'De los cuales, muestras', Valor: t.costo_muestra },
        { Campo: 'Ajustes de promoción (registros)', Valor: t.registros_ajuste_promocion },
        { Campo: 'Ajustes de promoción (costo, NO suma)', Valor: t.costo_ajuste_promocion },
        { Campo: 'Filas con costo estimado', Valor: t.filas_costo_estimado },
        { Campo: 'Filas sin costo cargado (no suman)', Valor: t.filas_sin_costo },
        {
          Campo: 'Nota',
          Valor:
            'La columna Costo de "Resumen por motivo" NO suma a la pérdida total: incluye las filas de ajuste de promoción, que se informan aparte porque no son pérdida.',
        },
      ];

      const porMotivo: Record<string, unknown>[] = completo.por_motivo.map((m) => ({
        Motivo: labelMotivo(m.motivo),
        Clasificación: labelClasificacion(m.clasificacion),
        Registros: m.registros,
        Unidades: m.unidades,
        Costo: m.costo,
        'A precio de hoy': m.precio,
      }));
      porMotivo.push(
        {
          Motivo: 'TOTAL PÉRDIDA (sin ajustes de promoción)',
          Clasificación: '',
          Registros: t.registros,
          Unidades: t.unidades,
          Costo: t.costo,
          'A precio de hoy': t.precio,
        },
        {
          Motivo: 'Ajustes de promoción (no son pérdida)',
          Clasificación: '',
          Registros: t.registros_ajuste_promocion,
          Unidades: t.unidades_ajuste_promocion,
          Costo: t.costo_ajuste_promocion,
          'A precio de hoy': '',
        },
      );

      const detalle: Record<string, unknown>[] = completo.detalle.map((f) => ({
        Fecha: fechaCorta(f.created_at),
        Producto: f.producto_nombre,
        Código: f.producto_codigo ?? '',
        Categoría: f.producto_categoria ?? '',
        Sucursal: f.sucursal_nombre ?? '',
        Cantidad: f.cantidad,
        Motivo: labelMotivo(f.motivo),
        Clasificación: labelClasificacion(f.clasificacion),
        'Costo unitario': f.costo_unitario ?? '',
        'Costo total': f.costo_total ?? '',
        'Origen del costo': f.origen_costo,
        'Precio de hoy': f.precio_total ?? '',
        'Stock antes': f.stock_anterior,
        'Stock después': f.stock_nuevo,
        Usuario: f.usuario_nombre ?? 'Sin registrar',
        Observaciones: f.observaciones ?? '',
      }));

      const { createMultiSheetExcel } = await import('../../../utils/excel');
      await createMultiSheetExcel(
        [
          { name: 'Info', data: meta, columnWidths: [34, 34] },
          { name: 'Resumen por motivo', data: porMotivo, columnWidths: [38, 20, 11, 11, 14, 14] },
          {
            name: 'Detalle',
            data: detalle,
            columnWidths: [11, 32, 12, 20, 20, 10, 18, 18, 14, 14, 16, 14, 12, 13, 20, 40],
          },
        ],
        `mermas-${completo.meta.sucursal_nombre}-${desde}_${hasta}`.replace(/\s+/g, '_'),
      );
    } finally {
      setExportando(false);
    }
  };

  if (error) {
    return (
      <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4 text-red-700 dark:text-red-300 text-sm">
        No se pudo cargar el reporte de mermas: {(error as Error).message}
      </div>
    );
  }

  const t = data?.totales;
  const chip =
    'inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs font-medium';

  return (
    <div className="space-y-4">
      {/* Filtros propios */}
      <div className="bg-gray-50 dark:bg-gray-800/60 rounded-lg p-4 space-y-3">
        <div className="grid gap-3 md:grid-cols-4">
          <div>
            <label htmlFor="mermas-periodo" className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">
              Período
            </label>
            <select
              id="mermas-periodo" value={presetId} onChange={(e) => elegirPreset(e.target.value)}
              className="w-full px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 dark:text-gray-100"
            >
              {presets.map((p) => (<option key={p.id} value={p.id}>{p.label}</option>))}
              <option value={PRESET_CUSTOM}>Personalizado…</option>
            </select>
          </div>

          {presetId === PRESET_CUSTOM ? (
            <>
              <div>
                <label htmlFor="mermas-desde" className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Desde</label>
                <input id="mermas-desde" type="date" value={desde} onChange={(e) => setDesde(e.target.value)}
                  className="w-full px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 dark:text-gray-100" />
              </div>
              <div>
                <label htmlFor="mermas-hasta" className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Hasta</label>
                <input id="mermas-hasta" type="date" value={hasta} onChange={(e) => setHasta(e.target.value)}
                  className="w-full px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 dark:text-gray-100" />
              </div>
            </>
          ) : (
            <div className="md:col-span-2 flex items-end">
              <p className="text-xs text-gray-500 dark:text-gray-400">{preset.desde} al {preset.hasta}</p>
            </div>
          )}

          {opcionesSucursal.length > 1 && (
            <div>
              <label htmlFor="mermas-sucursal" className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Sucursal</label>
              <select
                id="mermas-sucursal"
                value={sucursalSel === null ? 'red' : String(sucursalSel)}
                onChange={(e) => setSucursalSel(e.target.value === 'red' ? null : Number(e.target.value))}
                className="w-full px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 dark:text-gray-100"
              >
                {opcionesSucursal.map((o) => (
                  <option key={o.id ?? 'red'} value={o.id === null ? 'red' : String(o.id)}>{o.nombre}</option>
                ))}
              </select>
            </div>
          )}
        </div>

        <div className="grid gap-3 md:grid-cols-2">
          <div>
            <label htmlFor="mermas-motivo" className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">
              Motivo <span className="text-gray-400">· cambia los totales</span>
            </label>
            <select
              id="mermas-motivo" value={motivo} onChange={(e) => setMotivo(e.target.value)}
              className="w-full px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 dark:text-gray-100"
            >
              <option value="todos">Todos los motivos</option>
              {(data?.por_motivo ?? []).map((m) => (
                <option key={m.motivo} value={m.motivo}>{labelMotivo(m.motivo)}</option>
              ))}
            </select>
          </div>
          <div>
            <label htmlFor="mermas-buscar" className="block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">
              Buscar en el detalle <span className="text-gray-400">· no cambia los totales</span>
            </label>
            <div className="relative">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
              <input
                id="mermas-buscar" type="text" value={busqueda} onChange={(e) => setBusqueda(e.target.value)}
                placeholder="Producto, código u observación"
                className="w-full pl-9 pr-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 dark:text-gray-100"
              />
            </div>
          </div>
        </div>
      </div>

      {isLoading || !data || !t ? (
        <LoadingSpinner />
      ) : (
        <>
          <div className="flex flex-wrap items-center justify-between gap-2">
            {motivoParam && (
              <span className={`${chip} bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300`}>
                Motivo: {labelMotivo(motivoParam)}
              </span>
            )}
            <button
              onClick={exportar} disabled={exportando || data.detalle_total === 0}
              className="ml-auto flex items-center gap-2 px-3 py-2 bg-green-600 text-white rounded-lg hover:bg-green-700 disabled:opacity-50 text-sm transition-colors"
            >
              {exportando ? <Loader2 className="w-4 h-4 animate-spin" /> : <Download className="w-4 h-4" />}
              Exportar a Excel
            </button>
          </div>

          {/* KPIs */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-rose-50 dark:bg-rose-900/20 p-4 rounded-lg">
              <p className="text-sm text-rose-600 dark:text-rose-400">Pérdida a costo</p>
              <p className="text-xl font-bold text-rose-700 dark:text-rose-300">{formatPrecio(t.costo)}</p>
              <p className="text-xs text-rose-600/70 dark:text-rose-400/70 mt-1">Costo congelado al momento de la merma</p>
            </div>
            <div className="bg-gray-100 dark:bg-gray-700/40 p-4 rounded-lg">
              <p className="text-sm text-gray-600 dark:text-gray-400">Unidades perdidas</p>
              <p className="text-xl font-bold text-gray-700 dark:text-gray-200">{t.unidades.toLocaleString('es-AR')}</p>
              <p className="text-xs text-gray-500 mt-1">{t.registros.toLocaleString('es-AR')} registros</p>
            </div>
            <div className="bg-amber-50 dark:bg-amber-900/20 p-4 rounded-lg">
              <p className="text-sm text-amber-600 dark:text-amber-400">A precio de venta de hoy</p>
              <p className="text-xl font-bold text-amber-700 dark:text-amber-300">{formatPrecio(t.precio)}</p>
              <p className="text-xs text-amber-600/70 dark:text-amber-400/70 mt-1">Lo que se hubiera facturado</p>
            </div>
            <div className="bg-blue-50 dark:bg-blue-900/20 p-4 rounded-lg">
              <p className="text-sm text-blue-600 dark:text-blue-400">Composición</p>
              <p className="text-xs text-blue-700 dark:text-blue-300 mt-1 leading-relaxed">
                Pérdida {formatPrecio(t.costo_perdida)}<br />
                Ajustes {formatPrecio(t.costo_ajuste)}<br />
                Muestras {formatPrecio(t.costo_muestra)}
              </p>
            </div>
          </div>

          {/* Divulgaciones: cada una explica por qué un número no es lo que parece. */}
          <div className="space-y-2">
            {t.registros_ajuste_promocion > 0 && (
              <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300 bg-gray-50 dark:bg-gray-800/60 rounded-lg p-3">
                <Info className="w-4 h-4 flex-shrink-0 mt-0.5 text-gray-400" />
                <span>
                  {t.registros_ajuste_promocion} registros son <strong>ajustes de promoción</strong> por{' '}
                  {formatPrecio(t.costo_ajuste_promocion)} y quedan <strong>fuera</strong> del total: no son pérdida,
                  son la contrapartida en stock de un regalo ya contabilizado como bonificación en el pedido.
                  Es el mismo criterio que usa el reporte gerencial.
                </span>
              </p>
            )}
            <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300 bg-gray-50 dark:bg-gray-800/60 rounded-lg p-3">
              <Info className="w-4 h-4 flex-shrink-0 mt-0.5 text-gray-400" />
              <span>El precio de venta es el de <strong>hoy</strong>: la base no guarda a cuánto se vendía el día de la merma.</span>
            </p>
            {t.filas_costo_estimado > 0 && (
              <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300 bg-gray-50 dark:bg-gray-800/60 rounded-lg p-3">
                <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5 text-amber-500" />
                <span>
                  {t.filas_costo_estimado} registros son anteriores a que se guardara el costo del momento:
                  van valuados al <strong>costo actual</strong> del producto.
                </span>
              </p>
            )}
            {t.filas_sin_costo > 0 && (
              <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300 bg-gray-50 dark:bg-gray-800/60 rounded-lg p-3">
                <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5 text-amber-500" />
                <span>
                  {t.filas_sin_costo} registros son de productos <strong>sin costo cargado</strong> y no suman al total.
                  No es que valgan $0: es que no se sabe cuánto valen.
                </span>
              </p>
            )}
            {data.detalle_truncado && (
              <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300 bg-amber-50 dark:bg-amber-900/20 rounded-lg p-3">
                <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5 text-amber-500" />
                <span>
                  El período tiene {data.detalle_total.toLocaleString('es-AR')} registros y se listan los{' '}
                  {data.detalle_limite.toLocaleString('es-AR')} más recientes.{' '}
                  <strong>Los totales de arriba son del período completo</strong>; sólo la lista está recortada.
                  El Excel se baja igual con todo lo que entre. Achicá el rango o filtrá por motivo.
                </span>
              </p>
            )}
          </div>

          {/* Resumen por motivo */}
          <div className="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 overflow-x-auto">
            <table className="w-full text-sm">
              <thead className="bg-gray-50 dark:bg-gray-700/50">
                <tr>
                  <th className="px-4 py-2 text-left font-semibold text-gray-600 dark:text-gray-300">Motivo</th>
                  <th className="px-4 py-2 text-left font-semibold text-gray-600 dark:text-gray-300">Clasificación</th>
                  <th className="px-4 py-2 text-right font-semibold text-gray-600 dark:text-gray-300">Registros</th>
                  <th className="px-4 py-2 text-right font-semibold text-gray-600 dark:text-gray-300">Unidades</th>
                  <th className="px-4 py-2 text-right font-semibold text-gray-600 dark:text-gray-300">Costo</th>
                  <th className="px-4 py-2 text-right font-semibold text-gray-600 dark:text-gray-300">A precio de hoy</th>
                </tr>
              </thead>
              <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
                {data.por_motivo.map((m) => {
                  const esPromo = m.clasificacion === 'promocion';
                  return (
                    <tr key={m.motivo} className={esPromo ? 'text-gray-400 dark:text-gray-500' : 'text-gray-700 dark:text-gray-200'}>
                      <td className="px-4 py-2 font-medium">{labelMotivo(m.motivo)}</td>
                      <td className="px-4 py-2">
                        {esPromo ? (
                          <span className={`${chip} bg-gray-100 text-gray-500 dark:bg-gray-700 dark:text-gray-400`}>
                            Ajuste de promoción · fuera del total
                          </span>
                        ) : (
                          labelClasificacion(m.clasificacion)
                        )}
                      </td>
                      <td className="px-4 py-2 text-right tabular-nums">{m.registros.toLocaleString('es-AR')}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{m.unidades.toLocaleString('es-AR')}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatPrecio(m.costo)}</td>
                      <td className="px-4 py-2 text-right tabular-nums">{formatPrecio(m.precio)}</td>
                    </tr>
                  );
                })}
                <tr className="font-semibold border-t-2 border-gray-200 dark:border-gray-600 text-gray-800 dark:text-gray-100">
                  <td className="px-4 py-2" colSpan={2}>TOTAL PÉRDIDA (sin ajustes de promoción)</td>
                  <td className="px-4 py-2 text-right tabular-nums">{t.registros.toLocaleString('es-AR')}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{t.unidades.toLocaleString('es-AR')}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{formatPrecio(t.costo)}</td>
                  <td className="px-4 py-2 text-right tabular-nums">{formatPrecio(t.precio)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          {/* Detalle */}
          <div>
            <p className="text-xs text-gray-500 dark:text-gray-400 mb-2">
              Mostrando {detalleVisible.length.toLocaleString('es-AR')} de{' '}
              {data.detalle_total.toLocaleString('es-AR')} registros del período
            </p>
            {detalleVisible.length === 0 ? (
              <div className="text-center py-10 text-gray-500 dark:text-gray-400">
                <TrendingDown className="w-10 h-10 mx-auto mb-2 opacity-40" />
                <p className="text-sm">No hay mermas que coincidan con los filtros.</p>
              </div>
            ) : (
              <div className="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 overflow-x-auto">
                <table className="w-full text-sm">
                  <thead className="bg-gray-50 dark:bg-gray-700/50">
                    <tr>
                      <th className="px-4 py-2 text-left font-semibold text-gray-600 dark:text-gray-300">Fecha</th>
                      <th className="px-4 py-2 text-left font-semibold text-gray-600 dark:text-gray-300">Producto</th>
                      <th className="px-4 py-2 text-left font-semibold text-gray-600 dark:text-gray-300">Motivo</th>
                      <th className="px-4 py-2 text-right font-semibold text-gray-600 dark:text-gray-300">Cant.</th>
                      <th className="px-4 py-2 text-right font-semibold text-gray-600 dark:text-gray-300">Costo</th>
                      <th className="px-4 py-2 text-left font-semibold text-gray-600 dark:text-gray-300">Usuario</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
                    {detalleVisible.map((f) => (
                      <tr key={f.id} className="text-gray-700 dark:text-gray-200">
                        <td className="px-4 py-2 whitespace-nowrap">{fechaCorta(f.created_at)}</td>
                        <td className="px-4 py-2">
                          <span className="font-medium">{f.producto_nombre}</span>
                          {f.producto_codigo && (
                            <span className="text-xs text-gray-400 ml-1">({f.producto_codigo})</span>
                          )}
                          {f.observaciones && (
                            <p className="text-xs text-gray-500 dark:text-gray-400">{f.observaciones}</p>
                          )}
                        </td>
                        <td className="px-4 py-2">
                          <span className="whitespace-nowrap">{labelMotivo(f.motivo)}</span>
                          {f.clasificacion === 'promocion' && (
                            <span className={`${chip} ml-1 bg-gray-100 text-gray-500 dark:bg-gray-700 dark:text-gray-400`}>
                              fuera del total
                            </span>
                          )}
                          {f.origen_costo === 'estimado' && (
                            <span className={`${chip} ml-1 bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300`}>
                              costo estimado
                            </span>
                          )}
                          {f.origen_costo === 'sin_costo' && (
                            <span className={`${chip} ml-1 bg-amber-100 text-amber-700 dark:bg-amber-900/40 dark:text-amber-300`}>
                              sin costo
                            </span>
                          )}
                        </td>
                        {/* Una reversión de promoción devuelve stock: cantidad negativa.
                            El signo se arma acá, no se prefija a ciegas: '-' + (-3) daba '--3'. */}
                        <td className="px-4 py-2 text-right tabular-nums whitespace-nowrap">
                          {f.cantidad > 0 ? `-${f.cantidad}` : `+${Math.abs(f.cantidad)}`}
                        </td>
                        <td className="px-4 py-2 text-right tabular-nums">
                          {f.costo_total == null ? '—' : formatPrecio(f.costo_total)}
                        </td>
                        <td className="px-4 py-2 text-gray-500 dark:text-gray-400">
                          {f.usuario_nombre ?? 'Sin registrar'}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}

export default ReporteMermas;
