/**
 * Objetivos por preventista (migs 159-161).
 *
 * El avance sale del RPC `avance_metas_preventista`, no de un cálculo en el
 * front: el prorrateo y el semáforo se resuelven en SQL para que el número que
 * ve el preventista en su dashboard y el que ve el gerente en /metas sean
 * literalmente el mismo. `metas_gerenciales` prorratea en el front y por eso
 * sus semáforos pueden discrepar.
 *
 * BASE: pedidos entregados, canal app, sin bonificaciones — la misma de
 * `reporte_gerencial`. NO coincide con "Mis métricas" del dashboard
 * (`useMetricasQuery`, que cuenta todo lo no cancelado), por eso el panel se
 * rotula explícitamente.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'

// =============================================================================
// TYPES
// =============================================================================

export type TipoMeta = 'facturacion' | 'unidades' | 'cobertura' | 'clientes_nuevos'
export type EstadoMeta = 'cumplida' | 'adelantado' | 'en_curso' | 'en_riesgo'
export type TipoAlcance = 'marca' | 'categoria' | 'producto' | 'global'

export interface AlcanceMeta {
  tipo: TipoAlcance
  id: string | number | null
  nombre: string | null
}

export interface AvanceMeta {
  id: number
  tipo_meta: TipoMeta
  /** '$' | 'u' | 'clientes' — derivada de tipo_meta en el RPC. */
  unidad: string
  alcance: AlcanceMeta
  objetivo: number
  logrado: number
  pct: number
  /** objetivo × días transcurridos / días del mes. Calculado en SQL. */
  objetivo_prorrateado: number
  estado: EstadoMeta
}

export interface AvanceMetasResultado {
  preventista_id: string
  nombre: string | null
  periodo: string
  dias_transcurridos: number
  dias_periodo: number
  metas: AvanceMeta[]
  resumen: { total: number; cumplidas: number; en_riesgo: number }
  /** Productos sin marca en la sucursal. Solo > 0 si hay metas por marca. */
  productos_sin_marca: number
}

export interface MetaPreventista {
  id: number
  sucursal_id: number
  preventista_id: string
  periodo: string
  tipo_meta: TipoMeta
  marca_id: string | null
  categoria_id: string | null
  producto_id: number | null
  valor_objetivo: number
  activo: boolean
  created_at: string
}

export interface GuardarMetaInput {
  id?: number | null
  sucursalId: number
  preventistaId: string
  /** 'YYYY-MM-01'. El RPC lo normaliza al primer día del mes igual. */
  periodo: string
  tipoMeta: TipoMeta
  valorObjetivo: number
  marcaId?: string | null
  categoriaId?: string | null
  productoId?: number | null
}

export interface RendimientoPorMarca {
  marca: string
  venta: number
  unidades: number
}

export interface RendimientoPorCategoria {
  categoria: string
  venta: number
  unidades: number
}

export interface RendimientoPreventista {
  preventista_id: string
  nombre: string
  rol: string | null
  pedidos: number
  venta: number
  unidades: number
  margen_comercial: number
  cobertura: number
  clientes_nuevos: number
  ticket: number | null
  metas_cargadas: number
  por_marca: RendimientoPorMarca[]
  por_categoria: RendimientoPorCategoria[]
}

export interface RendimientoResultado {
  periodo: string
  preventistas: RendimientoPreventista[]
}

// =============================================================================
// QUERY KEYS
// =============================================================================

export const metasKeys = {
  all: (sucursalId: number | null) => ['metas-preventista', sucursalId] as const,
  avance: (sucursalId: number | null, preventistaId: string | null, periodo: string) =>
    [...metasKeys.all(sucursalId), 'avance', preventistaId ?? 'yo', periodo] as const,
  lista: (sucursalId: number | null, periodo: string) =>
    [...metasKeys.all(sucursalId), 'lista', periodo] as const,
  rendimiento: (sucursalId: number | null, periodo: string) =>
    [...metasKeys.all(sucursalId), 'rendimiento', periodo] as const,
}

/** Primer día del mes de una fecha, en formato ISO corto. */
export function periodoMensual(fecha: Date = new Date()): string {
  const y = fecha.getFullYear()
  const m = String(fecha.getMonth() + 1).padStart(2, '0')
  return `${y}-${m}-01`
}

// =============================================================================
// HOOKS
// =============================================================================

/**
 * Avance de un preventista. Sin `preventistaId` devuelve el del usuario
 * logueado (es lo que usa el dashboard). Pasar otro id requiere ser admin: el
 * RPC responde 42501 en caso contrario.
 */
export function useAvanceMetasQuery(
  preventistaId?: string | null,
  periodo: string = periodoMensual(),
  enabled = true,
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: metasKeys.avance(currentSucursalId, preventistaId ?? null, periodo),
    queryFn: async (): Promise<AvanceMetasResultado> => {
      const { data, error } = await supabase.rpc('avance_metas_preventista', {
        p_preventista_id: preventistaId ?? null,
        p_periodo: periodo,
      })
      if (error) throw error
      return data as AvanceMetasResultado
    },
    enabled,
    // Alineado con useMetricasQuery, que es lo que se ve al lado en el dashboard.
    staleTime: 2 * 60 * 1000,
  })
}

/** Metas cargadas del período (la RLS ya filtra: el preventista ve las suyas). */
export function useMetasPreventistaQuery(periodo: string = periodoMensual(), enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: metasKeys.lista(currentSucursalId, periodo),
    queryFn: async (): Promise<MetaPreventista[]> => {
      const { data, error } = await supabase
        .from('metas_preventista')
        .select('*')
        .eq('periodo', periodo)
        .eq('activo', true)
        .order('tipo_meta')
        .order('id')
      if (error) throw error
      return (data as MetaPreventista[]) || []
    },
    enabled,
    staleTime: 5 * 60 * 1000,
  })
}

/** Rendimiento comparado del equipo. Admin-only (el RPC tira 42501 al resto). */
export function useRendimientoPreventistasQuery(
  periodo: string = periodoMensual(),
  enabled = true,
) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: metasKeys.rendimiento(currentSucursalId, periodo),
    queryFn: async (): Promise<RendimientoResultado> => {
      const { data, error } = await supabase.rpc('rendimiento_preventistas', {
        p_sucursal_id: currentSucursalId,
        p_periodo: periodo,
      })
      if (error) throw error
      return data as RendimientoResultado
    },
    enabled,
    staleTime: 5 * 60 * 1000,
  })
}

export function useGuardarMetaPreventistaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (input: GuardarMetaInput): Promise<number> => {
      const { data, error } = await supabase.rpc('guardar_meta_preventista', {
        p_id: input.id ?? null,
        p_sucursal_id: input.sucursalId,
        p_preventista_id: input.preventistaId,
        p_periodo: input.periodo,
        p_tipo_meta: input.tipoMeta,
        p_valor_objetivo: input.valorObjetivo,
        p_marca_id: input.marcaId ?? null,
        p_categoria_id: input.categoriaId ?? null,
        p_producto_id: input.productoId ?? null,
      })
      if (error) throw error
      return data as number
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: metasKeys.all(currentSucursalId) })
    },
  })
}

export function useDesactivarMetaPreventistaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (id: number): Promise<void> => {
      const { error } = await supabase.rpc('desactivar_meta_preventista', { p_id: id })
      if (error) throw error
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: metasKeys.all(currentSucursalId) })
    },
  })
}
