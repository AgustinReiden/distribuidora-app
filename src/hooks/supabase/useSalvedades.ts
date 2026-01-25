/**
 * Hook para gestión de salvedades en items de pedidos
 * @module hooks/supabase/useSalvedades
 */
import { useState, useCallback } from 'react'
import { supabase, notifyError } from './base'
import type {
  SalvedadItemDBExtended,
  RegistrarSalvedadInput,
  RegistrarSalvedadResult,
  ResolverSalvedadInput,
  EstadisticasSalvedades,
  EstadoResolucionSalvedad,
  MotivoSalvedad,
  UseSalvedadesReturn
} from '../../types'

interface RPCResponse {
  success: boolean;
  error?: string;
  salvedad_id?: string;
  monto_afectado?: number;
  cantidad_entregada?: number;
  stock_devuelto?: boolean;
  nuevo_total_pedido?: number;
  nuevo_estado?: EstadoResolucionSalvedad;
  message?: string;
}

interface EstadisticasRPCResponse {
  total: number;
  pendientes: number;
  resueltas: number;
  anuladas: number;
  monto_total_afectado: number;
  monto_pendiente: number;
  por_motivo?: Record<string, number>;
  por_resolucion?: Record<string, number>;
  por_producto?: Array<{
    producto_id: string;
    producto_nombre: string;
    cantidad: number;
    monto: number;
    unidades_afectadas: number;
  }>;
  por_transportista?: Array<{
    transportista_id: string;
    transportista_nombre: string;
    cantidad: number;
    monto: number;
  }>;
}

export function useSalvedades(): UseSalvedadesReturn {
  const [salvedades, setSalvedades] = useState<SalvedadItemDBExtended[]>([])
  const [loading, setLoading] = useState<boolean>(false)

  // Fetch salvedades pendientes
  const fetchSalvedadesPendientes = useCallback(async (): Promise<SalvedadItemDBExtended[]> => {
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('vista_salvedades')
        .select('*')
        .eq('estado_resolucion', 'pendiente')
        .order('created_at', { ascending: false })

      if (error) throw error

      const salvedadesData = (data || []) as SalvedadItemDBExtended[]
      setSalvedades(salvedadesData)
      return salvedadesData
    } catch (error) {
      notifyError('Error al cargar salvedades: ' + (error as Error).message)
      setSalvedades([])
      return []
    } finally {
      setLoading(false)
    }
  }, [])

  // Fetch salvedades por pedido
  const fetchSalvedadesPorPedido = useCallback(async (pedidoId: string): Promise<SalvedadItemDBExtended[]> => {
    try {
      const { data, error } = await supabase
        .from('vista_salvedades')
        .select('*')
        .eq('pedido_id', pedidoId)
        .order('created_at', { ascending: false })

      if (error) throw error
      return (data || []) as SalvedadItemDBExtended[]
    } catch (error) {
      notifyError('Error al cargar salvedades del pedido: ' + (error as Error).message)
      return []
    }
  }, [])

  // Fetch salvedades por fecha
  const fetchSalvedadesPorFecha = useCallback(async (desde: string, hasta?: string): Promise<SalvedadItemDBExtended[]> => {
    setLoading(true)
    try {
      let query = supabase
        .from('vista_salvedades')
        .select('*')
        .gte('created_at', desde + 'T00:00:00')
        .order('created_at', { ascending: false })

      if (hasta) {
        query = query.lte('created_at', hasta + 'T23:59:59')
      }

      const { data, error } = await query
      if (error) throw error

      const salvedadesData = (data || []) as SalvedadItemDBExtended[]
      setSalvedades(salvedadesData)
      return salvedadesData
    } catch (error) {
      notifyError('Error al cargar salvedades: ' + (error as Error).message)
      setSalvedades([])
      return []
    } finally {
      setLoading(false)
    }
  }, [])

  // Fetch salvedad por ID
  const fetchSalvedadById = useCallback(async (id: string): Promise<SalvedadItemDBExtended | null> => {
    try {
      const { data, error } = await supabase
        .from('vista_salvedades')
        .select('*')
        .eq('id', id)
        .single()

      if (error) throw error
      return data as SalvedadItemDBExtended
    } catch (error) {
      notifyError('Error al cargar salvedad: ' + (error as Error).message)
      return null
    }
  }, [])

  // Registrar salvedad
  const registrarSalvedad = async (input: RegistrarSalvedadInput): Promise<RegistrarSalvedadResult> => {
    try {
      const { data, error } = await supabase.rpc('registrar_salvedad', {
        p_pedido_id: input.pedidoId,
        p_pedido_item_id: input.pedidoItemId,
        p_cantidad_afectada: input.cantidadAfectada,
        p_motivo: input.motivo,
        p_descripcion: input.descripcion || null,
        p_foto_url: input.fotoUrl || null,
        p_devolver_stock: input.devolverStock !== false
      })

      if (error) {
        notifyError('Error al registrar salvedad: ' + error.message)
        return { success: false, error: error.message }
      }

      const result = data as RPCResponse

      if (!result.success) {
        notifyError(result.error || 'Error al registrar salvedad')
        return { success: false, error: result.error }
      }

      return {
        success: true,
        salvedad_id: result.salvedad_id,
        monto_afectado: result.monto_afectado,
        cantidad_entregada: result.cantidad_entregada,
        stock_devuelto: result.stock_devuelto,
        nuevo_total_pedido: result.nuevo_total_pedido
      }
    } catch (error) {
      const message = (error as Error).message
      notifyError('Error al registrar salvedad: ' + message)
      return { success: false, error: message }
    }
  }

  // Resolver salvedad (admin)
  const resolverSalvedad = async (input: ResolverSalvedadInput): Promise<{ success: boolean; nuevoEstado: EstadoResolucionSalvedad }> => {
    const { data, error } = await supabase.rpc('resolver_salvedad', {
      p_salvedad_id: input.salvedadId,
      p_estado_resolucion: input.estadoResolucion,
      p_notas: input.notas || null,
      p_pedido_reprogramado_id: input.pedidoReprogramadoId || null
    })

    if (error) {
      notifyError('Error al resolver salvedad: ' + error.message)
      throw error
    }

    const result = data as RPCResponse

    if (!result.success) {
      notifyError(result.error || 'Error al resolver salvedad')
      throw new Error(result.error)
    }

    // Refrescar lista
    await fetchSalvedadesPendientes()

    return {
      success: true,
      nuevoEstado: result.nuevo_estado || input.estadoResolucion
    }
  }

  // Anular salvedad (admin)
  const anularSalvedad = async (salvedadId: string, notas?: string): Promise<{ success: boolean }> => {
    const { data, error } = await supabase.rpc('anular_salvedad', {
      p_salvedad_id: salvedadId,
      p_notas: notas || null
    })

    if (error) {
      notifyError('Error al anular salvedad: ' + error.message)
      throw error
    }

    const result = data as RPCResponse

    if (!result.success) {
      notifyError(result.error || 'Error al anular salvedad')
      throw new Error(result.error)
    }

    // Refrescar lista
    await fetchSalvedadesPendientes()

    return { success: true }
  }

  // Obtener estadísticas
  const getEstadisticas = async (desde?: string, hasta?: string): Promise<EstadisticasSalvedades> => {
    try {
      const { data, error } = await supabase.rpc('obtener_estadisticas_salvedades', {
        p_fecha_desde: desde || null,
        p_fecha_hasta: hasta || null
      })

      if (error) throw error

      const stats = data as EstadisticasRPCResponse

      return {
        total: stats.total || 0,
        pendientes: stats.pendientes || 0,
        resueltas: stats.resueltas || 0,
        anuladas: stats.anuladas || 0,
        monto_total_afectado: stats.monto_total_afectado || 0,
        monto_pendiente: stats.monto_pendiente || 0,
        por_motivo: stats.por_motivo as Record<MotivoSalvedad, number> | undefined,
        por_resolucion: stats.por_resolucion as Record<EstadoResolucionSalvedad, number> | undefined,
        por_producto: stats.por_producto,
        por_transportista: stats.por_transportista
      }
    } catch (error) {
      notifyError('Error al obtener estadísticas: ' + (error as Error).message)
      return {
        total: 0,
        pendientes: 0,
        resueltas: 0,
        anuladas: 0,
        monto_total_afectado: 0,
        monto_pendiente: 0
      }
    }
  }

  // Refetch
  const refetch = useCallback(async () => {
    await fetchSalvedadesPendientes()
  }, [fetchSalvedadesPendientes])

  return {
    salvedades,
    loading,
    registrarSalvedad,
    resolverSalvedad,
    anularSalvedad,
    fetchSalvedadesPorPedido,
    fetchSalvedadesPendientes,
    fetchSalvedadesPorFecha,
    fetchSalvedadById,
    getEstadisticas,
    refetch
  }
}
