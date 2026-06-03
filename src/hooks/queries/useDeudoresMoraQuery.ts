/**
 * TanStack Query hook para la lista de deudores en mora.
 *
 * Consume la RPC `obtener_deudores_mora(p_dias_min)`: clientes de la sucursal
 * activa con pedidos ENTREGADOS impagos cuya antigüedad (desde la fecha de
 * entrega + dias_credito) supera `p_dias_min` días. Orden: más atrasado primero.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'

export interface DeudorMora {
  cliente_id: number
  nombre: string
  /** Saldo total de cuenta corriente del cliente (clientes.saldo_cuenta). */
  saldo: number
  /** Suma de saldos de pedidos entregados impagos ya vencidos (en mora). */
  saldo_vencido: number
  /** Días de atraso del pedido vencido más viejo. */
  dias_mora_max: number
  /** Fecha base (entrega o, si falta, fecha del pedido) del más viejo. */
  pedido_mas_viejo: string | null
}

async function fetchDeudoresMora(diasMin: number): Promise<DeudorMora[]> {
  const { data, error } = await supabase.rpc('obtener_deudores_mora', { p_dias_min: diasMin })
  if (error) throw error
  return (data as DeudorMora[]) || []
}

export function useDeudoresMoraQuery(diasMin = 1, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: ['deudores-mora', currentSucursalId, diasMin],
    queryFn: () => fetchDeudoresMora(diasMin),
    enabled,
    staleTime: 60 * 1000,
  })
}
