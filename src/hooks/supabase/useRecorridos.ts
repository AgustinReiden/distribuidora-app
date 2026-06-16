import { useState, useCallback } from 'react'
import { supabase } from './base'
import { fechaLocalISO } from '../../utils/formatters'
import type {
  RecorridoDBExtended,
  RecorridoParada,
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
  polylines?: string[] | null;
  transportista?: TransportistaBasic | null;
  recorrido_pedidos?: Array<{
    id: string;
    orden_entrega?: number;
    estado_entrega?: string;
    hora_entrega?: string | null;
    pedido?: Record<string, unknown> | null;
  }>;
}

interface PedidoJson {
  pedido_id: string;
  orden_entrega: number;
}

// SELECT con joins: trae transportista y las paradas (recorrido_pedidos) con
// su pedido y cliente embebidos en UNA sola query. Antes se hacía select('*')
// sin joins (la vista esperaba recorrido.pedidos y nunca llegaba) más un N+1
// de perfiles por recorrido.
const RECORRIDO_SELECT = `*,
  transportista:perfiles!transportista_id(id, nombre),
  recorrido_pedidos(id, orden_entrega, estado_entrega, hora_entrega,
    pedido:pedidos(id, estado, estado_pago, total, monto_pagado, notas,
      cliente:clientes(nombre_fantasia, direccion, telefono, latitud, longitud),
      items:pedido_items(id)))`

// Mapea la fila cruda al shape que espera VistaRecorridos (recorrido.pedidos)
function mapRecorrido(r: RecorridoRaw): RecorridoDBExtended {
  const pedidos = (r.recorrido_pedidos || [])
    .slice()
    .sort((a, b) => (a.orden_entrega || 999) - (b.orden_entrega || 999))
    .map((rp): RecorridoParada => ({
      pedido_id: rp.pedido ? String((rp.pedido as { id?: unknown }).id ?? '') : undefined,
      orden_entrega: rp.orden_entrega,
      estado_entrega: rp.estado_entrega,
      hora_entrega: rp.hora_entrega,
      pedido: rp.pedido as RecorridoParada['pedido'],
    }))
  const { recorrido_pedidos: _omit, ...rest } = r
  return { ...rest, pedidos } as RecorridoDBExtended
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

  // Fetch compartido: una sola query con joins (transportista + paradas)
  const fetchRecorridosDeFecha = useCallback(async (fecha: string): Promise<RecorridoDBExtended[]> => {
    setLoading(true)
    try {
      const query = supabase
        .from('recorridos')
        .select(RECORRIDO_SELECT)
        .eq('fecha', fecha)
        // Ocultar canceladas: con la edición in-place (mig 088) ya no se generan,
        // pero pueden existir históricas del flujo viejo (cancelar + recrear) y
        // confundían al mostrar dos rutas del mismo transportista el mismo día.
        .neq('estado', 'cancelado')
        .order('created_at', { ascending: false })

      const { data, error } = await fetchConTimeout(query, 8000)

      if (error) {
        setRecorridos([])
        return []
      }

      const mapped = ((data || []) as unknown as RecorridoRaw[]).map(mapRecorrido)
      setRecorridos(mapped)
      return mapped
    } catch {
      setRecorridos([])
      return []
    } finally {
      setLoading(false)
    }
  }, [])

  // Obtener recorridos del dia
  const fetchRecorridosHoy = useCallback(async (): Promise<RecorridoDBExtended[]> => {
    return fetchRecorridosDeFecha(fechaLocalISO())
  }, [fetchRecorridosDeFecha])

  // Obtener recorridos por fecha
  const fetchRecorridosPorFecha = useCallback(async (fecha: string): Promise<RecorridoDBExtended[]> => {
    return fetchRecorridosDeFecha(fecha)
  }, [fetchRecorridosDeFecha])

  // Crear un nuevo recorrido cuando se aplica una ruta optimizada
  const crearRecorrido = useCallback(async (
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
  }, [fetchRecorridosHoy])

  // Completar un recorrido
  const completarRecorrido = useCallback(async (recorridoId: string): Promise<void> => {
    const { error } = await supabase
      .from('recorridos')
      .update({ estado: 'completado', completed_at: new Date().toISOString() })
      .eq('id', recorridoId)

    if (error) throw error
    await fetchRecorridosHoy()
  }, [fetchRecorridosHoy])

  // Obtener resumen de recorridos para estadisticas.
  // useCallback: si no, su referencia cambia en cada render y dispara un loop
  // infinito de fetches en RecorridosContainer (la tenía en las deps de un
  // useEffect vía cargarRecorridos) → ERR_INSUFFICIENT_RESOURCES.
  const getEstadisticasRecorridos = useCallback(async (
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
  }, [])

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
