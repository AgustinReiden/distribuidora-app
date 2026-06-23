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
  // Todas las sucursales ACTIVAS son destinos válidos de movimiento. NO se
  // filtra por `tipo`: en este deployment las sucursales operativas reales se
  // etiquetaron 'principal'/'secundaria' (id 1 Tucumán, id 2 Taco Pozo) y la
  // única 'distribuidora' era una sucursal fantasma vacía; filtrar por
  // tipo='distribuidora' dejaba el selector mostrando solo el fantasma y rompía
  // los envíos entre sucursales reales. El container excluye la sucursal actual.
  const { data, error } = await supabase
    .from('sucursales')
    .select('*')
    .eq('activa', true)
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
