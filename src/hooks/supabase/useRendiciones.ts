/**
 * Hook para gestión de rendiciones de transportistas
 * @module hooks/supabase/useRendiciones
 */
import { useState, useCallback } from 'react'
import { supabase, notifyError } from './base'
import type {
  RendicionDBExtended,
  PresentarRendicionInput,
  RevisarRendicionInput,
  EstadisticasRendiciones,
  EstadoRendicion,
  UseRendicionesReturn
} from '../../types'

export function useRendiciones(): UseRendicionesReturn {
  const [rendiciones, setRendiciones] = useState<RendicionDBExtended[]>([])
  const [rendicionActual, setRendicionActual] = useState<RendicionDBExtended | null>(null)
  const [loading, setLoading] = useState<boolean>(false)

  // Fetch rendiciones por fecha - usando tabla directa con joins
  const fetchRendicionesPorFecha = useCallback(async (fecha: string): Promise<RendicionDBExtended[]> => {
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('rendiciones')
        .select(`
          *,
          transportista:perfiles!transportista_id(id, nombre),
          recorrido:recorridos!recorrido_id(id, total_pedidos, pedidos_entregados, total_facturado, total_cobrado)
        `)
        .eq('fecha', fecha)
        .order('created_at', { ascending: false })

      if (error) throw error

      // Transformar datos para compatibilidad
      const rendicionesData = (data || []).map(r => ({
        ...r,
        transportista_nombre: r.transportista?.nombre,
        total_pedidos: r.recorrido?.total_pedidos || 0,
        pedidos_entregados: r.recorrido?.pedidos_entregados || 0,
        total_facturado: r.recorrido?.total_facturado || 0,
        total_cobrado: r.recorrido?.total_cobrado || 0
      })) as RendicionDBExtended[]

      setRendiciones(rendicionesData)
      return rendicionesData
    } catch (error) {
      notifyError('Error al cargar rendiciones: ' + (error as Error).message)
      setRendiciones([])
      return []
    } finally {
      setLoading(false)
    }
  }, [])

  // Fetch rendicion actual del transportista (del día)
  const fetchRendicionActual = useCallback(async (transportistaId: string): Promise<RendicionDBExtended | null> => {
    setLoading(true)
    try {
      const hoy = new Date().toISOString().split('T')[0]
      const { data, error } = await supabase
        .from('rendiciones')
        .select(`
          *,
          transportista:perfiles!transportista_id(id, nombre),
          items:rendicion_items(*),
          ajustes:rendicion_ajustes(*)
        `)
        .eq('transportista_id', transportistaId)
        .eq('fecha', hoy)
        .maybeSingle()

      if (error) throw error

      const rendicion = data as RendicionDBExtended | null
      setRendicionActual(rendicion)
      return rendicion
    } catch (error) {
      notifyError('Error al cargar rendición: ' + (error as Error).message)
      return null
    } finally {
      setLoading(false)
    }
  }, [])

  // Fetch rendicion por ID
  const fetchRendicionById = useCallback(async (id: string): Promise<RendicionDBExtended | null> => {
    try {
      const { data, error } = await supabase
        .from('rendiciones')
        .select(`
          *,
          transportista:perfiles!transportista_id(id, nombre),
          items:rendicion_items(*),
          ajustes:rendicion_ajustes(*)
        `)
        .eq('id', id)
        .single()

      if (error) throw error
      return data as RendicionDBExtended
    } catch (error) {
      notifyError('Error al cargar rendición: ' + (error as Error).message)
      return null
    }
  }, [])

  // Fetch rendiciones por transportista
  const fetchRendicionesPorTransportista = useCallback(async (
    transportistaId: string,
    desde?: string,
    hasta?: string
  ): Promise<RendicionDBExtended[]> => {
    try {
      let query = supabase
        .from('rendiciones')
        .select(`
          *,
          transportista:perfiles!transportista_id(id, nombre)
        `)
        .eq('transportista_id', transportistaId)
        .order('fecha', { ascending: false })

      if (desde) query = query.gte('fecha', desde)
      if (hasta) query = query.lte('fecha', hasta)

      const { data, error } = await query
      if (error) throw error

      return (data || []).map(r => ({
        ...r,
        transportista_nombre: r.transportista?.nombre
      })) as RendicionDBExtended[]
    } catch (error) {
      notifyError('Error al cargar rendiciones: ' + (error as Error).message)
      return []
    }
  }, [])

  // Crear rendición desde recorrido
  const crearRendicion = async (recorridoId: string, transportistaId?: string): Promise<string> => {
    const { data, error } = await supabase.rpc('crear_rendicion_recorrido', {
      p_recorrido_id: parseInt(recorridoId, 10),
      p_transportista_id: transportistaId || null
    })

    if (error) {
      notifyError('Error al crear rendición: ' + error.message)
      throw error
    }

    const rendicionId = String(data)

    // Si tenemos transportista, actualizar rendicion actual
    if (transportistaId) {
      await fetchRendicionActual(transportistaId)
    }

    return rendicionId
  }

  // Presentar rendición
  const presentarRendicion = async (input: PresentarRendicionInput): Promise<{ success: boolean; diferencia: number }> => {
    const { data, error } = await supabase.rpc('presentar_rendicion', {
      p_rendicion_id: parseInt(input.rendicionId, 10),
      p_monto_rendido: input.montoRendido,
      p_justificacion: input.justificacion || null
    })

    if (error) {
      notifyError('Error al presentar rendición: ' + error.message)
      throw error
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = data as any

    if (!result?.success) {
      notifyError(result?.error || 'Error al presentar rendición')
      throw new Error(result?.error)
    }

    return {
      success: true,
      diferencia: result.diferencia || 0
    }
  }

  // Agregar ajuste a rendición
  const agregarAjuste = async (rendicionId: string, ajuste: { tipo: string; monto: number; descripcion: string; foto?: File }): Promise<void> => {
    let fotoUrl: string | null = null

    // Subir foto si existe
    if (ajuste.foto) {
      const fileName = `rendicion-ajustes/${rendicionId}/${Date.now()}_${ajuste.foto.name}`
      const { error: uploadError } = await supabase.storage
        .from('evidencias')
        .upload(fileName, ajuste.foto)

      if (!uploadError) {
        const { data: urlData } = supabase.storage.from('evidencias').getPublicUrl(fileName)
        fotoUrl = urlData.publicUrl
      }
    }

    const { error } = await supabase.from('rendicion_ajustes').insert({
      rendicion_id: parseInt(rendicionId, 10),
      tipo: ajuste.tipo,
      monto: ajuste.monto,
      descripcion: ajuste.descripcion,
      foto_url: fotoUrl
    })

    if (error) {
      notifyError('Error al agregar ajuste: ' + error.message)
      throw error
    }
  }

  // Revisar rendición (admin)
  const revisarRendicion = async (input: RevisarRendicionInput): Promise<{ success: boolean; nuevoEstado: EstadoRendicion }> => {
    const { data, error } = await supabase.rpc('revisar_rendicion', {
      p_rendicion_id: parseInt(input.rendicionId, 10),
      p_accion: input.accion,
      p_observaciones: input.observaciones || null
    })

    if (error) {
      notifyError('Error al revisar rendición: ' + error.message)
      throw error
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const result = data as any

    if (!result?.success) {
      notifyError(result?.error || 'Error al revisar rendición')
      throw new Error(result?.error)
    }

    return {
      success: true,
      nuevoEstado: result.nuevo_estado || 'pendiente'
    }
  }

  // Obtener estadísticas - simplificado para evitar errores
  const getEstadisticas = async (
    desde?: string,
    hasta?: string,
    transportistaId?: string
  ): Promise<EstadisticasRendiciones> => {
    try {
      // Intentar usar el RPC
      const { data, error } = await supabase.rpc('obtener_estadisticas_rendiciones', {
        p_fecha_desde: desde || null,
        p_fecha_hasta: hasta || null,
        p_transportista_id: transportistaId || null
      })

      if (error) {
        // Si el RPC falla, calcular manualmente desde los datos locales
        console.warn('RPC estadisticas fallo, usando datos locales:', error.message)
        return calcularEstadisticasLocales()
      }

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const stats = data as any

      return {
        total: stats?.total || 0,
        pendientes: stats?.pendientes || 0,
        aprobadas: stats?.aprobadas || 0,
        rechazadas: stats?.rechazadas || 0,
        con_observaciones: stats?.con_observaciones || 0,
        total_efectivo_esperado: stats?.total_efectivo_esperado || 0,
        total_rendido: stats?.total_rendido || 0,
        total_diferencias: stats?.total_diferencias || 0,
        por_transportista: stats?.por_transportista || []
      }
    } catch (error) {
      notifyError('Error al obtener estadísticas: ' + (error as Error).message)
      return calcularEstadisticasLocales()
    }
  }

  // Calcular estadísticas desde los datos locales
  const calcularEstadisticasLocales = (): EstadisticasRendiciones => {
    return {
      total: rendiciones.length,
      pendientes: rendiciones.filter(r => r.estado === 'pendiente' || r.estado === 'presentada').length,
      aprobadas: rendiciones.filter(r => r.estado === 'aprobada').length,
      rechazadas: rendiciones.filter(r => r.estado === 'rechazada').length,
      con_observaciones: rendiciones.filter(r => r.estado === 'con_observaciones').length,
      total_efectivo_esperado: rendiciones.reduce((sum, r) => sum + (r.total_efectivo_esperado || 0), 0),
      total_rendido: rendiciones.filter(r => r.estado === 'aprobada').reduce((sum, r) => sum + (r.monto_rendido || 0), 0),
      total_diferencias: rendiciones.filter(r => r.estado === 'aprobada').reduce((sum, r) => sum + (r.diferencia || 0), 0)
    }
  }

  // Refetch del día actual
  const refetch = useCallback(async () => {
    const hoy = new Date().toISOString().split('T')[0]
    await fetchRendicionesPorFecha(hoy)
  }, [fetchRendicionesPorFecha])

  return {
    rendiciones,
    rendicionActual,
    loading,
    crearRendicion,
    presentarRendicion,
    agregarAjuste,
    revisarRendicion,
    fetchRendicionActual,
    fetchRendicionesPorFecha,
    fetchRendicionesPorTransportista,
    fetchRendicionById,
    getEstadisticas,
    refetch
  }
}
