/**
 * Hook para gestión de salvedades en items de pedidos
 * @module hooks/supabase/useSalvedades
 */
import { useState, useCallback } from 'react'
import { supabase, notifyError } from './base'
import { traerTodo } from '../../utils/paginacion'
import { calcularEstadisticasSalvedades } from '../../utils/salvedades'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
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
  //
  // Los hints hacia productos/pedidos/clientes son el NOMBRE DEL CONSTRAINT, no
  // el de la columna: esas FKs son compuestas (`(producto_id, sucursal_id)`,
  // aislamiento por sucursal) y `productos!producto_id` da PGRST200 en prod
  // (#1008). `pedidos` además tiene dos FKs desde acá (`pedido_id` y
  // `pedido_reprogramado_id`), así que sin hint sería PGRST201. Los hints a
  // `perfiles` sí son por columna: esas FKs son simples. Lo vigila
  // `scripts/check-embeds.mjs` contra prod.
  const buildSalvedadesQuery = () => {
    return supabase
      .from('salvedades_items')
      .select(`
        *,
        producto:productos!salvedades_items_producto_id_fkey(id, nombre, codigo),
        pedido:pedidos!salvedades_items_pedido_id_fkey(
          id,
          total,
          estado,
          transportista_id,
          cliente:clientes!pedidos_cliente_id_fkey(id, nombre_fantasia)
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

  // Resolver salvedad (admin o encargado desde la mig 252: resolver no mueve
  // stock ni plata, sólo dice quien se hace cargo). El espejo en la UI es
  // `puedeResolverSalvedad`.
  const resolverSalvedad = async (input: ResolverSalvedadInput): Promise<{ success: boolean; nuevoEstado: EstadoResolucionSalvedad }> => {
    const { data, error } = await supabase.rpc('resolver_salvedad', {
      p_salvedad_id: parseInt(input.salvedadId, 10),
      p_estado_resolucion: input.estadoResolucion,
      p_notas: input.notas || null,
      p_pedido_reprogramado_id: input.pedidoReprogramadoId ? parseInt(input.pedidoReprogramadoId, 10) : null
    })

    if (error) {
      notifyError('Error al resolver salvedad: ' + error.message)
      throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la resolución de la salvedad. Revisá si quedó hecha antes de reintentar.')
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
