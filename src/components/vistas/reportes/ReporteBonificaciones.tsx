/**
 * Reporte de bonificaciones: lo regalado por promoción, agregado y desagregado.
 *
 * Todo lo calcula el RPC `reporte_bonificaciones` sobre los pedidos ENTREGADOS
 * del período (por fecha del pedido); la pantalla no re-deriva ningún total. Es
 * el mismo número que "Bonificaciones" del reporte gerencial.
 *
 * No es la merma "Promociones" de la pestaña Mermas: esa es la salida de stock
 * del regalo por día de CARGA, que cuenta también pedidos sin entregar. Por eso
 * los dos montos no tienen por qué coincidir, y la pantalla lo dice.
 *
 * Los filtros del detalle sólo achican la lista y su resumen: los totales y los
 * cortes son del período completo.
 */
import React, { useMemo, useState } from 'react';
import { Download, Info, AlertTriangle, Gift, Search } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import Paginacion from '../../layout/Paginacion';
import { Button } from '../../ui/Button';
import { useSucursal } from '../../../contexts/SucursalContext';
import {
  useBonificacionesReporteQuery,
  fetchReporteBonificaciones,
  type ReporteBonificaciones as DatosReporteBonificaciones,
} from '../../../hooks/queries/useBonificacionesReporteQuery';
import {
  FILTROS_BONIF_VACIOS,
  SIN_DATO,
  filtrarDetalleBonificaciones,
  formatBultos,
  formatPct,
  pctSobreVenta,
  resumirBonificaciones,
  type FiltrosDetalleBonificaciones,
} from '../../../utils/bonificaciones';
import { presetsVentas, type PeriodoPreset } from '../../../utils/periodosReporte';

export interface ReporteBonificacionesProps {
  formatPrecio: (precio: number) => string;
  /** Rango del contexto compartido (URL). Vacío = usar el default de la pestaña. */
  desde?: string;
  hasta?: string;
  /** Sucursal del contexto compartido. `undefined` = no vino en la URL. */
  sucursalUrl?: number | null;
  /** Escribe el rango en la URL, para que el link siga siendo compartible. */
  onRango?: (desde: string, hasta: string) => void;
}

const PRESET_CUSTOM = 'custom';
const DETALLE_PAGE_SIZE = 20;

type Corte = 'promocion' | 'producto' | 'promocion-producto' | 'vendedor' | 'cliente';

const CORTES: { value: Corte; label: string }[] = [
  { value: 'promocion', label: 'Por promoción' },
  { value: 'producto', label: 'Por producto' },
  { value: 'promocion-producto', label: 'Promoción × producto' },
  { value: 'vendedor', label: 'Por vendedor' },
  { value: 'cliente', label: 'Por cliente' },
];

const CLASE_INPUT =
  'w-full px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 dark:text-gray-100';
const CLASE_LABEL = 'block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1';
const TH = 'px-4 py-2 font-semibold text-gray-600 dark:text-gray-300';
const TD_NUM = 'px-4 py-2 text-right tabular-nums';
const BADGE = 'ml-1 inline-flex px-1.5 py-0.5 rounded text-xs bg-gray-100 text-gray-500 dark:bg-gray-700 dark:text-gray-400';

function fechaCorta(iso?: string | null): string {
  if (!iso) return '';
  const [a, m, d] = iso.slice(0, 10).split('-');
  return `${d}/${m}/${a}`;
}

const num = (n: number | null | undefined): string => Number(n ?? 0).toLocaleString('es-AR');

export function ReporteBonificaciones({
  formatPrecio, desde: desdeUrl, hasta: hastaUrl, sucursalUrl, onRango,
}: ReporteBonificacionesProps): React.ReactElement {
  const presets = useMemo(() => presetsVentas(), []);
  // El RPC exige un rango: sin período en la URL usa el default de la pestaña y
  // no lo escribe (cambiaría el contexto de las otras pestañas).
  const desde = desdeUrl || presets[0].desde;
  const hasta = hastaUrl || presets[0].hasta;
  const presetDelRango = presets.find((p) => p.desde === desde && p.hasta === hasta);
  // "Personalizado…" no cambia el rango: si no se recuerda la elección, el
  // select vuelve al preset que coincide y las fechas no aparecen nunca.
  const [personalizado, setPersonalizado] = useState(false);
  const presetId = personalizado || !presetDelRango ? PRESET_CUSTOM : presetDelRango.id;
  const preset: PeriodoPreset = presetDelRango ?? { ...presets[0], id: PRESET_CUSTOM, label: 'Personalizado', desde, hasta };

  // Sucursal: misma resolución que Mermas y Rechazos (#1052). El default es la
  // activa; la red (null) sólo por elección explícita.
  const { sucursales, hasMultipleSucursales, currentSucursalId } = useSucursal();
  const [sucursalLocal, setSucursalLocal] = useState<number | null | undefined>(undefined);
  const sucursalDeUrl = sucursalUrl != null && !sucursales.some((s) => s.id === sucursalUrl) ? undefined : sucursalUrl;
  const sucursalSel = sucursalLocal !== undefined ? sucursalLocal : (sucursalDeUrl !== undefined ? sucursalDeUrl : currentSucursalId);
  const sucursalResuelta = sucursalLocal !== undefined || sucursalDeUrl !== undefined || currentSucursalId !== null;
  const opcionesSucursal = useMemo(() => {
    const list = sucursales.map((s) => ({ id: s.id as number | null, nombre: s.nombre }));
    return hasMultipleSucursales ? [{ id: null, nombre: 'Red (consolidado)' }, ...list] : list;
  }, [sucursales, hasMultipleSucursales]);

  const [corte, setCorte] = useState<Corte>('promocion');
  const [filtros, setFiltros] = useState<FiltrosDetalleBonificaciones>(FILTROS_BONIF_VACIOS);
  const [pagina, setPagina] = useState(1);
  const [exportando, setExportando] = useState(false);

  // Otro período u otra sucursal es otro reporte: los filtros del detalle
  // (que nombran promociones y vendedores de ese reporte) vuelven a cero.
  const claveReporte = `${sucursalSel}|${desde}|${hasta}`;
  const [claveVista, setClaveVista] = useState(claveReporte);
  if (claveVista !== claveReporte) {
    setClaveVista(claveReporte);
    setFiltros(FILTROS_BONIF_VACIOS);
    setPagina(1);
  }

  const { data, isLoading, error } = useBonificacionesReporteQuery(sucursalSel, desde, hasta, sucursalResuelta);

  const filtradas = useMemo(
    () => filtrarDetalleBonificaciones(data?.detalle ?? [], filtros),
    [data, filtros],
  );
  const resumen = useMemo(() => resumirBonificaciones(filtradas), [filtradas]);
  const totalPaginas = Math.ceil(filtradas.length / DETALLE_PAGE_SIZE);
  const paginaVisible = Math.min(pagina, Math.max(1, totalPaginas));
  const filasPagina = filtradas.slice((paginaVisible - 1) * DETALLE_PAGE_SIZE, paginaVisible * DETALLE_PAGE_SIZE);
  const hayFiltros = Object.values(filtros).some((v) => v.trim() !== '');

  const cambiarFiltro = (cambio: Partial<FiltrosDetalleBonificaciones>): void => {
    setFiltros((prev) => ({ ...prev, ...cambio }));
    setPagina(1);
  };

  const elegirPreset = (id: string): void => {
    if (id === PRESET_CUSTOM) {
      setPersonalizado(true);
      return;
    }
    const p = presets.find((x) => x.id === id);
    if (p) {
      setPersonalizado(false);
      onRango?.(p.desde, p.hasta);
    }
  };

  // Una fecha borrada no se escribe: el RPC exige rango.
  const cambiarFecha = (nuevoDesde: string, nuevoHasta: string): void => {
    if (nuevoDesde && nuevoHasta) onRango?.(nuevoDesde, nuevoHasta);
  };

  const exportar = async (): Promise<void> => {
    setExportando(true);
    try {
      // Se vuelve a pedir para que el archivo sea del momento en que se baja.
      const r: DatosReporteBonificaciones = await fetchReporteBonificaciones(sucursalSel, desde, hasta);
      const t = r.totales;
      const info: Record<string, unknown>[] = [
        { Campo: 'Sucursal', Valor: r.meta.sucursal_nombre },
        { Campo: 'Desde', Valor: r.meta.desde },
        { Campo: 'Hasta', Valor: r.meta.hasta },
        { Campo: 'Criterio', Valor: r.meta.criterio },
        { Campo: 'Generado', Valor: r.meta.generado_at },
        { Campo: 'Regalado a costo', Valor: t.costo },
        { Campo: 'Regalado a precio de lista de hoy', Valor: t.valor_venta },
        { Campo: 'Venta del período (productos)', Valor: t.venta },
        { Campo: 'Regalado sobre venta (a costo)', Valor: pctSobreVenta(t.costo, t.venta) ?? '' },
        { Campo: 'Bultos regalados', Valor: t.bultos },
        { Campo: 'Unidades regaladas (botellas y bultos)', Valor: t.unidades },
        { Campo: 'Líneas de regalo', Valor: t.lineas },
        { Campo: 'Pedidos con regalo', Valor: t.pedidos_con_bonif },
        { Campo: 'Pedidos entregados', Valor: t.pedidos_entregados },
        { Campo: 'Clientes con regalo', Valor: t.clientes_con_bonif },
        { Campo: 'Venta de los pedidos con regalo', Valor: t.venta_pedidos_con_bonif },
        { Campo: 'Líneas sin costo cargado (no suman)', Valor: t.filas_sin_costo },
        { Campo: 'Detalle recortado', Valor: r.detalle_truncado ? `Sí (${r.detalle_limite} de ${r.detalle_total})` : 'No' },
      ];
      const montos = (x: { bultos: number; costo: number; valor_venta: number }) => ({
        Bultos: x.bultos, 'Costo': x.costo, 'A precio de lista': x.valor_venta,
        '% del total (costo)': t.costo > 0 ? x.costo / t.costo : '',
      });
      const { createMultiSheetExcel } = await import('../../../utils/excel');
      await createMultiSheetExcel(
        [
          { name: 'Info', data: info, columnWidths: [40, 60] },
          {
            name: 'Por promoción',
            data: r.por_promocion.map((p) => ({
              Promoción: p.nombre, Activa: p.activo === false ? 'No' : (p.activo ? 'Sí' : ''),
              Pedidos: p.pedidos, Clientes: p.clientes, Unidades: p.unidades, ...montos(p),
            })),
          },
          {
            name: 'Por producto',
            data: r.por_producto.map((p) => ({
              Producto: p.nombre, Código: p.codigo ?? '', 'Regalo por botella': p.es_fraccion ? 'Sí' : 'No',
              Pedidos: p.pedidos, Unidades: p.unidades, ...montos(p),
            })),
          },
          {
            name: 'Promoción × producto',
            data: r.por_promocion_producto.map((p) => ({
              Promoción: p.promocion, Producto: p.producto, Unidades: p.unidades, ...montos(p),
            })),
          },
          {
            name: 'Por vendedor',
            data: r.por_vendedor.map((v) => ({
              Vendedor: v.nombre, 'Pedidos entregados': v.pedidos_entregados, 'Pedidos con regalo': v.pedidos_con_bonif,
              Venta: v.venta, ...montos(v), 'Regalado sobre su venta': pctSobreVenta(v.costo, v.venta) ?? '',
            })),
          },
          {
            name: 'Por cliente',
            data: r.por_cliente.map((c) => ({
              Cliente: c.nombre ?? '', Código: c.codigo ?? '', Activo: c.activo === false ? 'No' : 'Sí',
              'Pedidos entregados': c.pedidos_entregados, 'Pedidos con regalo': c.pedidos_con_bonif,
              Venta: c.venta, ...montos(c), 'Regalado sobre su venta': pctSobreVenta(c.costo, c.venta) ?? '',
            })),
          },
          {
            name: 'Detalle',
            data: r.detalle.map((l) => ({
              Fecha: fechaCorta(l.fecha), Sucursal: l.sucursal_nombre ?? '', Pedido: l.pedido_id,
              Cliente: l.cliente_nombre ?? '', 'Cliente activo': l.cliente_activo === false ? 'No' : 'Sí',
              Vendedor: l.vendedor_nombre, Promoción: l.promocion_nombre,
              Producto: l.producto_nombre, Código: l.producto_codigo ?? '',
              Cantidad: l.cantidad, 'Unidad': l.es_fraccion ? `botella (fardo de ${l.factor})` : 'bulto',
              Bultos: l.bultos, 'Costo unitario': l.costo_unitario ?? '', Costo: l.costo,
              'A precio de lista': l.valor_venta, 'Sin costo': l.sin_costo ? 'Sí' : '',
            })),
          },
        ],
        `bonificaciones-${r.meta.sucursal_nombre}-${desde}_${hasta}`.replace(/\s+/g, '_'),
      );
    } finally {
      setExportando(false);
    }
  };

  if (error) {
    return (
      <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4 text-red-700 dark:text-red-300 text-sm">
        No se pudo cargar el reporte de bonificaciones: {(error as Error).message}
      </div>
    );
  }

  const t = data?.totales;

  return (
    <div className="space-y-4">
      {/* Período y sucursal */}
      <div className="bg-gray-50 dark:bg-gray-800/60 rounded-lg p-4">
        <div className="grid gap-3 md:grid-cols-4">
          <div>
            <label htmlFor="bonif-periodo" className={CLASE_LABEL}>Período (fecha del pedido)</label>
            <select id="bonif-periodo" value={presetId} onChange={(e) => elegirPreset(e.target.value)} className={CLASE_INPUT}>
              {presets.map((p) => (<option key={p.id} value={p.id}>{p.label}</option>))}
              <option value={PRESET_CUSTOM}>Personalizado…</option>
            </select>
          </div>
          {presetId === PRESET_CUSTOM ? (
            <>
              <div>
                <label htmlFor="bonif-desde" className={CLASE_LABEL}>Desde</label>
                <input id="bonif-desde" type="date" value={desde} onChange={(e) => cambiarFecha(e.target.value, hasta)} className={CLASE_INPUT} />
              </div>
              <div>
                <label htmlFor="bonif-hasta" className={CLASE_LABEL}>Hasta</label>
                <input id="bonif-hasta" type="date" value={hasta} onChange={(e) => cambiarFecha(desde, e.target.value)} className={CLASE_INPUT} />
              </div>
            </>
          ) : (
            <div className="md:col-span-2 flex items-end">
              <p className="text-xs text-gray-500 dark:text-gray-400">{preset.desde} al {preset.hasta}</p>
            </div>
          )}
          {opcionesSucursal.length > 1 && (
            <div>
              <label htmlFor="bonif-sucursal" className={CLASE_LABEL}>Sucursal</label>
              <select
                id="bonif-sucursal"
                value={sucursalSel === null ? 'red' : String(sucursalSel)}
                onChange={(e) => setSucursalLocal(e.target.value === 'red' ? null : Number(e.target.value))}
                className={CLASE_INPUT}
              >
                {opcionesSucursal.map((o) => (
                  <option key={o.id ?? 'red'} value={o.id === null ? 'red' : String(o.id)}>{o.nombre}</option>
                ))}
              </select>
            </div>
          )}
        </div>
      </div>

      {isLoading || !data || !t ? (
        <LoadingSpinner />
      ) : (
        <>
          <div className="flex flex-wrap items-center justify-end gap-2">
            <Button
              onClick={exportar} disabled={exportando || data.detalle_total === 0}
              loading={exportando} variant="success" size="md"
            >
              {!exportando && <Download className="w-4 h-4" />}
              Exportar a Excel
            </Button>
          </div>

          {/* KPIs */}
          <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
            <div className="bg-violet-50 dark:bg-violet-900/20 p-4 rounded-lg">
              <p className="text-sm text-violet-700 dark:text-violet-300">Regalado a costo</p>
              <p className="text-xl font-bold text-violet-800 dark:text-violet-200" data-testid="kpi-costo">{formatPrecio(t.costo)}</p>
              <p className="text-xs text-violet-700/80 dark:text-violet-300/80 mt-1">
                {formatPct(pctSobreVenta(t.costo, t.venta))} de la venta del período ({formatPrecio(t.venta)})
              </p>
            </div>
            <div className="bg-amber-50 dark:bg-amber-900/20 p-4 rounded-lg">
              <p className="text-sm text-amber-700 dark:text-amber-400">A precio de lista de hoy</p>
              <p className="text-xl font-bold text-amber-800 dark:text-amber-300" data-testid="kpi-valor-venta">{formatPrecio(t.valor_venta)}</p>
              <p className="text-xs text-amber-700/80 dark:text-amber-400/80 mt-1">Lo que se hubiera facturado</p>
            </div>
            <div className="bg-gray-100 dark:bg-gray-700/40 p-4 rounded-lg">
              <p className="text-sm text-gray-600 dark:text-gray-400">Bultos regalados</p>
              <p className="text-xl font-bold text-gray-700 dark:text-gray-200" data-testid="kpi-bultos">{formatBultos(t.bultos)}</p>
              <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                {num(t.unidades)} unidades en {num(t.lineas)} líneas
              </p>
            </div>
            <div className="bg-sky-50 dark:bg-sky-900/20 p-4 rounded-lg">
              <p className="text-sm text-sky-700 dark:text-sky-300">Pedidos con regalo</p>
              <p className="text-xl font-bold text-sky-800 dark:text-sky-200" data-testid="kpi-pedidos">
                {num(t.pedidos_con_bonif)} de {num(t.pedidos_entregados)}
              </p>
              <p className="text-xs text-sky-700/80 dark:text-sky-300/80 mt-1">
                {num(t.clientes_con_bonif)} clientes · {formatPct(pctSobreVenta(t.costo, t.venta_pedidos_con_bonif))} de lo que compraron
              </p>
            </div>
          </div>

          <div className="space-y-2">
            <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300 bg-gray-50 dark:bg-gray-800/60 rounded-lg p-3">
              <Info className="w-4 h-4 flex-shrink-0 mt-0.5 text-gray-400" />
              <span>
                Es el mismo número que <strong>Bonificaciones</strong> del reporte gerencial. No coincide con la
                merma «Promociones»: esa cuenta la salida de stock por <strong>día de carga</strong>, incluidos los
                pedidos todavía no entregados. «Bultos» lleva las botellas sueltas a su fardo (6 botellas de un
                fardo de 6 son 1 bulto).
              </span>
            </p>
            {t.filas_sin_costo > 0 && (
              <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300 bg-gray-50 dark:bg-gray-800/60 rounded-lg p-3">
                <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5 text-amber-500" />
                <span>
                  {num(t.filas_sin_costo)} líneas son de productos <strong>sin costo cargado</strong> y no suman al
                  costo regalado.
                </span>
              </p>
            )}
          </div>

          {/* Cortes */}
          <div className="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700">
            <div role="tablist" aria-label="Cortes" className="flex flex-wrap gap-1 p-2 border-b border-gray-200 dark:border-gray-700">
              {CORTES.map((c) => (
                <Button
                  key={c.value}
                  type="button"
                  role="tab"
                  aria-selected={corte === c.value}
                  onClick={() => setCorte(c.value)}
                  variant={corte === c.value ? 'primary' : 'ghost'}
                  size="sm"
                >
                  {c.label}
                </Button>
              ))}
            </div>
            <div className="overflow-x-auto">
              {data.detalle_total === 0 ? (
                <p className="text-center py-8 text-sm text-gray-500 dark:text-gray-400">No hubo regalos en el período.</p>
              ) : (
                <TablaCorte corte={corte} data={data} formatPrecio={formatPrecio} />
              )}
            </div>
          </div>

          {/* Detalle */}
          <div className="space-y-3">
            <div className="grid gap-3 md:grid-cols-3">
              <div>
                <label htmlFor="bonif-promocion" className={CLASE_LABEL}>Promoción</label>
                <select id="bonif-promocion" value={filtros.promocion} onChange={(e) => cambiarFiltro({ promocion: e.target.value })} className={CLASE_INPUT}>
                  <option value="">Todas</option>
                  {data.por_promocion.map((p) => (
                    <option key={p.promocion_id ?? SIN_DATO} value={p.promocion_id == null ? SIN_DATO : String(p.promocion_id)}>{p.nombre}</option>
                  ))}
                </select>
              </div>
              <div>
                <label htmlFor="bonif-vendedor" className={CLASE_LABEL}>Vendedor</label>
                <select id="bonif-vendedor" value={filtros.vendedor} onChange={(e) => cambiarFiltro({ vendedor: e.target.value })} className={CLASE_INPUT}>
                  <option value="">Todos</option>
                  {data.por_vendedor.map((v) => (
                    <option key={v.usuario_id ?? SIN_DATO} value={v.usuario_id ?? SIN_DATO}>{v.nombre}</option>
                  ))}
                </select>
              </div>
              <div>
                <label htmlFor="bonif-buscar" className={CLASE_LABEL}>Buscar</label>
                <div className="relative">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
                  <input
                    id="bonif-buscar" type="text" value={filtros.busqueda}
                    onChange={(e) => cambiarFiltro({ busqueda: e.target.value })}
                    placeholder="Cliente, producto o pedido"
                    className={`${CLASE_INPUT} pl-9`}
                  />
                </div>
              </div>
            </div>

            <p className="text-xs text-gray-500 dark:text-gray-400" data-testid="resumen-detalle">
              {hayFiltros ? 'Lo filtrado' : 'El período'}: {num(resumen.lineas)} líneas en {num(resumen.pedidos)} pedidos ·{' '}
              {formatBultos(resumen.bultos)} bultos · {formatPrecio(resumen.costo)} a costo ·{' '}
              {formatPrecio(resumen.valor_venta)} a precio de lista
              {hayFiltros && <> · los filtros no cambian los totales de arriba</>}
            </p>
            {data.detalle_truncado && (
              <p className="flex items-start gap-2 text-xs text-amber-700 dark:text-amber-300">
                <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" />
                <span>
                  La lista trae las {num(data.detalle_limite)} líneas más recientes de {num(data.detalle_total)}. Los
                  totales y los cortes son del período completo; achicá el período para ver el resto.
                </span>
              </p>
            )}

            {filtradas.length === 0 ? (
              <div className="text-center py-10 text-gray-500 dark:text-gray-400">
                <Gift className="w-10 h-10 mx-auto mb-2 opacity-40" />
                <p className="text-sm">No hay regalos que coincidan.</p>
              </div>
            ) : (
              <div className="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 overflow-x-auto">
                <table className="w-full text-sm" aria-label="Detalle de bonificaciones">
                  <thead className="bg-gray-50 dark:bg-gray-700/50">
                    <tr>
                      <th className={`${TH} text-left`}>Fecha</th>
                      <th className={`${TH} text-left`}>Cliente</th>
                      <th className={`${TH} text-left`}>Vendedor</th>
                      <th className={`${TH} text-left`}>Promoción</th>
                      <th className={`${TH} text-left`}>Regalo</th>
                      <th className={`${TH} text-right`}>Costo</th>
                      <th className={`${TH} text-right`}>A precio de lista</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
                    {filasPagina.map((l, i) => (
                      <tr key={`${l.pedido_id}-${l.producto_id ?? ''}-${l.promocion_id ?? ''}-${i}`} className="text-gray-700 dark:text-gray-200">
                        <td className="px-4 py-2 whitespace-nowrap">
                          {fechaCorta(l.fecha)}
                          <p className="text-xs text-gray-400">#{l.pedido_id}{l.sucursal_nombre && data.meta.sucursal_id == null ? ` · ${l.sucursal_nombre}` : ''}</p>
                        </td>
                        <td className="px-4 py-2">
                          {l.cliente_nombre ?? '—'}
                          {l.cliente_activo === false && <span className={BADGE}>inactivo</span>}
                        </td>
                        <td className="px-4 py-2 text-gray-600 dark:text-gray-300">{l.vendedor_nombre}</td>
                        <td className="px-4 py-2">{l.promocion_nombre}</td>
                        <td className="px-4 py-2">
                          <span className="font-medium">{num(l.cantidad)} × {l.producto_nombre}</span>
                          {l.es_fraccion && (
                            <p className="text-xs text-gray-500 dark:text-gray-400">
                              botellas · {formatBultos(l.bultos)} {l.bultos === 1 ? 'bulto' : 'bultos'}
                            </p>
                          )}
                        </td>
                        <td className={TD_NUM}>{l.sin_costo ? <span className="text-xs text-amber-600">sin costo</span> : formatPrecio(l.costo)}</td>
                        <td className={TD_NUM}>{formatPrecio(l.valor_venta)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
            <Paginacion
              paginaActual={paginaVisible}
              totalPaginas={totalPaginas}
              onPageChange={setPagina}
              totalItems={filtradas.length}
              itemsLabel="líneas"
            />
          </div>
        </>
      )}
    </div>
  );
}

function TablaCorte({ corte, data, formatPrecio }: {
  corte: Corte;
  data: DatosReporteBonificaciones;
  formatPrecio: (n: number) => string;
}): React.ReactElement {
  const total = data.totales.costo;
  const pctTotal = (costo: number): string => formatPct(total > 0 ? costo / total : null);
  const montos = (x: { bultos: number; costo: number; valor_venta: number }) => (
    <>
      <td className={TD_NUM}>{formatBultos(x.bultos)}</td>
      <td className={TD_NUM}>{formatPrecio(x.costo)}</td>
      <td className={`${TD_NUM} text-gray-500 dark:text-gray-400`}>{formatPrecio(x.valor_venta)}</td>
    </>
  );
  const encabezadoMontos = (
    <>
      <th className={`${TH} text-right`}>Bultos</th>
      <th className={`${TH} text-right`}>Costo</th>
      <th className={`${TH} text-right`}>A precio de lista</th>
    </>
  );
  const filaTotal = (colsAntes: number, extra?: React.ReactNode) => (
    <tfoot className="bg-gray-50 dark:bg-gray-700/50 font-semibold text-gray-700 dark:text-gray-200">
      <tr>
        <td className="px-4 py-2" colSpan={colsAntes}>Total</td>
        {montos(data.totales)}
        {extra}
      </tr>
    </tfoot>
  );

  if (corte === 'promocion') {
    return (
      <table className="w-full text-sm" aria-label="Por promoción">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className={`${TH} text-left`}>Promoción</th>
            <th className={`${TH} text-right`}>Pedidos</th>
            <th className={`${TH} text-right`}>Clientes</th>
            {encabezadoMontos}
            <th className={`${TH} text-right`}>% del total</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-700 dark:text-gray-200">
          {data.por_promocion.map((p) => (
            <tr key={p.promocion_id ?? SIN_DATO}>
              <td className="px-4 py-2 font-medium">
                {p.nombre}
                {p.activo === false && <span className={BADGE}>inactiva</span>}
              </td>
              <td className={TD_NUM}>{num(p.pedidos)}</td>
              <td className={TD_NUM}>{num(p.clientes)}</td>
              {montos(p)}
              <td className={TD_NUM}>{pctTotal(p.costo)}</td>
            </tr>
          ))}
        </tbody>
        {filaTotal(3, <td className={TD_NUM}>100 %</td>)}
      </table>
    );
  }

  if (corte === 'producto') {
    return (
      <table className="w-full text-sm" aria-label="Por producto">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className={`${TH} text-left`}>Producto</th>
            <th className={`${TH} text-right`}>Pedidos</th>
            <th className={`${TH} text-right`}>Unidades</th>
            {encabezadoMontos}
            <th className={`${TH} text-right`}>% del total</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-700 dark:text-gray-200">
          {data.por_producto.map((p) => (
            <tr key={p.producto_id ?? SIN_DATO}>
              <td className="px-4 py-2 font-medium">
                {p.nombre}
                {p.codigo && <span className="text-xs text-gray-400 ml-1">({p.codigo})</span>}
              </td>
              <td className={TD_NUM}>{num(p.pedidos)}</td>
              <td className={TD_NUM}>
                {num(p.unidades)}
                {p.es_fraccion && <span className="text-xs text-gray-400 ml-1">bot.</span>}
              </td>
              {montos(p)}
              <td className={TD_NUM}>{pctTotal(p.costo)}</td>
            </tr>
          ))}
        </tbody>
        {filaTotal(3, <td className={TD_NUM}>100 %</td>)}
      </table>
    );
  }

  if (corte === 'promocion-producto') {
    // Agrupado por promoción, con su subtotal: el desglose del corte por promoción.
    const grupos = data.por_promocion.map((p) => ({
      promo: p,
      filas: data.por_promocion_producto.filter((x) => (x.promocion_id ?? null) === (p.promocion_id ?? null)),
    }));
    return (
      <table className="w-full text-sm" aria-label="Promoción por producto">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className={`${TH} text-left`}>Promoción / producto</th>
            <th className={`${TH} text-right`}>Unidades</th>
            {encabezadoMontos}
          </tr>
        </thead>
        {grupos.map(({ promo, filas }) => (
          <tbody key={promo.promocion_id ?? SIN_DATO} className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-700 dark:text-gray-200">
            <tr className="bg-gray-50/60 dark:bg-gray-700/30 font-semibold">
              <td className="px-4 py-2">{promo.nombre}</td>
              <td className={TD_NUM}>{num(promo.unidades)}</td>
              {montos(promo)}
            </tr>
            {filas.map((f) => (
              <tr key={`${promo.promocion_id ?? SIN_DATO}-${f.producto_id ?? SIN_DATO}`}>
                <td className="px-4 py-2 pl-8">{f.producto}</td>
                <td className={TD_NUM}>
                  {num(f.unidades)}
                  {f.es_fraccion && <span className="text-xs text-gray-400 ml-1">bot.</span>}
                </td>
                {montos(f)}
              </tr>
            ))}
          </tbody>
        ))}
        {filaTotal(2)}
      </table>
    );
  }

  if (corte === 'vendedor') {
    return (
      <table className="w-full text-sm" aria-label="Por vendedor">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className={`${TH} text-left`}>Vendedor</th>
            <th className={`${TH} text-right`}>Pedidos con regalo</th>
            <th className={`${TH} text-right`}>Venta</th>
            {encabezadoMontos}
            <th className={`${TH} text-right`}>Sobre su venta</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-700 dark:text-gray-200">
          {data.por_vendedor.map((v) => (
            <tr key={v.usuario_id ?? SIN_DATO}>
              <td className="px-4 py-2 font-medium">{v.nombre}</td>
              <td className={TD_NUM}>{num(v.pedidos_con_bonif)} de {num(v.pedidos_entregados)}</td>
              <td className={TD_NUM}>{formatPrecio(v.venta)}</td>
              {montos(v)}
              <td className={TD_NUM}>{formatPct(pctSobreVenta(v.costo, v.venta))}</td>
            </tr>
          ))}
        </tbody>
      </table>
    );
  }

  return (
    <table className="w-full text-sm" aria-label="Por cliente">
      <thead className="bg-gray-50 dark:bg-gray-700/50">
        <tr>
          <th className={`${TH} text-left`}>Cliente</th>
          <th className={`${TH} text-right`}>Pedidos con regalo</th>
          <th className={`${TH} text-right`}>Compró</th>
          {encabezadoMontos}
          <th className={`${TH} text-right`}>Sobre lo que compró</th>
        </tr>
      </thead>
      <tbody className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-700 dark:text-gray-200">
        {data.por_cliente.map((c) => (
          <tr key={String(c.cliente_id ?? SIN_DATO)}>
            <td className="px-4 py-2 font-medium">
              {c.nombre ?? '—'}
              {c.codigo && <span className="text-xs text-gray-400 ml-1">({c.codigo})</span>}
              {c.activo === false && <span className={BADGE}>inactivo</span>}
            </td>
            <td className={TD_NUM}>{num(c.pedidos_con_bonif)} de {num(c.pedidos_entregados)}</td>
            <td className={TD_NUM}>{formatPrecio(c.venta)}</td>
            {montos(c)}
            <td className={TD_NUM}>{formatPct(pctSobreVenta(c.costo, c.venta))}</td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export default ReporteBonificaciones;
