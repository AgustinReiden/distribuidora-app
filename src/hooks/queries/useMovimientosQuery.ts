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
import { supabase } from '../supabase/base'
import { fechaLocalISO, fechaHaceDias } from '../../utils/formatters'
import { useSucursal } from '../../contexts/SucursalContext'

export const MOVIMIENTOS_PAGE_SIZE = 50

export type EstadoMovimiento = 'pendiente' | 'aceptada' | 'denegada'

export interface MovimientoSucursalDB {
  id: number
  sucursal_origen_id: number
  sucursal_destino_id: number
  estado: EstadoMovimiento
  total_costo: number
  notas: string | null
  motivo_rechazo: string | null
  creado_por: string
  resuelto_por: string | null
  created_at: string
  resuelto_at: string | null
  origen?: { id: number; nombre: string } | null
  destino?: { id: number; nombre: string } | null
  creador?: { id: string; nombre: string } | null
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
  producto_destino_id: number | null
  resolucion: 'match_existente' | 'creado_nuevo' | null
  costo_aplicado_destino: number | null
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

async function fetchMovimientos(opts: FetchOpts): Promise<MovimientoSucursalDB[]> {
  let q = supabase
    .from('movimientos_sucursal')
    .select(`
      *,
      origen:sucursales!sucursal_origen_id(id, nombre),
      destino:sucursales!sucursal_destino_id(id, nombre),
      creador:perfiles!creado_por(id, nombre)
    `)
    .gte('created_at', `${opts.desde}T00:00:00`)
    .lte('created_at', `${opts.hasta}T23:59:59`)
    .order('created_at', { ascending: false })
    .range(opts.offset, opts.offset + opts.limit - 1)

  if (opts.estado && opts.estado !== 'todos') {
    q = q.eq('estado', opts.estado)
  }

  const { data, error } = await q
  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data || []) as MovimientoSucursalDB[]
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

export function useMovimientosQuery(filtros: MovimientosFiltros = {}) {
  const { currentSucursalId } = useSucursal()
  const desde = filtros.desde ?? fechaHaceDias(60)
  const hasta = filtros.hasta ?? fechaLocalISO()
  const pagina = filtros.pagina ?? 1
  const estado = filtros.estado ?? 'todos'
  return useQuery({
    queryKey: movimientosKeys.list(currentSucursalId, { desde, hasta, pagina, estado }),
    queryFn: () => fetchMovimientos({
      desde, hasta, estado,
      limit: MOVIMIENTOS_PAGE_SIZE,
      offset: (pagina - 1) * MOVIMIENTOS_PAGE_SIZE,
    }),
    staleTime: 60 * 1000,
  })
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
    queryClient.invalidateQueries({ queryKey: movimientosKeys.lists(currentSucursalId) })
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
