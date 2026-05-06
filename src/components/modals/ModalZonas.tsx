/**
 * Modal para gestionar zonas (panel admin).
 *
 * Espejo simplificado de ModalCategorias. La fuente de verdad es la tabla
 * `zonas` (FK desde `clientes.zona_id` y `proveedores.zona_id` con
 * RESTRICT) — no existe el concepto de "derivada" como en categorías,
 * así que no se cuentan/mergean strings sueltos. El admin ve también las
 * inactivas para poder reactivarlas o eliminarlas.
 */
import { memo, useMemo, useState } from 'react';
import { Loader2, Plus, Pencil, Trash2, Check, X, MapPin, AlertCircle, ToggleLeft, ToggleRight } from 'lucide-react';
import ModalBase from './ModalBase';
import {
  useZonasEstandarizadasQuery,
  useCrearZonaMutation,
  useRenombrarZonaMutation,
  useEliminarZonaMutation,
  useToggleZonaActivaMutation,
} from '../../hooks/queries';
import type { ZonaDB } from '../../hooks/queries/useZonasQuery';

export interface ModalZonasProps {
  /** Callback al cerrar */
  onClose: () => void;
}

const ModalZonas = memo(function ModalZonas({ onClose }: ModalZonasProps) {
  // Admin view: incluye inactivas para que puedan reactivarse/eliminarse.
  const { data: zonas = [], isLoading } = useZonasEstandarizadasQuery({ includeInactive: true });
  const crearMut = useCrearZonaMutation();
  const renameMut = useRenombrarZonaMutation();
  const deleteMut = useEliminarZonaMutation();
  const toggleMut = useToggleZonaActivaMutation();

  const [nuevoNombre, setNuevoNombre] = useState('');
  const [error, setError] = useState('');
  const [editandoId, setEditandoId] = useState<string | null>(null);
  const [editNombre, setEditNombre] = useState('');
  const [confirmDelete, setConfirmDelete] = useState<ZonaDB | null>(null);

  // Activas primero, luego alfabético dentro de cada grupo.
  const entries = useMemo((): ZonaDB[] => {
    return [...zonas].sort((a, b) => {
      const aActiva = a.activo !== false;
      const bActiva = b.activo !== false;
      if (aActiva !== bActiva) return aActiva ? -1 : 1;
      return a.nombre.localeCompare(b.nombre);
    });
  }, [zonas]);

  const handleCrear = async () => {
    const nombre = nuevoNombre.trim();
    if (!nombre) {
      setError('Ingresá un nombre');
      return;
    }
    if (entries.some(e => e.nombre.toLowerCase() === nombre.toLowerCase())) {
      setError(`Ya existe una zona "${nombre}"`);
      return;
    }
    setError('');
    try {
      await crearMut.mutateAsync(nombre);
      setNuevoNombre('');
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al crear zona');
    }
  };

  const handleIniciarRename = (entry: ZonaDB) => {
    setEditandoId(entry.id);
    setEditNombre(entry.nombre);
    setError('');
  };

  const handleCancelarRename = () => {
    setEditandoId(null);
    setEditNombre('');
    setError('');
  };

  const handleConfirmarRename = async (entry: ZonaDB) => {
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
      setError(`Ya existe una zona "${nuevo}"`);
      return;
    }
    setError('');
    try {
      await renameMut.mutateAsync({ id: entry.id, nombre: nuevo });
      handleCancelarRename();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al renombrar zona');
    }
  };

  const handleEliminar = async (entry: ZonaDB) => {
    setError('');
    try {
      await deleteMut.mutateAsync(entry.id);
      setConfirmDelete(null);
    } catch (e) {
      // El helper enriquece el mensaje con cuántos clientes/proveedores
      // siguen referenciando la zona; lo mostramos tal cual.
      setError(e instanceof Error ? e.message : 'Error al eliminar zona');
    }
  };

  const handleToggleActiva = async (entry: ZonaDB) => {
    setError('');
    try {
      await toggleMut.mutateAsync({ id: entry.id, activo: entry.activo === false });
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al cambiar estado');
    }
  };

  const working = crearMut.isPending || renameMut.isPending || deleteMut.isPending || toggleMut.isPending;

  return (
    <ModalBase title="Gestionar Zonas" onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4 space-y-4">
        {/* Agregar nueva */}
        <div>
          <label htmlFor="nueva-zona" className="block text-sm font-medium mb-1 dark:text-gray-200">
            Nueva zona
          </label>
          <div className="flex gap-2">
            <input
              id="nueva-zona"
              type="text"
              value={nuevoNombre}
              onChange={e => setNuevoNombre(e.target.value)}
              onKeyDown={e => {
                if (e.key === 'Enter') {
                  e.preventDefault();
                  void handleCrear();
                }
              }}
              placeholder="Ej.: ZONA NORTE"
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
            <MapPin className="w-4 h-4" />
            Zonas ({entries.length})
          </h3>

          {isLoading ? (
            <div className="flex items-center justify-center py-8">
              <Loader2 className="w-6 h-6 animate-spin text-blue-600" />
            </div>
          ) : entries.length === 0 ? (
            <p className="text-center text-sm text-gray-500 dark:text-gray-400 py-6">
              No hay zonas creadas todavía. Creá la primera con el formulario de arriba.
            </p>
          ) : (
            <ul className="border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-700 max-h-[50vh] overflow-y-auto">
              {entries.map(entry => {
                const editing = editandoId === entry.id;
                const activa = entry.activo !== false;
                return (
                  <li key={entry.id} className="flex items-center gap-2 px-3 py-2.5">
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
                      <div className={`flex-1 min-w-0 flex items-center gap-2 flex-wrap ${!activa ? 'opacity-60' : ''}`}>
                        <span className="font-medium dark:text-white truncate">{entry.nombre}</span>
                        {!activa && (
                          <span className="text-xs px-2 py-0.5 bg-gray-200 dark:bg-gray-600 text-gray-600 dark:text-gray-300 rounded-full font-medium">
                            inactiva
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
                        <button
                          type="button"
                          onClick={() => handleToggleActiva(entry)}
                          disabled={working}
                          className="p-1.5 hover:bg-gray-100 dark:hover:bg-gray-700 rounded disabled:opacity-50"
                          title={activa ? `Desactivar ${entry.nombre}` : `Activar ${entry.nombre}`}
                          aria-label={activa ? `Desactivar ${entry.nombre}` : `Activar ${entry.nombre}`}
                        >
                          {activa
                            ? <ToggleRight className="w-5 h-5 text-green-600" />
                            : <ToggleLeft className="w-5 h-5 text-gray-400" />
                          }
                        </button>
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
            <strong>Eliminar "{confirmDelete.nombre}"?</strong>{' '}
            Si hay clientes o proveedores asignados a esta zona, la base de datos
            rechazará la operación y deberás reasignarlos primero.
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

export default ModalZonas;
