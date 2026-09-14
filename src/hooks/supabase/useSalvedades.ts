/**
 * Hook para gestión de salvedades en items de pedidos
 * @module hooks/supabase/useSalvedades
 */
import { useState, useCallback } from 'react'
import { supabase, notifyError } from './base'
import { traerTodo } from '../../utils/paginacion'
import { calcularEstadisticasSalvedades } from '../../utils/salvedades'
import type {
  SalvedadItemDBExtended,
  ResolverSalvedadInput,
  EstadisticasSalvedades,
  EstadoResolucionSalvedad,
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

  // Fetch todas las salvedades (para análisis y métricas). Paginado con
  // `traerTodo`: la tabla crece con cada entrega con salvedad y no hay
  // garantía de que se mantenga bajo las 1.000 filas que corta PostgREST.
  const fetchTodasSalvedades = useCallback(async (): Promise<SalvedadItemDBExtended[]> => {
    setLoading(true)
    try {
      const data = await traerTodo(
        () => buildSalvedadesQuery().order('created_at', { ascending: false }).order('id', { ascending: false }),
        { etiqueta: 'las salvedades' },
      )

      const salvedadesData = data.map(transformarSalvedad)
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

  // Obtener estadísticas del universo completo cargado. Para KPIs sobre un
  // subconjunto filtrado, usar calcularEstadisticasSalvedades directamente
  // (ver VistaSalvedades).
  const getEstadisticas = useCallback(async (): Promise<EstadisticasSalvedades> => {
    return calcularEstadisticasSalvedades(salvedades)
  }, [salvedades])

  // Refetch (carga todas las salvedades para análisis completo)
  const refetch = useCallback(async () => {
    await fetchTodasSalvedades()
  }, [fetchTodasSalvedades])

  return {
    salvedades,
    loading,
    resolverSalvedad,
    fetchTodasSalvedades,
    getEstadisticas,
    refetch
  }
}
