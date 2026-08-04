/**
 * Alta, edición y baja de objetivos (migs 159-164).
 *
 * Dos modos:
 *  - alta: multiselección de preventistas, para cargarle el mismo objetivo a
 *    todo el equipo de una. En la base igual queda UNA fila por persona (el
 *    avance es individual); el modal sólo evita cargarlo cinco veces a mano.
 *  - edición: se abre desde el panel con un objetivo ya cargado. Ahí el
 *    preventista es uno solo y no se cambia — mover un objetivo de persona
 *    sería borrar el avance de una y estrenar el de otra sin dejar rastro.
 *
 * El período es mensual por defecto y editable: una quincena, una semana de
 * acción o una campaña que cruza meses.
 *
 * El tipo de meta manda sobre el alcance: "cobertura" y "clientes nuevos" no
 * lo admiten (se cuentan sobre clientes, no sobre productos) y "unidades" lo
 * exige. Los CHECK de la base dicen lo mismo; acá se refleja para no ofrecer
 * combinaciones que van a fallar del otro lado.
 */
import { memo, useMemo, useState } from 'react';
import { Loader2, Plus, AlertCircle, Target, Search, Check } from 'lucide-react';
import ModalBase from './ModalBase';
import NumberInput from '../ui/NumberInput';
import {
  useGuardarMetaPreventistaMutation,
  useMarcasQuery,
  useCategoriasQuery,
  useProductosQuery,
  usePreventistasAsignablesQuery,
} from '../../hooks/queries';
import type { TipoMeta, AvanceMeta } from '../../hooks/queries';
import { useSucursal } from '../../contexts/SucursalContext';

export interface ModalMetasPreventistaProps {
  /** Período 'YYYY-MM-01' del panel; da el mes por defecto del formulario. */
  periodo: string;
  /** Si viene, el modal abre en modo edición de ese objetivo. */
  edicion?: { meta: AvanceMeta; preventistaId: string } | null;
  onClose: () => void;
}

const TIPOS: Array<{ valor: TipoMeta; label: string; ayuda: string }> = [
  { valor: 'facturacion', label: 'Facturación ($)', ayuda: 'Pesos vendidos en el período.' },
  { valor: 'unidades', label: 'Unidades vendidas', ayuda: 'Cantidad de unidades. Elegí de qué.' },
  { valor: 'cobertura', label: 'Clientes visitados', ayuda: 'Clientes distintos con pedido entregado.' },
  { valor: 'clientes_nuevos', label: 'Clientes nuevos', ayuda: 'Clientes que compran por primera vez.' },
];

const ADMITE_ALCANCE: TipoMeta[] = ['facturacion', 'unidades'];
const EXIGE_ALCANCE: TipoMeta[] = ['unidades'];

/** Último día del mes de una fecha ISO 'YYYY-MM-DD'. */
function finDeMes(iso: string): string {
  const [y, m] = iso.split('-').map(Number);
  return new Date(y, m, 0).toISOString().slice(0, 10);
}

const ModalMetasPreventista = memo(function ModalMetasPreventista({
  periodo,
  edicion,
  onClose,
}: ModalMetasPreventistaProps) {
  const { currentSucursalId } = useSucursal();
  const { data: preventistas = [] } = usePreventistasAsignablesQuery();
  const { data: marcas = [] } = useMarcasQuery();
  const { data: categorias = [] } = useCategoriasQuery();
  const { data: productos = [] } = useProductosQuery();
  const guardarMut = useGuardarMetaPreventistaMutation();

  const esEdicion = Boolean(edicion);
  const m = edicion?.meta;

  const [seleccionados, setSeleccionados] = useState<Set<string>>(
    () => new Set(edicion ? [edicion.preventistaId] : []),
  );
  const [tipoMeta, setTipoMeta] = useState<TipoMeta>(m?.tipo_meta ?? 'facturacion');
  const [alcance, setAlcance] = useState(() => {
    if (!m) return '';
    if (m.marca_id) return `marca:${m.marca_id}`;
    if (m.categoria_id) return `categoria:${m.categoria_id}`;
    if (m.producto_ids?.length) return 'productos';
    return '';
  });
  const [productosSel, setProductosSel] = useState<Set<string>>(
    () => new Set((m?.producto_ids ?? []).map(String)),
  );
  const [busquedaProd, setBusquedaProd] = useState('');
  const [valor, setValor] = useState<number>(Number(m?.objetivo ?? 0));
  const [desde, setDesde] = useState(m?.desde ?? periodo);
  const [hasta, setHasta] = useState(m?.hasta ?? finDeMes(periodo));
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');

  const admiteAlcance = ADMITE_ALCANCE.includes(tipoMeta);
  const exigeAlcance = EXIGE_ALCANCE.includes(tipoMeta);
  // Mes completo = el caso normal; se avisa cuando deja de serlo.
  const esMesCompleto = desde === `${desde.slice(0, 7)}-01` && hasta === finDeMes(desde);

  const nombrePorId = useMemo(() => {
    const map = new Map<string, string>();
    preventistas.forEach(p => map.set(p.id, p.nombre || p.email || p.id));
    return map;
  }, [preventistas]);

  const productosFiltrados = useMemo(() => {
    const q = busquedaProd.trim().toLowerCase();
    return productos
      .filter(p => !q || p.nombre.toLowerCase().includes(q) || (p.categoria || '').toLowerCase().includes(q))
      .sort((a, b) => a.nombre.localeCompare(b.nombre));
  }, [productos, busquedaProd]);

  const todosFiltradosSel =
    productosFiltrados.length > 0 && productosFiltrados.every(p => productosSel.has(p.id));

  const handleTipoChange = (t: TipoMeta): void => {
    setTipoMeta(t);
    if (!ADMITE_ALCANCE.includes(t)) {
      setAlcance('');
      setProductosSel(new Set());
    }
    setError('');
  };

  const handleGuardar = async (): Promise<void> => {
    if (seleccionados.size === 0) {
      setError('Elegí al menos un preventista');
      return;
    }
    if (currentSucursalId == null) {
      setError('No hay sucursal activa. Recargá la página.');
      return;
    }
    const objetivo = Number(valor);
    if (!objetivo || objetivo <= 0) {
      setError('El objetivo tiene que ser mayor a 0');
      return;
    }
    if (exigeAlcance && !alcance) {
      setError('Elegí de qué son las unidades (marca, categoría o productos)');
      return;
    }
    if (alcance === 'productos' && productosSel.size === 0) {
      setError('Elegí al menos un producto');
      return;
    }
    if (hasta < desde) {
      setError('El fin del período no puede ser anterior al inicio');
      return;
    }

    const [tipoAlc, idAlc] = alcance.includes(':') ? alcance.split(':') : [alcance, null];
    setError('');
    setOkMsg('');

    const comun = {
      sucursalId: currentSucursalId,
      periodo: desde,
      // Sólo se manda el fin si NO es el mes completo: así el RPC conserva su
      // comportamiento mensual por defecto y no se guardan rangos "custom"
      // que en realidad son un mes.
      periodoHasta: esMesCompleto ? null : hasta,
      tipoMeta,
      valorObjetivo: objetivo,
      marcaId: tipoAlc === 'marca' ? idAlc : null,
      categoriaId: tipoAlc === 'categoria' ? idAlc : null,
      productoIds: tipoAlc === 'productos' ? [...productosSel].map(Number) : null,
    };

    if (esEdicion && m) {
      try {
        await guardarMut.mutateAsync({ ...comun, id: m.id, preventistaId: edicion!.preventistaId });
        onClose();
      } catch (e) {
        setError(e instanceof Error ? e.message : 'No se pudo guardar el objetivo');
      }
      return;
    }

    // Alta: una fila por preventista. Si uno falla se sigue con el resto —
    // que a uno le falte la sucursal no tiene por qué tirar abajo la carga.
    const fallos: string[] = [];
    for (const pid of seleccionados) {
      try {
        await guardarMut.mutateAsync({ ...comun, preventistaId: pid });
      } catch (e) {
        fallos.push(`${nombrePorId.get(pid) ?? pid}: ${e instanceof Error ? e.message : 'error'}`);
      }
    }
    const ok = seleccionados.size - fallos.length;
    if (fallos.length > 0) setError(fallos.join(' · '));
    if (ok > 0) {
      setOkMsg(`Objetivo cargado para ${ok} preventista${ok === 1 ? '' : 's'}.`);
      setValor(0);
      setAlcance('');
      setProductosSel(new Set());
    }
  };

  return (
    <ModalBase
      title={esEdicion ? 'Editar objetivo' : 'Cargar objetivos'}
      onClose={onClose}
      maxWidth="max-w-2xl"
    >
      <div className="p-4 space-y-3">
        {esEdicion ? (
          <p className="text-sm px-3 py-2 rounded-lg bg-blue-50 dark:bg-blue-900/20 text-blue-800 dark:text-blue-300">
            Editando el objetivo de <strong>{nombrePorId.get(edicion!.preventistaId) ?? ''}</strong>.
            Para asignárselo a otra persona, cargá uno nuevo y eliminá este.
          </p>
        ) : (
          <div>
            <div className="flex items-baseline justify-between gap-2 mb-1">
              <label className="block text-sm font-medium dark:text-gray-200">
                Preventistas ({seleccionados.size})
              </label>
              <button
                type="button"
                onClick={() => setSeleccionados(
                  seleccionados.size === preventistas.length
                    ? new Set()
                    : new Set(preventistas.map(p => p.id)),
                )}
                className="text-sm font-medium text-blue-600 hover:underline"
              >
                {seleccionados.size === preventistas.length ? 'Ninguno' : 'Todos'}
              </button>
            </div>
            <div className="border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700 max-h-36 overflow-y-auto">
              {preventistas.map(p => (
                <label
                  key={p.id}
                  className="flex items-center gap-2 px-3 py-2 text-sm cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50"
                >
                  <input
                    type="checkbox"
                    checked={seleccionados.has(p.id)}
                    onChange={e => setSeleccionados(prev => {
                      const next = new Set(prev);
                      if (e.target.checked) next.add(p.id); else next.delete(p.id);
                      return next;
                    })}
                    className="w-4 h-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
                  />
                  <span className="dark:text-white truncate">{p.nombre || p.email}</span>
                </label>
              ))}
            </div>
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              Se carga el mismo objetivo para cada uno; el avance se mide por separado.
            </p>
          </div>
        )}

        {/* Período: mensual por defecto, editable. */}
        <div className="grid grid-cols-2 gap-2">
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Desde</label>
            <input
              type="date"
              value={desde}
              onChange={e => setDesde(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            />
          </div>
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Hasta</label>
            <input
              type="date"
              value={hasta}
              onChange={e => setHasta(e.target.value)}
              min={desde}
              className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
            />
          </div>
        </div>
        <div className="flex items-center gap-2 -mt-1">
          <button
            type="button"
            onClick={() => { const d = `${desde.slice(0, 7)}-01`; setDesde(d); setHasta(finDeMes(d)); }}
            className="text-xs font-medium text-blue-600 hover:underline"
          >
            Usar el mes completo
          </button>
          <span className="text-xs text-gray-500 dark:text-gray-400">
            {esMesCompleto ? 'Mes completo (lo habitual)' : 'Período personalizado'}
          </span>
        </div>

        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">Tipo de objetivo</label>
          <select
            value={tipoMeta}
            onChange={e => handleTipoChange(e.target.value as TipoMeta)}
            className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          >
            {TIPOS.map(t => <option key={t.valor} value={t.valor}>{t.label}</option>)}
          </select>
          <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
            {TIPOS.find(t => t.valor === tipoMeta)?.ayuda}
          </p>
        </div>

        {admiteAlcance && (
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">
              {exigeAlcance ? 'De qué (obligatorio)' : 'Acotar a (opcional)'}
            </label>
            <select
              value={alcance}
              onChange={e => setAlcance(e.target.value)}
              className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white"
            >
              <option value="">{exigeAlcance ? 'Elegí…' : 'Todo (sin acotar)'}</option>
              <option value="productos">Productos específicos…</option>
              {marcas.filter(x => x.activa).length > 0 && (
                <optgroup label="Marcas">
                  {marcas.filter(x => x.activa).map(x => (
                    <option key={x.id} value={`marca:${x.id}`}>{x.nombre}</option>
                  ))}
                </optgroup>
              )}
              {categorias.filter(c => c.activa !== false).length > 0 && (
                <optgroup label="Categorías">
                  {categorias.filter(c => c.activa !== false).map(c => (
                    <option key={c.id} value={`categoria:${c.id}`}>{c.nombre}</option>
                  ))}
                </optgroup>
              )}
            </select>
            <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
              Para "2 millones de Manaos y de esos, 100 gaseosas" cargá dos objetivos.
            </p>
          </div>
        )}

        {admiteAlcance && alcance === 'productos' && (
          <div>
            <div className="flex items-baseline justify-between gap-2 mb-1">
              <label className="block text-sm font-medium dark:text-gray-200">
                Productos incluidos ({productosSel.size})
              </label>
              <button
                type="button"
                onClick={() => setProductosSel(prev => {
                  const next = new Set(prev);
                  if (todosFiltradosSel) productosFiltrados.forEach(p => next.delete(p.id));
                  else productosFiltrados.forEach(p => next.add(p.id));
                  return next;
                })}
                disabled={productosFiltrados.length === 0}
                className="text-sm font-medium text-blue-600 hover:underline disabled:opacity-50 disabled:no-underline"
              >
                {todosFiltradosSel ? 'Quitar' : 'Agregar'} los {productosFiltrados.length} de la lista
              </button>
            </div>

            <div className="relative mb-2">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-4 h-4 pointer-events-none" />
              <input
                type="text"
                value={busquedaProd}
                onChange={e => setBusquedaProd(e.target.value)}
                placeholder="Filtrar por nombre o categoría… (ej: 3LT)"
                className="w-full pl-9 pr-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
              />
            </div>

            <div className="border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700 max-h-44 overflow-y-auto">
              {productosFiltrados.length === 0 ? (
                <p className="px-3 py-4 text-center text-sm text-gray-500 dark:text-gray-400">
                  No hay productos que coincidan.
                </p>
              ) : productosFiltrados.map(p => (
                <label
                  key={p.id}
                  className="flex items-center gap-2 px-3 py-2 text-sm cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50"
                >
                  <input
                    type="checkbox"
                    checked={productosSel.has(p.id)}
                    onChange={e => setProductosSel(prev => {
                      const next = new Set(prev);
                      if (e.target.checked) next.add(p.id); else next.delete(p.id);
                      return next;
                    })}
                    className="w-4 h-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 shrink-0"
                  />
                  <span className="flex-1 min-w-0">
                    <span className="block dark:text-white truncate">{p.nombre}</span>
                    <span className="block text-xs text-gray-500 dark:text-gray-400">
                      {p.categoria || 'sin categoría'}
                    </span>
                  </span>
                </label>
              ))}
            </div>
          </div>
        )}

        <div>
          <label className="block text-sm font-medium mb-1 dark:text-gray-200">
            Objetivo del período {tipoMeta === 'facturacion' ? '($)' : tipoMeta === 'unidades' ? '(unidades)' : '(clientes)'}
          </label>
          <NumberInput
            value={valor}
            onChange={setValor}
            min={0}
            integer={tipoMeta !== 'facturacion'}
            className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white"
          />
        </div>

        {error && (
          <div role="alert" className="flex items-start gap-2 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg text-sm text-red-700 dark:text-red-300">
            <AlertCircle className="w-4 h-4 flex-shrink-0 mt-0.5" />
            <span>{error}</span>
          </div>
        )}
        {okMsg && (
          <p className="p-3 bg-green-50 dark:bg-green-900/20 border border-green-200 dark:border-green-800 rounded-lg text-sm text-green-700 dark:text-green-300">
            {okMsg}
          </p>
        )}

        <button
          type="button"
          onClick={handleGuardar}
          disabled={guardarMut.isPending}
          className="w-full py-2 bg-blue-600 text-white font-medium rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed flex items-center justify-center gap-1.5"
        >
          {guardarMut.isPending
            ? <Loader2 className="w-4 h-4 animate-spin" />
            : esEdicion ? <Check className="w-4 h-4" /> : <Plus className="w-4 h-4" />}
          {esEdicion
            ? 'Guardar cambios'
            : seleccionados.size > 1
              ? `Agregar objetivo a ${seleccionados.size} preventistas`
              : 'Agregar objetivo'}
        </button>
      </div>

      <div className="p-4 border-t dark:border-gray-600 flex items-center justify-between gap-2">
        <span className="text-xs text-gray-500 dark:text-gray-400 flex items-center gap-1.5">
          <Target className="w-3.5 h-3.5" />
          Los objetivos y su avance se ven en el panel.
        </span>
        <button
          type="button"
          onClick={onClose}
          className="px-4 py-2 text-gray-700 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg"
        >
          Cerrar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalMetasPreventista;
