/**
 * Modal para gestionar zonas (panel admin).
 *
 * Espejo simplificado de ModalCategorias. La fuente de verdad es la tabla
 * `zonas` (FK desde `clientes.zona_id` y `proveedores.zona_id` con
 * RESTRICT) — no existe el concepto de "derivada" como en categorías,
 * así que no se cuentan/mergean strings sueltos. El admin ve también las
 * inactivas para poder reactivarlas o eliminarlas.
 *
 * Cada zona tiene a lo sumo un preventista (mig 359). Elegirlo le pasa todos
 * los clientes de la zona; por eso primero se simula en la base y se confirma
 * con lo que va a cambiar.
 */
import { memo, useMemo, useState } from 'react';
import { Loader2, Plus, Pencil, Trash2, Check, X, MapPin, AlertCircle, ToggleLeft, ToggleRight } from 'lucide-react';
import ModalBase from './ModalBase';
import { Button } from '../ui/Button';
import {
  useZonasEstandarizadasQuery,
  useCrearZonaMutation,
  useRenombrarZonaMutation,
  useEliminarZonaMutation,
  useToggleZonaActivaMutation,
  usePreventistasQuery,
  useDueniosZonasQuery,
  useSimularAsignacionZonaMutation,
  useAsignarPreventistaZonaMutation,
} from '../../hooks/queries';
import type { ZonaDB, ResultadoAsignacionZona } from '../../hooks/queries/useZonasQuery';
import { textoConfirmacionLinkZona } from '../../utils/zonasPreventista';

interface LinkPendiente {
  zona: ZonaDB;
  preventistaId: string | null;
  preventistaNombre: string | null;
  simulacion: ResultadoAsignacionZona;
}

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
  const { data: preventistas = [] } = usePreventistasQuery();
  const { data: duenios = new Map<string, string>() } = useDueniosZonasQuery();
  const simularMut = useSimularAsignacionZonaMutation();
  const asignarMut = useAsignarPreventistaZonaMutation();

  const [nuevoNombre, setNuevoNombre] = useState('');
  const [error, setError] = useState('');
  const [editandoId, setEditandoId] = useState<string | null>(null);
  const [editNombre, setEditNombre] = useState('');
  const [confirmDelete, setConfirmDelete] = useState<ZonaDB | null>(null);
  const [linkPendiente, setLinkPendiente] = useState<LinkPendiente | null>(null);

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

  const handleElegirPreventista = async (entry: ZonaDB, preventistaId: string | null) => {
    if ((duenios.get(String(entry.id)) ?? null) === preventistaId) return;
    setError('');
    setConfirmDelete(null);
    try {
      const simulacion = await simularMut.mutateAsync({ zonaId: entry.id, preventistaId });
      const preventistaNombre = preventistaId
        ? preventistas.find(p => p.id === preventistaId)?.nombre ?? 'el preventista'
        : null;
      setLinkPendiente({ zona: entry, preventistaId, preventistaNombre, simulacion });
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al calcular el cambio');
    }
  };

  const handleConfirmarLink = async () => {
    if (!linkPendiente) return;
    setError('');
    try {
      await asignarMut.mutateAsync({ zonaId: linkPendiente.zona.id, preventistaId: linkPendiente.preventistaId });
      setLinkPendiente(null);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Error al asignar el preventista');
    }
  };

  const working = crearMut.isPending || renameMut.isPending || deleteMut.isPending || toggleMut.isPending
    || simularMut.isPending || asignarMut.isPending;

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
                  <li key={entry.id} className="flex flex-wrap items-center gap-2 px-3 py-2.5">
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

                    {!editing && (
                      <select
                        value={duenios.get(String(entry.id)) ?? ''}
                        onChange={e => void handleElegirPreventista(entry, e.target.value || null)}
                        disabled={working || !!linkPendiente}
                        aria-label={`Preventista de ${entry.nombre}`}
                        className="w-full sm:w-44 order-last sm:order-none px-2 py-1 border rounded text-sm bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none"
                      >
                        <option value="">(sin preventista)</option>
                        {preventistas.map(p => (
                          <option key={p.id} value={p.id}>{p.nombre}</option>
                        ))}
                      </select>
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
                        <Button
                          type="button"
                          variant="ghost"
                          size="iconSm"
                          onClick={() => handleToggleActiva(entry)}
                          disabled={working}
                          title={activa ? `Desactivar ${entry.nombre}` : `Activar ${entry.nombre}`}
                          aria-label={activa ? `Desactivar ${entry.nombre}` : `Activar ${entry.nombre}`}
                        >
                          {activa
                            ? <ToggleRight className="w-5 h-5 text-green-600" />
                            : <ToggleLeft className="w-5 h-5 text-gray-400" />
                          }
                        </Button>
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
                  </li>
                );
              })}
            </ul>
          )}
        </div>
      </div>

      {/* Confirmación del preventista de la zona: va adentro del modal (si
          quedara como hermano en el container, el overlay lo taparía). */}
      {linkPendiente && (
        <div role="alertdialog" aria-label="Confirmar preventista de la zona" className="p-4 border-t dark:border-gray-600 bg-blue-50 dark:bg-blue-900/20">
          <div className="text-sm text-blue-900 dark:text-blue-100 mb-3 space-y-1">
            {textoConfirmacionLinkZona(
              linkPendiente.zona.nombre,
              linkPendiente.preventistaNombre,
              linkPendiente.simulacion,
            ).map((linea, i) => (
              <p key={i} className={i === 0 ? 'font-semibold' : undefined}>{linea}</p>
            ))}
          </div>
          <div className="flex justify-end gap-2">
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => setLinkPendiente(null)}
              disabled={asignarMut.isPending}
            >
              Cancelar
            </Button>
            <Button
              type="button"
              variant="primary"
              size="sm"
              onClick={handleConfirmarLink}
              disabled={asignarMut.isPending}
              loading={asignarMut.isPending}
            >
              Confirmar
            </Button>
          </div>
        </div>
      )}

      {/* Confirmación de eliminación inline */}
      {confirmDelete && (
        <div className="p-4 border-t dark:border-gray-600 bg-amber-50 dark:bg-amber-900/20">
          <p className="text-sm text-amber-900 dark:text-amber-200 mb-3">
            <strong>Eliminar "{confirmDelete.nombre}"?</strong>{' '}
            Si hay clientes o proveedores asignados a esta zona, la base de datos
            rechazará la operación y deberás reasignarlos primero.
          </p>
          <div className="flex justify-end gap-2">
            <Button
              type="button"
              variant="ghost"
              size="sm"
              onClick={() => setConfirmDelete(null)}
              disabled={deleteMut.isPending}
            >
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

export default ModalZonas;
