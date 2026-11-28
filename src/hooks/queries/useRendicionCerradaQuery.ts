/**
 * Hook para consultar si la rendicion de un dia/sucursal ya esta cerrada
 * (confirmada o resuelta). Lo usa ModalPagosMasivos para bloquear al
 * encargado cuando intenta registrar pagos a una fecha cuya rendicion
 * ya fue confirmada.
 *
 * El RPC `rendicion_dia_cerrada` se define en migracion 039.
 *
 * D6 (T5, decisión del dueño 26/11): con `cobradoPor`, la rendición de quien cobra (confirmar la de un
 * chofer no traba los cobros de los demás). Sin él, la de cualquiera de la sucursal, como antes.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'

export const rendicionCerradaKeys = {
  all: ['rendicion_dia_cerrada'] as const,
  forDate: (sucursalId: number | null, fecha: string, cobradoPor: string | null = null) =>
    [...rendicionCerradaKeys.all, sucursalId, fecha, cobradoPor] as const,
}

async function fetchRendicionCerrada(fecha: string, sucursalId: number | null, cobradoPor: string | null): Promise<boolean> {
  if (!fecha || sucursalId == null) return false
  const { data, error } = await supabase.rpc('rendicion_dia_cerrada', {
    p_fecha: fecha,
    p_sucursal_id: sucursalId,
    ...(cobradoPor ? { p_cobrado_por: cobradoPor } : {}),
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo verificar si la rendición está cerrada. Revisá la señal e intentá de nuevo.')
  return Boolean(data)
}

export function useRendicionCerradaQuery(fecha: string | null | undefined, enabled = true, cobradoPor?: string | null) {
  const { currentSucursalId } = useSucursal()
  const fechaSafe = fecha || ''
  const quien = cobradoPor || null
  return useQuery({
    queryKey: rendicionCerradaKeys.forDate(currentSucursalId, fechaSafe, quien),
    queryFn: () => fetchRendicionCerrada(fechaSafe, currentSucursalId, quien),
    enabled: enabled && !!fechaSafe && currentSucursalId != null,
    staleTime: 30 * 1000,
  })
}
