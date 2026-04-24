/**
 * Modal para gestionar categorías de productos.
 *
 * Permite agregar, renombrar y eliminar categorías. La fuente de verdad es la
 * tabla `categorias` (migración 009) pero la lista muestra también categorías
 * que existen solo como string en productos (para que el admin pueda
 * normalizarlas). Renombrar/eliminar actualizan en bloque `productos.categoria`.
 */
import { memo, useMemo, useState } from 'react';
import { Loader2, Plus, Pencil, Trash2, Check, X, Tag, AlertCircle, ToggleLeft, ToggleRight } from 'lucide-react';
import ModalBase from './ModalBase';
import {
  useCategoriasQuery,
  useCrearCategoriaMutation,
  useRenombrarCategoriaMutation,
  useEliminarCategoriaMutation,
  useToggleCategoriaActivaMutation,
} from '../../hooks/queries';
import type { CategoriaDB } from '../../hooks/queries';
import type { ProductoDB } from '../../types';

export interface ModalCategoriasProps {
  /** Productos actuales de la sucursal (para contar por categoría y mostrar las derivadas) */
  productos: ProductoDB[];
  /** Callback al cerrar */
  onClose: () => void;
}

/** Entrada unificada que combina categorías de la tabla y derivadas de productos */
interface CategoriaEntry {
  id: string | null;       // null cuando solo existe como string en productos
  nombre: string;
  productCount: number;
  source: 'tabla' | 'derivada' | 'ambas';
  activa: boolean;
}

const ModalCategorias = memo(function ModalCategorias({ productos, onClose }: ModalCategoriasProps) {
  const { data: categoriasTabla = [], isLoading } = useCategoriasQuery();
  const crearMut = useCrearCategoriaMutation();
  const renameMut = useRenombrarCategoriaMutation();
  const deleteMut = useEliminarCategoriaMutation();
  const toggleMut = useToggleCategoriaActivaMutation();

  const [nuevoNombre, setNuevoNombre] = useState('');
  const [error, setError] = useState('');
  const [editandoId, setEditandoId] = useState<string | null>(null); // `tabla-uuid` o `derivada-nombre`
  const [editNombre, setEditNombre] = useState('');
  const [confirmDelete, setConfirmDelete] = useState<CategoriaEntry | null>(null);

  // Unir categorías de tabla + derivadas de productos
  const entries = useMemo((): CategoriaEntry[] => {
    const tablaMap = new Map<string, CategoriaDB>();
    categoriasTabla.forEach(c => tablaMap.set(c.nombre, c));

    const counts = new Map<string, number>();
    productos.forEach(p => {
      if (p.categoria) counts.set(p.categoria, (counts.get(p.categoria) || 0) + 1);
    });

    const names = new Set<string>([...tablaMap.keys(), ...counts.keys()]);
    const combined: CategoriaEntry[] = [];
    names.forEach(nombre => {
      const enTabla = tablaMap.has(nombre);
      const enProductos = counts.has(nombre);
      const cat = enTabla ? tablaMap.get(nombre)! : null;
      combined.push({
        id: cat ? cat.id : null,
        nombre,
        productCount: counts.get(nombre) || 0,
        source: enTabla && enProductos ? 'ambas' : enTabla ? 'tabla' : 'derivada',
        activa: cat ? cat.activa !== false : true,
      });
    });
    return combined.sort((a, b) => a.nombre.localeCompare(b.nombre));
  }, [categoriasTabla, productos]);

  const handleCrear = async () => {
    const nombre = nuevoNombre.trim();
    if (!nombre) {
      setError('Ingresá un nombre');
      return;
    }
    if (entries.some(e => e.nombre.toLowerCase() === nombre.toLowerCase())) {
      setError(`Ya existe una categoría "${nombre}"`);
      return;
    }
    setError('');
    try {
      await crearMut.mutateAsync(nombre);
      setNuevoNombre('');
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al crear categoría');
    }
  };

  const handleIniciarRename = (entry: CategoriaEntry) => {
    setEditandoId(entry.id ? `tabla-${entry.id}` : `derivada-${entry.nombre}`);
    setEditNombre(entry.nombre);
    setError('');
  };

  const handleCancelarRename = () => {
    setEditandoId(null);
    setEditNombre('');
    setError('');
  };

  const handleConfirmarRename = async (entry: CategoriaEntry) => {
    const nuevo = editNombre.trim();
    if (!nuevo) {
      setError('El nombre no puede estar vacío');
      return;
    }
    if (nuevo === entry.nombre) {
      handleCancelarRename();
      return;
    }
    if (entries.some(e => e.nombre.toLowerCase() === nuevo.toLowerCase() && e.nombre !== entry.nombre)) {
      setError(`Ya existe una categoría "${nuevo}"`);
      return;
    }
    setError('');
    try {
      await renameMut.mutateAsync({
        id: entry.id,
        nombreViejo: entry.nombre,
        nombreNuevo: nuevo,
      });
      handleCancelarRename();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al renombrar categoría');
    }
  };

  const handleEliminar = async (entry: CategoriaEntry) => {
    setError('');
    try {
      await deleteMut.mutateAsync({ id: entry.id, nombre: entry.nombre });
      setConfirmDelete(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al eliminar categoría');
    }
  };

  const handleToggleActiva = async (entry: CategoriaEntry) => {
    if (!entry.id) return;
    setError('');
    try {
      await toggleMut.mutateAsync({ id: entry.id, activa: !entry.activa, nombre: entry.nombre });
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al cambiar estado');
    }
  };

  const working = crearMut.isPending || renameMut.isPending || deleteMut.isPending || toggleMut.isPending;

  return (
    <ModalBase title="Gestionar categorías" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4">
        {/* Agregar nueva */}
        <div>
          <label htmlFor="nueva-categoria" className="block text-sm font-medium mb-1 dark:text-gray-200">
            Nueva categoría
          </label>
          <div className="flex gap-2">
            <input
              id="nueva-categoria"
              type="text"
              value={nuevoNombre}
              onChange={e => setNuevoNombre(e.target.value)}
              onKeyDown={e => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  void handleCrear();
                }
              }}
              placeholder="Ej.: AGUAS SABORIZADAS"
              className="flex-1 px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none"
              disabled={crearMut.isPending}
            />
            <button
              type="button"
              onClick={handleCrear}
              disabled={crearMut.isPending || !nuevoNombre.trim()}
              className="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-700 disabled:bg-gray-400 disabled:cursor-not-allowed flex items-center gap-1.5 font-medium"
            >
              {crearMut.isPending ? <Loader2 className="w-4 h-4 animate-spin" /> : <Plus className="w-4 h-4" />}
              Agregar
            </button>
          </div>
        </div>

        {error && (
          <div role="alert" className="flex items-start gap-2 p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg text-sm text-red-700 dark:text-red-300">
            <AlertCircle className="w-4 h-4 flex-shrink-0 mt-0.5" />
            <span>{error}</span>
          </div>
        )}

        {/* Lista */}
        <div>
          <h3 className="text-sm font-medium mb-2 dark:text-gray-200 flex items-center gap-1.5">
            <Tag className="w-4 h-4" />
            Categorías ({entries.length})
          </h3>

          {isLoading ? (
            <div className="flex items-center justify-center py-8">
              <Loader2 className="w-6 h-6 animate-spin text-blue-600" />
            </div>
          ) : entries.length === 0 ? (
            <p className="text-center text-sm text-gray-500 dark:text-gray-400 py-6">
              Todavía no hay categorías. Agregá la primera arriba.
            </p>
          ) : (
            <ul className="border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700 max-h-[50vh] overflow-y-auto">
              {entries.map(entry => {
                const editing = editandoId === (entry.id ? `tabla-${entry.id}` : `derivada-${entry.nombre}`);
                return (
                  <li key={entry.id ?? entry.nombre} className="flex items-center gap-2 px-3 py-2.5">
                    {editing ? (
                      <input
                        type="text"
                        value={editNombre}
                        onChange={e => setEditNombre(e.target.value)}
                        onKeyDown={e => {
                          if (e.key === 'Enter') {
                            e.preventDefault();
                            void handleConfirmarRename(entry);
                          } else if (e.key === 'Escape') {
                            handleCancelarRename();
                          }
                        }}
                        className="flex-1 px-2 py-1 border rounded bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none text-sm"
                        autoFocus
                        disabled={renameMut.isPending}
                      />
                    ) : (
                      <div className={`flex-1 min-w-0 flex items-center gap-2 flex-wrap ${!entry.activa ? 'opacity-60' : ''}`}>
                        <span className="font-medium dark:text-white truncate">{entry.nombre}</span>
                        <span className="text-xs px-2 py-0.5 bg-gray-100 dark:bg-gray-700 text-gray-700 dark:text-gray-300 rounded-full">
                          {entry.productCount} {entry.productCount === 1 ? 'producto' : 'productos'}
                        </span>
                        {!entry.activa && (
                          <span className="text-xs px-2 py-0.5 bg-gray-200 dark:bg-gray-600 text-gray-600 dark:text-gray-300 rounded-full font-medium">
                            inactiva
                          </span>
                        )}
                        {entry.source === 'derivada' && (
                          <span
                            className="text-xs px-2 py-0.5 bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-300 rounded-full"
                            title="Solo existe como texto en productos. Al renombrarla se formaliza en la tabla de categorías."
                          >
                            pendiente
                          </span>
                        )}
                      </div>
                    )}

                    {editing ? (
                      <div className="flex gap-1 shrink-0">
                        <button
                          type="button"
                          onClick={() => handleConfirmarRename(entry)}
                          disabled={renameMut.isPending}
                          className="p-1.5 text-green-600 hover:bg-green-50 dark:hover:bg-green-900/20 rounded disabled:opacity-50"
                          title="Guardar"
                          aria-label="Guardar"
                        >
                          {renameMut.isPending ? <Loader2 className="w-4 h-4 animate-spin" /> : <Check className="w-4 h-4" />}
                        </button>
                        <button
                          type="button"
                          onClick={handleCancelarRename}
                          disabled={renameMut.isPending}
                          className="p-1.5 text-gray-500 hover:bg-gray-50 dark:hover:bg-gray-700 rounded disabled:opacity-50"
                          title="Cancelar"
                          aria-label="Cancelar"
                        >
                          <X className="w-4 h-4" />
                        </button>
                      </div>
                    ) : (
                      <div className="flex gap-1 shrink-0">
                        <button
                          type="button"
                          onClick={() => handleIniciarRename(entry)}
                          disabled={working}
                          className="p-1.5 text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/20 rounded disabled:opacity-50"
                          title={`Renombrar ${entry.nombre}`}
                          aria-label={`Renombrar ${entry.nombre}`}
                        >
                          <Pencil className="w-4 h-4" />
                        </button>
                        {entry.id && (
                          <button
                            type="button"
                            onClick={() => handleToggleActiva(entry)}
                            disabled={working}
                            className="p-1.5 hover:bg-gray-100 dark:hover:bg-gray-700 rounded disabled:opacity-50"
                            title={entry.activa ? `Desactivar ${entry.nombre}` : `Activar ${entry.nombre}`}
                            aria-label={entry.activa ? `Desactivar ${entry.nombre}` : `Activar ${entry.nombre}`}
                          >
                            {entry.activa
                              ? <ToggleRight className="w-5 h-5 text-green-600" />
                              : <ToggleLeft className="w-5 h-5 text-gray-400" />
                            }
                          </button>
                        )}
                        <button
                          type="button"
                          onClick={() => setConfirmDelete(entry)}
                          disabled={working}
                          className="p-1.5 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded disabled:opacity-50"
                          title={`Eliminar ${entry.nombre}`}
                          aria-label={`Eliminar ${entry.nombre}`}
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </div>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>

      {/* Confirmación de eliminación inline */}
      {confirmDelete && (
        <div className="p-4 border-t dark:border-gray-600 bg-amber-50 dark:bg-amber-900/20">
          <p className="text-sm text-amber-900 dark:text-amber-200 mb-3">
            <strong>Eliminar "{confirmDelete.nombre}"?</strong>
            {confirmDelete.productCount > 0 ? (
              <>
                {' '}{confirmDelete.productCount} {confirmDelete.productCount === 1 ? 'producto quedará sin categoría' : 'productos quedarán sin categoría'}. No se borran productos.
              </>
            ) : (
              <> No hay productos asociados.</>
            )}
          </p>
          <div className="flex justify-end gap-2">
            <button
              type="button"
              onClick={() => setConfirmDelete(null)}
              disabled={deleteMut.isPending}
              className="px-3 py-1.5 text-sm font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 rounded-lg"
            >
              Cancelar
            </button>
            <button
              type="button"
              onClick={() => handleEliminar(confirmDelete)}
              disabled={deleteMut.isPending}
              className="px-3 py-1.5 text-sm bg-red-600 text-white font-medium rounded-lg hover:bg-red-700 disabled:bg-gray-400 flex items-center gap-1.5"
            >
              {deleteMut.isPending && <Loader2 className="w-4 h-4 animate-spin" />}
              Eliminar
            </button>
          </div>
        </div>
      )}

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

export default ModalCategorias;
