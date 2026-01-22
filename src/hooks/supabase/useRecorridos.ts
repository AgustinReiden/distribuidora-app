import { useState, useCallback } from 'react'
import { supabase } from './base'
import type {
  RecorridoDBExtended,
  PedidoOrdenado,
  EstadisticasRecorridos,
  EstadisticaTransportista,
  TransportistaBasic,
  UseRecorridosReturnExtended
} from '../../types'

interface RecorridoActual {
  id: string;
}

interface RecorridoRaw {
  id: string;
  transportista_id: string;
  fecha: string;
  pedidos_json?: Array<{ pedido_id: string; orden_entrega: number }>;
  estado?: string;
  total_pedidos?: number;
  pedidos_entregados?: number;
  total_facturado?: number;
  total_cobrado?: number;
  distancia_total?: number;
  duracion_total?: number;
  completed_at?: string | null;
  created_at?: string;
  transportista?: TransportistaBasic | null;
}

interface PedidoJson {
  pedido_id: string;
  orden_entrega: number;
}

export function useRecorridos(): UseRecorridosReturnExtended {
  const [recorridos, setRecorridos] = useState<RecorridoDBExtended[]>([])
  const [recorridoActual, setRecorridoActual] = useState<RecorridoActual | null>(null)
  const [loading, setLoading] = useState<boolean>(false)

  // Funcion auxiliar para fetch con timeout
  const fetchConTimeout = async <T>(
    queryPromise: PromiseLike<T>,
    timeoutMs: number = 10000
  ): Promise<T> => {
    const timeoutPromise = new Promise<never>((_, reject) =>
      setTimeout(() => reject(new Error('Timeout')), timeoutMs)
    )
    return Promise.race([queryPromise, timeoutPromise])
  }

  // Obtener recorridos del dia
  const fetchRecorridosHoy = useCallback(async (): Promise<RecorridoDBExtended[]> => {
    setLoading(true)
    const hoy = new Date().toISOString().split('T')[0]

    try {
      const query = supabase
        .from('recorridos')
        .select('*')
        .eq('fecha', hoy)
        .order('created_at', { ascending: false })

      const { data, error } = await fetchConTimeout(query, 8000)

      if (error) {
        setRecorridos([])
        return []
      }

      const dataTyped = (data || []) as RecorridoRaw[]

      // Si hay recorridos, enriquecer con datos del transportista
      if (dataTyped.length > 0) {
        const recorridosEnriquecidos = await Promise.all(
          dataTyped.map(async (recorrido): Promise<RecorridoDBExtended> => {
            let transportista: TransportistaBasic | null = null
            if (recorrido.transportista_id) {
              try {
                const { data: perfil } = await supabase
                  .from('perfiles')
                  .select('id, nombre')
                  .eq('id', recorrido.transportista_id)
                  .single()
                transportista = perfil as TransportistaBasic | null
              } catch {
                // Error silenciado
              }
            }
            return { ...recorrido, transportista }
          })
        )
        setRecorridos(recorridosEnriquecidos)
        return recorridosEnriquecidos
      }

      setRecorridos(dataTyped)
      return dataTyped
    } catch {
      setRecorridos([])
      return []
    } finally {
      setLoading(false)
    }
  }, [])

  // Obtener recorridos por fecha
  const fetchRecorridosPorFecha = useCallback(async (fecha: string): Promise<RecorridoDBExtended[]> => {
    setLoading(true)

    try {
      const query = supabase
        .from('recorridos')
        .select('*')
        .eq('fecha', fecha)
        .order('created_at', { ascending: false })

      const { data, error } = await fetchConTimeout(query, 8000)

      if (error) {
        setRecorridos([])
        return []
      }

      const dataTyped = (data || []) as RecorridoRaw[]

      // Si hay recorridos, enriquecer con datos del transportista
      if (dataTyped.length > 0) {
        const recorridosEnriquecidos = await Promise.all(
          dataTyped.map(async (recorrido): Promise<RecorridoDBExtended> => {
            let transportista: TransportistaBasic | null = null
            if (recorrido.transportista_id) {
              try {
                const { data: perfil } = await supabase
                  .from('perfiles')
                  .select('id, nombre')
                  .eq('id', recorrido.transportista_id)
                  .single()
                transportista = perfil as TransportistaBasic | null
              } catch {
                // Error silenciado
              }
            }
            return { ...recorrido, transportista }
          })
        )
        setRecorridos(recorridosEnriquecidos)
        return recorridosEnriquecidos
      }

      setRecorridos(dataTyped)
      return dataTyped
    } catch {
      setRecorridos([])
      return []
    } finally {
      setLoading(false)
    }
  }, [])

  // Crear un nuevo recorrido cuando se aplica una ruta optimizada
  const crearRecorrido = async (
    transportistaId: string,
    pedidosOrdenados: PedidoOrdenado[],
    distancia: number | null = null,
    duracion: number | null = null
  ): Promise<string> => {
    const pedidosJson: PedidoJson[] = pedidosOrdenados.map((p, idx) => ({
      pedido_id: p.pedido_id || p.id || '',
      orden_entrega: p.orden || idx + 1
    }))

    const { data, error } = await supabase.rpc('crear_recorrido', {
      p_transportista_id: transportistaId,
      p_pedidos: pedidosJson,
      p_distancia: distancia,
      p_duracion: duracion
    })

    if (error) throw error

    const recorridoId = data as string
    setRecorridoActual({ id: recorridoId })
    await fetchRecorridosHoy()
    return recorridoId
  }

  // Completar un recorrido
  const completarRecorrido = async (recorridoId: string): Promise<void> => {
    const { error } = await supabase
      .from('recorridos')
      .update({ estado: 'completado', completed_at: new Date().toISOString() })
      .eq('id', recorridoId)

    if (error) throw error
    await fetchRecorridosHoy()
  }

  // Obtener resumen de recorridos para estadisticas
  const getEstadisticasRecorridos = async (
    fechaDesde: string,
    fechaHasta: string
  ): Promise<EstadisticasRecorridos> => {
    try {
      const query = supabase
        .from('recorridos')
        .select(`
          *,
          transportista:perfiles!transportista_id(id, nombre)
        `)
        .gte('fecha', fechaDesde)
        .lte('fecha', fechaHasta)

      const { data, error } = await query
      if (error) throw error

      const dataTyped = (data || []) as RecorridoRaw[]

      // Agrupar por transportista
      const porTransportista: Record<string, EstadisticaTransportista> = {}
      dataTyped.forEach(r => {
        const tid = r.transportista_id
        if (!porTransportista[tid]) {
          porTransportista[tid] = {
            transportista: r.transportista || null,
            recorridos: 0,
            pedidosTotales: 0,
            pedidosEntregados: 0,
            totalFacturado: 0,
            totalCobrado: 0,
            distanciaTotal: 0
          }
        }
        porTransportista[tid].recorridos += 1
        porTransportista[tid].pedidosTotales += r.total_pedidos || 0
        porTransportista[tid].pedidosEntregados += r.pedidos_entregados || 0
        porTransportista[tid].totalFacturado += r.total_facturado || 0
        porTransportista[tid].totalCobrado += r.total_cobrado || 0
        porTransportista[tid].distanciaTotal += r.distancia_total || 0
      })

      return {
        total: dataTyped.length,
        porTransportista: Object.values(porTransportista)
      }
    } catch {
      return { total: 0, porTransportista: [] }
    }
  }

  return {
    recorridos,
    recorridoActual,
    loading,
    fetchRecorridosHoy,
    fetchRecorridosPorFecha,
    crearRecorrido,
    completarRecorrido,
    getEstadisticasRecorridos
  }
}
