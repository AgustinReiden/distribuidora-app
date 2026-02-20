/**
 * TanStack Query hooks para Zonas estandarizadas
 * Tabla centralizada de zonas + asignación múltiple a preventistas
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'

// Types
export interface ZonaDB {
  id: string;
  nombre: string;
  activo?: boolean;
  created_at?: string;
}

// Query keys
export const zonasKeys = {
  all: ['zonas'] as const,
  lists: () => [...zonasKeys.all, 'list'] as const,
  preventista: (perfilId: string) => [...zonasKeys.all, 'preventista', perfilId] as const,
}

// Fetch functions
async function fetchZonas(): Promise<ZonaDB[]> {
  const { data, error } = await supabase
    .from('zonas')
    .select('*')
    .eq('activo', true)
    .order('nombre')

  if (error) throw error
  return (data as ZonaDB[]) || []
}

async function fetchPreventistaZonas(perfilId: string): Promise<string[]> {
  const { data, error } = await supabase
    .from('preventista_zonas')
    .select('zona_id')
    .eq('perfil_id', perfilId)

  if (error) throw error
  return (data || []).map(d => String(d.zona_id))
}

async function crearZona(nombre: string): Promise<ZonaDB> {
  const trimmed = nombre.trim()
  if (!trimmed) throw new Error('El nombre de la zona es requerido')

  const { data, error } = await supabase
    .from('zonas')
    .insert({ nombre: trimmed })
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

// Hooks

export function useZonasEstandarizadasQuery() {
  return useQuery({
    queryKey: zonasKeys.lists(),
    queryFn: fetchZonas,
    staleTime: 10 * 60 * 1000,
  })
}

export function usePreventistaZonasQuery(perfilId: string | undefined) {
  return useQuery({
    queryKey: zonasKeys.preventista(perfilId || ''),
    queryFn: () => fetchPreventistaZonas(perfilId!),
    enabled: !!perfilId,
    staleTime: 5 * 60 * 1000,
  })
}

export function useCrearZonaMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: crearZona,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: zonasKeys.all })
    },
  })
}

export function useAsignarZonasPrevMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ perfilId, zonaIds }: { perfilId: string; zonaIds: string[] }) =>
      asignarZonasPreventista(perfilId, zonaIds),
    onSuccess: (_data, variables) => {
      queryClient.invalidateQueries({ queryKey: zonasKeys.preventista(variables.perfilId) })
    },
  })
}
