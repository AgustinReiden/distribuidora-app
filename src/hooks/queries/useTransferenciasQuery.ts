/**
 * TanStack Query hooks para Sucursales.
 *
 * Nota histórica: este archivo manejaba el flujo viejo de transferencias entre
 * sucursales (un solo lado, inmediato), reemplazado por el flujo de
 * "movimientos entre sucursales con aprobación" (ver `useMovimientosQuery.ts`).
 * Quedan solo los helpers de sucursales, que el flujo nuevo sigue usando
 * (`MovimientosContainer` importa `useSucursalesQuery`). Las tablas/RPCs viejas
 * (`transferencias_stock`, `transferencia_items`, `registrar_transferencia`,
 * `registrar_ingreso_sucursal`) se mantienen en la DB como histórico.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type { SucursalDB } from '../../types'

export const sucursalesKeys = {
  all: ['sucursales'] as const,
  lists: () => [...sucursalesKeys.all, 'list'] as const,
}

async function fetchSucursales(): Promise<SucursalDB[]> {
  // Multi-tenant (C3): filter out tenant rows (ManaosApp/TP Export, tipo
  // 'principal' / 'secundaria') from the transfer-destination dropdown.
  // Only sub-sucursales (tipo='distribuidora') are valid transfer targets;
  // otherwise the UI would let a user move stock into the tenant row itself,
  // which has no warehouse semantics.
  const { data, error } = await supabase
    .from('sucursales')
    .select('*')
    .eq('activa', true)
    .eq('tipo', 'distribuidora')
    .order('nombre', { ascending: true })

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data || []) as SucursalDB[]
}

/**
 * Hook para obtener sucursales activas
 */
export function useSucursalesQuery() {
  return useQuery({
    queryKey: sucursalesKeys.lists(),
    queryFn: fetchSucursales,
    staleTime: 10 * 60 * 1000,
  })
}
