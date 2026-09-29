/**
 * Modal para gestionar categorías de productos.
 *
 * Permite agregar, renombrar y eliminar categorías. La fuente de verdad es la
 * tabla `categorias` (migración 009) pero la lista muestra también categorías
 * que existen solo como string en productos (para que el admin pueda
 * normalizarlas). Renombrar/eliminar actualizan en bloque `productos.categoria`.
 */
import { memo, useMemo, useState } from 'react';
import { Loader2, Plus, CornerDownRight, Pencil, Trash2, Check, X, Tag, AlertCircle, ToggleLeft, ToggleRight } from 'lucide-react';
import ModalBase from './ModalBase';
import { Button } from '../ui/Button';
import {
  useCategoriasQuery,
  useCrearCategoriaMutation,
  useRenombrarCategoriaMutation,
  useEliminarCategoriaMutation,
  useToggleCategoriaActivaMutation,
  useSubcategoriasQuery,
  useCrearSubcategoriaMutation,
  useRenombrarSubcategoriaMutation,
  useEliminarSubcategoriaMutation,
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
  const { data: subrubros = [] } = useSubcategoriasQuery();
  const crearSubMut = useCrearSubcategoriaMutation();
  const renameSubMut = useRenombrarSubcategoriaMutation();
  const deleteSubMut = useEliminarSubcategoriaMutation();

  // Subrubros (mig 270): se agregan bajo un rubro de la tabla.
  const [agregandoSubDe, setAgregandoSubDe] = useState<string | null>(null);
  const [nuevoSub, setNuevoSub] = useState('');
  const [editandoSub, setEditandoSub] = useState<string | null>(null);
  const [editSubNombre, setEditSubNombre] = useState('');

  const [nuevoNombre, setNuevoNombre] = useState('');
  const [error, setError] = useState('');
  const [editandoId, setEditandoId] = useState<string | null>(null); // `tabla-uuid` o `derivada-nombre`
  const [editNombre, setEditNombre] = useState('');
  const [confirmDelete, setConfirmDelete] = useState<CategoriaEntry | null>(null);
  const [confirmDeleteSub, setConfirmDeleteSub] = useState<CategoriaDB | null>(null);

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

  const subrubrosPorRubro = useMemo(() => {
    const map = new Map<string, CategoriaDB[]>();
    subrubros.forEach(s => {
      if (!s.parent_id) return;
      map.set(s.parent_id, [...(map.get(s.parent_id) ?? []), s]);
    });
    map.forEach(list => list.sort((a, b) => a.nombre.localeCompare(b.nombre)));
    return map;
  }, [subrubros]);

  const handleCrearSub = async (parentId: string) => {
    const nombre = nuevoSub.trim();
    if (!nombre) {
      setError('Ingresá un nombre para el subrubro');
      return;
    }
    setError('');
    try {
      await crearSubMut.mutateAsync({ nombre, parentId });
      setNuevoSub('');
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al crear subrubro');
    }
  };

  const handleRenameSub = async (sub: CategoriaDB) => {
    const nombre = editSubNombre.trim();
    if (!nombre) {
      setError('El nombre no puede estar vacío');
      return;
    }
    if (nombre === sub.nombre) {
      setEditandoSub(null);
      return;
    }
    setError('');
    try {
      await renameSubMut.mutateAsync({ id: sub.id, nombre });
      setEditandoSub(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al renombrar subrubro');
    }
  };

  const handleEliminarSub = async (sub: CategoriaDB) => {
    setError('');
    try {
      await deleteSubMut.mutateAsync(sub.id);
      setConfirmDeleteSub(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al eliminar subrubro');
    }
  };

  const working = crearSubMut.isPending || renameSubMut.isPending || deleteSubMut.isPending || crearMut.isPending || renameMut.isPending || deleteMut.isPending || toggleMut.isPending;

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
                  <li key={entry.id ?? entry.nombre} className="px-3 py-2.5">
                    <div className="flex items-center gap-2">
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
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          onClick={() => handleConfirmarRename(entry)}
                          disabled={renameMut.isPending}
                          loading={renameMut.isPending}
                          title="Guardar"
                          aria-label="Guardar"
                          className="text-green-600 hover:bg-green-50 dark:hover:bg-green-900/20 dark:text-green-400"
                        >
                          {!renameMut.isPending && <Check className="w-4 h-4" />}
                        </Button>
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          onClick={handleCancelarRename}
                          disabled={renameMut.isPending}
                          title="Cancelar"
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
                          size="iconSm"
                          onClick={() => handleIniciarRename(entry)}
                          disabled={working}
                          title={`Renombrar ${entry.nombre}`}
                          aria-label={`Renombrar ${entry.nombre}`}
                          className="text-blue-600 hover:bg-blue-50 dark:hover:bg-blue-900/20 dark:text-blue-400"
                        >
                          <Pencil className="w-4 h-4" />
                        </Button>
                        {entry.id && (
                          <Button
                            type="button"
                            variant="ghost"
                            size="iconSm"
                            onClick={() => handleToggleActiva(entry)}
                            disabled={working}
                            title={entry.activa ? `Desactivar ${entry.nombre}` : `Activar ${entry.nombre}`}
                            aria-label={entry.activa ? `Desactivar ${entry.nombre}` : `Activar ${entry.nombre}`}
                          >
                            {entry.activa
                              ? <ToggleRight className="w-5 h-5 text-green-600" />
                              : <ToggleLeft className="w-5 h-5 text-gray-400" />
                            }
                          </Button>
                        )}
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          onClick={() => setConfirmDelete(entry)}
                          disabled={working}
                          title={`Eliminar ${entry.nombre}`}
                          aria-label={`Eliminar ${entry.nombre}`}
                          className="text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 dark:text-red-400"
                        >
                          <Trash2 className="w-4 h-4" />
                        </Button>
                      </div>
                    )}
                    </div>
                    {entry.id && (
                      <div className="mt-2 ml-4 space-y-1">
                        {(subrubrosPorRubro.get(entry.id) ?? []).map(sub => (
                          <div key={sub.id} className="flex items-center gap-2 text-sm">
                            <CornerDownRight className="w-3.5 h-3.5 text-gray-400 shrink-0" />
                            {editandoSub === sub.id ? (
                              <>
                                <input
                                  type="text"
                                  value={editSubNombre}
                                  onChange={e => setEditSubNombre(e.target.value)}
                                  onKeyDown={e => {
                                    if (e.key === 'Enter') { e.preventDefault(); void handleRenameSub(sub); }
                                    else if (e.key === 'Escape') setEditandoSub(null);
                                  }}
                                  className="flex-1 px-2 py-1 border rounded bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
                                  aria-label={`Nuevo nombre del subrubro ${sub.nombre}`}
                                  autoFocus
                                />
                                <Button type="button" variant="ghost" size="iconSm" onClick={() => handleRenameSub(sub)} title="Guardar" aria-label="Guardar subrubro" className="text-green-600">
                                  <Check className="w-4 h-4" />
                                </Button>
                                <Button type="button" variant="ghost" size="iconSm" onClick={() => setEditandoSub(null)} title="Cancelar" aria-label="Cancelar">
                                  <X className="w-4 h-4" />
                                </Button>
                              </>
                            ) : (
                              <>
                                <span className="flex-1 min-w-0 truncate dark:text-gray-200">{sub.nombre}</span>
                                <Button type="button" variant="ghost" size="iconSm" disabled={working}
                                  onClick={() => { setEditandoSub(sub.id); setEditSubNombre(sub.nombre); setError(''); }}
                                  title={`Renombrar ${sub.nombre}`} aria-label={`Renombrar subrubro ${sub.nombre}`}
                                  className="text-blue-600 dark:text-blue-400">
                                  <Pencil className="w-3.5 h-3.5" />
                                </Button>
                                <Button type="button" variant="ghost" size="iconSm" disabled={working}
                                  onClick={() => setConfirmDeleteSub(sub)}
                                  title={`Eliminar ${sub.nombre}`} aria-label={`Eliminar subrubro ${sub.nombre}`}
                                  className="text-red-500 dark:text-red-400">
                                  <Trash2 className="w-3.5 h-3.5" />
                                </Button>
                              </>
                            )}
                          </div>
                        ))}
                        {agregandoSubDe === entry.id ? (
                          <div className="flex items-center gap-2">
                            <input
                              type="text"
                              value={nuevoSub}
                              onChange={e => setNuevoSub(e.target.value)}
                              onKeyDown={e => {
                                if (e.key === 'Enter') { e.preventDefault(); void handleCrearSub(entry.id!); }
                                else if (e.key === 'Escape') { setAgregandoSubDe(null); setNuevoSub(''); }
                              }}
                              placeholder="Ej.: Manaos 3000cc"
                              aria-label={`Nuevo subrubro de ${entry.nombre}`}
                              className="flex-1 px-2 py-1 border rounded bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
                              autoFocus
                              disabled={crearSubMut.isPending}
                            />
                            <Button type="button" variant="primary" size="sm" onClick={() => handleCrearSub(entry.id!)} disabled={crearSubMut.isPending || !nuevoSub.trim()} loading={crearSubMut.isPending}>
                              Agregar
                            </Button>
                            <Button type="button" variant="ghost" size="sm" onClick={() => { setAgregandoSubDe(null); setNuevoSub(''); }}>
                              Cancelar
                            </Button>
                          </div>
                        ) : (
                          <button
                            type="button"
                            onClick={() => { setAgregandoSubDe(entry.id); setNuevoSub(''); setError(''); }}
                            className="text-xs text-blue-600 hover:text-blue-700 dark:text-blue-400"
                          >
                            + Agregar subrubro
                          </button>
                        )}
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

      {confirmDeleteSub && (
        <div className="p-4 border-t dark:border-gray-600 bg-amber-50 dark:bg-amber-900/20">
          <p className="text-sm text-amber-900 dark:text-amber-200 mb-3">
            <strong>Eliminar el subrubro "{confirmDeleteSub.nombre}"?</strong> Los productos que lo tenían quedan solo con su rubro. No se borran productos.
          </p>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="ghost" size="sm" onClick={() => setConfirmDeleteSub(null)} disabled={deleteSubMut.isPending}>
              Cancelar
            </Button>
            <Button type="button" variant="danger" size="sm" onClick={() => handleEliminarSub(confirmDeleteSub)} disabled={deleteSubMut.isPending} loading={deleteSubMut.isPending}>
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

export default ModalCategorias;
