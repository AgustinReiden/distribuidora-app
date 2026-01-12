import { useState, useCallback } from 'react'
import { supabase } from './base'

export function useRecorridos() {
  const [recorridos, setRecorridos] = useState([])
  const [recorridoActual, setRecorridoActual] = useState(null)
  const [loading, setLoading] = useState(false)

  // Función auxiliar para fetch con timeout
  const fetchConTimeout = async (queryPromise, timeoutMs = 10000) => {
    const timeoutPromise = new Promise((_, reject) =>
      setTimeout(() => reject(new Error('Timeout')), timeoutMs)
    )
    return Promise.race([queryPromise, timeoutPromise])
  }

  // Obtener recorridos del día
  const fetchRecorridosHoy = useCallback(async () => {
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

      // Si hay recorridos, enriquecer con datos del transportista
      if (data && data.length > 0) {
        const recorridosEnriquecidos = await Promise.all(
          data.map(async (recorrido) => {
            let transportista = null
            if (recorrido.transportista_id) {
              try {
                const { data: perfil } = await supabase
                  .from('perfiles')
                  .select('id, nombre')
                  .eq('id', recorrido.transportista_id)
                  .single()
                transportista = perfil
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

      setRecorridos(data || [])
      return data || []
    } catch {
      setRecorridos([])
      return []
    } finally {
      setLoading(false)
    }
  }, [])

  // Obtener recorridos por fecha
  const fetchRecorridosPorFecha = useCallback(async (fecha) => {
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

      // Si hay recorridos, enriquecer con datos del transportista
      if (data && data.length > 0) {
        const recorridosEnriquecidos = await Promise.all(
          data.map(async (recorrido) => {
            let transportista = null
            if (recorrido.transportista_id) {
              try {
                const { data: perfil } = await supabase
                  .from('perfiles')
                  .select('id, nombre')
                  .eq('id', recorrido.transportista_id)
                  .single()
                transportista = perfil
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

      setRecorridos(data || [])
      return data || []
    } catch {
      setRecorridos([])
      return []
    } finally {
      setLoading(false)
    }
  }, [])

  // Crear un nuevo recorrido cuando se aplica una ruta optimizada
  const crearRecorrido = async (transportistaId, pedidosOrdenados, distancia = null, duracion = null) => {
    const pedidosJson = pedidosOrdenados.map((p, idx) => ({
      pedido_id: p.pedido_id || p.id,
      orden_entrega: p.orden || idx + 1
    }))

    const { data, error } = await supabase.rpc('crear_recorrido', {
      p_transportista_id: transportistaId,
      p_pedidos: pedidosJson,
      p_distancia: distancia,
      p_duracion: duracion
    })

    if (error) throw error

    setRecorridoActual({ id: data })
    await fetchRecorridosHoy()
    return data
  }

  // Completar un recorrido
  const completarRecorrido = async (recorridoId) => {
    const { error } = await supabase
      .from('recorridos')
      .update({ estado: 'completado', completed_at: new Date().toISOString() })
      .eq('id', recorridoId)

    if (error) throw error
    await fetchRecorridosHoy()
  }

  // Obtener resumen de recorridos para estadísticas
  const getEstadisticasRecorridos = async (fechaDesde, fechaHasta) => {
    try {
      let query = supabase
        .from('recorridos')
        .select(`
          *,
          transportista:perfiles!transportista_id(id, nombre)
        `)
        .gte('fecha', fechaDesde)
        .lte('fecha', fechaHasta)

      const { data, error } = await query
      if (error) throw error

      // Agrupar por transportista
      const porTransportista = {}
      ;(data || []).forEach(r => {
        const tid = r.transportista_id
        if (!porTransportista[tid]) {
          porTransportista[tid] = {
            transportista: r.transportista,
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
        total: data?.length || 0,
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
