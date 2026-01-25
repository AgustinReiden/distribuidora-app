/**
 * Hook para gestión de rendiciones de transportistas
 * @module hooks/supabase/useRendiciones
 */
import { useState, useCallback } from 'react'
import { supabase, notifyError } from './base'
import type {
  RendicionDBExtended,
  RendicionAjusteInput,
  PresentarRendicionInput,
  RevisarRendicionInput,
  EstadisticasRendiciones,
  EstadoRendicion,
  UseRendicionesReturn
} from '../../types'

interface RendicionRaw {
  id: string;
  recorrido_id: string;
  transportista_id: string;
  fecha: string;
  total_efectivo_esperado: number;
  total_otros_medios: number;
  monto_rendido: number;
  diferencia: number;
  estado: EstadoRendicion;
  justificacion_transportista?: string | null;
  observaciones_admin?: string | null;
  presentada_at?: string | null;
  revisada_at?: string | null;
  revisada_por?: string | null;
  created_at?: string;
  updated_at?: string;
  // Relaciones
  transportista?: { id: string; nombre: string } | null;
  revisada_por_perfil?: { id: string; nombre: string } | null;
  items?: unknown[];
  ajustes?: unknown[];
  // Datos del recorrido
  total_pedidos?: number;
  pedidos_entregados?: number;
  total_facturado?: number;
  total_cobrado?: number;
  total_ajustes?: number;
}

interface RPCResponse {
  success: boolean;
  error?: string;
  diferencia?: number;
  nuevo_estado?: EstadoRendicion;
  requiere_justificacion?: boolean;
}

interface EstadisticasRPCResponse {
  total: number;
  pendientes: number;
  aprobadas: number;
  rechazadas: number;
  con_observaciones: number;
  total_efectivo_esperado: number;
  total_rendido: number;
  total_diferencias: number;
  por_transportista?: Array<{
    transportista_id: string;
    transportista_nombre: string;
    rendiciones: number;
    total_rendido: number;
    total_diferencias: number;
  }>;
}

export function useRendiciones(): UseRendicionesReturn {
  const [rendiciones, setRendiciones] = useState<RendicionDBExtended[]>([])
  const [rendicionActual, setRendicionActual] = useState<RendicionDBExtended | null>(null)
  const [loading, setLoading] = useState<boolean>(false)

  // Fetch rendiciones por fecha
  const fetchRendicionesPorFecha = useCallback(async (fecha: string): Promise<RendicionDBExtended[]> => {
    setLoading(true)
    try {
      const { data, error } = await supabase
        .from('vista_rendiciones')
        .select('*')
        .eq('fecha', fecha)
        .order('created_at', { ascending: false })

      if (error) throw error

      const rendicionesData = (data || []) as RendicionDBExtended[]
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
          items:rendicion_items(
            *,
            pedido:pedidos(id, total, cliente:clientes(nombre_fantasia))
          ),
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
          items:rendicion_items(
            *,
            pedido:pedidos(id, total, forma_pago, estado_pago, cliente:clientes(nombre_fantasia))
          ),
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
        .from('vista_rendiciones')
        .select('*')
        .eq('transportista_id', transportistaId)
        .order('fecha', { ascending: false })

      if (desde) query = query.gte('fecha', desde)
      if (hasta) query = query.lte('fecha', hasta)

      const { data, error } = await query
      if (error) throw error

      return (data || []) as RendicionDBExtended[]
    } catch (error) {
      notifyError('Error al cargar rendiciones: ' + (error as Error).message)
      return []
    }
  }, [])

  // Crear rendición desde recorrido
  const crearRendicion = async (recorridoId: string, transportistaId?: string): Promise<string> => {
    const { data, error } = await supabase.rpc('crear_rendicion_recorrido', {
      p_recorrido_id: recorridoId,
      p_transportista_id: transportistaId || null
    })

    if (error) {
      notifyError('Error al crear rendición: ' + error.message)
      throw error
    }

    const rendicionId = data as string

    // Si tenemos transportista, actualizar rendicion actual
    if (transportistaId) {
      await fetchRendicionActual(transportistaId)
    }

    return rendicionId
  }

  // Presentar rendición
  const presentarRendicion = async (input: PresentarRendicionInput): Promise<{ success: boolean; diferencia: number }> => {
    // Primero presentar la rendición
    const { data, error } = await supabase.rpc('presentar_rendicion', {
      p_rendicion_id: input.rendicionId,
      p_monto_rendido: input.montoRendido,
      p_justificacion: input.justificacion || null
    })

    if (error) {
      notifyError('Error al presentar rendición: ' + error.message)
      throw error
    }

    const result = data as RPCResponse

    if (!result.success) {
      notifyError(result.error || 'Error al presentar rendición')
      throw new Error(result.error)
    }

    // Agregar ajustes si los hay
    if (input.ajustes && input.ajustes.length > 0) {
      for (const ajuste of input.ajustes) {
        await agregarAjuste(input.rendicionId, ajuste)
      }
    }

    return {
      success: true,
      diferencia: result.diferencia || 0
    }
  }

  // Agregar ajuste a rendición
  const agregarAjuste = async (rendicionId: string, ajuste: RendicionAjusteInput): Promise<void> => {
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
      rendicion_id: rendicionId,
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
      p_rendicion_id: input.rendicionId,
      p_accion: input.accion,
      p_observaciones: input.observaciones || null
    })

    if (error) {
      notifyError('Error al revisar rendición: ' + error.message)
      throw error
    }

    const result = data as RPCResponse

    if (!result.success) {
      notifyError(result.error || 'Error al revisar rendición')
      throw new Error(result.error)
    }

    return {
      success: true,
      nuevoEstado: result.nuevo_estado || 'pendiente'
    }
  }

  // Obtener estadísticas
  const getEstadisticas = async (
    desde?: string,
    hasta?: string,
    transportistaId?: string
  ): Promise<EstadisticasRendiciones> => {
    try {
      const { data, error } = await supabase.rpc('obtener_estadisticas_rendiciones', {
        p_fecha_desde: desde || null,
        p_fecha_hasta: hasta || null,
        p_transportista_id: transportistaId || null
      })

      if (error) throw error

      const stats = data as EstadisticasRPCResponse

      return {
        total: stats.total || 0,
        pendientes: stats.pendientes || 0,
        aprobadas: stats.aprobadas || 0,
        rechazadas: stats.rechazadas || 0,
        con_observaciones: stats.con_observaciones || 0,
        total_efectivo_esperado: stats.total_efectivo_esperado || 0,
        total_rendido: stats.total_rendido || 0,
        total_diferencias: stats.total_diferencias || 0,
        por_transportista: stats.por_transportista || []
      }
    } catch (error) {
      notifyError('Error al obtener estadísticas: ' + (error as Error).message)
      return {
        total: 0,
        pendientes: 0,
        aprobadas: 0,
        rechazadas: 0,
        con_observaciones: 0,
        total_efectivo_esperado: 0,
        total_rendido: 0,
        total_diferencias: 0
      }
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
