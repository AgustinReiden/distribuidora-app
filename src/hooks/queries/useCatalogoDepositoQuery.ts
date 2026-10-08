/**
 * El catálogo que ve depósito en /productos (#999), por la RPC
 * `catalogo_deposito()`: las columnas de productos MENOS las de plata (sin
 * precio, precio_sin_iva, costos, impuestos ni IVA). Depósito no lee `productos`
 * por REST: `mt_productos_select` lo excluye, porque la RLS filtra filas y no
 * columnas.
 *
 * El realtime de productos no le llega (la misma RLS filtra los eventos), así
 * que el catálogo se refresca solo al volver a la pantalla y cada minuto.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import type { ProductoDB } from '../../types'

export const catalogoDepositoKeys = {
  all: (sucursalId: number | null) => ['catalogo-deposito', sucursalId] as const,
}

async function fetchCatalogoDeposito(): Promise<ProductoDB[]> {
  const { data, error } = await supabase.rpc('catalogo_deposito')
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar los productos. Revisá la señal e intentá de nuevo.')
  // Las filas no traen `precio`: la vista no lo dibuja para depósito
  // (puedeVerPrecioVenta). El resto llega igual que por REST (ids incluidos).
  return (data as unknown as ProductoDB[]) || []
}

export function useCatalogoDepositoQuery(opts?: { enabled?: boolean }) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: catalogoDepositoKeys.all(currentSucursalId),
    queryFn: fetchCatalogoDeposito,
    enabled: opts?.enabled ?? true,
    staleTime: 60 * 1000,
    refetchOnWindowFocus: true,
  })
}
