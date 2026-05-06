/**
 * TanStack Query hooks para Zonas estandarizadas
 * Tabla centralizada de zonas + asignación múltiple a preventistas
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'

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
}

// Fetch functions
async function fetchZonas(includeInactive = false): Promise<ZonaDB[]> {
  let q = supabase.from('zonas').select('*').order('nombre');
  if (!includeInactive) q = q.eq('activo', true);
  const { data, error } = await q;
  if (error) throw error;
  return (data as ZonaDB[]) || [];
}

async function fetchPreventistaZonas(perfilId: string): Promise<string[]> {
  const { data, error } = await supabase
    .from('preventista_zonas')
    .select('zona_id')
    .eq('perfil_id', perfilId)

  if (error) throw error
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
    throw error
  }
  return data as ZonaDB
}

async function asignarZonasPreventista(perfilId: string, zonaIds: string[]): Promise<void> {
  // Delete existing assignments
  const { error: delError } = await supabase
    .from('preventista_zonas')
    .delete()
    .eq('perfil_id', perfilId)

  if (delError) throw delError

  // Insert new assignments
  if (zonaIds.length > 0) {
    const inserts = zonaIds.map(zonaId => ({
      perfil_id: perfilId,
      zona_id: parseInt(zonaId)
    }))
    const { error: insError } = await supabase
      .from('preventista_zonas')
      .insert(inserts)
    if (insError) throw insError
  }
}

async function renombrarZona(id: string, nombre: string): Promise<void> {
  const trimmed = nombre.trim();
  if (!trimmed) throw new Error('El nombre de la zona es requerido');
  const { error } = await supabase.from('zonas').update({ nombre: trimmed }).eq('id', id);
  if (error) {
    if (error.code === '23505') throw new Error(`La zona "${trimmed}" ya existe`);
    throw error;
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
    throw error;
  }
}

async function toggleZonaActiva(id: string, activo: boolean): Promise<void> {
  const { error } = await supabase.from('zonas').update({ activo }).eq('id', id);
  if (error) throw error;
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

export function useAsignarZonasPrevMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: ({ perfilId, zonaIds }: { perfilId: string; zonaIds: string[] }) =>
      asignarZonasPreventista(perfilId, zonaIds),
    onSuccess: (_data, variables) => {
      queryClient.invalidateQueries({ queryKey: zonasKeys.preventista(currentSucursalId, variables.perfilId) })
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
