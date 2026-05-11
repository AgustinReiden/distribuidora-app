/**
 * Hook para consultar si la rendicion de un dia/sucursal ya esta cerrada
 * (confirmada o resuelta). Lo usa ModalPagosMasivos para bloquear al
 * encargado cuando intenta registrar pagos a una fecha cuya rendicion
 * ya fue confirmada.
 *
 * El RPC `rendicion_dia_cerrada` se define en migracion 039.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'

export const rendicionCerradaKeys = {
  all: ['rendicion_dia_cerrada'] as const,
  forDate: (sucursalId: number | null, fecha: string) =>
    [...rendicionCerradaKeys.all, sucursalId, fecha] as const,
}

async function fetchRendicionCerrada(fecha: string, sucursalId: number | null): Promise<boolean> {
  if (!fecha || sucursalId == null) return false
  const { data, error } = await supabase.rpc('rendicion_dia_cerrada', {
    p_fecha: fecha,
    p_sucursal_id: sucursalId,
  })
  if (error) throw error
  return Boolean(data)
}

export function useRendicionCerradaQuery(fecha: string | null | undefined, enabled = true) {
  const { currentSucursalId } = useSucursal()
  const fechaSafe = fecha || ''
  return useQuery({
    queryKey: rendicionCerradaKeys.forDate(currentSucursalId, fechaSafe),
    queryFn: () => fetchRendicionCerrada(fechaSafe, currentSucursalId),
    enabled: enabled && !!fechaSafe && currentSucursalId != null,
    staleTime: 30 * 1000,
  })
}
