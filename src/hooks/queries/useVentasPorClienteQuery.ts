/**
 * TanStack Query hook para el reporte de ventas por cliente y por zona (mig 197).
 *
 * RPC `reporte_ventas_por_cliente(p_desde, p_hasta, p_preventista_id, p_sucursal_id)`:
 * total vendido a cada cliente en el período, con la zona que el cliente tiene
 * en su ficha, más el mismo corte agregado por zona. Un solo viaje alimenta las
 * dos pestañas ("Por Cliente" y "Por Zona").
 *
 * Criterio (vive en el RPC, ver el comentario de la migración): pedidos
 * ENTREGADOS, por `pedidos.fecha`, atribuidos a quien los cargó
 * (`pedidos.usuario_id`). Excluye cancelados y cambios/devoluciones.
 *
 * La agregación es del lado del servidor a propósito: la versión anterior la
 * hacía en el navegador y se comía el límite de 1.000 filas de PostgREST sin
 * avisar.
 */
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../../lib/supabase'
import { useSucursal } from '../../contexts/SucursalContext'

export interface VentaClienteRow {
  /** NULL en la fila "(sin cliente asignado)": pedidos con cliente_id NULL. */
  cliente_id: number | null
  codigo: number | null
  nombre: string
  zona: string
  pedidos: number
  total: number
  /** { 'YYYY-MM': total } — sólo los meses en que ese cliente compró. */
  por_mes: Record<string, number>
}

export interface VentaZonaRow {
  zona: string
  clientes: number
  pedidos: number
  total: number
  ticket_promedio: number
}

/**
 * Quien cargó ventas en el período (mig 198). Sale de los datos, no de
 * `perfiles.rol`: la venta se atribuye a `pedidos.usuario_id` y también cargan
 * pedidos encargados y admins (Jony, encargado, lleva $16,6M en 2026). Se
 * calcula ignorando el filtro de preventista, así que la lista no se achica al
 * elegir a alguien.
 */
export interface VendedorRow {
  id: string
  nombre: string
  pedidos: number
  total: number
}

export interface VentasPorCliente {
  meta: {
    desde: string
    hasta: string
    preventista_id: string | null
    preventista_nombre: string
    sucursal_id: number | null
    sucursal_nombre: string
    generado_at: string
    criterio: string
  }
  /** Meses con datos dentro del rango, ordenados: ['2026-06', '2026-07', ...] */
  meses: string[]
  /** Para el selector: NO se achica al filtrar por preventista. */
  vendedores: VendedorRow[]
  totales: { clientes: number; pedidos: number; total: number }
  clientes: VentaClienteRow[]
  zonas: VentaZonaRow[]
}

export const ventasPorClienteKeys = {
  all: (sucursalId: number | null) => ['ventas-por-cliente', sucursalId] as const,
  rango: (
    sucursalId: number | null,
    desde: string,
    hasta: string,
    preventistaId: string | null
  ) => [...ventasPorClienteKeys.all(sucursalId), desde, hasta, preventistaId] as const,
}

export function useVentasPorClienteQuery(
  desde: string,
  hasta: string,
  preventistaId: string | null = null
) {
  const { currentSucursalId } = useSucursal()

  return useQuery({
    queryKey: ventasPorClienteKeys.rango(currentSucursalId, desde, hasta, preventistaId),
    queryFn: async (): Promise<VentasPorCliente> => {
      const { data, error } = await supabase.rpc('reporte_ventas_por_cliente', {
        p_desde: desde,
        p_hasta: hasta,
        p_preventista_id: preventistaId,
        p_sucursal_id: currentSucursalId,
      })
      if (error) throw new Error(error.message)
      return data as VentasPorCliente
    },
    enabled: !!currentSucursalId && !!desde && !!hasta,
    staleTime: 5 * 60 * 1000,
  })
}
