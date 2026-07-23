/**
 * Hook para consultar la fecha del ultimo cierre de caja de la sucursal actual
 * (rendicion confirmada/resuelta mas reciente). Se usa para poner el `min` de
 * los inputs de fecha de pago: no se puede registrar una cobranza con fecha
 * anterior o igual al ultimo cierre (lo valida el trigger del backend, mig 134).
 *
 * El RPC `ultima_fecha_caja_cerrada(p_sucursal_id)` se define en migracion 134.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'

export const ultimaFechaCajaCerradaKeys = {
  all: ['ultima_fecha_caja_cerrada'] as const,
  forSucursal: (sucursalId: number | null) =>
    [...ultimaFechaCajaCerradaKeys.all, sucursalId] as const,
}

async function fetchUltimaFechaCajaCerrada(sucursalId: number | null): Promise<string | null> {
  if (sucursalId == null) return null
  const { data, error } = await supabase.rpc('ultima_fecha_caja_cerrada', {
    p_sucursal_id: sucursalId,
  })
  if (error) throw error
  return (data as string | null) ?? null
}

/** Fecha (YYYY-MM-DD) del ultimo cierre de caja de la sucursal, o null si no hay. */
export function useUltimaFechaCajaCerradaQuery(enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: ultimaFechaCajaCerradaKeys.forSucursal(currentSucursalId),
    queryFn: () => fetchUltimaFechaCajaCerrada(currentSucursalId),
    enabled: enabled && currentSucursalId != null,
    staleTime: 60 * 1000,
  })
}

/**
 * Fecha minima permitida para registrar un pago (ultimo cierre + 1 dia), en
 * formato YYYY-MM-DD para el atributo `min` de un <input type="date">. Devuelve
 * undefined si la sucursal no tiene ninguna caja cerrada (sin restriccion).
 */
export function useFechaMinimaPago(enabled = true): string | undefined {
  const { data } = useUltimaFechaCajaCerradaQuery(enabled)
  if (!data) return undefined
  // Anclar a mediodia UTC para que sumar un dia no cruce husos horarios.
  const d = new Date(`${data}T12:00:00Z`)
  d.setUTCDate(d.getUTCDate() + 1)
  return d.toISOString().slice(0, 10)
}
