/**
 * TanStack Query hooks para Movimientos entre Sucursales (con aprobación).
 *
 * Flujo A→B: la sucursal origen crea un movimiento "pendiente" (no mueve stock);
 * la sucursal destino lo acepta (mueve stock atómico, con matching de productos)
 * o lo deniega. RLS bidireccional: el listado trae tanto entrantes (destino =
 * activa) como salientes (origen = activa).
 *
 * Doble FK a `sucursales` (origen/destino) → hints PostgREST explícitos.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import type { QueryKey } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { fechaLocalISO, fechaHaceDias } from '../../utils/formatters'
import { rangoArgentino } from '../../utils/rangoArgentino'
import { useSucursal } from '../../contexts/SucursalContext'
import type { CondicionIva } from '../../types'

export const MOVIMIENTOS_PAGE_SIZE = 50

export type EstadoMovimiento = 'pendiente' | 'aceptada' | 'denegada' | 'cancelada'

export interface MovimientoSucursalDB {
  id: number
  sucursal_origen_id: number
  sucursal_destino_id: number
  estado: EstadoMovimiento
  total_costo: number
  /** Unidades totales del envío (mig 139): la lista no trae los items. */
  total_unidades: number
  /** true = el origen tiene estas unidades descontadas AHORA (mig 139). */
  stock_descontado: boolean
  notas: string | null
  motivo_rechazo: string | null
  creado_por: string
  resuelto_por: string | null
  editado_por: string | null
  created_at: string
  resuelto_at: string | null
  editado_at: string | null
  origen?: { id: number; nombre: string } | null
  destino?: { id: number; nombre: string } | null
  creador?: { id: string; nombre: string } | null
  /** Quien aceptó, denegó o canceló. */
  resuelto?: { id: string; nombre: string } | null
  editor?: { id: string; nombre: string } | null
}

export interface MovimientoItemDB {
  id: number
  movimiento_id: number
  producto_origen_id: number
  cantidad: number
  origen_nombre: string
  origen_codigo: string | null
  origen_tp_import_id: number | null
  origen_categoria: string | null
  origen_precio: number | null
  origen_precio_sin_iva: number | null
  origen_costo_sin_iva: number | null
  origen_costo_con_iva: number | null
  origen_impuestos_internos: number | null
  origen_porcentaje_iva: number | null
  /** Condición de IVA del origen (mig 177). NULL = movimiento anterior. */
  origen_condicion_iva: CondicionIva | null
  producto_destino_id: number | null
  resolucion: 'match_existente' | 'creado_nuevo' | null
  costo_aplicado_destino: number | null
  /** Asiento de stock. El origen se llena al crear/editar (mig 139); el destino al aceptar. */
  stock_origen_anterior: number | null
  stock_origen_nuevo: number | null
  stock_destino_anterior: number | null
  stock_destino_nuevo: number | null
}

export interface MovimientosFiltros {
  desde?: string
  hasta?: string
  pagina?: number
  estado?: EstadoMovimiento | 'todos'
}

/** Resolución de un item al aceptar. */
export interface ResolucionItem {
  item_id: number
  accion: 'match_existente' | 'crear_nuevo'
  producto_destino_id?: number
}

export const movimientosKeys = {
  all: (s: number | null) => ['movimientos', s] as const,
  lists: (s: number | null) => [...movimientosKeys.all(s), 'list'] as const,
  list: (s: number | null, f: Record<string, unknown>) => [...movimientosKeys.lists(s), f] as const,
  items: (s: number | null, id: string) => [...movimientosKeys.all(s), 'items', id] as const,
}

interface FetchOpts {
  desde: string
  hasta: string
  estado?: EstadoMovimiento | 'todos'
  limit: number
  offset: number
}

/** Una página del listado y cuántos movimientos hay en total con esos filtros. */
export interface PaginaMovimientos {
  movimientos: MovimientoSucursalDB[]
  /** Conteo exacto de PostgREST: el de TODA la lista filtrada, no el de la página. */
  total: number
}

async function fetchMovimientos(opts: FetchOpts): Promise<PaginaMovimientos> {
  // `created_at` es timestamptz: el corte de día tiene que ir en hora
  // Argentina (rangoArgentino, ex-useMermasQuery) o un movimiento cargado
  // después de las 21hs se corre al día siguiente.
  const rango = rangoArgentino({ desde: opts.desde, hasta: opts.hasta })
  // `count: 'exact'` en la MISMA consulta: es lo que le dice a la UI cuántas
  // páginas hay, sin una segunda ida al servidor ni una migración.
  const consultar = (desde: number, hasta: number) => {
    let q = supabase
      .from('movimientos_sucursal')
      .select(`
        *,
        origen:sucursales!sucursal_origen_id(id, nombre),
        destino:sucursales!sucursal_destino_id(id, nombre),
        creador:perfiles!creado_por(id, nombre),
        resuelto:perfiles!resuelto_por(id, nombre),
        editor:perfiles!editado_por(id, nombre)
      `, { count: 'exact' })
      .order('created_at', { ascending: false })
      .range(desde, hasta)

    if (rango.desde) q = q.gte('created_at', rango.desde)
    if (rango.hasta) q = q.lte('created_at', rango.hasta)

    if (opts.estado && opts.estado !== 'todos') {
      q = q.eq('estado', opts.estado)
    }
    return q
  }

  const { data, error, count } = await consultar(opts.offset, opts.offset + opts.limit - 1)
  if (error) {
    if (error.message.includes('does not exist')) return { movimientos: [], total: 0 }
    // Con el conteo pedido, PostgREST contesta 416 (PGRST103) si el offset
    // pasa del final. Pasa justo en el flujo de esta pantalla: se resuelve el
    // último movimiento de la última página y esa página deja de existir. No es
    // un error de verdad: se devuelve vacía con el total, y el container
    // retrocede a la última página que sí existe.
    if (error.code === 'PGRST103' && opts.offset > 0) {
      const primera = await consultar(0, 0)
      if (primera.error) throw primera.error
      return { movimientos: [], total: primera.count ?? 0 }
    }
    throw error
  }
  return { movimientos: (data || []) as MovimientoSucursalDB[], total: count ?? 0 }
}

async function fetchMovimientoItems(movimientoId: string): Promise<MovimientoItemDB[]> {
  const { data, error } = await supabase
    .from('movimiento_sucursal_items')
    .select('*')
    .eq('movimiento_id', movimientoId)
    .order('id', { ascending: true })
  if (error) throw error
  return (data || []) as MovimientoItemDB[]
}

interface RPCResult { success: boolean; movimiento_id?: number; error?: string }

async function crearMovimiento(input: {
  sucursalDestinoId: number
  notas?: string | null
  items: Array<{ producto_id: number; cantidad: number }>
}): Promise<number> {
  const { data, error } = await supabase.rpc('crear_movimiento_sucursal', {
    p_sucursal_destino_id: input.sucursalDestinoId,
    p_notas: input.notas ?? null,
    p_items: input.items,
  })
  if (error) throw error
  const r = data as RPCResult
  if (!r.success) throw new Error(r.error || 'Error al crear el movimiento')
  return r.movimiento_id!
}

async function aceptarMovimiento(input: { movimientoId: number; resoluciones: ResolucionItem[] }): Promise<void> {
  const { data, error } = await supabase.rpc('aceptar_movimiento_sucursal', {
    p_movimiento_id: input.movimientoId,
    p_resoluciones: input.resoluciones,
  })
  if (error) throw error
  const r = data as RPCResult
  if (!r.success) throw new Error(r.error || 'Error al aceptar el movimiento')
}

async function denegarMovimiento(input: { movimientoId: number; motivo?: string | null }): Promise<void> {
  const { data, error } = await supabase.rpc('denegar_movimiento_sucursal', {
    p_movimiento_id: input.movimientoId,
    p_motivo: input.motivo ?? null,
  })
  if (error) throw error
  const r = data as RPCResult
  if (!r.success) throw new Error(r.error || 'Error al denegar el movimiento')
}

/** Cancela un envío pendiente desde el origen y le devuelve el stock (mig 139). */
async function cancelarMovimiento(input: { movimientoId: number; motivo?: string | null }): Promise<void> {
  const { data, error } = await supabase.rpc('cancelar_movimiento_sucursal', {
    p_movimiento_id: input.movimientoId,
    p_motivo: input.motivo ?? null,
  })
  if (error) throw error
  const r = data as RPCResult
  if (!r.success) throw new Error(r.error || 'Error al cancelar el movimiento')
}

/** Edita un envío pendiente desde el origen ajustando el stock por delta (mig 139). */
async function editarMovimiento(input: {
  movimientoId: number
  notas?: string | null
  items: Array<{ producto_id: number; cantidad: number }>
}): Promise<void> {
  const { data, error } = await supabase.rpc('editar_movimiento_sucursal', {
    p_movimiento_id: input.movimientoId,
    p_notas: input.notas ?? null,
    p_items: input.items,
  })
  if (error) throw error
  const r = data as RPCResult
  if (!r.success) throw new Error(r.error || 'Error al editar el movimiento')
}

/**
 * ¿Es la misma lista (misma sucursal, mismo estado, mismas fechas) en otra
 * página? Solo entonces conviene mostrar la página anterior mientras llega la
 * nueva. Si cambió el estado (otra pestaña) los datos viejos serían de otra
 * lista, y es mejor el "Cargando..." de siempre.
 */
function esLaMismaListaEnOtraPagina(previa: QueryKey | undefined, actual: QueryKey): boolean {
  if (!previa || previa[2] !== 'list' || actual[2] !== 'list') return false
  const a = previa[3] as Partial<Record<string, unknown>> | undefined
  const b = actual[3] as Partial<Record<string, unknown>> | undefined
  if (!a || !b) return false
  return previa[1] === actual[1] && a.estado === b.estado && a.desde === b.desde && a.hasta === b.hasta
}

/**
 * Lista paginada en el servidor (`MOVIMIENTOS_PAGE_SIZE` por página).
 *
 * `data` sigue siendo el array de la página, igual que antes del conteo, así
 * que quien solo quería las filas no cambia. El total de TODA la lista filtrada
 * viene aparte en `total` (0 mientras no hay datos): con eso se calculan las
 * páginas.
 */
export function useMovimientosQuery(filtros: MovimientosFiltros = {}) {
  const { currentSucursalId } = useSucursal()
  const desde = filtros.desde ?? fechaHaceDias(60)
  const hasta = filtros.hasta ?? fechaLocalISO()
  const pagina = filtros.pagina ?? 1
  const estado = filtros.estado ?? 'todos'
  const queryKey = movimientosKeys.list(currentSucursalId, { desde, hasta, pagina, estado })
  const query = useQuery({
    // La página va en la key: cada página es su propia entrada de cache.
    queryKey,
    queryFn: () => fetchMovimientos({
      desde, hasta, estado,
      limit: MOVIMIENTOS_PAGE_SIZE,
      offset: (pagina - 1) * MOVIMIENTOS_PAGE_SIZE,
    }),
    staleTime: 60 * 1000,
    // Al pasar de página la lista y el control de páginas no parpadean.
    placeholderData: (previa, consultaPrevia) =>
      esLaMismaListaEnOtraPagina(consultaPrevia?.queryKey, queryKey) ? previa : undefined,
  })
  return { ...query, data: query.data?.movimientos, total: query.data?.total ?? 0 }
}

export function useMovimientoItemsQuery(movimientoId: string | null | undefined) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: movimientosKeys.items(currentSucursalId, movimientoId ?? ''),
    queryFn: () => fetchMovimientoItems(movimientoId!),
    enabled: !!movimientoId,
    staleTime: 30 * 1000,
  })
}

function useInvalidarMovimientos() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return () => {
    // `all` y no `lists`: la edición cambia los items, así que el detalle
    // cacheado (movimientosKeys.items) también tiene que invalidarse.
    queryClient.invalidateQueries({ queryKey: movimientosKeys.all(currentSucursalId) })
    queryClient.invalidateQueries({ queryKey: ['productos'] })
    queryClient.invalidateQueries({ queryKey: ['notificaciones'] })
  }
}

export function useCrearMovimientoMutation() {
  const invalidar = useInvalidarMovimientos()
  return useMutation({ mutationFn: crearMovimiento, onSuccess: invalidar })
}

export function useAceptarMovimientoMutation() {
  const invalidar = useInvalidarMovimientos()
  return useMutation({ mutationFn: aceptarMovimiento, onSuccess: invalidar })
}

export function useDenegarMovimientoMutation() {
  const invalidar = useInvalidarMovimientos()
  return useMutation({ mutationFn: denegarMovimiento, onSuccess: invalidar })
}

export function useCancelarMovimientoMutation() {
  const invalidar = useInvalidarMovimientos()
  return useMutation({ mutationFn: cancelarMovimiento, onSuccess: invalidar })
}

export function useEditarMovimientoMutation() {
  const invalidar = useInvalidarMovimientos()
  return useMutation({ mutationFn: editarMovimiento, onSuccess: invalidar })
}
