/**
 * Panel "Mis entregas": qué pasó, día por día, con los pedidos que tomó el
 * preventista (migs 179).
 *
 * Sale de dos RPC y no de PostgREST, por tres razones que no son de estilo:
 *
 * - El día del reparto hay que derivarlo. `fecha_entrega_programada` coincide
 *   con la entrega real sólo el 52% de las veces, y un cancelado ni siquiera
 *   tiene `fecha_entrega` (NULL en 266 de 271): el día del rechazo vive en
 *   `pedido_historial`.
 * - La RLS de `clientes` acota al preventista a los clientes asignados a él
 *   (`cliente_preventistas`), así que por PostgREST unos cuantos pedidos
 *   propios volverían con el cliente en null. Un panel que se llama "a qué
 *   clientes se les entregó" no puede tener filas sin nombre.
 * - `salvedades_items` tiene DOS FKs a `pedidos` (`pedido_id` y
 *   `pedido_reprogramado_id`): embeberla da PGRST201 y rompe la consulta
 *   entera. Es la misma forma que tumbó "Armar ruta" en prod.
 *
 * CONTRATO DE PERMISOS (igual que `avance_metas_preventista`):
 * `p_preventista_id: null` = el usuario logueado. Pasar otro id devuelve
 * 42501 salvo que quien pregunta sea admin o encargado.
 *
 * MODO REPARTO (#723): las mismas preguntas sobre lo que el usuario REPARTIÓ,
 * con `jornadas_transportista` / `jornada_transportista_detalle`: el dueño del
 * pedido es `pedidos.transportista_id` en vez de `usuario_id`. Misma forma de
 * salida y mismo contrato (`p_transportista_id: null` = yo); además la RPC
 * rechaza a quien no es transportista ni admin/encargado.
 */
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useQuery } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { Desenlace } from '../../constants/desenlacePedido'

// =============================================================================
// TYPES
// =============================================================================

export interface ResumenDia {
  /** YYYY-MM-DD del día de reparto (entrega o caída), no el de la carga. */
  dia: string
  total: number
  /** Incluye los entregados con salvedad. */
  entregados: number
  con_salvedad: number
  rechazados: number
  /** Cancelados por error de carga, prueba, duplicado, unificación o cambio
   *  de cliente. No son rechazos y no cuentan como tales. */
  administrativos: number
  monto_entregado: number
  monto_rechazado: number
}

export interface SalvedadResumen {
  producto: string
  cantidad_afectada: number
  cantidad_original: number
  motivo: string
  descripcion: string | null
  monto_afectado: number
}

/** De quién son los pedidos: los que vendió o los que repartió (#723). */
export type ModoJornadas = 'vendedor' | 'reparto'

const RPC_DE: Record<ModoJornadas, { resumen: string; detalle: string; param: string }> = {
  vendedor: { resumen: 'jornadas_preventista', detalle: 'jornada_preventista_detalle', param: 'p_preventista_id' },
  reparto: { resumen: 'jornadas_transportista', detalle: 'jornada_transportista_detalle', param: 'p_transportista_id' },
}

export interface PedidoDelDia {
  pedido_id: number
  cliente: string
  monto: number
  desenlace: Desenlace
  estado: string
  /** Día en que el preventista cargó el pedido (puede ser muy anterior). */
  fecha_pedido: string
  motivo_tipo: string | null
  motivo_nota: string | null
  transportista: string | null
  /** Quién tomó el pedido. Sólo en modo reparto, donde el transportista es uno mismo. */
  vendedor?: string | null
  salvedades: SalvedadResumen[]
}

export interface PendientesResumen {
  total: number
  monto: number
  /** Fecha del pedido colgado más viejo. Null si no hay ninguno. */
  mas_viejo: string | null
}

export interface JornadasResultado {
  /** Modo vendedor. */
  preventista_id?: string
  /** Modo reparto. */
  transportista_id?: string
  nombre: string | null
  desde: string
  hasta: string
  dias: ResumenDia[]
  totales: {
    entregados: number
    rechazados: number
    pct_rechazo: number
    monto_rechazado: number
  }
  pendientes: PendientesResumen
}

// =============================================================================
// QUERY KEYS
// =============================================================================

export const jornadasKeys = {
  all: (sucursalId: number | null) => ['jornadas-preventista', sucursalId] as const,
  rango: (sucursalId: number | null, preventistaId: string | null, desde: string, hasta: string, modo: ModoJornadas = 'vendedor') =>
    [...jornadasKeys.all(sucursalId), modo, preventistaId ?? 'yo', desde, hasta] as const,
  detalle: (sucursalId: number | null, preventistaId: string | null, dia: string | null, modo: ModoJornadas = 'vendedor') =>
    [...jornadasKeys.all(sucursalId), modo, preventistaId ?? 'yo', 'detalle', dia ?? 'pendientes'] as const,
}

// =============================================================================
// HOOKS
// =============================================================================

async function fetchJornadas(
  desde: string,
  hasta: string,
  preventistaId: string | null,
  modo: ModoJornadas,
): Promise<JornadasResultado> {
  const rpc = RPC_DE[modo]
  const { data, error } = await supabase.rpc(rpc.resumen, {
    p_desde: desde,
    p_hasta: hasta,
    [rpc.param]: preventistaId,
  })

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar las jornadas. Revisá la señal e intentá de nuevo.')
  return data as JornadasResultado
}

/**
 * Resumen por día. Liviano: una fila por día, sin los pedidos.
 * `preventistaId` es el dueño en el modo elegido (null = yo).
 */
export function useJornadasPreventistaQuery(
  desde: string,
  hasta: string,
  preventistaId: string | null = null,
  enabled = true,
  modo: ModoJornadas = 'vendedor',
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: jornadasKeys.rango(currentSucursalId, preventistaId, desde, hasta, modo),
    queryFn: () => fetchJornadas(desde, hasta, preventistaId, modo),
    enabled: enabled && Boolean(desde) && Boolean(hasta),
    staleTime: 2 * 60 * 1000,
  })
}

async function fetchDetalle(
  dia: string | null,
  preventistaId: string | null,
  modo: ModoJornadas,
): Promise<PedidoDelDia[]> {
  const rpc = RPC_DE[modo]
  const { data, error } = await supabase.rpc(rpc.detalle, {
    p_dia: dia,
    [rpc.param]: preventistaId,
  })

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el detalle de la jornada. Revisá la señal e intentá de nuevo.')
  return (data as PedidoDelDia[]) ?? []
}

/**
 * Detalle de un día, al expandir la tarjeta. `dia = null` devuelve el bucket
 * de pedidos sin desenlace.
 *
 * Se pide on-expand y no todo junto porque son 30 días × ~14 pedidos y esta
 * pantalla se abre desde el teléfono, en la calle.
 */
export function useJornadaDetalleQuery(
  dia: string | null,
  preventistaId: string | null = null,
  enabled = true,
  modo: ModoJornadas = 'vendedor',
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: jornadasKeys.detalle(currentSucursalId, preventistaId, dia, modo),
    queryFn: () => fetchDetalle(dia, preventistaId, modo),
    enabled,
    staleTime: 2 * 60 * 1000,
  })
}
