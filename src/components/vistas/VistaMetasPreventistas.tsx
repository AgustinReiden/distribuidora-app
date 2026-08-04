/**
 * Objetivos y rendimiento del equipo comercial (migs 159-164).
 *
 * El panel muestra a TODOS los preventistas de la sucursal —vendieran o no—
 * con sus objetivos, a quién están asignados y el progreso, sin tener que
 * expandir nada. Un preventista que no vendió en el mes es justamente el que
 * hay que ver: esconderlo (que era lo que pasaba al armar la lista desde los
 * pedidos entregados) dejaba objetivos invisibles.
 *
 * El avance viene embebido en el mismo RPC, y sale del mismo cálculo que ve el
 * preventista en su dashboard, así que los números no pueden discrepar.
 *
 * Expandir la fila agrega el desglose por marca y por categoría.
 */
import { memo, useState } from 'react';
import { Loader2, ChevronRight, Target, Users, UserPlus, TrendingUp, Pencil, Trash2 } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import BarraProgresoMeta from '../metas/BarraProgresoMeta';
import type { AvanceMeta, RendimientoPreventista, RendimientoResultado } from '../../hooks/queries';

export interface VistaMetasPreventistasProps {
  resultado?: RendimientoResultado;
  loading: boolean;
  periodo: string;
  onCambiarPeriodo: (periodo: string) => void;
  onAbrirObjetivos: () => void;
  onEditarMeta: (meta: AvanceMeta, preventistaId: string) => void;
  onEliminarMeta: (meta: AvanceMeta) => void;
  eliminando?: boolean;
}

const FilaPreventista = memo(function FilaPreventista({
  p,
  onEditarMeta,
  onEliminarMeta,
  eliminando,
}: {
  p: RendimientoPreventista;
  onEditarMeta: VistaMetasPreventistasProps['onEditarMeta'];
  onEliminarMeta: VistaMetasPreventistasProps['onEliminarMeta'];
  eliminando?: boolean;
}) {
  const [abierta, setAbierta] = useState(false);
  const metas = p.metas ?? [];
  const resumen = p.resumen_metas ?? { total: 0, cumplidas: 0, en_riesgo: 0 };

  return (
    <>
      <tr
        className="border-b dark:border-gray-700 hover:bg-gray-50 dark:hover:bg-gray-700/40 cursor-pointer"
        onClick={() => setAbierta(v => !v)}
      >
        <td className="px-3 py-2.5">
          <span className="flex items-center gap-1.5 font-medium dark:text-white">
            <ChevronRight className={`w-4 h-4 text-gray-400 transition-transform ${abierta ? 'rotate-90' : ''}`} />
            {p.nombre}
            {p.rol && p.rol !== 'preventista' && (
              <span className="text-xs px-1.5 py-0.5 rounded-full bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300">
                {p.rol}
              </span>
            )}
          </span>
        </td>
        <td className="px-3 py-2.5 text-right tabular-nums font-medium dark:text-white">{formatPrecio(p.venta)}</td>
        <td className="px-3 py-2.5 text-right tabular-nums dark:text-gray-300 hidden sm:table-cell">{p.pedidos}</td>
        <td className="px-3 py-2.5 text-right tabular-nums dark:text-gray-300 hidden md:table-cell">
          {p.ticket != null ? formatPrecio(p.ticket) : '—'}
        </td>
        <td className="px-3 py-2.5 text-right tabular-nums dark:text-gray-300">{p.cobertura}</td>
        <td className="px-3 py-2.5 text-right tabular-nums dark:text-gray-300 hidden sm:table-cell">{p.clientes_nuevos}</td>
        <td className="px-3 py-2.5 text-right tabular-nums">
          {resumen.total > 0 ? (
            <span className="dark:text-gray-300">
              {resumen.cumplidas} de {resumen.total}
              {resumen.en_riesgo > 0 && (
                <span className="ml-1.5 text-xs text-rose-600 dark:text-rose-400">
                  · {resumen.en_riesgo} atrasado{resumen.en_riesgo === 1 ? '' : 's'}
                </span>
              )}
            </span>
          ) : (
            <span className="text-gray-400 text-xs">sin objetivos</span>
          )}
        </td>
      </tr>

      {/* Objetivos SIEMPRE visibles: son el motivo de esta pantalla. */}
      {metas.length > 0 && (
        <tr className="border-b dark:border-gray-700">
          <td colSpan={7} className="px-3 pt-1 pb-3 bg-gray-50/60 dark:bg-gray-800/40">
            <div className="space-y-1 max-w-3xl">
              {metas.map(m => (
                <div key={m.id} className="flex items-start gap-2">
                  <div className="flex-1 min-w-0">
                    <BarraProgresoMeta meta={m} densa />
                  </div>
                  <div className="flex gap-0.5 shrink-0 pt-1.5">
                    <button
                      type="button"
                      onClick={() => onEditarMeta(m, p.preventista_id)}
                      className="p-1.5 text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/20 rounded"
                      aria-label={`Editar objetivo de ${p.nombre}`}
                      title="Editar objetivo"
                    >
                      <Pencil className="w-4 h-4" />
                    </button>
                    <button
                      type="button"
                      onClick={() => onEliminarMeta(m)}
                      disabled={eliminando}
                      className="p-1.5 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded disabled:opacity-50"
                      aria-label={`Eliminar objetivo de ${p.nombre}`}
                      title="Eliminar objetivo"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </td>
        </tr>
      )}

      {abierta && (
        <tr className="bg-gray-50/60 dark:bg-gray-800/60 border-b dark:border-gray-700">
          <td colSpan={7} className="px-3 py-3">
            <div className="grid gap-4 md:grid-cols-2">
              <div>
                <h4 className="text-sm font-semibold mb-1 dark:text-white">Por marca</h4>
                <ul className="text-sm space-y-0.5">
                  {p.por_marca.slice(0, 6).map(m => (
                    <li key={m.marca} className="flex justify-between gap-2">
                      <span className="text-gray-600 dark:text-gray-400 truncate">{m.marca}</span>
                      <span className="tabular-nums dark:text-gray-300 shrink-0">
                        {formatPrecio(m.venta)} · {m.unidades} u
                      </span>
                    </li>
                  ))}
                  {p.por_marca.length === 0 && <li className="text-gray-400">Sin ventas en el período</li>}
                </ul>
              </div>
              <div>
                <h4 className="text-sm font-semibold mb-1 dark:text-white">Por categoría</h4>
                <ul className="text-sm space-y-0.5">
                  {p.por_categoria.slice(0, 6).map(c => (
                    <li key={c.categoria} className="flex justify-between gap-2">
                      <span className="text-gray-600 dark:text-gray-400 truncate">{c.categoria}</span>
                      <span className="tabular-nums dark:text-gray-300 shrink-0">
                        {formatPrecio(c.venta)} · {c.unidades} u
                      </span>
                    </li>
                  ))}
                  {p.por_categoria.length === 0 && <li className="text-gray-400">Sin ventas en el período</li>}
                </ul>
                <p className="text-xs text-gray-500 dark:text-gray-400 mt-2">
                  Margen comercial del período: {formatPrecio(p.margen_comercial)}
                </p>
              </div>
            </div>
          </td>
        </tr>
      )}
    </>
  );
});

/** Últimos 12 meses como opciones de período. */
function opcionesPeriodo(): Array<{ valor: string; label: string }> {
  const meses = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio',
    'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
  const hoy = new Date();
  const out: Array<{ valor: string; label: string }> = [];
  for (let i = 0; i < 12; i++) {
    const d = new Date(hoy.getFullYear(), hoy.getMonth() - i, 1);
    const valor = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-01`;
    out.push({ valor, label: `${meses[d.getMonth()]} ${d.getFullYear()}` });
  }
  return out;
}

const VistaMetasPreventistas = memo(function VistaMetasPreventistas({
  resultado,
  loading,
  periodo,
  onCambiarPeriodo,
  onAbrirObjetivos,
  onEditarMeta,
  onEliminarMeta,
  eliminando,
}: VistaMetasPreventistasProps) {
  const preventistas = resultado?.preventistas ?? [];
  const totalVenta = preventistas.reduce((t, p) => t + p.venta, 0);
  const totalNuevos = preventistas.reduce((t, p) => t + p.clientes_nuevos, 0);
  const totalCobertura = preventistas.reduce((t, p) => t + p.cobertura, 0);
  const totalObjetivos = preventistas.reduce((t, p) => t + (p.resumen_metas?.total ?? 0), 0);

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 className="text-xl font-semibold dark:text-white">Objetivos y rendimiento</h1>
          <p className="text-sm text-gray-500 dark:text-gray-400">
            Sobre pedidos entregados del mes, sin bonificaciones.
          </p>
        </div>
        <div className="flex items-center gap-2">
          <select
            value={periodo}
            onChange={e => onCambiarPeriodo(e.target.value)}
            className="px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            aria-label="Mes"
          >
            {opcionesPeriodo().map(o => <option key={o.valor} value={o.valor}>{o.label}</option>)}
          </select>
          <button
            type="button"
            onClick={onAbrirObjetivos}
            className="px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 flex items-center gap-1.5"
          >
            <Target className="w-4 h-4" />
            Cargar objetivos
          </button>
        </div>
      </div>

      <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
        {[
          { icon: TrendingUp, label: 'Venta del mes', valor: formatPrecio(totalVenta) },
          { icon: Users, label: 'Clientes atendidos', valor: String(totalCobertura) },
          { icon: UserPlus, label: 'Clientes nuevos', valor: String(totalNuevos) },
          { icon: Target, label: 'Objetivos cargados', valor: String(totalObjetivos) },
        ].map(k => (
          <div key={k.label} className="rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 p-3">
            <p className="text-xs text-gray-500 dark:text-gray-400 flex items-center gap-1">
              <k.icon className="w-3.5 h-3.5" />
              {k.label}
            </p>
            <p className="text-lg font-semibold dark:text-white tabular-nums mt-0.5">{k.valor}</p>
          </div>
        ))}
      </div>

      <div className="rounded-xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-800 overflow-x-auto">
        {loading ? (
          <div className="flex justify-center py-16"><Loader2 className="w-6 h-6 animate-spin text-blue-600" /></div>
        ) : preventistas.length === 0 ? (
          <p className="text-center text-sm text-gray-500 dark:text-gray-400 py-12">
            No hay preventistas ni objetivos en esta sucursal.
          </p>
        ) : (
          <table className="w-full text-sm">
            <thead className="text-xs uppercase text-gray-500 dark:text-gray-400 border-b dark:border-gray-700">
              <tr>
                <th className="px-3 py-2 text-left font-medium">Preventista</th>
                <th className="px-3 py-2 text-right font-medium">Venta</th>
                <th className="px-3 py-2 text-right font-medium hidden sm:table-cell">Pedidos</th>
                <th className="px-3 py-2 text-right font-medium hidden md:table-cell">Ticket</th>
                <th className="px-3 py-2 text-right font-medium">Clientes</th>
                <th className="px-3 py-2 text-right font-medium hidden sm:table-cell">Nuevos</th>
                <th className="px-3 py-2 text-right font-medium">Objetivos</th>
              </tr>
            </thead>
            <tbody>
              {preventistas.map(p => (
                <FilaPreventista
                  key={p.preventista_id}
                  p={p}
                  onEditarMeta={onEditarMeta}
                  onEliminarMeta={onEliminarMeta}
                  eliminando={eliminando}
                />
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
});

export default VistaMetasPreventistas;
