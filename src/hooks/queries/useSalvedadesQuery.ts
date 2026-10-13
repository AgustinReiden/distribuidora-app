/**
 * Salvedades de entrega: lista paginada en el servidor, KPIs del mismo filtro
 * y la resolución. Reemplaza al viejo `hooks/supabase/useSalvedades`, que traía
 * TODAS las salvedades y filtraba en el cliente.
 *
 * Qué se ve lo decide la RLS (`mt_salvedades_items_select`, mig 346): admin y
 * encargado, todas las de la sucursal activa; el resto, sólo las de sus
 * pedidos. Ninguna consulta de acá filtra por rol ni por sucursal: la sucursal
 * va en la key para que cambiarla vuelva a consultar.
 *
 * Los filtros se arman en UN lugar (`aplicarFiltrosSalvedades`) y los usan la
 * página y los KPIs: así el número de las tarjetas es, por construcción, el de
 * la lista que se está mirando.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import type { QueryKey } from '@tanstack/react-query'
import { supabase, notifyError } from '../supabase/base'
import { traerTodo } from '../../utils/paginacion'
import { rangoArgentino } from '../../utils/rangoArgentino'
import { calcularEstadisticasSalvedades, type FilaEstadisticaSalvedad } from '../../utils/salvedades'
import { errorDeSupabase, type ErrorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'
import type {
  SalvedadItemDBExtended,
  ResolverSalvedadInput,
  EstadisticasSalvedades,
  EstadoResolucionSalvedad,
  MotivoSalvedad,
} from '../../types'

export const SALVEDADES_PAGE_SIZE = 20

export interface SalvedadesFiltros {
  /** 'pendientes' muestra todas las pendientes, de cualquier fecha: una vieja no se esconde. */
  estado: 'pendientes' | 'todas'
  motivo: MotivoSalvedad | 'todos'
  /** 'YYYY-MM-DD', día argentino, sobre `created_at`. Sólo rige con estado 'todas'. */
  desde: string
  hasta: string
  /** `pedidos.transportista_id` del pedido de la salvedad. `null` = todos. */
  transportistaId: string | null
}

export const salvedadesKeys = {
  all: ['salvedades'] as const,
  sucursal: (s: number | null) => [...salvedadesKeys.all, s] as const,
  lista: (s: number | null, f: SalvedadesFiltros, pagina: number) =>
    [...salvedadesKeys.sucursal(s), 'lista', f, pagina] as const,
  estadisticas: (s: number | null, f: SalvedadesFiltros) =>
    [...salvedadesKeys.sucursal(s), 'estadisticas', f] as const,
}

// Los hints hacia productos/pedidos/clientes son el NOMBRE DEL CONSTRAINT, no
// el de la columna: esas FKs son compuestas (`(producto_id, sucursal_id)`,
// aislamiento por sucursal) y `productos!producto_id` da PGRST200 en prod
// (#1008). `pedidos` además tiene dos FKs desde acá (`pedido_id` y
// `pedido_reprogramado_id`), así que sin hint sería PGRST201. Los hints a
// `perfiles` sí son por columna: esas FKs son simples. Lo vigila
// `scripts/check-embeds.mjs` contra prod.
export const SALVEDADES_SELECT = `
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
`

// Igual, con el pedido `!inner`: es lo que deja filtrar por
// `pedido.transportista_id`. Sólo se usa con ese filtro puesto, porque `!inner`
// descarta la salvedad cuyo pedido no se ve, y sin filtro no hay por qué.
export const SALVEDADES_SELECT_POR_TRANSPORTISTA = `
  *,
  producto:productos!salvedades_items_producto_id_fkey(id, nombre, codigo),
  pedido:pedidos!salvedades_items_pedido_id_fkey!inner(
    id,
    total,
    estado,
    transportista_id,
    cliente:clientes!pedidos_cliente_id_fkey(id, nombre_fantasia)
  ),
  reportado:perfiles!reportado_por(id, nombre),
  resuelto:perfiles!resuelto_por(id, nombre)
`

// Los KPIs sólo necesitan estas dos columnas de cada fila filtrada.
export const SALVEDADES_SELECT_KPI = 'estado_resolucion, monto_afectado'
export const SALVEDADES_SELECT_KPI_POR_TRANSPORTISTA =
  'estado_resolucion, monto_afectado, pedido:pedidos!salvedades_items_pedido_id_fkey!inner(transportista_id)'

/** Lo mínimo del builder de PostgREST que usan los filtros (para tipar sin atarse a supabase-js). */
interface FiltrableSalvedades<Q> {
  eq(columna: string, valor: unknown): Q
  gte(columna: string, valor: unknown): Q
  lte(columna: string, valor: unknown): Q
}

/**
 * Los filtros de la pantalla, en UN lugar: los usan la página y los KPIs.
 * La fecha corta en día argentino (`rangoArgentino`), no en UTC: una salvedad
 * cargada después de las 21 hs es del día en que se cargó.
 */
export function aplicarFiltrosSalvedades<Q extends FiltrableSalvedades<Q>>(q: Q, f: SalvedadesFiltros): Q {
  if (f.estado === 'pendientes') {
    q = q.eq('estado_resolucion', 'pendiente')
  } else {
    const rango = rangoArgentino({ desde: f.desde, hasta: f.hasta })
    if (rango.desde) q = q.gte('created_at', rango.desde)
    if (rango.hasta) q = q.lte('created_at', rango.hasta)
  }
  if (f.motivo !== 'todos') q = q.eq('motivo', f.motivo)
  if (f.transportistaId) q = q.eq('pedido.transportista_id', f.transportistaId)
  return q
}

/**
 * Normaliza el error de supabase-js, lo avisa por toast y devuelve el Error para lanzarlo (#1081).
 * Sin servidor el mensaje "Sin conexión: ..." ya dice todo; con servidor se conserva el prefijo.
 */
function errorNotificado(error: unknown, prefijo: string, mensajeSinConexion: string): ErrorDeSupabase {
  const normalizado = errorDeSupabase(error, mensajeSinConexion)
  notifyError(normalizado.sinServidor ? normalizado.message : prefijo + ': ' + normalizado.message)
  return normalizado
}

// Transformar datos para compatibilidad con tipos extendidos
const transformarSalvedad = (s: any, nombresTransportistas: Map<string, string>): SalvedadItemDBExtended => ({
  ...s,
  producto_nombre: s.producto?.nombre,
  producto_codigo: s.producto?.codigo,
  cliente_nombre: s.pedido?.cliente?.nombre_fantasia,
  transportista_id: s.pedido?.transportista_id,
  transportista_nombre: s.pedido?.transportista_id ? nombresTransportistas.get(String(s.pedido.transportista_id)) : undefined,
  pedido_estado: s.pedido?.estado,
  pedido_total: s.pedido?.total,
  reportado_por_nombre: s.reportado?.nombre,
  resuelto_por_nombre: s.resuelto?.nombre
})

// Nombre del transportista de cada pedido (#1072). Consulta plana a perfiles y
// no un embed: `pedidos` no tiene FK a `perfiles`, así que embeberlo daría
// PGRST200 y tumbaría la consulta entera (trampa 5). Si esta consulta falla,
// se avisa y la lista carga igual con el nombre vacío (los componentes
// muestran '-'): no se lanza, porque la página entera quedaría en error.
async function traerNombresTransportistas(data: any[]): Promise<Map<string, string>> {
  const nombres = new Map<string, string>()
  const ids = [...new Set(
    data.map(s => s.pedido?.transportista_id).filter(Boolean).map(String),
  )]
  if (ids.length === 0) return nombres
  const { data: perfiles, error } = await supabase.from('perfiles').select('id, nombre').in('id', ids)
  if (error) {
    errorNotificado(error, 'Error al cargar los transportistas', 'Sin conexión: no se pudieron cargar los nombres de los transportistas.')
    return nombres
  }
  for (const p of (perfiles ?? []) as Array<{ id: string; nombre: string | null }>) {
    if (p.nombre) nombres.set(String(p.id), p.nombre)
  }
  return nombres
}

/** Una página y cuántas salvedades hay en total con esos filtros. */
export interface PaginaSalvedades {
  salvedades: SalvedadItemDBExtended[]
  /** Conteo exacto de PostgREST: el de TODA la lista filtrada, no el de la página. */
  total: number
}

const SIN_CONEXION_LISTA = 'Sin conexión: no se pudieron cargar las salvedades. Revisá la señal e intentá de nuevo.'

export async function fetchSalvedadesPagina(f: SalvedadesFiltros, pagina: number): Promise<PaginaSalvedades> {
  const consultar = (desde: number, hasta: number) => {
    // Cada rama con su from + select completo, con la constante por nombre: así
    // el gate de embeds (scripts/check-embeds.mjs) prueba los dos contra prod.
    const base = f.transportistaId
      ? supabase.from('salvedades_items').select(SALVEDADES_SELECT_POR_TRANSPORTISTA, { count: 'exact' })
      : supabase.from('salvedades_items').select(SALVEDADES_SELECT, { count: 'exact' })
    return aplicarFiltrosSalvedades(base, f)
      .order('created_at', { ascending: false })
      .order('id', { ascending: false })
      .range(desde, hasta)
  }

  const desde = (pagina - 1) * SALVEDADES_PAGE_SIZE
  const { data, error, count } = await consultar(desde, desde + SALVEDADES_PAGE_SIZE - 1)
  if (error) {
    // Con el conteo pedido, PostgREST contesta 416 (PGRST103) si el offset
    // pasa del final. Pasa en esta pantalla: se resuelve la última pendiente de
    // la última página y esa página deja de existir. Se devuelve vacía con el
    // total y la vista retrocede a la última página que sí existe.
    if (error.code === 'PGRST103' && desde > 0) {
      const primera = await consultar(0, 0)
      if (primera.error) throw errorDeSupabase(primera.error, SIN_CONEXION_LISTA)
      return { salvedades: [], total: primera.count ?? 0 }
    }
    throw errorDeSupabase(error, SIN_CONEXION_LISTA)
  }
  const filas = data ?? []
  const nombres = await traerNombresTransportistas(filas)
  return { salvedades: filas.map(s => transformarSalvedad(s, nombres)), total: count ?? 0 }
}

/**
 * KPIs de TODA la lista filtrada, no de la página: trae sólo estado y monto de
 * cada fila (con los mismos filtros y la misma RLS) y los pasa por
 * `calcularEstadisticasSalvedades`. Paginado con `traerTodo` por el corte de
 * 1.000 filas de PostgREST.
 */
export async function fetchEstadisticasSalvedades(f: SalvedadesFiltros): Promise<EstadisticasSalvedades> {
  const filas = await traerTodo<FilaEstadisticaSalvedad>(
    () => {
      const base = f.transportistaId
        ? supabase.from('salvedades_items').select(SALVEDADES_SELECT_KPI_POR_TRANSPORTISTA)
        : supabase.from('salvedades_items').select(SALVEDADES_SELECT_KPI)
      return aplicarFiltrosSalvedades(base, f)
        .order('created_at', { ascending: false })
        .order('id', { ascending: false })
    },
    { etiqueta: 'las salvedades' },
  )
  return calcularEstadisticasSalvedades(filas)
}

/**
 * ¿Es la misma lista (sucursal y filtros) en otra página? Sólo entonces se
 * muestra la página anterior mientras llega la nueva: con otro filtro, los
 * datos viejos serían de otra lista.
 */
function esLaMismaListaEnOtraPagina(previa: QueryKey | undefined, actual: QueryKey): boolean {
  if (!previa || previa[2] !== 'lista' || actual[2] !== 'lista') return false
  return previa[1] === actual[1] && JSON.stringify(previa[3]) === JSON.stringify(actual[3])
}

/** Una página de salvedades (`SALVEDADES_PAGE_SIZE`) con el total de la lista filtrada. */
export function useSalvedadesQuery(filtros: SalvedadesFiltros, pagina: number) {
  const { currentSucursalId } = useSucursal()
  const queryKey = salvedadesKeys.lista(currentSucursalId, filtros, pagina)
  const query = useQuery({
    queryKey,
    queryFn: () => fetchSalvedadesPagina(filtros, pagina),
    // Sin staleTime: volver a la pantalla vuelve a consultar (como la vista
    // vieja, que recargaba al abrirse). Registrar una salvedad desde Pedidos no
    // invalida esta key, así que con cache "fresca" la nueva no aparecía.
    placeholderData: (previa, consultaPrevia) =>
      esLaMismaListaEnOtraPagina(consultaPrevia?.queryKey, queryKey) ? previa : undefined,
  })
  return { ...query, data: query.data?.salvedades, total: query.data?.total ?? 0 }
}

/** KPIs de la lista filtrada entera. La página no entra en la key: no cambia el número. */
export function useEstadisticasSalvedadesQuery(filtros: SalvedadesFiltros) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: salvedadesKeys.estadisticas(currentSucursalId, filtros),
    queryFn: () => fetchEstadisticasSalvedades(filtros),
  })
}

// Resolver salvedad (admin o encargado desde la mig 252: resolver no mueve
// stock ni plata, sólo dice quien se hace cargo). El espejo en la UI es
// `puedeResolverSalvedad`.
async function resolverSalvedad(input: ResolverSalvedadInput): Promise<{ success: boolean; nuevoEstado: EstadoResolucionSalvedad }> {
  const { data, error } = await supabase.rpc('resolver_salvedad', {
    p_salvedad_id: parseInt(input.salvedadId, 10),
    p_estado_resolucion: input.estadoResolucion,
    p_notas: input.notas || null,
    p_pedido_reprogramado_id: input.pedidoReprogramadoId ? parseInt(input.pedidoReprogramadoId, 10) : null
  })

  if (error) {
    // Toast y throw salen del error normalizado (#1081): el `.message` crudo de supabase-js en un
    // fallo de red es "TypeError: Failed to fetch". Sin servidor, "Sin conexión: ..." ya lo dice todo.
    throw errorNotificado(error, 'Error al resolver salvedad', 'Sin conexión: no se pudo confirmar la resolución de la salvedad. Revisá si quedó hecha antes de reintentar.')
  }

  const result = data as { success?: boolean; error?: string; nuevo_estado?: EstadoResolucionSalvedad } | null

  if (!result?.success) {
    notifyError(result?.error || 'Error al resolver salvedad')
    throw new Error(result?.error)
  }

  return {
    success: true,
    nuevoEstado: result.nuevo_estado || input.estadoResolucion
  }
}

/** Al resolver, invalida la lista y los KPIs (todas las páginas y filtros) y espera el refresco. */
export function useResolverSalvedadMutation() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: resolverSalvedad,
    // Se devuelve la promesa: `mutateAsync` (y el modal que se cierra con él)
    // espera a que la lista y los KPIs estén refrescados.
    onSuccess: () => queryClient.invalidateQueries({ queryKey: salvedadesKeys.all }),
  })
}
