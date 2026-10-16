/**
 * TanStack Query para los combos (#1191).
 *
 * Los combos vigentes los da la RPC `combos_vigentes` (SECURITY DEFINER: el tope
 * suma los pedidos de todos los vendedores). La foto de los combos de un pedido
 * (`pedido_combos`) se lee por REST: quien ve el pedido ve su foto. Escribir un
 * combo es de `guardar_combo` (admin).
 */
import { useEffect, useState } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { cacheData, getCachedData } from '../../lib/offlineDb'
import { fechaLocalISO } from '../../utils/formatters'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'
import type { ComboComponente, ComboVigente } from '../../utils/combos'
import type { LugarCombo } from '../../utils/comboCategorias'

export const combosKeys = {
  all: (sucursalId: number | null) => ['combos', sucursalId] as const,
  vigentes: (sucursalId: number | null, fecha?: string, pedidoId?: string) =>
    [...combosKeys.all(sucursalId), 'vigentes', fecha ?? 'today', pedidoId ?? null] as const,
  fotos: (sucursalId: number | null, pedidoId?: string) =>
    [...combosKeys.all(sucursalId), 'fotos', pedidoId ?? null] as const,
  lista: (sucursalId: number | null) => [...combosKeys.all(sucursalId), 'lista'] as const,
}

interface ComponenteDB {
  componente: number | string
  cantidad: number | string
  productos: Array<number | string>
}

function componentesDe(raw: unknown): ComboComponente[] {
  if (!Array.isArray(raw)) return []
  return (raw as ComponenteDB[]).map(c => ({
    componente: Number(c.componente),
    cantidad: Number(c.cantidad),
    productos: (c.productos ?? []).map(String),
  }))
}

interface ComboVigenteDB {
  id: number | string
  nombre: string
  precio: number | string
  combina_escalas: boolean
  prioridad: number | null
  componentes: unknown
  tope_restante: number | null
}

export async function fetchCombosVigentes(fecha?: string, pedidoId?: string): Promise<ComboVigente[]> {
  const { data, error } = await supabase.rpc('combos_vigentes', {
    p_fecha: fecha ?? null,
    p_pedido_id: pedidoId ? Number(pedidoId) : null,
  })
  if (error) throw errorDeSupabase(error, 'No se pudieron cargar los combos')
  return ((data as ComboVigenteDB[] | null) ?? []).map(c => ({
    id: String(c.id),
    nombre: c.nombre,
    precio: Number(c.precio),
    combinaEscalas: Boolean(c.combina_escalas),
    prioridad: Number(c.prioridad ?? 0),
    componentes: componentesDe(c.componentes),
    topeRestante: c.tope_restante == null ? null : Number(c.tope_restante),
  }))
}

/**
 * Combos vigentes en `fecha` (YYYY-MM-DD; sin fecha, hoy). En la edición,
 * `pedidoId` no cuenta los combos de ese pedido contra el tope.
 * `enabled: false` para lo que no lleva combos (un vale blanco).
 */
export function useCombosVigentesQuery(fecha?: string, pedidoId?: string, enabled = true) {
  const { currentSucursalId } = useSucursal()
  // Sin señal (#1194): los últimos combos que este teléfono vio para esa fecha,
  // guardados en Dexie como la política comercial. Sirven para armar y sugerir
  // combos offline; si al sincronizar el server rechaza uno (vencido, tope),
  // la cola ofrece "Sincronizar sin los combos" (#1191). Un caché de otro día
  // no se usa: un combo de ayer puede haber terminado.
  const dia = fecha ?? fechaLocalISO()
  const [cacheado, setCacheado] = useState<ComboVigente[] | null>(null)
  useEffect(() => {
    if (!enabled) return
    let vigente = true
    getCachedData<CacheCombos>(CACHE_COMBOS, currentSucursalId)
      .then(v => { if (vigente && v && v.fecha === dia) setCacheado(v.combos) })
      .catch(() => { /* sin caché, sin combos offline */ })
    return () => { vigente = false }
  }, [currentSucursalId, dia, enabled])

  const query = useQuery({
    queryKey: combosKeys.vigentes(currentSucursalId, fecha, pedidoId),
    queryFn: async () => {
      const combos = await fetchCombosVigentes(fecha, pedidoId)
      // Sólo la consulta general: la de una edición no cuenta el propio pedido
      // contra el tope y no sirve para otro.
      if (!pedidoId) {
        await cacheData(CACHE_COMBOS, { fecha: dia, combos } satisfies CacheCombos, undefined, currentSucursalId)
          .catch(() => { /* que falle el caché no rompe el pedido */ })
      }
      return combos
    },
    staleTime: 5 * 60 * 1000,
    enabled,
  })

  return {
    ...query,
    data: query.data ?? cacheado ?? undefined,
    isLoading: query.isLoading && !cacheado,
  }
}

const CACHE_COMBOS = 'combos_vigentes'
interface CacheCombos {
  fecha: string
  combos: ComboVigente[]
}

export type FotoCombo = ComboVigente & { cantidadCombos: number }

interface FotoComboDB {
  combo_id: number | string
  nombre: string
  precio: number | string
  combina_escalas: boolean
  componentes: unknown
  cantidad_combos: number
}

export async function fetchFotosCombosPedido(pedidoId: string): Promise<FotoCombo[]> {
  const { data, error } = await supabase
    .from('pedido_combos')
    .select('combo_id, nombre, precio, combina_escalas, componentes, cantidad_combos')
    .eq('pedido_id', Number(pedidoId))
  if (error) throw errorDeSupabase(error, 'No se pudieron cargar los combos del pedido')
  return ((data as FotoComboDB[] | null) ?? []).map(f => ({
    id: String(f.combo_id),
    nombre: f.nombre,
    precio: Number(f.precio),
    combinaEscalas: Boolean(f.combina_escalas),
    prioridad: 0,
    componentes: componentesDe(f.componentes),
    topeRestante: null,
    cantidadCombos: Number(f.cantidad_combos),
  }))
}

/** La foto de los combos que un pedido ya tiene (para conservarlos al editarlo). */
export function useFotosCombosPedidoQuery(pedidoId?: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: combosKeys.fotos(currentSucursalId, pedidoId),
    queryFn: () => fetchFotosCombosPedido(pedidoId as string),
    enabled: Boolean(pedidoId),
    staleTime: 60 * 1000,
  })
}

/**
 * Nombre de cada combo de la sucursal, por id: para rotular las líneas de combo
 * de un pedido guardado (la tarjeta, el remito). Incluye los inactivos: un
 * pedido viejo puede tener un combo que ya terminó.
 */
export function useNombresCombosQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: [...combosKeys.all(currentSucursalId), 'nombres'] as const,
    queryFn: async (): Promise<Map<string, string>> => {
      const { data, error } = await supabase.from('combos').select('id, nombre')
      if (error) throw errorDeSupabase(error, 'No se pudieron cargar los combos')
      return new Map(((data as { id: number | string; nombre: string }[] | null) ?? []).map(c => [String(c.id), c.nombre]))
    },
    staleTime: 10 * 60 * 1000,
  })
}

// =============================================================================
// ADMIN
// =============================================================================

export interface ComboAdmin {
  id: string
  nombre: string
  activo: boolean
  fechaInicio: string
  fechaFin: string | null
  precio: number
  combinaEscalas: boolean
  prioridad: number
  topeCombos: number | null
  productoAMoverId: string | null
  /** Cada lugar: productos sueltos y categorías vivas (#1213). Lo que vende lo da `resolverLugares`. */
  componentes: LugarCombo[]
}

interface ComboAdminDB {
  id: number | string
  nombre: string
  activo: boolean
  fecha_inicio: string
  fecha_fin: string | null
  precio: number | string
  combina_escalas: boolean
  prioridad: number | null
  tope_combos: number | null
  producto_a_mover_id: number | string | null
  combo_componentes: { componente: number; producto_id: number | string | null; categoria_id: string | null; cantidad: number }[] | null
}

export async function fetchCombosAdmin(): Promise<ComboAdmin[]> {
  const { data, error } = await supabase
    .from('combos')
    .select('id, nombre, activo, fecha_inicio, fecha_fin, precio, combina_escalas, prioridad, tope_combos, producto_a_mover_id, combo_componentes(componente, producto_id, categoria_id, cantidad)')
    .order('activo', { ascending: false })
    .order('fecha_inicio', { ascending: false })
  if (error) throw errorDeSupabase(error, 'No se pudieron cargar los combos')
  return ((data as ComboAdminDB[] | null) ?? []).map(c => {
    const porLugar = new Map<number, { cantidad: number; sueltos: string[]; categorias: string[] }>()
    for (const cc of [...(c.combo_componentes ?? [])].sort((a, b) => a.componente - b.componente)) {
      const lugar = porLugar.get(cc.componente) ?? { cantidad: Number(cc.cantidad), sueltos: [], categorias: [] }
      if (cc.producto_id != null) lugar.sueltos.push(String(cc.producto_id))
      if (cc.categoria_id != null) lugar.categorias.push(String(cc.categoria_id))
      porLugar.set(cc.componente, lugar)
    }
    return {
      id: String(c.id),
      nombre: c.nombre,
      activo: Boolean(c.activo),
      fechaInicio: c.fecha_inicio,
      fechaFin: c.fecha_fin,
      precio: Number(c.precio),
      combinaEscalas: Boolean(c.combina_escalas),
      prioridad: Number(c.prioridad ?? 0),
      topeCombos: c.tope_combos == null ? null : Number(c.tope_combos),
      productoAMoverId: c.producto_a_mover_id == null ? null : String(c.producto_a_mover_id),
      componentes: [...porLugar.values()],
    }
  })
}

export function useCombosAdminQuery(enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: combosKeys.lista(currentSucursalId),
    queryFn: fetchCombosAdmin,
    staleTime: 2 * 60 * 1000,
    enabled,
  })
}

export interface ComboFormInput {
  id?: string
  nombre: string
  precio: number
  fechaInicio: string
  fechaFin?: string | null
  activo?: boolean
  combinaEscalas?: boolean
  prioridad?: number
  topeCombos?: number | null
  productoAMoverId?: string | null
  componentes: LugarCombo[]
  /**
   * El grupo de combos que compiten, de arriba (gana) a abajo, con 0 para este
   * combo si es nuevo (#1213). `guardar_combo` reescribe su prioridad. Sin
   * orden se guarda `prioridad` tal cual.
   */
  orden?: number[]
}

export async function guardarCombo(input: ComboFormInput): Promise<string> {
  const { data, error } = await supabase.rpc('guardar_combo', {
    p_combo: {
      id: input.id ? Number(input.id) : null,
      nombre: input.nombre,
      precio: input.precio,
      fecha_inicio: input.fechaInicio,
      fecha_fin: input.fechaFin || null,
      activo: input.activo ?? true,
      combina_escalas: input.combinaEscalas ?? false,
      prioridad: input.prioridad ?? 0,
      tope_combos: input.topeCombos ?? null,
      producto_a_mover_id: input.productoAMoverId ? Number(input.productoAMoverId) : null,
      componentes: input.componentes.map(c => ({
        cantidad: c.cantidad,
        productos: c.sueltos.map(Number),
        categorias: [...c.categorias],
      })),
      ...(input.orden ? { orden: input.orden } : {}),
    },
  })
  if (error) throw errorDeSupabase(error, 'No se pudo guardar el combo')
  const r = data as { success: boolean; id?: number; error?: string } | null
  if (!r?.success) throw new Error(r?.error || 'No se pudo guardar el combo')
  return String(r.id)
}

export function useGuardarComboMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: guardarCombo,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: combosKeys.all(currentSucursalId) })
    },
  })
}
