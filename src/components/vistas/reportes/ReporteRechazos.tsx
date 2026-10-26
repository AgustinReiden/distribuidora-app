/**
 * Reporte de rechazos (#1198).
 *
 * Junta los dos rechazos que antes vivían separados: el pedido entero cancelado
 * en la calle (un motivo de cancelación que no es administrativo) y la línea con
 * salvedad. Todo lo calcula el RPC `reporte_rechazos`; la pantalla no re-deriva
 * ningún total.
 *
 * Muestra CAUSAS, no culpas (decisión del dueño, 2026-10-15): qué pasó, dónde y
 * con quién —motivo, preventista, chofer, cliente y producto—. No asigna un
 * responsable: eso lo decide el gerente mirando estos cortes.
 *
 * Dos montos que no se suman entre sí:
 *  - venta perdida: lo que volvió al stock, a precio de venta;
 *  - pérdida real: lo mermado (dañado, vencido, faltante), a costo.
 *
 * Los filtros del detalle sólo achican la lista y su resumen: los totales y los
 * cortes son del período completo.
 */
import React, { useMemo, useState } from 'react';
import { Download, Info, AlertTriangle, PackageX, Search } from 'lucide-react';
import LoadingSpinner from '../../layout/LoadingSpinner';
import Paginacion from '../../layout/Paginacion';
import { Button } from '../../ui/Button';
import { useSucursal } from '../../../contexts/SucursalContext';
import {
  useRechazosReporteQuery,
  fetchReporteRechazos,
  type ReporteRechazos as DatosReporteRechazos,
} from '../../../hooks/queries/useRechazosReporteQuery';
import {
  FILTROS_DETALLE_VACIOS,
  LABEL_DESTINO,
  LABEL_TIPO_RECHAZO,
  SIN_ASIGNAR,
  claveMotivo,
  filtrarDetalleRechazos,
  formatTasa,
  labelMotivoRechazo,
  resumirRechazos,
  type FiltrosDetalleRechazos,
} from '../../../utils/rechazos';
import { ESTADOS_RESOLUCION_LABELS } from '../../../lib/schemas';
import { presetsVentas, type PeriodoPreset } from '../../../utils/periodosReporte';

export interface ReporteRechazosProps {
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

type Corte = 'motivo' | 'preventista' | 'chofer' | 'armador' | 'cliente' | 'producto';

const CORTES: { value: Corte; label: string }[] = [
  { value: 'motivo', label: 'Motivo' },
  { value: 'preventista', label: 'Preventista' },
  { value: 'chofer', label: 'Chofer' },
  { value: 'armador', label: 'Armador' },
  { value: 'cliente', label: 'Cliente' },
  { value: 'producto', label: 'Producto' },
];

const CLASE_INPUT =
  'w-full px-3 py-2 text-sm border border-gray-300 dark:border-gray-600 rounded-lg bg-white dark:bg-gray-700 dark:text-gray-100';
const CLASE_LABEL = 'block text-xs font-medium text-gray-500 dark:text-gray-400 mb-1';
const TH = 'px-4 py-2 font-semibold text-gray-600 dark:text-gray-300';
const TD_NUM = 'px-4 py-2 text-right tabular-nums';

function fechaCorta(iso?: string | null): string {
  if (!iso) return '';
  const [a, m, d] = iso.slice(0, 10).split('-');
  return `${d}/${m}/${a}`;
}

const num = (n: number | null | undefined): string => Number(n ?? 0).toLocaleString('es-AR');

export function ReporteRechazos({
  formatPrecio, desde: desdeUrl, hasta: hastaUrl, sucursalUrl, onRango,
}: ReporteRechazosProps): React.ReactElement {
  const presets = useMemo(() => presetsVentas(), []);
  // El RPC exige un rango: sin período en la URL usa el default de la pestaña y
  // no lo escribe (cambiaría el contexto de las otras pestañas).
  const desde = desdeUrl || presets[0].desde;
  const hasta = hastaUrl || presets[0].hasta;
  const presetDelRango = presets.find((p) => p.desde === desde && p.hasta === hasta);
  // "Personalizado…" no cambia el rango, así que no se puede deducir del rango:
  // si no se recuerda la elección, el select vuelve al preset que coincide y las
  // fechas no aparecen nunca.
  const [personalizado, setPersonalizado] = useState(false);
  const presetId = personalizado || !presetDelRango ? PRESET_CUSTOM : presetDelRango.id;
  const preset: PeriodoPreset = presetDelRango ?? { ...presets[0], id: PRESET_CUSTOM, label: 'Personalizado', desde, hasta };

  // Sucursal: misma resolución que Mermas (#1052). El default es la activa;
  // la red (null) sólo por elección explícita.
  const { sucursales, hasMultipleSucursales, currentSucursalId } = useSucursal();
  const [sucursalLocal, setSucursalLocal] = useState<number | null | undefined>(undefined);
  const sucursalDeUrl = sucursalUrl != null && !sucursales.some((s) => s.id === sucursalUrl) ? undefined : sucursalUrl;
  const sucursalSel = sucursalLocal !== undefined ? sucursalLocal : (sucursalDeUrl !== undefined ? sucursalDeUrl : currentSucursalId);
  const sucursalResuelta = sucursalLocal !== undefined || sucursalDeUrl !== undefined || currentSucursalId !== null;
  const opcionesSucursal = useMemo(() => {
    const list = sucursales.map((s) => ({ id: s.id as number | null, nombre: s.nombre }));
    return hasMultipleSucursales ? [{ id: null, nombre: 'Red (consolidado)' }, ...list] : list;
  }, [sucursales, hasMultipleSucursales]);

  const [corte, setCorte] = useState<Corte>('motivo');
  const [filtros, setFiltros] = useState<FiltrosDetalleRechazos>(FILTROS_DETALLE_VACIOS);
  const [pagina, setPagina] = useState(1);
  const [exportando, setExportando] = useState(false);

  // Otro período u otra sucursal es otro reporte: los filtros del detalle
  // (que nombran personas y motivos de ese reporte) vuelven a cero.
  const claveReporte = `${sucursalSel}|${desde}|${hasta}`;
  const [claveVista, setClaveVista] = useState(claveReporte);
  if (claveVista !== claveReporte) {
    setClaveVista(claveReporte);
    setFiltros(FILTROS_DETALLE_VACIOS);
    setPagina(1);
  }

  const { data, isLoading, error } = useRechazosReporteQuery(sucursalSel, desde, hasta, sucursalResuelta);

  const filtradas = useMemo(
    () => filtrarDetalleRechazos(data?.detalle ?? [], filtros),
    [data, filtros],
  );
  const resumen = useMemo(() => resumirRechazos(filtradas), [filtradas]);
  const totalPaginas = Math.ceil(filtradas.length / DETALLE_PAGE_SIZE);
  const paginaVisible = Math.min(pagina, Math.max(1, totalPaginas));
  const filasPagina = filtradas.slice((paginaVisible - 1) * DETALLE_PAGE_SIZE, paginaVisible * DETALLE_PAGE_SIZE);
  const hayFiltros = Object.values(filtros).some((v) => v.trim() !== '');

  const cambiarFiltro = (cambio: Partial<FiltrosDetalleRechazos>): void => {
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

  // Una fecha borrada no se escribe: el RPC exige rango, y la URL vacía haría
  // volver al preset por defecto en medio de la edición.
  const cambiarFecha = (nuevoDesde: string, nuevoHasta: string): void => {
    if (nuevoDesde && nuevoHasta) onRango?.(nuevoDesde, nuevoHasta);
  };

  const exportar = async (): Promise<void> => {
    setExportando(true);
    try {
      // Se vuelve a pedir para que el archivo sea del momento en que se baja.
      const r: DatosReporteRechazos = await fetchReporteRechazos(sucursalSel, desde, hasta);
      const t = r.totales;
      const info: Record<string, unknown>[] = [
        { Campo: 'Sucursal', Valor: r.meta.sucursal_nombre },
        { Campo: 'Desde', Valor: r.meta.desde },
        { Campo: 'Hasta', Valor: r.meta.hasta },
        { Campo: 'Criterio', Valor: r.meta.criterio },
        { Campo: 'Generado', Valor: r.meta.generado_at },
        { Campo: 'Pedidos que salieron', Valor: t.pedidos_salieron },
        { Campo: 'Rechazados enteros', Valor: t.rechazos_totales },
        { Campo: 'Entregados con salvedad', Valor: t.pedidos_con_salvedad },
        { Campo: 'Líneas con salvedad', Valor: t.lineas_salvedad },
        { Campo: 'Tasa de rechazo', Valor: t.tasa_rechazo ?? '' },
        { Campo: 'Venta perdida (volvió al stock, a precio)', Valor: t.venta_perdida },
        { Campo: 'Pérdida real (mermado, a costo)', Valor: t.perdida_real },
        { Campo: 'Todo lo rechazado, a precio', Valor: t.monto },
        { Campo: 'Mermas sin costo cargado (no suman)', Valor: t.mermas_sin_costo },
        { Campo: 'Detalle recortado', Valor: r.detalle_truncado ? `Sí (${r.detalle_limite} de ${r.detalle_total})` : 'No' },
      ];
      const persona = (sin: string) => (x: { nombre: string | null; pedidos_salieron: number; rechazos_totales: number; pedidos_con_salvedad: number; lineas_salvedad: number; tasa_rechazo: number | null; venta_perdida: number; perdida_real: number; monto: number }) => ({
        Nombre: x.nombre ?? sin,
        'Pedidos que salieron': x.pedidos_salieron,
        'Rechazados enteros': x.rechazos_totales,
        'Entregados con salvedad': x.pedidos_con_salvedad,
        'Líneas con salvedad': x.lineas_salvedad,
        'Tasa de rechazo': x.tasa_rechazo ?? '',
        'Venta perdida': x.venta_perdida,
        'Pérdida real': x.perdida_real,
        'Rechazado a precio': x.monto,
      });
      const { createMultiSheetExcel } = await import('../../../utils/excel');
      await createMultiSheetExcel(
        [
          { name: 'Info', data: info, columnWidths: [40, 60] },
          {
            name: 'Por motivo',
            data: r.por_motivo.map((m) => ({
              Tipo: LABEL_TIPO_RECHAZO[m.tipo], Motivo: labelMotivoRechazo(m.tipo, m.motivo), Casos: m.casos,
              Unidades: m.unidades, 'Venta perdida': m.venta_perdida, 'Pérdida real': m.perdida_real, 'Rechazado a precio': m.monto,
            })),
          },
          { name: 'Por preventista', data: r.por_preventista.map(persona('Sin preventista')) },
          { name: 'Por chofer', data: r.por_chofer.map(persona('Sin chofer')) },
          {
            name: 'Por armador',
            data: r.por_armador.map((a) => ({
              Armador: a.nombre ?? 'Sin dato', 'Pedidos que armó': a.pedidos_salieron,
              'Pedidos con error de armado': a.pedidos_con_error_armado, 'Errores de armado': a.errores_armado,
              'Tasa de error de armado': a.tasa_error_armado ?? '',
              'Venta perdida': a.venta_perdida, 'Pérdida real': a.perdida_real, 'Rechazado a precio': a.monto,
            })),
          },
          {
            name: 'Por cliente',
            data: r.por_cliente.map((c) => ({
              Cliente: c.nombre ?? '', Código: c.codigo ?? '', Activo: c.activo === false ? 'No' : 'Sí',
              'Rechazados enteros': c.rechazos_totales, 'Líneas con salvedad': c.lineas_salvedad,
              'Venta perdida': c.venta_perdida, 'Pérdida real': c.perdida_real, 'Rechazado a precio': c.monto,
            })),
          },
          {
            name: 'Por producto',
            data: r.por_producto.map((p) => ({
              Producto: p.nombre ?? '', Código: p.codigo ?? '', 'Unidades (pedidos enteros)': p.unidades_total,
              'Unidades (salvedades)': p.unidades_parcial, 'Venta perdida': p.venta_perdida,
              'Pérdida real': p.perdida_real, 'Rechazado a precio': p.monto,
            })),
          },
          {
            name: 'Detalle',
            data: r.detalle.map((f) => ({
              Fecha: fechaCorta(f.fecha), Sucursal: f.sucursal_nombre ?? '', Pedido: f.pedido_id,
              Tipo: LABEL_TIPO_RECHAZO[f.tipo], Motivo: labelMotivoRechazo(f.tipo, f.motivo), Descripción: f.descripcion ?? '',
              Cliente: f.cliente_nombre ?? '', 'Cliente activo': f.cliente_activo === false ? 'No' : 'Sí',
              Preventista: f.preventista_nombre ?? 'Sin preventista', Chofer: f.chofer_nombre ?? 'Sin chofer',
              Producto: f.producto_nombre ?? (f.tipo === 'total' ? `${f.lineas} líneas` : ''),
              Unidades: f.unidades, Destino: LABEL_DESTINO[f.destino] ?? f.destino,
              'Venta perdida': f.venta_perdida, 'Pérdida real': f.perdida_real, 'Rechazado a precio': f.monto,
              Estado: f.estado_resolucion ? (ESTADOS_RESOLUCION_LABELS as Record<string, string>)[f.estado_resolucion] ?? f.estado_resolucion : '',
            })),
          },
        ],
        `rechazos-${r.meta.sucursal_nombre}-${desde}_${hasta}`.replace(/\s+/g, '_'),
      );
    } finally {
      setExportando(false);
    }
  };

  if (error) {
    return (
      <div className="bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg p-4 text-red-700 dark:text-red-300 text-sm">
        No se pudo cargar el reporte de rechazos: {(error as Error).message}
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
            <label htmlFor="rechazos-periodo" className={CLASE_LABEL}>Período (fecha del pedido)</label>
            <select id="rechazos-periodo" value={presetId} onChange={(e) => elegirPreset(e.target.value)} className={CLASE_INPUT}>
              {presets.map((p) => (<option key={p.id} value={p.id}>{p.label}</option>))}
              <option value={PRESET_CUSTOM}>Personalizado…</option>
            </select>
          </div>
          {presetId === PRESET_CUSTOM ? (
            <>
              <div>
                <label htmlFor="rechazos-desde" className={CLASE_LABEL}>Desde</label>
                <input id="rechazos-desde" type="date" value={desde} onChange={(e) => cambiarFecha(e.target.value, hasta)} className={CLASE_INPUT} />
              </div>
              <div>
                <label htmlFor="rechazos-hasta" className={CLASE_LABEL}>Hasta</label>
                <input id="rechazos-hasta" type="date" value={hasta} onChange={(e) => cambiarFecha(desde, e.target.value)} className={CLASE_INPUT} />
              </div>
            </>
          ) : (
            <div className="md:col-span-2 flex items-end">
              <p className="text-xs text-gray-500 dark:text-gray-400">{preset.desde} al {preset.hasta}</p>
            </div>
          )}
          {opcionesSucursal.length > 1 && (
            <div>
              <label htmlFor="rechazos-sucursal" className={CLASE_LABEL}>Sucursal</label>
              <select
                id="rechazos-sucursal"
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
          <div className="flex flex-wrap items-center justify-between gap-2">
            <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300">
              <Info className="w-4 h-4 flex-shrink-0 mt-0.5 text-gray-400" />
              <span>
                El reporte muestra <strong>qué pasó, dónde y con quién</strong>. No asigna responsables:
                eso lo decide el gerente con estos cortes. El corte por armador cuenta los pedidos con un
                error de armado (faltante, error en el pedido o producto dañado) sobre los que armó quien
                los marcó en preparación; los anteriores al registro figuran como «Sin dato».
              </span>
            </p>
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
            <div className="bg-red-50 dark:bg-red-900/20 p-4 rounded-lg">
              <p className="text-sm text-red-600 dark:text-red-400">Tasa de rechazo</p>
              <p className="text-xl font-bold text-red-700 dark:text-red-300" data-testid="kpi-tasa">{formatTasa(t.tasa_rechazo)}</p>
              <p className="text-xs text-red-600/80 dark:text-red-400/80 mt-1">
                {num(t.rechazos_totales + t.pedidos_con_salvedad)} de {num(t.pedidos_salieron)} pedidos que salieron
              </p>
            </div>
            <div className="bg-gray-100 dark:bg-gray-700/40 p-4 rounded-lg">
              <p className="text-sm text-gray-600 dark:text-gray-400">Rechazos</p>
              <p className="text-xl font-bold text-gray-700 dark:text-gray-200" data-testid="kpi-rechazos">
                {num(t.rechazos_totales)} enteros · {num(t.lineas_salvedad)} líneas
              </p>
              <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                {num(t.pedidos_con_salvedad)} pedidos entregados con salvedad
              </p>
            </div>
            <div className="bg-amber-50 dark:bg-amber-900/20 p-4 rounded-lg">
              <p className="text-sm text-amber-700 dark:text-amber-400">Venta perdida</p>
              <p className="text-xl font-bold text-amber-800 dark:text-amber-300" data-testid="kpi-venta-perdida">{formatPrecio(t.venta_perdida)}</p>
              <p className="text-xs text-amber-700/80 dark:text-amber-400/80 mt-1">Volvió al stock, a precio de venta</p>
            </div>
            <div className="bg-rose-50 dark:bg-rose-900/20 p-4 rounded-lg">
              <p className="text-sm text-rose-600 dark:text-rose-400">Pérdida real</p>
              <p className="text-xl font-bold text-rose-700 dark:text-rose-300" data-testid="kpi-perdida-real">{formatPrecio(t.perdida_real)}</p>
              <p className="text-xs text-rose-600/80 dark:text-rose-400/80 mt-1">Mermado (dañado, vencido, faltante), a costo</p>
            </div>
          </div>

          <div className="space-y-2">
            <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300 bg-gray-50 dark:bg-gray-800/60 rounded-lg p-3">
              <Info className="w-4 h-4 flex-shrink-0 mt-0.5 text-gray-400" />
              <span>
                Todo lo rechazado suma {formatPrecio(t.monto)} a precio de venta: {formatPrecio(t.venta_perdida)} volvió
                al stock, {formatPrecio(t.monto_mermado)} se mermó (a costo, {formatPrecio(t.perdida_real)})
                {t.monto_sin_movimiento > 0 && <> y {formatPrecio(t.monto_sin_movimiento)} no movió stock</>}.
                La venta perdida y la pérdida real <strong>no se suman</strong>: una es a precio y la otra a costo.
              </span>
            </p>
            {t.salvedades_pendientes > 0 && (
              <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300 bg-gray-50 dark:bg-gray-800/60 rounded-lg p-3">
                <Info className="w-4 h-4 flex-shrink-0 mt-0.5 text-gray-400" />
                <span>
                  {num(t.salvedades_pendientes)} de las líneas siguen pendientes en el panel de Salvedades. Resolverlas
                  no cambia este reporte: una salvedad resuelta sigue siendo un rechazo.
                </span>
              </p>
            )}
            {t.mermas_sin_costo > 0 && (
              <p className="flex items-start gap-2 text-xs text-gray-600 dark:text-gray-300 bg-gray-50 dark:bg-gray-800/60 rounded-lg p-3">
                <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5 text-amber-500" />
                <span>
                  {num(t.mermas_sin_costo)} mermas son de productos <strong>sin costo cargado</strong> y no suman a la
                  pérdida real.
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
                  Por {c.label.toLowerCase()}
                </Button>
              ))}
            </div>
            <div className="overflow-x-auto">
              <TablaCorte corte={corte} data={data} formatPrecio={formatPrecio} />
            </div>
          </div>

          {/* Detalle */}
          <div className="space-y-3">
            <div className="grid gap-3 md:grid-cols-5">
              <div>
                <label htmlFor="rechazos-tipo" className={CLASE_LABEL}>Tipo</label>
                <select id="rechazos-tipo" value={filtros.tipo} onChange={(e) => cambiarFiltro({ tipo: e.target.value as FiltrosDetalleRechazos['tipo'] })} className={CLASE_INPUT}>
                  <option value="">Todos</option>
                  <option value="total">{LABEL_TIPO_RECHAZO.total}</option>
                  <option value="parcial">{LABEL_TIPO_RECHAZO.parcial}</option>
                </select>
              </div>
              <div>
                <label htmlFor="rechazos-motivo" className={CLASE_LABEL}>Motivo</label>
                <select id="rechazos-motivo" value={filtros.motivo} onChange={(e) => cambiarFiltro({ motivo: e.target.value })} className={CLASE_INPUT}>
                  <option value="">Todos</option>
                  {data.por_motivo.map((m) => (
                    <option key={claveMotivo(m.tipo, m.motivo)} value={claveMotivo(m.tipo, m.motivo)}>
                      {labelMotivoRechazo(m.tipo, m.motivo)} ({m.tipo === 'total' ? 'entero' : 'línea'})
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <label htmlFor="rechazos-preventista" className={CLASE_LABEL}>Preventista</label>
                <select id="rechazos-preventista" value={filtros.preventista} onChange={(e) => cambiarFiltro({ preventista: e.target.value })} className={CLASE_INPUT}>
                  <option value="">Todos</option>
                  {data.por_preventista.filter((p) => p.monto > 0 || p.rechazos_totales > 0 || p.lineas_salvedad > 0).map((p) => (
                    <option key={p.usuario_id ?? SIN_ASIGNAR} value={p.usuario_id ?? SIN_ASIGNAR}>{p.nombre ?? 'Sin preventista'}</option>
                  ))}
                </select>
              </div>
              <div>
                <label htmlFor="rechazos-chofer" className={CLASE_LABEL}>Chofer</label>
                <select id="rechazos-chofer" value={filtros.chofer} onChange={(e) => cambiarFiltro({ chofer: e.target.value })} className={CLASE_INPUT}>
                  <option value="">Todos</option>
                  {data.por_chofer.filter((c) => c.monto > 0 || c.rechazos_totales > 0 || c.lineas_salvedad > 0).map((c) => (
                    <option key={c.transportista_id ?? SIN_ASIGNAR} value={c.transportista_id ?? SIN_ASIGNAR}>{c.nombre ?? 'Sin chofer'}</option>
                  ))}
                </select>
              </div>
              <div>
                <label htmlFor="rechazos-buscar" className={CLASE_LABEL}>Buscar</label>
                <div className="relative">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-gray-400" />
                  <input
                    id="rechazos-buscar" type="text" value={filtros.busqueda}
                    onChange={(e) => cambiarFiltro({ busqueda: e.target.value })}
                    placeholder="Cliente, producto o pedido"
                    className={`${CLASE_INPUT} pl-9`}
                  />
                </div>
              </div>
            </div>

            <p className="text-xs text-gray-500 dark:text-gray-400" data-testid="resumen-detalle">
              {hayFiltros ? 'Lo filtrado' : 'El período'}: {num(resumen.pedidos_enteros)} pedidos enteros y{' '}
              {num(resumen.lineas)} líneas · venta perdida {formatPrecio(resumen.venta_perdida)} · pérdida real{' '}
              {formatPrecio(resumen.perdida_real)}
              {hayFiltros && <> · los filtros no cambian los totales de arriba</>}
            </p>
            {data.detalle_truncado && (
              <p className="flex items-start gap-2 text-xs text-amber-700 dark:text-amber-300">
                <AlertTriangle className="w-4 h-4 flex-shrink-0 mt-0.5" />
                <span>
                  La lista trae los {num(data.detalle_limite)} más recientes de {num(data.detalle_total)}. Los totales y los
                  cortes son del período completo; achicá el período para ver el resto.
                </span>
              </p>
            )}

            {filtradas.length === 0 ? (
              <div className="text-center py-10 text-gray-500 dark:text-gray-400">
                <PackageX className="w-10 h-10 mx-auto mb-2 opacity-40" />
                <p className="text-sm">No hay rechazos que coincidan.</p>
              </div>
            ) : (
              <div className="bg-white dark:bg-gray-800 rounded-lg border border-gray-200 dark:border-gray-700 overflow-x-auto">
                <table className="w-full text-sm" aria-label="Detalle de rechazos">
                  <thead className="bg-gray-50 dark:bg-gray-700/50">
                    <tr>
                      <th className={`${TH} text-left`}>Fecha</th>
                      <th className={`${TH} text-left`}>Qué</th>
                      <th className={`${TH} text-left`}>Motivo</th>
                      <th className={`${TH} text-left`}>Cliente</th>
                      <th className={`${TH} text-left`}>Preventista · Chofer</th>
                      <th className={`${TH} text-right`}>Venta perdida</th>
                      <th className={`${TH} text-right`}>Pérdida real</th>
                    </tr>
                  </thead>
                  <tbody className="divide-y divide-gray-100 dark:divide-gray-700">
                    {filasPagina.map((f) => (
                      <tr key={`${f.tipo}-${f.pedido_id}-${f.salvedad_id ?? ''}`} className="text-gray-700 dark:text-gray-200">
                        <td className="px-4 py-2 whitespace-nowrap">
                          {fechaCorta(f.fecha)}
                          <p className="text-xs text-gray-400">#{f.pedido_id}{f.sucursal_nombre && data.meta.sucursal_id == null ? ` · ${f.sucursal_nombre}` : ''}</p>
                        </td>
                        <td className="px-4 py-2">
                          {f.tipo === 'total' ? (
                            <span className="font-medium">Pedido entero <span className="text-xs text-gray-400">({num(f.lineas)} líneas)</span></span>
                          ) : (
                            <span className="font-medium">
                              {num(f.unidades)} × {f.producto_nombre ?? 'Producto'}
                              {f.producto_codigo && <span className="text-xs text-gray-400 ml-1">({f.producto_codigo})</span>}
                            </span>
                          )}
                          <p className="text-xs text-gray-500 dark:text-gray-400">{LABEL_DESTINO[f.destino] ?? f.destino}</p>
                        </td>
                        <td className="px-4 py-2">
                          {labelMotivoRechazo(f.tipo, f.motivo)}
                          {f.descripcion && <p className="text-xs text-gray-500 dark:text-gray-400">{f.descripcion}</p>}
                        </td>
                        <td className="px-4 py-2">
                          {f.cliente_nombre ?? '—'}
                          {f.cliente_activo === false && (
                            <span className="ml-1 inline-flex px-1.5 py-0.5 rounded text-xs bg-gray-100 text-gray-500 dark:bg-gray-700 dark:text-gray-400">inactivo</span>
                          )}
                        </td>
                        <td className="px-4 py-2 text-gray-600 dark:text-gray-300">
                          {f.preventista_nombre ?? 'Sin preventista'}
                          <p className="text-xs text-gray-500 dark:text-gray-400">{f.chofer_nombre ?? 'Sin chofer'}</p>
                        </td>
                        <td className={TD_NUM}>{f.venta_perdida ? formatPrecio(f.venta_perdida) : '—'}</td>
                        <td className={TD_NUM}>{f.perdida_real ? formatPrecio(f.perdida_real) : '—'}</td>
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
              itemsLabel="rechazos"
            />
          </div>
        </>
      )}
    </div>
  );
}

function TablaCorte({ corte, data, formatPrecio }: {
  corte: Corte;
  data: DatosReporteRechazos;
  formatPrecio: (n: number) => string;
}): React.ReactElement {
  const montos = (x: { venta_perdida: number; perdida_real: number; monto: number }) => (
    <>
      <td className={TD_NUM}>{formatPrecio(x.venta_perdida)}</td>
      <td className={TD_NUM}>{formatPrecio(x.perdida_real)}</td>
      <td className={`${TD_NUM} text-gray-500 dark:text-gray-400`}>{formatPrecio(x.monto)}</td>
    </>
  );
  const encabezadoMontos = (
    <>
      <th className={`${TH} text-right`}>Venta perdida</th>
      <th className={`${TH} text-right`}>Pérdida real</th>
      <th className={`${TH} text-right`}>Rechazado a precio</th>
    </>
  );

  if (corte === 'motivo') {
    return (
      <table className="w-full text-sm" aria-label="Por motivo">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className={`${TH} text-left`}>Motivo</th>
            <th className={`${TH} text-left`}>Tipo</th>
            <th className={`${TH} text-right`}>Casos</th>
            <th className={`${TH} text-right`}>Unidades</th>
            {encabezadoMontos}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-700 dark:text-gray-200">
          {data.por_motivo.map((m) => (
            <tr key={claveMotivo(m.tipo, m.motivo)}>
              <td className="px-4 py-2 font-medium">{labelMotivoRechazo(m.tipo, m.motivo)}</td>
              <td className="px-4 py-2">{LABEL_TIPO_RECHAZO[m.tipo]}</td>
              <td className={TD_NUM}>{num(m.casos)}</td>
              <td className={TD_NUM}>{num(m.unidades)}</td>
              {montos(m)}
            </tr>
          ))}
        </tbody>
      </table>
    );
  }

  if (corte === 'preventista' || corte === 'chofer') {
    const filas = corte === 'preventista'
      ? data.por_preventista.map((p) => ({ ...p, clave: p.usuario_id ?? SIN_ASIGNAR, etiqueta: p.nombre ?? 'Sin preventista' }))
      : data.por_chofer.map((c) => ({ ...c, clave: c.transportista_id ?? SIN_ASIGNAR, etiqueta: c.nombre ?? 'Sin chofer' }));
    return (
      <table className="w-full text-sm" aria-label={corte === 'preventista' ? 'Por preventista' : 'Por chofer'}>
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className={`${TH} text-left`}>{corte === 'preventista' ? 'Preventista' : 'Chofer'}</th>
            <th className={`${TH} text-right`}>Salieron</th>
            <th className={`${TH} text-right`}>Enteros</th>
            <th className={`${TH} text-right`}>Con salvedad</th>
            <th className={`${TH} text-right`}>Tasa</th>
            {encabezadoMontos}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-700 dark:text-gray-200">
          {filas.map((p) => (
            <tr key={p.clave}>
              <td className="px-4 py-2 font-medium">{p.etiqueta}</td>
              <td className={TD_NUM}>{num(p.pedidos_salieron)}</td>
              <td className={TD_NUM}>{num(p.rechazos_totales)}</td>
              <td className={TD_NUM}>{num(p.pedidos_con_salvedad)}</td>
              <td className={TD_NUM}>{formatTasa(p.tasa_rechazo)}</td>
              {montos(p)}
            </tr>
          ))}
        </tbody>
      </table>
    );
  }

  if (corte === 'armador') {
    return (
      <table className="w-full text-sm" aria-label="Por armador">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className={`${TH} text-left`}>Armador</th>
            <th className={`${TH} text-right`}>Pedidos que armó</th>
            <th className={`${TH} text-right`}>Con error de armado</th>
            <th className={`${TH} text-right`}>Errores</th>
            <th className={`${TH} text-right`}>Tasa</th>
            {encabezadoMontos}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-700 dark:text-gray-200">
          {data.por_armador.map((a) => (
            <tr key={a.armado_por ?? SIN_ASIGNAR}>
              <td className="px-4 py-2 font-medium">{a.nombre ?? 'Sin dato'}</td>
              <td className={TD_NUM}>{num(a.pedidos_salieron)}</td>
              <td className={TD_NUM}>{num(a.pedidos_con_error_armado)}</td>
              <td className={TD_NUM}>{num(a.errores_armado)}</td>
              <td className={TD_NUM}>{formatTasa(a.tasa_error_armado)}</td>
              {montos(a)}
            </tr>
          ))}
        </tbody>
      </table>
    );
  }

  if (corte === 'cliente') {
    return (
      <table className="w-full text-sm" aria-label="Por cliente">
        <thead className="bg-gray-50 dark:bg-gray-700/50">
          <tr>
            <th className={`${TH} text-left`}>Cliente</th>
            <th className={`${TH} text-right`}>Enteros</th>
            <th className={`${TH} text-right`}>Líneas</th>
            {encabezadoMontos}
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-700 dark:text-gray-200">
          {data.por_cliente.map((c) => (
            <tr key={String(c.cliente_id ?? SIN_ASIGNAR)}>
              <td className="px-4 py-2 font-medium">
                {c.nombre ?? '—'}
                {c.codigo && <span className="text-xs text-gray-400 ml-1">({c.codigo})</span>}
                {c.activo === false && (
                  <span className="ml-1 inline-flex px-1.5 py-0.5 rounded text-xs bg-gray-100 text-gray-500 dark:bg-gray-700 dark:text-gray-400">inactivo</span>
                )}
              </td>
              <td className={TD_NUM}>{num(c.rechazos_totales)}</td>
              <td className={TD_NUM}>{num(c.lineas_salvedad)}</td>
              {montos(c)}
            </tr>
          ))}
        </tbody>
      </table>
    );
  }

  return (
    <table className="w-full text-sm" aria-label="Por producto">
      <thead className="bg-gray-50 dark:bg-gray-700/50">
        <tr>
          <th className={`${TH} text-left`}>Producto</th>
          <th className={`${TH} text-right`}>U. en pedidos enteros</th>
          <th className={`${TH} text-right`}>U. en salvedades</th>
          {encabezadoMontos}
        </tr>
      </thead>
      <tbody className="divide-y divide-gray-100 dark:divide-gray-700 text-gray-700 dark:text-gray-200">
        {data.por_producto.map((p) => (
          <tr key={String(p.producto_id ?? SIN_ASIGNAR)}>
            <td className="px-4 py-2 font-medium">
              {p.nombre ?? '—'}
              {p.codigo && <span className="text-xs text-gray-400 ml-1">({p.codigo})</span>}
            </td>
            <td className={TD_NUM}>{num(p.unidades_total)}</td>
            <td className={TD_NUM}>{num(p.unidades_parcial)}</td>
            {montos(p)}
          </tr>
        ))}
      </tbody>
    </table>
  );
}

export default ReporteRechazos;
