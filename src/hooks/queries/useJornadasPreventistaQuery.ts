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
 */
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
  salvedades: SalvedadResumen[]
}

export interface PendientesResumen {
  total: number
  monto: number
  /** Fecha del pedido colgado más viejo. Null si no hay ninguno. */
  mas_viejo: string | null
}

export interface JornadasResultado {
  preventista_id: string
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
  rango: (sucursalId: number | null, preventistaId: string | null, desde: string, hasta: string) =>
    [...jornadasKeys.all(sucursalId), preventistaId ?? 'yo', desde, hasta] as const,
  detalle: (sucursalId: number | null, preventistaId: string | null, dia: string | null) =>
    [...jornadasKeys.all(sucursalId), preventistaId ?? 'yo', 'detalle', dia ?? 'pendientes'] as const,
}

// =============================================================================
// HOOKS
// =============================================================================

async function fetchJornadas(
  desde: string,
  hasta: string,
  preventistaId: string | null,
): Promise<JornadasResultado> {
  const { data, error } = await supabase.rpc('jornadas_preventista', {
    p_desde: desde,
    p_hasta: hasta,
    p_preventista_id: preventistaId,
  })

  if (error) throw error
  return data as JornadasResultado
}

/** Resumen por día. Liviano: una fila por día, sin los pedidos. */
export function useJornadasPreventistaQuery(
  desde: string,
  hasta: string,
  preventistaId: string | null = null,
  enabled = true,
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: jornadasKeys.rango(currentSucursalId, preventistaId, desde, hasta),
    queryFn: () => fetchJornadas(desde, hasta, preventistaId),
    enabled: enabled && Boolean(desde) && Boolean(hasta),
    staleTime: 2 * 60 * 1000,
  })
}

async function fetchDetalle(
  dia: string | null,
  preventistaId: string | null,
): Promise<PedidoDelDia[]> {
  const { data, error } = await supabase.rpc('jornada_preventista_detalle', {
    p_dia: dia,
    p_preventista_id: preventistaId,
  })

  if (error) throw error
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
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: jornadasKeys.detalle(currentSucursalId, preventistaId, dia),
    queryFn: () => fetchDetalle(dia, preventistaId),
    enabled,
    staleTime: 2 * 60 * 1000,
  })
}
