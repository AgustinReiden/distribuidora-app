/**
 * TanStack Query hooks para Zonas estandarizadas
 * Tabla centralizada de zonas y su preventista dueño (mig 359)
 */
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { clientesKeys } from './useClientesQuery'

// Types
export interface ZonaDB {
  id: string;
  nombre: string;
  activo?: boolean;
  created_at?: string;
}

// Query keys
export const zonasKeys = {
  all: (sucursalId: number | null) => ['zonas', sucursalId] as const,
  lists: (sucursalId: number | null) => [...zonasKeys.all(sucursalId), 'list'] as const,
  preventista: (sucursalId: number | null, perfilId: string) => [...zonasKeys.all(sucursalId), 'preventista', perfilId] as const,
  duenios: (sucursalId: number | null) => [...zonasKeys.all(sucursalId), 'duenios'] as const,
}

// Fetch functions
async function fetchZonas(includeInactive = false): Promise<ZonaDB[]> {
  let q = supabase.from('zonas').select('*').order('nombre');
  if (!includeInactive) q = q.eq('activo', true);
  const { data, error } = await q;
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar las zonas. Revisá la señal e intentá de nuevo.');
  return (data as ZonaDB[]) || [];
}

async function fetchPreventistaZonas(perfilId: string): Promise<string[]> {
  const { data, error } = await supabase
    .from('preventista_zonas')
    .select('zona_id')
    .eq('perfil_id', perfilId)

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar las zonas del preventista. Revisá la señal e intentá de nuevo.')
  return (data || []).map(d => String(d.zona_id))
}

async function crearZona(nombre: string, sucursalId: number): Promise<ZonaDB> {
  const trimmed = nombre.trim()
  if (!trimmed) throw new Error('El nombre de la zona es requerido')
  if (!sucursalId) throw new Error('Se requiere sucursal para crear la zona')

  const { data, error } = await supabase
    .from('zonas')
    .insert({ nombre: trimmed, sucursal_id: sucursalId })
    .select()
    .single()

  if (error) {
    if (error.code === '23505') throw new Error(`La zona "${trimmed}" ya existe`)
    throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el alta de la zona. Revisá la lista de zonas antes de reintentar, puede haber quedado hecho.')
  }
  return data as ZonaDB
}

/** Lo que devuelve `asignar_preventista_zona` (mig 359), simulado o no. */
export interface ResultadoAsignacionZona {
  duenio_anterior: string | null;
  clientes_zona: number;
  /** Clientes cuya asignación no es exactamente {preventista nuevo}. */
  cambian: number;
  /** Reservados a administración: el link no los toca. */
  reservados: number;
  /** Por cada OTRO preventista, cuántos clientes de la zona pierde. */
  quitados: Array<{ preventista_id: string; nombre: string; clientes: number }>;
  simulado: boolean;
}

/**
 * Dueño de cada zona: zona_id → perfil_id. Una zona tiene a lo sumo uno
 * (UNIQUE desde la mig 359). Se lee por separado y no embebido en `zonas`:
 * un embed nuevo es un string que no ven ni tsc ni los tests (trampa 5).
 */
async function fetchDueniosZonas(): Promise<Map<string, string>> {
  const { data, error } = await supabase
    .from('preventista_zonas')
    .select('zona_id, perfil_id')
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar los preventistas de las zonas. Revisá la señal e intentá de nuevo.')
  return new Map((data || []).map(d => [String(d.zona_id), String(d.perfil_id)]))
}

/**
 * Linkea la zona con un preventista (o la deja sin, con null). Toda la regla
 * —reasignar los clientes de la zona, no tocar los reservados— vive en la RPC.
 * Con `simular` no escribe nada: devuelve lo que cambiaría.
 */
async function asignarPreventistaZona(
  zonaId: string,
  preventistaId: string | null,
  simular: boolean,
): Promise<ResultadoAsignacionZona> {
  const { data, error } = await supabase.rpc('asignar_preventista_zona', {
    p_zona_id: Number(zonaId),
    p_preventista_id: preventistaId,
    p_simular: simular,
  })
  if (error) {
    throw errorDeSupabase(error, simular
      ? 'Sin conexión: no se pudo cargar qué clientes cambian. Revisá la señal e intentá de nuevo.'
      : 'Sin conexión: no se pudo confirmar el preventista de la zona. Revisá la zona antes de reintentar, puede haber quedado hecho.')
  }
  return data as ResultadoAsignacionZona
}

async function renombrarZona(id: string, nombre: string): Promise<void> {
  const trimmed = nombre.trim();
  if (!trimmed) throw new Error('El nombre de la zona es requerido');
  const { error } = await supabase.from('zonas').update({ nombre: trimmed }).eq('id', id);
  if (error) {
    if (error.code === '23505') throw new Error(`La zona "${trimmed}" ya existe`);
    throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el cambio de nombre de la zona. Revisá la lista de zonas antes de reintentar, puede haber quedado hecho.');
  }
}

async function eliminarZona(id: string): Promise<void> {
  // Best-effort UX hint: count related rows for a friendlier message if delete fails.
  // The DB is the source of truth — clientes_fk and proveedores_fk are both RESTRICT.
  const { error } = await supabase.from('zonas').delete().eq('id', id);
  if (error) {
    if (error.code === '23503') {
      // Try to enrich the message with a count (best effort, ignore if it fails)
      const { count: nClientes } = await supabase
        .from('clientes')
        .select('id', { count: 'exact', head: true })
        .eq('zona_id', id);
      const { count: nProveedores } = await supabase
        .from('proveedores')
        .select('id', { count: 'exact', head: true })
        .eq('zona_id', id);
      const partes: string[] = [];
      if (nClientes && nClientes > 0) partes.push(`${nClientes} cliente${nClientes === 1 ? '' : 's'}`);
      if (nProveedores && nProveedores > 0) partes.push(`${nProveedores} proveedor${nProveedores === 1 ? '' : 'es'}`);
      const ref = partes.length > 0 ? partes.join(' y ') : 'registros';
      throw new Error(`No se puede eliminar: hay ${ref} asignados a esta zona. Reasignalos primero.`);
    }
    throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la eliminación de la zona. Revisá la lista de zonas antes de reintentar, puede haber quedado hecho.');
  }
}

async function toggleZonaActiva(id: string, activo: boolean): Promise<void> {
  const { error } = await supabase.from('zonas').update({ activo }).eq('id', id);
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el cambio de la zona. Revisá la lista de zonas antes de reintentar, puede haber quedado hecho.');
}

// Hooks

export function useZonasEstandarizadasQuery(opts?: { includeInactive?: boolean }) {
  const { currentSucursalId } = useSucursal()
  const includeInactive = opts?.includeInactive ?? false;
  return useQuery({
    queryKey: [...zonasKeys.lists(currentSucursalId), includeInactive],
    queryFn: () => fetchZonas(includeInactive),
    staleTime: 10 * 60 * 1000,
  })
}

export function usePreventistaZonasQuery(perfilId: string | undefined) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: zonasKeys.preventista(currentSucursalId, perfilId || ''),
    queryFn: () => fetchPreventistaZonas(perfilId!),
    enabled: !!perfilId,
    staleTime: 5 * 60 * 1000,
  })
}

export function useCrearZonaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: (nombre: string) => {
      if (!currentSucursalId) {
        return Promise.reject(new Error('No hay sucursal activa'))
      }
      return crearZona(nombre, currentSucursalId)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: zonasKeys.all(currentSucursalId) })
    },
  })
}

export function useDueniosZonasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: zonasKeys.duenios(currentSucursalId),
    queryFn: fetchDueniosZonas,
    enabled: !!currentSucursalId,
    staleTime: 5 * 60 * 1000,
  })
}

/** Sólo calcula: no escribe, no invalida nada. */
export function useSimularAsignacionZonaMutation() {
  return useMutation({
    mutationFn: ({ zonaId, preventistaId }: { zonaId: string; preventistaId: string | null }) =>
      asignarPreventistaZona(zonaId, preventistaId, true),
  })
}

export function useAsignarPreventistaZonaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: ({ zonaId, preventistaId }: { zonaId: string; preventistaId: string | null }) =>
      asignarPreventistaZona(zonaId, preventistaId, false),
    onSuccess: () => {
      // Dueños y zonas de cada preventista (prefijo), y los clientes: el link
      // les cambió la asignación.
      queryClient.invalidateQueries({ queryKey: zonasKeys.all(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: clientesKeys.all(currentSucursalId) })
    },
  })
}

export function useRenombrarZonaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: ({ id, nombre }: { id: string; nombre: string }) => renombrarZona(id, nombre),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: zonasKeys.all(currentSucursalId) })
    },
  })
}

export function useEliminarZonaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: eliminarZona,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: zonasKeys.all(currentSucursalId) })
    },
  })
}

export function useToggleZonaActivaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: ({ id, activo }: { id: string; activo: boolean }) => toggleZonaActiva(id, activo),
    onSuccess: () => {
      // zonasKeys.all is the prefix that includes both `lists(*, includeInactive)` and
      // `preventista(*)` keys — TanStack prefix-match clears all variants in one call.
      // CASCADE on preventista_zonas means deleted zonas already have their assignments
      // wiped DB-side; toggling activo just hides them from selectors.
      queryClient.invalidateQueries({ queryKey: zonasKeys.all(currentSucursalId) })
    },
  })
}
