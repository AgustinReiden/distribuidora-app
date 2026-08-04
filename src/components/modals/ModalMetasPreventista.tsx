/**
 * Alta y baja de objetivos mensuales por preventista (migs 159 y 162).
 *
 * Arriba las metas ya cargadas del período, abajo el formulario. El tipo de
 * meta manda sobre el resto: "cobertura" y "clientes nuevos" no admiten
 * alcance (se cuentan sobre clientes, no sobre productos) y "unidades" lo
 * exige (100 unidades sin decir de qué no es una meta). Los CHECK de la base
 * dicen lo mismo; acá se refleja para no ofrecer combinaciones que van a
 * fallar del otro lado.
 *
 * Dos multiselecciones, por pedido explícito:
 *  - Preventistas: el mismo objetivo suele ir para todo el equipo. En la base
 *    igual se guarda UNA fila por persona (el avance es individual); el modal
 *    sólo evita cargarlo cinco veces a mano.
 *  - Productos: "las gaseosas de 3 litros" son varios SKUs y no siempre
 *    coinciden con una categoría entera (mig 162).
 */
import { memo, useMemo, useState } from 'react';
import { Loader2, Plus, Trash2, AlertCircle, Target, Search } from 'lucide-react';
import ModalBase from './ModalBase';
import NumberInput from '../ui/NumberInput';
import { formatPrecio } from '../../utils/formatters';
import {
  useMetasPreventistaQuery,
  useGuardarMetaPreventistaMutation,
  useDesactivarMetaPreventistaMutation,
  useMarcasQuery,
  useCategoriasQuery,
  useProductosQuery,
  usePreventistasAsignablesQuery,
} from '../../hooks/queries';
import type { TipoMeta, MetaPreventista } from '../../hooks/queries';
import { useSucursal } from '../../contexts/SucursalContext';

export interface ModalMetasPreventistaProps {
  /** Período 'YYYY-MM-01' sobre el que se cargan las metas. */
  periodo: string;
  onClose: () => void;
}

const TIPOS: Array<{ valor: TipoMeta; label: string; ayuda: string }> = [
  { valor: 'facturacion', label: 'Facturación ($)', ayuda: 'Pesos vendidos en el mes.' },
  { valor: 'unidades', label: 'Unidades vendidas', ayuda: 'Cantidad de unidades. Elegí de qué.' },
  { valor: 'cobertura', label: 'Clientes visitados', ayuda: 'Clientes distintos con pedido entregado.' },
  { valor: 'clientes_nuevos', label: 'Clientes nuevos', ayuda: 'Clientes que compran por primera vez.' },
];

/** Tipos que aceptan acotar el alcance a una marca/categoría/producto. */
const ADMITE_ALCANCE: TipoMeta[] = ['facturacion', 'unidades'];
/** Tipos donde el alcance es obligatorio. */
const EXIGE_ALCANCE: TipoMeta[] = ['unidades'];

const ModalMetasPreventista = memo(function ModalMetasPreventista({
  periodo,
  onClose,
}: ModalMetasPreventistaProps) {
  const { currentSucursalId } = useSucursal();
  const { data: metas = [], isLoading } = useMetasPreventistaQuery(periodo);
  const { data: preventistas = [] } = usePreventistasAsignablesQuery();
  const { data: marcas = [] } = useMarcasQuery();
  const { data: categorias = [] } = useCategoriasQuery();
  const { data: productos = [] } = useProductosQuery();
  const guardarMut = useGuardarMetaPreventistaMutation();
  const bajaMut = useDesactivarMetaPreventistaMutation();

  const [seleccionados, setSeleccionados] = useState<Set<string>>(new Set());
  const [tipoMeta, setTipoMeta] = useState<TipoMeta>('facturacion');
  // 'marca:<uuid>' | 'categoria:<uuid>' | 'productos' | '' (global)
  const [alcance, setAlcance] = useState('');
  const [productosSel, setProductosSel] = useState<Set<string>>(new Set());
  const [busquedaProd, setBusquedaProd] = useState('');
  const [valor, setValor] = useState<number>(0);
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');

  const admiteAlcance = ADMITE_ALCANCE.includes(tipoMeta);
  const exigeAlcance = EXIGE_ALCANCE.includes(tipoMeta);

  const nombrePorId = useMemo(() => {
    const m = new Map<string, string>();
    preventistas.forEach(p => m.set(p.id, p.nombre || p.email || p.id));
    marcas.forEach(x => m.set(x.id, x.nombre));
    categorias.forEach(x => m.set(x.id, x.nombre));
    return m;
  }, [preventistas, marcas, categorias]);

  const describirMeta = (meta: MetaPreventista): string => {
    const tipo = TIPOS.find(t => t.valor === meta.tipo_meta)?.label ?? meta.tipo_meta;
    const n = meta.producto_ids?.length ?? 0;
    const alc = meta.marca_id ? nombrePorId.get(meta.marca_id)
      : meta.categoria_id ? nombrePorId.get(meta.categoria_id)
      // Con un solo producto vale la pena el nombre; con varios no entra.
      : n === 1 ? (productos.find(p => String(p.id) === String(meta.producto_ids![0]))?.nombre ?? '1 producto')
      : n > 1 ? `${n} productos`
      : null;
    return alc ? `${tipo} — ${alc}` : tipo;
  };

  const formatObjetivo = (meta: MetaPreventista): string =>
    meta.tipo_meta === 'facturacion'
      ? formatPrecio(meta.valor_objetivo)
      : `${meta.valor_objetivo}${meta.tipo_meta === 'unidades' ? ' u' : ''}`;

  const handleTipoChange = (t: TipoMeta): void => {
    setTipoMeta(t);
    // Cambiar a un tipo sin alcance deja basura seleccionada que la base rechaza.
    if (!ADMITE_ALCANCE.includes(t)) {
      setAlcance('');
      setProductosSel(new Set());
    }
    setError('');
  };

  const productosFiltrados = useMemo(() => {
    const q = busquedaProd.trim().toLowerCase();
    return productos
      .filter(p => !q || p.nombre.toLowerCase().includes(q) || (p.categoria || '').toLowerCase().includes(q))
      .sort((a, b) => a.nombre.localeCompare(b.nombre));
  }, [productos, busquedaProd]);

  const todosFiltradosSel =
    productosFiltrados.length > 0 && productosFiltrados.every(p => productosSel.has(p.id));

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

    const [tipoAlc, idAlc] = alcance.includes(':') ? alcance.split(':') : [alcance, null];
    setError('');
    setOkMsg('');

    // Una fila por preventista: el avance es individual. El modal sólo evita
    // cargar el mismo objetivo cinco veces a mano.
    const fallos: string[] = [];
    for (const pid of seleccionados) {
      try {
        await guardarMut.mutateAsync({
          sucursalId: currentSucursalId,
          preventistaId: pid,
          periodo,
          tipoMeta,
          valorObjetivo: objetivo,
          marcaId: tipoAlc === 'marca' ? idAlc : null,
          categoriaId: tipoAlc === 'categoria' ? idAlc : null,
          productoIds: tipoAlc === 'productos' ? [...productosSel].map(Number) : null,
        });
      } catch (e) {
        // Se sigue con el resto: que uno falle (ej. no pertenece a la sucursal)
        // no tiene por qué tirar abajo la carga de los demás.
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

  // Agrupadas por preventista para que se lea "qué le pedí a cada uno".
  const porPreventista = useMemo(() => {
    const grupos = new Map<string, MetaPreventista[]>();
    metas.forEach(m => {
      const arr = grupos.get(m.preventista_id) ?? [];
      arr.push(m);
      grupos.set(m.preventista_id, arr);
    });
    return [...grupos.entries()].sort(
      (a, b) => (nombrePorId.get(a[0]) ?? '').localeCompare(nombrePorId.get(b[0]) ?? ''),
    );
  }, [metas, nombrePorId]);

  return (
    <ModalBase title="Objetivos del mes" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4">
        {/* Cargadas */}
        <div>
          <h3 className="text-sm font-medium mb-2 dark:text-gray-200 flex items-center gap-1.5">
            <Target className="w-4 h-4" />
            Objetivos cargados ({metas.length})
          </h3>
          {isLoading ? (
            <div className="flex justify-center py-6"><Loader2 className="w-5 h-5 animate-spin text-blue-600" /></div>
          ) : metas.length === 0 ? (
            <p className="text-sm text-gray-500 dark:text-gray-400 py-3">
              Todavía no hay objetivos para este mes.
            </p>
          ) : (
            <div className="border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700 max-h-56 overflow-y-auto">
              {porPreventista.map(([pid, lista]) => (
                <div key={pid} className="px-3 py-2">
                  <p className="text-sm font-semibold dark:text-white mb-1">
                    {nombrePorId.get(pid) ?? pid}
                  </p>
                  <ul className="space-y-1">
                    {lista.map(meta => (
                      <li key={meta.id} className="flex items-center justify-between gap-2 text-sm">
                        <span className="text-gray-700 dark:text-gray-300 truncate">
                          {describirMeta(meta)}
                        </span>
                        <span className="flex items-center gap-2 shrink-0">
                          <span className="font-medium tabular-nums dark:text-white">
                            {formatObjetivo(meta)}
                          </span>
                          <button
                            type="button"
                            onClick={() => bajaMut.mutateAsync(meta.id)}
                            disabled={bajaMut.isPending}
                            className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded disabled:opacity-50"
                            aria-label="Quitar objetivo"
                          >
                            <Trash2 className="w-4 h-4" />
                          </button>
                        </span>
                      </li>
                    ))}
                  </ul>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Alta */}
        <div className="border-t dark:border-gray-600 pt-4 space-y-3">
          <h3 className="text-sm font-medium dark:text-gray-200">Nuevo objetivo</h3>

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
                {marcas.filter(m => m.activa).length > 0 && (
                  <optgroup label="Marcas">
                    {marcas.filter(m => m.activa).map(m => (
                      <option key={m.id} value={`marca:${m.id}`}>{m.nombre}</option>
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

          {/* Selector de productos: "las gaseosas de 3 litros" son varios SKUs
              y no siempre coinciden con una categoría entera. */}
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
              Objetivo del mes {tipoMeta === 'facturacion' ? '($)' : tipoMeta === 'unidades' ? '(unidades)' : '(clientes)'}
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
            {guardarMut.isPending ? <Loader2 className="w-4 h-4 animate-spin" /> : <Plus className="w-4 h-4" />}
            {seleccionados.size > 1
              ? `Agregar objetivo a ${seleccionados.size} preventistas`
              : 'Agregar objetivo'}
          </button>
        </div>
      </div>

      <div className="p-4 border-t dark:border-gray-600 flex justify-end">
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
