/**
 * Modal para gestionar marcas y asignarlas a productos (mig 158).
 *
 * Dos vistas en el mismo modal:
 *  - "lista": ABM de marcas con el conteo de productos de cada una.
 *  - "asignar": selector masivo de productos para una marca.
 *
 * La vista de asignación es la que hace el trabajo real: la mig 158 solo pudo
 * backfillear las marcas de la sucursal 1 (donde había categorías que en
 * realidad eran marcas). En Taco Pozo la marca vive dentro del nombre del
 * producto ("PLACER NARANJA 1500CC X 6"), así que el filtro por nombre +
 * "seleccionar todo lo filtrado" es lo que convierte un trabajo de horas en
 * uno de minutos. Deliberadamente no se adivina la marca por patrón de
 * nombre: "AGUA VILLA MANAOS" y "MANAOS SODA" son marcas distintas y un
 * heurístico las mezcla en silencio.
 */
import { memo, useMemo, useState } from 'react';
import { Loader2, Plus, Pencil, Trash2, Check, X, Award, AlertCircle, ToggleLeft, ToggleRight, Search, ChevronLeft } from 'lucide-react';
import ModalBase from './ModalBase';
import { Button } from '../ui/Button';
import {
  useMarcasQuery,
  useCrearMarcaMutation,
  useRenombrarMarcaMutation,
  useEliminarMarcaMutation,
  useToggleMarcaActivaMutation,
  useAsignarMarcaMasivaMutation,
} from '../../hooks/queries';
import type { MarcaDB } from '../../hooks/queries';
import type { ProductoDB } from '../../types';

export interface ModalMarcasProps {
  /** Productos de la sucursal activa (para contar y para el selector masivo). */
  productos: ProductoDB[];
  onClose: () => void;
}

const ModalMarcas = memo(function ModalMarcas({ productos, onClose }: ModalMarcasProps) {
  const { data: marcas = [], isLoading } = useMarcasQuery();
  const crearMut = useCrearMarcaMutation();
  const renameMut = useRenombrarMarcaMutation();
  const deleteMut = useEliminarMarcaMutation();
  const toggleMut = useToggleMarcaActivaMutation();
  const asignarMut = useAsignarMarcaMasivaMutation();

  const [nuevoNombre, setNuevoNombre] = useState('');
  const [error, setError] = useState('');
  const [editandoId, setEditandoId] = useState<string | null>(null);
  const [editNombre, setEditNombre] = useState('');
  const [confirmDelete, setConfirmDelete] = useState<MarcaDB | null>(null);

  // Vista de asignación: null = lista de marcas.
  const [asignando, setAsignando] = useState<MarcaDB | null>(null);
  const [busqueda, setBusqueda] = useState('');
  const [soloSinMarca, setSoloSinMarca] = useState(true);
  const [seleccion, setSeleccion] = useState<Set<string>>(new Set());
  const [okMsg, setOkMsg] = useState('');

  const conteoPorMarca = useMemo(() => {
    const counts = new Map<string, number>();
    productos.forEach(p => {
      if (p.marca_id) counts.set(p.marca_id, (counts.get(p.marca_id) || 0) + 1);
    });
    return counts;
  }, [productos]);

  const sinMarca = useMemo(() => productos.filter(p => !p.marca_id).length, [productos]);

  const working = crearMut.isPending || renameMut.isPending || deleteMut.isPending || toggleMut.isPending;

  // ---------------------------------------------------------------- ABM

  const handleCrear = async (): Promise<void> => {
    const nombre = nuevoNombre.trim();
    if (!nombre) {
      setError('Ingresá un nombre');
      return;
    }
    if (marcas.some(m => m.nombre.toLowerCase() === nombre.toLowerCase())) {
      setError(`Ya existe una marca "${nombre}"`);
      return;
    }
    setError('');
    try {
      await crearMut.mutateAsync(nombre);
      setNuevoNombre('');
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al crear marca');
    }
  };

  const handleConfirmarRename = async (marca: MarcaDB): Promise<void> => {
    const nuevo = editNombre.trim();
    if (!nuevo) {
      setError('El nombre no puede estar vacío');
      return;
    }
    if (nuevo === marca.nombre) {
      setEditandoId(null);
      return;
    }
    setError('');
    try {
      await renameMut.mutateAsync({ id: marca.id, nombreNuevo: nuevo });
      setEditandoId(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al renombrar marca');
    }
  };

  const handleEliminar = async (marca: MarcaDB): Promise<void> => {
    setError('');
    try {
      await deleteMut.mutateAsync(marca.id);
      setConfirmDelete(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al eliminar marca');
    }
  };

  // ---------------------------------------------------------- Asignación

  const abrirAsignar = (marca: MarcaDB): void => {
    setAsignando(marca);
    setBusqueda('');
    setSoloSinMarca(true);
    setSeleccion(new Set());
    setError('');
    setOkMsg('');
  };

  const productosFiltrados = useMemo(() => {
    if (!asignando) return [];
    const q = busqueda.trim().toLowerCase();
    return productos
      .filter(p => {
        if (soloSinMarca && p.marca_id && p.marca_id !== asignando.id) return false;
        if (!q) return true;
        return p.nombre.toLowerCase().includes(q) || (p.categoria || '').toLowerCase().includes(q);
      })
      .sort((a, b) => a.nombre.localeCompare(b.nombre));
  }, [productos, asignando, busqueda, soloSinMarca]);

  const todosFiltradosSeleccionados =
    productosFiltrados.length > 0 && productosFiltrados.every(p => seleccion.has(p.id));

  const toggleTodosFiltrados = (): void => {
    setSeleccion(prev => {
      const next = new Set(prev);
      if (todosFiltradosSeleccionados) {
        productosFiltrados.forEach(p => next.delete(p.id));
      } else {
        productosFiltrados.forEach(p => next.add(p.id));
      }
      return next;
    });
  };

  const handleAsignar = async (quitar = false): Promise<void> => {
    if (!asignando || seleccion.size === 0) return;
    setError('');
    setOkMsg('');
    try {
      const n = await asignarMut.mutateAsync({
        marcaId: quitar ? null : asignando.id,
        productoIds: [...seleccion],
      });
      setOkMsg(
        quitar
          ? `${n} ${n === 1 ? 'producto quedó' : 'productos quedaron'} sin marca.`
          : `${n} ${n === 1 ? 'producto asignado' : 'productos asignados'} a ${asignando.nombre}.`,
      );
      setSeleccion(new Set());
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al asignar la marca');
    }
  };

  // ------------------------------------------------------------- Render

  if (asignando) {
    return (
      <ModalBase title={`Productos de ${asignando.nombre}`} onClose={onClose} maxWidth="max-w-2xl">
        <div className="p-4 space-y-3">
          <button
            type="button"
            onClick={() => setAsignando(null)}
            className="inline-flex items-center gap-1 text-sm text-blue-600 hover:underline"
          >
            <ChevronLeft className="w-4 h-4" />
            Volver a las marcas
          </button>

          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-5 h-5 pointer-events-none" />
            <input
              type="text"
              value={busqueda}
              onChange={e => setBusqueda(e.target.value)}
              placeholder="Filtrar por nombre o categoría…"
              className="w-full pl-10 pr-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none"
            />
          </div>

          <label className="flex items-center gap-2 text-sm dark:text-gray-200 cursor-pointer">
            <input
              type="checkbox"
              checked={soloSinMarca}
              onChange={e => setSoloSinMarca(e.target.checked)}
              className="w-4 h-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
            />
            Ocultar los que ya tienen otra marca
          </label>

          <div className="flex items-center justify-between gap-2">
            <button
              type="button"
              onClick={toggleTodosFiltrados}
              disabled={productosFiltrados.length === 0}
              className="text-sm font-medium text-blue-600 hover:underline disabled:opacity-50 disabled:no-underline"
            >
              {todosFiltradosSeleccionados ? 'Deseleccionar' : 'Seleccionar'} los {productosFiltrados.length} de la lista
            </button>
            <span className="text-sm text-gray-500 dark:text-gray-400">
              {seleccion.size} seleccionado{seleccion.size === 1 ? '' : 's'}
            </span>
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

          <ul className="border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700 max-h-[45vh] overflow-y-auto">
            {productosFiltrados.length === 0 ? (
              <li className="px-3 py-6 text-center text-sm text-gray-500 dark:text-gray-400">
                No hay productos que coincidan.
              </li>
            ) : productosFiltrados.map(p => (
              <li key={p.id}>
                <label className="flex items-center gap-3 px-3 py-2.5 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50">
                  <input
                    type="checkbox"
                    checked={seleccion.has(p.id)}
                    onChange={e => setSeleccion(prev => {
                      const next = new Set(prev);
                      if (e.target.checked) next.add(p.id); else next.delete(p.id);
                      return next;
                    })}
                    className="w-4 h-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500 shrink-0"
                  />
                  <span className="flex-1 min-w-0">
                    <span className="block text-sm dark:text-white truncate">{p.nombre}</span>
                    <span className="block text-xs text-gray-500 dark:text-gray-400">
                      {p.categoria || 'sin categoría'}
                      {p.marca_id === asignando.id && ' · ya es de esta marca'}
                    </span>
                  </span>
                </label>
              </li>
            ))}
          </ul>
        </div>

        <div className="p-4 border-t dark:border-gray-600 flex flex-wrap justify-end gap-2">
          <Button
            type="button"
            variant="ghost"
            size="md"
            onClick={() => handleAsignar(true)}
            disabled={asignarMut.isPending || seleccion.size === 0}
          >
            Quitar marca
          </Button>
          <Button
            type="button"
            variant="primary"
            size="md"
            onClick={() => handleAsignar(false)}
            disabled={asignarMut.isPending || seleccion.size === 0}
            loading={asignarMut.isPending}
          >
            Asignar a {asignando.nombre}
          </Button>
        </div>
      </ModalBase>
    );
  }

  return (
    <ModalBase title="Gestionar marcas" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4">
        <p className="text-sm text-gray-600 dark:text-gray-400">
          La marca es independiente de la categoría: un producto es <em>Manaos</em> (marca) y{' '}
          <em>gaseosas</em> (categoría). Sirve para poner objetivos y medir ventas por marca.
        </p>

        <div>
          <label htmlFor="nueva-marca" className="block text-sm font-medium mb-1 dark:text-gray-200">
            Nueva marca
          </label>
          <div className="flex gap-2">
            <input
              id="nueva-marca"
              type="text"
              value={nuevoNombre}
              onChange={e => setNuevoNombre(e.target.value)}
              onKeyDown={e => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  void handleCrear();
                }
              }}
              placeholder="Ej.: COTELLA"
              className="flex-1 px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none"
              disabled={crearMut.isPending}
            />
            <Button
              type="button"
              variant="primary"
              size="md"
              onClick={handleCrear}
              disabled={crearMut.isPending || !nuevoNombre.trim()}
              loading={crearMut.isPending}
            >
              {!crearMut.isPending && <Plus className="w-4 h-4" />}
              Agregar
            </Button>
          </div>
        </div>

        {error && (
          <div role="alert" className="flex items-start gap-2 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg text-sm text-red-700 dark:text-red-300">
            <AlertCircle className="w-4 h-4 flex-shrink-0 mt-0.5" />
            <span>{error}</span>
          </div>
        )}

        {/* Cobertura: sin esto, una meta por marca mide sobre datos incompletos
            y el error es invisible. */}
        {sinMarca > 0 && (
          <p className="text-sm px-3 py-2 rounded-lg bg-amber-50 dark:bg-amber-900/20 text-amber-800 dark:text-amber-300">
            {sinMarca} {sinMarca === 1 ? 'producto no tiene' : 'productos no tienen'} marca asignada. Los
            objetivos por marca no los van a contar.
          </p>
        )}

        <div>
          <h3 className="text-sm font-medium mb-2 dark:text-gray-200 flex items-center gap-1.5">
            <Award className="w-4 h-4" />
            Marcas ({marcas.length})
          </h3>

          {isLoading ? (
            <div className="flex items-center justify-center py-8">
              <Loader2 className="w-6 h-6 animate-spin text-blue-600" />
            </div>
          ) : marcas.length === 0 ? (
            <p className="text-center text-sm text-gray-500 dark:text-gray-400 py-6">
              Todavía no hay marcas. Agregá la primera arriba.
            </p>
          ) : (
            <ul className="border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700 max-h-[50vh] overflow-y-auto">
              {marcas.map(marca => {
                const editing = editandoId === marca.id;
                const count = conteoPorMarca.get(marca.id) || 0;
                return (
                  <li key={marca.id} className="flex items-center gap-2 px-3 py-2.5">
                    {editing ? (
                      <input
                        type="text"
                        value={editNombre}
                        onChange={e => setEditNombre(e.target.value)}
                        onKeyDown={e => {
                          if (e.key === 'Enter') {
                            e.preventDefault();
                            void handleConfirmarRename(marca);
                          } else if (e.key === 'Escape') {
                            setEditandoId(null);
                          }
                        }}
                        className="flex-1 px-2 py-1 border rounded bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none text-sm"
                        autoFocus
                        disabled={renameMut.isPending}
                      />
                    ) : (
                      <div className={`flex-1 min-w-0 flex items-center gap-2 flex-wrap ${!marca.activa ? 'opacity-60' : ''}`}>
                        <span className="font-medium dark:text-white truncate">{marca.nombre}</span>
                        <span className="text-xs px-2 py-0.5 bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-full">
                          {count} {count === 1 ? 'producto' : 'productos'}
                        </span>
                        {!marca.activa && (
                          <span className="text-xs px-2 py-0.5 bg-gray-200 dark:bg-gray-600 text-gray-600 dark:text-gray-300 rounded-full font-medium">
                            inactiva
                          </span>
                        )}
                      </div>
                    )}

                    {editing ? (
                      <div className="flex gap-1 shrink-0">
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          onClick={() => handleConfirmarRename(marca)}
                          disabled={renameMut.isPending}
                          loading={renameMut.isPending}
                          aria-label="Guardar"
                          className="text-green-600 hover:bg-green-50 dark:hover:bg-green-900/20 dark:text-green-400"
                        >
                          {!renameMut.isPending && <Check className="w-4 h-4" />}
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          onClick={() => setEditandoId(null)}
                          disabled={renameMut.isPending}
                          aria-label="Cancelar"
                        >
                          <X className="w-4 h-4" />
                        </Button>
                      </div>
                    ) : (
                      <div className="flex gap-1 shrink-0">
                        <Button
                          type="button"
                          variant="ghost"
                          size="sm"
                          onClick={() => abrirAsignar(marca)}
                          disabled={working}
                          className="text-xs font-medium text-blue-600 dark:text-blue-400 hover:bg-blue-50 dark:hover:bg-blue-900/20"
                        >
                          Productos
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          onClick={() => { setEditandoId(marca.id); setEditNombre(marca.nombre); setError(''); }}
                          disabled={working}
                          aria-label={`Renombrar ${marca.nombre}`}
                          className="text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/20 dark:text-blue-400"
                        >
                          <Pencil className="w-4 h-4" />
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          onClick={() => toggleMut.mutateAsync({ id: marca.id, activa: !marca.activa })}
                          disabled={working}
                          aria-label={marca.activa ? `Desactivar ${marca.nombre}` : `Activar ${marca.nombre}`}
                        >
                          {marca.activa
                            ? <ToggleRight className="w-5 h-5 text-green-600" />
                            : <ToggleLeft className="w-5 h-5 text-gray-400" />}
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          onClick={() => setConfirmDelete(marca)}
                          disabled={working}
                          aria-label={`Eliminar ${marca.nombre}`}
                          className="text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 dark:text-red-400"
                        >
                          <Trash2 className="w-4 h-4" />
                        </Button>
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>

      {confirmDelete && (
        <div className="p-4 border-t dark:border-gray-600 bg-amber-50 dark:bg-amber-900/20">
          <p className="text-sm text-amber-900 dark:text-amber-200 mb-3">
            <strong>¿Eliminar "{confirmDelete.nombre}"?</strong>{' '}
            {(conteoPorMarca.get(confirmDelete.id) || 0) > 0
              ? `${conteoPorMarca.get(confirmDelete.id)} producto(s) quedarán sin marca. No se borran productos.`
              : 'No hay productos asociados.'}
            {' '}Los objetivos que apunten a esta marca se van a quedar sin nada que medir.
          </p>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" size="sm" onClick={() => setConfirmDelete(null)} disabled={deleteMut.isPending}>
              Cancelar
            </Button>
            <Button
              type="button"
              variant="danger"
              size="sm"
              onClick={() => handleEliminar(confirmDelete)}
              disabled={deleteMut.isPending}
              loading={deleteMut.isPending}
            >
              Eliminar
            </Button>
          </div>
        </div>
      )}

      <div className="p-4 border-t dark:border-gray-600 flex justify-end">
        <Button type="button" variant="ghost" size="md" onClick={onClose}>
          Cerrar
        </Button>
      </div>
    </ModalBase>
  );
});

export default ModalMarcas;
