/**
 * ModalControlStock
 *
 * Control de stock por planilla:
 *  - Descargar planilla (Excel) filtrando por categoría (admin y encargado).
 *  - Cargar planilla completada para ajustar stock (solo admin). Parsea, matchea
 *    productos por código/nombre, muestra preview de diferencias y aplica via RPC.
 *
 * Regla clave: solo se ajustan los ítems con "Stock Real" cargado en la planilla.
 * Las filas vacías se omiten (no se pisa a 0 un ítem no controlado).
 */
import { useState, useMemo, memo } from 'react';
import { Download, Upload, Loader2, AlertTriangle, CheckCircle2, FileSpreadsheet, X } from 'lucide-react';
import ModalBase from './ModalBase';
import { exportControlStock, readControlStockPlanilla, type ControlStockRow } from '../../utils/excel';
import type { ProductoDB } from '../../types';
import type { AplicarControlStockResult } from '../../hooks/queries/useControlStockQuery';

export interface ModalControlStockProps {
  productos: ProductoDB[];
  /** Si el usuario puede cargar la planilla (aplicar ajustes). Solo admin. */
  puedeCargar: boolean;
  /** Aplica los ajustes via RPC. Devuelve el resumen de la sesión. */
  onAplicar: (ajustes: Array<{ producto_id: string; stock_real: number }>) => Promise<AplicarControlStockResult>;
  aplicando: boolean;
  onClose: () => void;
}

const SIN_CATEGORIA = 'Sin categoría';
const catDe = (p: ProductoDB): string => (p.categoria || '').trim() || SIN_CATEGORIA;

interface PreviewItem {
  producto: ProductoDB;
  stockReal: number;
  diferencia: number;
}

const ModalControlStock = memo(function ModalControlStock({ productos, puedeCargar, onAplicar, aplicando, onClose }: ModalControlStockProps) {
  const categoriasDisponibles = useMemo(() => {
    const set = new Set<string>();
    productos.forEach(p => set.add(catDe(p)));
    return [...set].sort((a, b) => a.localeCompare(b));
  }, [productos]);

  const [categoriasSel, setCategoriasSel] = useState<Set<string>>(() => new Set(categoriasDisponibles));
  const [descargando, setDescargando] = useState(false);

  const [parseando, setParseando] = useState(false);
  const [parseError, setParseError] = useState<string | null>(null);
  const [preview, setPreview] = useState<{ matched: PreviewItem[]; unmatched: ControlStockRow[] } | null>(null);
  const [resultado, setResultado] = useState<AplicarControlStockResult | null>(null);

  const productosFiltrados = useMemo(
    () => productos.filter(p => categoriasSel.has(catDe(p))),
    [productos, categoriasSel]
  );

  const toggleCategoria = (cat: string): void => {
    setCategoriasSel(prev => {
      const next = new Set(prev);
      if (next.has(cat)) next.delete(cat); else next.add(cat);
      return next;
    });
  };
  const seleccionarTodas = (): void => setCategoriasSel(new Set(categoriasDisponibles));
  const seleccionarNinguna = (): void => setCategoriasSel(new Set());

  const handleDescargar = async (): Promise<void> => {
    if (productosFiltrados.length === 0) return;
    setDescargando(true);
    try {
      await exportControlStock(productosFiltrados);
    } finally {
      setDescargando(false);
    }
  };

  const matchProducto = (row: ControlStockRow): ProductoDB | undefined => {
    if (row.codigo) {
      const porCodigo = productos.find(p => (p.codigo || '').trim() === row.codigo);
      if (porCodigo) return porCodigo;
    }
    if (row.nombre) {
      const n = row.nombre.trim().toLowerCase();
      return productos.find(p => (p.nombre || '').trim().toLowerCase() === n);
    }
    return undefined;
  };

  const handleArchivo = async (file: File | undefined): Promise<void> => {
    if (!file) return;
    setParseError(null);
    setPreview(null);
    setResultado(null);
    setParseando(true);
    try {
      const filas = await readControlStockPlanilla(file);
      const matched: PreviewItem[] = [];
      const unmatched: ControlStockRow[] = [];
      for (const row of filas) {
        const producto = matchProducto(row);
        if (!producto) { unmatched.push(row); continue; }
        matched.push({ producto, stockReal: row.stockReal, diferencia: row.stockReal - producto.stock });
      }
      if (matched.length === 0 && unmatched.length === 0) {
        setParseError('La planilla no tiene ninguna fila con "Stock Real" cargado.');
        return;
      }
      setPreview({ matched, unmatched });
    } catch (e) {
      setParseError((e as Error).message || 'No se pudo leer la planilla.');
    } finally {
      setParseando(false);
    }
  };

  const cambios = preview ? preview.matched.filter(m => m.diferencia !== 0) : [];

  const handleAplicar = async (): Promise<void> => {
    if (!preview || cambios.length === 0) return;
    const ajustes = preview.matched.map(m => ({ producto_id: String(m.producto.id), stock_real: m.stockReal }));
    const res = await onAplicar(ajustes);
    setResultado(res);
    setPreview(null);
  };

  return (
    <ModalBase title="Control de stock" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-5 max-h-[70vh] overflow-y-auto">
        {/* ── Descargar ── */}
        <section>
          <div className="flex items-center gap-2 mb-2">
            <FileSpreadsheet className="w-5 h-5 text-amber-600" />
            <h3 className="font-medium text-gray-800 dark:text-gray-100">Descargar planilla</h3>
          </div>
          <p className="text-xs text-gray-500 mb-2">
            Elegí qué categorías controlar. La planilla solo incluye esas categorías; el resto no se toca al cargar.
          </p>

          <div className="flex items-center gap-3 mb-2 text-xs">
            <button type="button" onClick={seleccionarTodas} className="text-blue-600 hover:underline">Todas</button>
            <button type="button" onClick={seleccionarNinguna} className="text-blue-600 hover:underline">Ninguna</button>
            <span className="text-gray-400">{categoriasSel.size}/{categoriasDisponibles.length} categorías · {productosFiltrados.length} productos</span>
          </div>

          <div className="max-h-40 overflow-y-auto border rounded-lg dark:border-gray-600 p-2 grid grid-cols-1 sm:grid-cols-2 gap-1">
            {categoriasDisponibles.map(cat => (
              <label key={cat} className="flex items-center gap-2 px-2 py-1 rounded hover:bg-gray-50 dark:hover:bg-gray-700 cursor-pointer">
                <input type="checkbox" checked={categoriasSel.has(cat)} onChange={() => toggleCategoria(cat)} className="rounded" />
                <span className="text-sm dark:text-gray-200 truncate">{cat}</span>
              </label>
            ))}
          </div>

          <button
            type="button"
            onClick={handleDescargar}
            disabled={descargando || productosFiltrados.length === 0}
            className="mt-3 inline-flex items-center gap-2 px-4 py-2 bg-amber-600 text-white rounded-lg hover:bg-amber-700 disabled:bg-gray-400 disabled:cursor-not-allowed font-medium"
          >
            {descargando ? <Loader2 className="w-4 h-4 animate-spin" /> : <Download className="w-4 h-4" />}
            Descargar planilla
          </button>
        </section>

        {/* ── Cargar (solo admin) ── */}
        {puedeCargar && (
          <section className="border-t pt-4 dark:border-gray-700">
            <div className="flex items-center gap-2 mb-2">
              <Upload className="w-5 h-5 text-emerald-600" />
              <h3 className="font-medium text-gray-800 dark:text-gray-100">Cargar planilla completada</h3>
            </div>
            <p className="text-xs text-gray-500 mb-2">
              Solo se ajustan los ítems con "Stock Real" cargado. Las filas vacías se omiten.
            </p>

            {resultado ? (
              <div className="rounded-lg border border-emerald-200 bg-emerald-50 dark:bg-emerald-900/20 dark:border-emerald-700 p-3">
                <div className="flex items-center gap-2 text-emerald-700 dark:text-emerald-300 font-medium mb-1">
                  <CheckCircle2 className="w-5 h-5" />
                  Ajustes aplicados
                </div>
                <p className="text-sm text-gray-700 dark:text-gray-200">
                  {resultado.total_items} producto{resultado.total_items === 1 ? '' : 's'} ajustado{resultado.total_items === 1 ? '' : 's'}
                  {' · '}<span className="text-emerald-600">+{resultado.total_altas}</span>
                  {' / '}<span className="text-rose-600">-{resultado.total_bajas}</span>
                </p>
                {resultado.no_encontrados.length > 0 && (
                  <p className="text-xs text-amber-600 mt-1">{resultado.no_encontrados.length} fila(s) no se pudieron asociar a un producto.</p>
                )}
                <button type="button" onClick={() => setResultado(null)} className="mt-2 text-sm text-blue-600 hover:underline">
                  Cargar otra planilla
                </button>
              </div>
            ) : preview ? (
              <div className="space-y-3">
                <div className="text-sm text-gray-700 dark:text-gray-200">
                  <span className="font-medium">{cambios.length}</span> de {preview.matched.length} ítems tienen diferencia.
                  {preview.unmatched.length > 0 && (
                    <span className="text-amber-600"> {preview.unmatched.length} sin asociar.</span>
                  )}
                </div>

                {cambios.length > 0 && (
                  <div className="max-h-56 overflow-y-auto border rounded-lg dark:border-gray-600 divide-y dark:divide-gray-700">
                    {cambios.map(m => (
                      <div key={m.producto.id} className="flex items-center justify-between gap-2 px-3 py-2 text-sm">
                        <span className="truncate dark:text-gray-200">{m.producto.nombre}</span>
                        <span className="flex items-center gap-2 shrink-0">
                          <span className="text-gray-400">{m.producto.stock}</span>
                          <span className="text-gray-400">→</span>
                          <span className="font-medium dark:text-gray-100">{m.stockReal}</span>
                          <span className={`w-12 text-right font-semibold ${m.diferencia > 0 ? 'text-emerald-600' : 'text-rose-600'}`}>
                            {m.diferencia > 0 ? '+' : ''}{m.diferencia}
                          </span>
                        </span>
                      </div>
                    ))}
                  </div>
                )}

                {preview.unmatched.length > 0 && (
                  <details className="text-xs text-gray-500">
                    <summary className="cursor-pointer">Ver {preview.unmatched.length} fila(s) sin asociar</summary>
                    <ul className="mt-1 pl-4 list-disc">
                      {preview.unmatched.slice(0, 30).map((u, i) => (
                        <li key={i}>{u.codigo || '(sin código)'} — {u.nombre || '(sin nombre)'} → {u.stockReal}</li>
                      ))}
                    </ul>
                  </details>
                )}

                <div className="flex items-center gap-2">
                  <button
                    type="button"
                    onClick={handleAplicar}
                    disabled={aplicando || cambios.length === 0}
                    className="inline-flex items-center gap-2 px-4 py-2 bg-emerald-600 text-white rounded-lg hover:bg-emerald-700 disabled:bg-gray-400 disabled:cursor-not-allowed font-medium"
                  >
                    {aplicando ? <Loader2 className="w-4 h-4 animate-spin" /> : <CheckCircle2 className="w-4 h-4" />}
                    Aplicar ajustes
                  </button>
                  <button type="button" onClick={() => setPreview(null)} className="inline-flex items-center gap-1 px-3 py-2 text-sm text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg">
                    <X className="w-4 h-4" /> Descartar
                  </button>
                </div>
              </div>
            ) : (
              <label className="flex flex-col items-center justify-center gap-2 border-2 border-dashed rounded-lg p-6 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/40 dark:border-gray-600">
                {parseando ? (
                  <Loader2 className="w-6 h-6 animate-spin text-gray-400" />
                ) : (
                  <Upload className="w-6 h-6 text-gray-400" />
                )}
                <span className="text-sm text-gray-600 dark:text-gray-300">
                  {parseando ? 'Leyendo planilla...' : 'Hacé clic para elegir el archivo .xlsx'}
                </span>
                <input
                  type="file"
                  accept=".xlsx,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
                  className="hidden"
                  onChange={e => { handleArchivo(e.target.files?.[0]); e.target.value = ''; }}
                  disabled={parseando}
                />
              </label>
            )}

            {parseError && (
              <div className="mt-2 flex items-start gap-2 text-sm text-rose-600">
                <AlertTriangle className="w-4 h-4 mt-0.5 shrink-0" />
                <span>{parseError}</span>
              </div>
            )}
          </section>
        )}
      </div>

      <div className="flex justify-end p-4 border-t bg-gray-50 dark:bg-gray-800 dark:border-gray-700">
        <button onClick={onClose} className="px-4 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-700">Cerrar</button>
      </div>
    </ModalBase>
  );
});

export default ModalControlStock;
