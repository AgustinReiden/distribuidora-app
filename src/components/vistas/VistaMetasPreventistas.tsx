/**
 * Rendimiento del equipo comercial + avance de objetivos (migs 159-161).
 *
 * Una fila por preventista con sus números del mes; al expandir, el desglose
 * por marca y por categoría y el avance de cada objetivo.
 *
 * La base es "pedidos entregados del mes, sin bonificaciones" — la misma de
 * `reporte_gerencial`, así que la columna Venta cierra peso a peso con la
 * sección "Equipo comercial" del reporte gerencial. Está escrito en pantalla
 * porque `/comisiones` usa otra base (todo lo no cancelado) y ver dos números
 * distintos sin explicación destruye la confianza en los dos.
 */
import { memo, useState } from 'react';
import { Loader2, ChevronRight, Target, Users, UserPlus, TrendingUp } from 'lucide-react';
import { formatPrecio } from '../../utils/formatters';
import BarraProgresoMeta from '../metas/BarraProgresoMeta';
import { useAvanceMetasQuery } from '../../hooks/queries';
import type { RendimientoPreventista, RendimientoResultado } from '../../hooks/queries';

export interface VistaMetasPreventistasProps {
  resultado?: RendimientoResultado;
  loading: boolean;
  periodo: string;
  onCambiarPeriodo: (periodo: string) => void;
  onAbrirObjetivos: () => void;
}

/** Avance de un preventista, cargado sólo al expandir su fila. */
const DetalleAvance = memo(function DetalleAvance({
  preventistaId,
  periodo,
}: { preventistaId: string; periodo: string }) {
  const { data: avance, isLoading } = useAvanceMetasQuery(preventistaId, periodo);

  if (isLoading) {
    return <div className="py-3 flex justify-center"><Loader2 className="w-4 h-4 animate-spin text-blue-600" /></div>;
  }
  if (!avance?.metas?.length) {
    return <p className="text-sm text-gray-500 dark:text-gray-400 py-2">Sin objetivos cargados este mes.</p>;
  }
  return (
    <div className="divide-y dark:divide-gray-700">
      {avance.metas.map(m => <BarraProgresoMeta key={m.id} meta={m} densa />)}
    </div>
  );
});

const FilaPreventista = memo(function FilaPreventista({
  p,
  periodo,
}: { p: RendimientoPreventista; periodo: string }) {
  const [abierta, setAbierta] = useState(false);

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
          {p.metas_cargadas > 0 ? (
            <span className="dark:text-gray-300">{p.metas_cargadas}</span>
          ) : (
            <span className="text-gray-400 text-xs">sin metas</span>
          )}
        </td>
      </tr>

      {abierta && (
        <tr className="bg-gray-50/60 dark:bg-gray-800/60">
          <td colSpan={7} className="px-3 py-3">
            <div className="grid gap-4 md:grid-cols-2">
              <div>
                <h4 className="text-sm font-semibold mb-2 dark:text-white flex items-center gap-1.5">
                  <Target className="w-4 h-4 text-blue-600" />
                  Objetivos
                </h4>
                <DetalleAvance preventistaId={p.preventista_id} periodo={periodo} />
              </div>

              <div className="space-y-3">
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
                    {p.por_marca.length === 0 && (
                      <li className="text-gray-400">Sin datos</li>
                    )}
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
                    {p.por_categoria.length === 0 && (
                      <li className="text-gray-400">Sin datos</li>
                    )}
                  </ul>
                </div>
                <p className="text-xs text-gray-500 dark:text-gray-400">
                  Margen comercial del mes: {formatPrecio(p.margen_comercial)}
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
}: VistaMetasPreventistasProps) {
  const preventistas = resultado?.preventistas ?? [];
  const totalVenta = preventistas.reduce((t, p) => t + p.venta, 0);
  const totalNuevos = preventistas.reduce((t, p) => t + p.clientes_nuevos, 0);
  const totalCobertura = preventistas.reduce((t, p) => t + p.cobertura, 0);

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

      <div className="grid grid-cols-3 gap-3">
        {[
          { icon: TrendingUp, label: 'Venta del mes', valor: formatPrecio(totalVenta) },
          { icon: Users, label: 'Clientes atendidos', valor: String(totalCobertura) },
          { icon: UserPlus, label: 'Clientes nuevos', valor: String(totalNuevos) },
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
            No hay ventas entregadas en este mes.
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
                <FilaPreventista key={p.preventista_id} p={p} periodo={periodo} />
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
});

export default VistaMetasPreventistas;
