/**
 * TanStack Query hooks para Notas de Credito
 * Permite consultar y registrar notas de credito asociadas a compras
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'
import type { NotaCreditoDB, NotaCreditoFormInput } from '../../types'
import { comprasKeys } from './useComprasQuery'
import { lotesKeys } from './useLotesQuery'
import { PRODUCTO_COLUMNAS } from '../../lib/productoColumnas'
import { avisosAnulacionNotaCredito, resumirNotasCreditoPorCompra } from '../../utils/notaCredito'

// Resumen ligero de NCs por compra (para badges en lista)
export interface NCResumen {
  compra_id: string
  cantidad: number
  total: number
}

// Query keys
export const notasCreditoKeys = {
  all: (sucursalId: number | null) => ['notas_credito', sucursalId] as const,
  lists: (sucursalId: number | null) => [...notasCreditoKeys.all(sucursalId), 'list'] as const,
  resumen: (sucursalId: number | null) => [...notasCreditoKeys.all(sucursalId), 'resumen'] as const,
  byCompra: (sucursalId: number | null, compraId: string) => [...notasCreditoKeys.all(sucursalId), 'compra', compraId] as const,
}

// Fetch functions
async function fetchNotasCreditoResumen(): Promise<NCResumen[]> {
  const { data, error } = await supabase
    .from('notas_credito')
    .select('compra_id, total, anulada')

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar las notas de crédito. Revisá la señal e intentá de nuevo.')
  }

  // Por compra, sólo las vigentes: una nota anulada no cuenta en el badge ni bloquea editar.
  return resumirNotasCreditoPorCompra(data || [])
}

/**
 * El nombre de quien anuló cada nota. `anulada_por` no tiene clave foránea a
 * `perfiles` (mig 524: con dos, el embed de `usuario` quedaba ambiguo y la consulta
 * entera fallaba), así que no se embebe: se pide aparte, sólo si hay anuladas. Si
 * no se puede leer (RLS, señal), la nota se muestra sin el nombre.
 */
async function nombresDeAnuladores(notas: NotaCreditoDB[]): Promise<NotaCreditoDB[]> {
  const ids = [...new Set(notas.map(n => n.anulada_por).filter((id): id is string => !!id))]
  if (ids.length === 0) return notas
  const { data, error } = await supabase.from('perfiles').select('id, nombre').in('id', ids)
  if (error || !data) return notas
  const nombres = new Map((data as Array<{ id: string; nombre: string | null }>).map(p => [String(p.id), p.nombre]))
  return notas.map(n => (n.anulada_por ? { ...n, anulada_por_nombre: nombres.get(String(n.anulada_por)) ?? null } : n))
}

async function fetchNotasCreditoByCompra(compraId: string): Promise<NotaCreditoDB[]> {
  // El embed de `perfiles` nombra su relación: la tabla guarda también quién anuló la nota
  // (`anulada_por`), y si esa columna vuelve a tener FK a `perfiles`, sin el nombre el embed
  // queda ambiguo y PostgREST rechaza la consulta entera (PGRST201; pasó con la mig 523).
  const { data, error } = await supabase
    .from('notas_credito')
    .select(`
      *,
      items:nota_credito_items(*, producto:productos(${PRODUCTO_COLUMNAS})),
      usuario:perfiles!notas_credito_usuario_id_fkey(id, nombre)
    `)
    .eq('compra_id', compraId)
    .order('created_at', { ascending: false })

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar las notas de crédito. Revisá la señal e intentá de nuevo.')
  }
  // El detalle es historial: trae también las anuladas, marcadas (`anulada`, `anulada_at`,
  // `motivo_anulacion`, por el `*`), y quien suma las filtra con `esNotaVigente`.
  return nombresDeAnuladores((data || []) as NotaCreditoDB[])
}

/** Lo que devuelve `anular_nota_credito_compra` (mig 523). */
interface ResultadoAnularNota {
  success?: boolean
  error?: string
  warnings?: unknown
}

async function anularNotaCreditoCompra({ notaId, motivo }: { notaId: string; motivo: string }): Promise<string[]> {
  const { data, error } = await supabase.rpc('anular_nota_credito_compra', {
    p_nota_id: Number(notaId),
    p_motivo: motivo,
  })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo anular la nota de crédito. Revisá la compra antes de reintentar.')
  const resultado = data as ResultadoAnularNota | null
  // El rechazo de la base ya viene en castellano y con su motivo (la nota anterior al
  // 10/11/2026, la compra cancelada, sin motivo, ya anulada): se muestra tal cual.
  if (!resultado?.success) throw new Error(resultado?.error || 'No se pudo anular la nota de crédito')
  return avisosAnulacionNotaCredito(resultado.warnings)
}

// Mutation functions
async function registrarNotaCredito(data: NotaCreditoFormInput): Promise<void> {
  const itemsParaRPC = data.items.map(item => ({
    producto_id: item.productoId,
    cantidad: item.cantidad,
    costo_unitario: item.costoUnitario,
    subtotal: item.subtotal,
  }))

  const { data: result, error } = await supabase.rpc('registrar_nota_credito', {
    p_compra_id: data.compraId,
    p_numero_nota: data.numeroNota || null,
    p_motivo: data.motivo || null,
    p_subtotal: data.subtotal,
    p_iva: data.iva,
    p_total: data.total,
    p_usuario_id: data.usuarioId || null,
    p_items: itemsParaRPC,
    // mig 280: en una devolución la base recalcula el II y ajusta el total;
    // en un ajuste sin mercadería (items vacíos) se guarda el que se declara.
    p_impuestos_internos: data.impuestosInternos ?? 0,
  })

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la nota de crédito. Revisá la compra antes de reintentar.')

  const rpcResult = result as { success?: boolean; error?: string } | null
  if (rpcResult && !rpcResult.success) {
    throw new Error(rpcResult.error || 'Error al registrar nota de credito')
  }
}

// Hooks

/**
 * Hook para obtener notas de credito de una compra
 */
export function useNotasCreditoByCompraQuery(compraId: string | undefined, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: notasCreditoKeys.byCompra(currentSucursalId, compraId || ''),
    queryFn: () => fetchNotasCreditoByCompra(compraId!),
    enabled: !!compraId && enabled,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para obtener resumen de NCs por compra (para badges en lista)
 */
export function useNotasCreditoResumenQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: notasCreditoKeys.resumen(currentSucursalId),
    queryFn: fetchNotasCreditoResumen,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para registrar una nota de credito
 */
export function useRegistrarNotaCreditoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: registrarNotaCredito,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: comprasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
      queryClient.invalidateQueries({ queryKey: notasCreditoKeys.all(currentSucursalId) })
      // #1079: la devolución con ítems sale de los lotes de la compra.
      queryClient.invalidateQueries({ queryKey: lotesKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Hook para anular una nota de crédito de compra (mig 523, B18 de #1603). La base
 * valida el rol y la sucursal; devuelve los avisos en castellano. Al anular vuelven
 * el stock, los lotes, el promedio y la reposición, y cambian «Compras del período»,
 * los descuentos de proveedores y la posición fiscal: se invalida todo eso.
 */
export function useAnularNotaCreditoCompraMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: anularNotaCreditoCompra,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: notasCreditoKeys.all(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: comprasKeys.all(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
      queryClient.invalidateQueries({ queryKey: lotesKeys.all(currentSucursalId) })
      // Las claves de useReporteGerencialQuery (sin importarlo: es un módulo pesado).
      queryClient.invalidateQueries({ queryKey: ['reporte-gerencial'] })
      queryClient.invalidateQueries({ queryKey: ['posicion-fiscal'] })
      // El stock de la red y la valuación del inventario (stock × costo).
      queryClient.invalidateQueries({ queryKey: ['stock-red'] })
      queryClient.invalidateQueries({ queryKey: ['valuacion-inventario'] })
    },
  })
}
