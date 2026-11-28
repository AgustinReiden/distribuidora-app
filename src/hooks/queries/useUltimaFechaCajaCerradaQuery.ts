/**
 * Hook para consultar la fecha del ultimo cierre de caja de la sucursal actual
 * (rendicion confirmada/resuelta mas reciente). Se usa para poner el `min` de
 * los inputs de fecha de pago: no se puede registrar una cobranza con fecha
 * anterior o igual al ultimo cierre (lo valida el trigger del backend, mig 134).
 *
 * El RPC `ultima_fecha_caja_cerrada(p_sucursal_id)` se define en migracion 134.
 *
 * D6 (T5, decisión del dueño 26/11): con `cobradoPor`, la caja de quien cobra (el último día que se le
 * confirmó): confirmar la de un chofer no traba los cobros de los demás. Sin él, la de la sucursal.
 */
import { useQueries, useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'

export const ultimaFechaCajaCerradaKeys = {
  all: ['ultima_fecha_caja_cerrada'] as const,
  forSucursal: (sucursalId: number | null, cobradoPor: string | null = null) =>
    [...ultimaFechaCajaCerradaKeys.all, sucursalId, cobradoPor] as const,
}

async function fetchUltimaFechaCajaCerrada(sucursalId: number | null, cobradoPor: string | null): Promise<string | null> {
  if (sucursalId == null) return null
  const { data, error } = await supabase.rpc('ultima_fecha_caja_cerrada', {
    p_sucursal_id: sucursalId,
    ...(cobradoPor ? { p_cobrado_por: cobradoPor } : {}),
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar la fecha del último cierre de caja. Revisá la señal e intentá de nuevo.')
  return (data as string | null) ?? null
}

/** Fecha (YYYY-MM-DD) del ultimo cierre de caja de la sucursal, o null si no hay. */
export function useUltimaFechaCajaCerradaQuery(enabled = true, cobradoPor?: string | null) {
  const { currentSucursalId } = useSucursal()
  const quien = cobradoPor || null
  return useQuery({
    queryKey: ultimaFechaCajaCerradaKeys.forSucursal(currentSucursalId, quien),
    queryFn: () => fetchUltimaFechaCajaCerrada(currentSucursalId, quien),
    enabled: enabled && currentSucursalId != null,
    staleTime: 60 * 1000,
  })
}

/** El día siguiente a una fecha YYYY-MM-DD (o undefined). */
function diaSiguiente(fecha: string | null | undefined): string | undefined {
  if (!fecha) return undefined
  // Anclar a mediodia UTC para que sumar un dia no cruce husos horarios.
  const d = new Date(`${fecha}T12:00:00Z`)
  d.setUTCDate(d.getUTCDate() + 1)
  return d.toISOString().slice(0, 10)
}

/**
 * D6 (T5): la fecha mínima de cada caja, por quien cobró. Para anular un cobro o cambiarle la forma:
 * el server mira la caja de quien lo cobró (`pagos.cobrado_por`); un cobro sin dueño, la de la
 * sucursal (clave `null`). Devuelve la fecha mínima (último cierre + 1 día) por dueño; sin cierre, no
 * tiene entrada.
 */
export function useFechasMinimasPorCobrador(cobradores: ReadonlyArray<string | null | undefined>, enabled = true): Map<string | null, string> {
  const { currentSucursalId } = useSucursal()
  const distintos = [...new Set(cobradores.map(c => c || null))]
  const resultados = useQueries({
    queries: distintos.map(quien => ({
      queryKey: ultimaFechaCajaCerradaKeys.forSucursal(currentSucursalId, quien),
      queryFn: () => fetchUltimaFechaCajaCerrada(currentSucursalId, quien),
      enabled: enabled && currentSucursalId != null,
      staleTime: 60 * 1000,
    })),
  })
  const mapa = new Map<string | null, string>()
  distintos.forEach((quien, i) => {
    const minima = diaSiguiente(resultados[i]?.data)
    if (minima) mapa.set(quien, minima)
  })
  return mapa
}

/**
 * Fecha minima permitida para registrar un pago (ultimo cierre + 1 dia), en
 * formato YYYY-MM-DD para el atributo `min` de un <input type="date">. Devuelve
 * undefined si la sucursal no tiene ninguna caja cerrada (sin restriccion).
 */
export function useFechaMinimaPago(enabled = true, cobradoPor?: string | null): string | undefined {
  const { data } = useUltimaFechaCajaCerradaQuery(enabled, cobradoPor)
  return diaSiguiente(data)
}
