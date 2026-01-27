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

export function useSalvedades(): UseSalvedadesReturn {
  const [salvedades, setSalvedades] = useState<SalvedadItemDBExtended[]>([])
  const [loading, setLoading] = useState<boolean>(false)

  // Query base para salvedades con joins
  // Nota: evitamos el join anidado pedidos->perfiles porque genera errores de FK en Supabase
  const buildSalvedadesQuery = () => {
    return supabase
      .from('salvedades_items')
      .select(`
        *,
        producto:productos!producto_id(id, nombre, codigo),
        pedido:pedidos!pedido_id(
          id,
          total,
          estado,
          transportista_id,
          cliente:clientes!cliente_id(id, nombre_fantasia)
        ),
        reportado:perfiles!reportado_por(id, nombre),
        resuelto:perfiles!resuelto_por(id, nombre)
      `)
  }

  // Transformar datos para compatibilidad con tipos extendidos
  const transformarSalvedad = (s: any): SalvedadItemDBExtended => ({
    ...s,
    producto_nombre: s.producto?.nombre,
    producto_codigo: s.producto?.codigo,
    cliente_nombre: s.pedido?.cliente?.nombre_fantasia,
    transportista_id: s.pedido?.transportista_id,
    pedido_estado: s.pedido?.estado,
    pedido_total: s.pedido?.total,
    reportado_por_nombre: s.reportado?.nombre,
    resuelto_por_nombre: s.resuelto?.nombre
  })

  // Fetch todas las salvedades (para análisis y métricas)
  const fetchTodasSalvedades = useCallback(async (): Promise<SalvedadItemDBExtended[]> => {
    setLoading(true)
    try {
      const { data, error } = await buildSalvedadesQuery()
        .order('created_at', { ascending: false })

      if (error) throw error

      const salvedadesData = (data || []).map(transformarSalvedad)
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

  // Fetch salvedades pendientes - usando tabla directa
  const fetchSalvedadesPendientes = useCallback(async (): Promise<SalvedadItemDBExtended[]> => {
    setLoading(true)
    try {
      const { data, error } = await buildSalvedadesQuery()
        .eq('estado_resolucion', 'pendiente')
        .order('created_at', { ascending: false })

      if (error) throw error

      const salvedadesData = (data || []).map(transformarSalvedad)
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
      const { data, error } = await buildSalvedadesQuery()
        .eq('pedido_id', parseInt(pedidoId, 10))
        .order('created_at', { ascending: false })

      if (error) throw error
      return (data || []).map(transformarSalvedad)
    } catch (error) {
      notifyError('Error al cargar salvedades del pedido: ' + (error as Error).message)
      return []
    }
  }, [])

  // Fetch salvedades por fecha
  const fetchSalvedadesPorFecha = useCallback(async (desde: string, hasta?: string): Promise<SalvedadItemDBExtended[]> => {
    setLoading(true)
    try {
      let query = buildSalvedadesQuery()
        .gte('created_at', desde + 'T00:00:00')
        .order('created_at', { ascending: false })

      if (hasta) {
        query = query.lte('created_at', hasta + 'T23:59:59')
      }

      const { data, error } = await query
      if (error) throw error

      const salvedadesData = (data || []).map(transformarSalvedad)
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
      const { data, error } = await buildSalvedadesQuery()
        .eq('id', parseInt(id, 10))
        .single()

      if (error) throw error
      return transformarSalvedad(data)
    } catch (error) {
      notifyError('Error al cargar salvedad: ' + (error as Error).message)
      return null
    }
  }, [])

  // Registrar salvedad
  const registrarSalvedad = async (input: RegistrarSalvedadInput): Promise<RegistrarSalvedadResult> => {
    try {
      const { data, error } = await supabase.rpc('registrar_salvedad', {
        p_pedido_id: parseInt(input.pedidoId, 10),
        p_pedido_item_id: parseInt(input.pedidoItemId, 10),
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

       
      const result = data as any

      if (!result?.success) {
        notifyError(result?.error || 'Error al registrar salvedad')
        return { success: false, error: result?.error }
      }

      return {
        success: true,
        salvedad_id: result.salvedad_id ? String(result.salvedad_id) : undefined,
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
      p_salvedad_id: parseInt(input.salvedadId, 10),
      p_estado_resolucion: input.estadoResolucion,
      p_notas: input.notas || null,
      p_pedido_reprogramado_id: input.pedidoReprogramadoId ? parseInt(input.pedidoReprogramadoId, 10) : null
    })

    if (error) {
      notifyError('Error al resolver salvedad: ' + error.message)
      throw error
    }

     
    const result = data as any

    if (!result?.success) {
      notifyError(result?.error || 'Error al resolver salvedad')
      throw new Error(result?.error)
    }

    // Refrescar lista (todas, no solo pendientes)
    await fetchTodasSalvedades()

    return {
      success: true,
      nuevoEstado: result.nuevo_estado || input.estadoResolucion
    }
  }

  // Anular salvedad (admin)
  const anularSalvedad = async (salvedadId: string, notas?: string): Promise<{ success: boolean }> => {
    const { data, error } = await supabase.rpc('anular_salvedad', {
      p_salvedad_id: parseInt(salvedadId, 10),
      p_notas: notas || null
    })

    if (error) {
      notifyError('Error al anular salvedad: ' + error.message)
      throw error
    }

     
    const result = data as any

    if (!result?.success) {
      notifyError(result?.error || 'Error al anular salvedad')
      throw new Error(result?.error)
    }

    // Refrescar lista (todas, no solo pendientes)
    await fetchTodasSalvedades()

    return { success: true }
  }

  // Obtener estadísticas - cálculo directo desde datos locales
  // (No usamos RPC porque puede no existir en Supabase)
  const getEstadisticas = useCallback(async (): Promise<EstadisticasSalvedades> => {
    return {
      total: salvedades.length,
      pendientes: salvedades.filter(s => s.estado_resolucion === 'pendiente').length,
      resueltas: salvedades.filter(s => s.estado_resolucion !== 'pendiente' && s.estado_resolucion !== 'anulada').length,
      anuladas: salvedades.filter(s => s.estado_resolucion === 'anulada').length,
      monto_total_afectado: salvedades.reduce((sum, s) => sum + (s.monto_afectado || 0), 0),
      monto_pendiente: salvedades.filter(s => s.estado_resolucion === 'pendiente').reduce((sum, s) => sum + (s.monto_afectado || 0), 0)
    }
  }, [salvedades])

  // Refetch (carga todas las salvedades para análisis completo)
  const refetch = useCallback(async () => {
    await fetchTodasSalvedades()
  }, [fetchTodasSalvedades])

  return {
    salvedades,
    loading,
    registrarSalvedad,
    resolverSalvedad,
    anularSalvedad,
    fetchSalvedadesPorPedido,
    fetchSalvedadesPendientes,
    fetchTodasSalvedades,
    fetchSalvedadesPorFecha,
    fetchSalvedadById,
    getEstadisticas,
    refetch
  }
}
