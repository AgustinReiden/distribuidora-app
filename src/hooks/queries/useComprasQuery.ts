/**
 * TanStack Query hooks para Compras
 * Reemplaza el hook useCompras con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import type {
  CompraDBExtended,
  CompraFormInputExtended,
  RegistrarCompraResult
} from '../../types'

// Query keys
export const comprasKeys = {
  all: ['compras'] as const,
  lists: () => [...comprasKeys.all, 'list'] as const,
  list: (filters: Record<string, unknown>) => [...comprasKeys.lists(), filters] as const,
  details: () => [...comprasKeys.all, 'detail'] as const,
  detail: (id: string) => [...comprasKeys.details(), id] as const,
  byProveedor: (proveedorId: string) => [...comprasKeys.all, 'proveedor', proveedorId] as const,
  byProducto: (productoId: string) => [...comprasKeys.all, 'producto', productoId] as const,
}

interface CompraItemRPC {
  producto_id: string
  cantidad: number
  costo_unitario: number
  subtotal: number
  bonificacion: number
}

interface RPCResult {
  success: boolean
  compra_id: string
  error?: string
}

// Fetch functions
async function fetchCompras(): Promise<CompraDBExtended[]> {
  const { data, error } = await supabase
    .from('compras')
    .select(`
      *,
      proveedor:proveedores(*),
      items:compra_items(*, producto:productos(*)),
      usuario:perfiles(id, nombre)
    `)
    .order('created_at', { ascending: false })

  if (error) {
    if (error.message.includes('does not exist')) return []
    throw error
  }
  return (data || []) as CompraDBExtended[]
}

async function fetchCompraById(id: string): Promise<CompraDBExtended | null> {
  const { data, error } = await supabase
    .from('compras')
    .select(`
      *,
      proveedor:proveedores(*),
      items:compra_items(*, producto:productos(*)),
      usuario:perfiles(id, nombre)
    `)
    .eq('id', id)
    .single()

  if (error) throw error
  return data as CompraDBExtended
}

async function fetchComprasByProveedor(proveedorId: string): Promise<CompraDBExtended[]> {
  const { data, error } = await supabase
    .from('compras')
    .select(`
      *,
      proveedor:proveedores(*),
      items:compra_items(*, producto:productos(*))
    `)
    .eq('proveedor_id', proveedorId)
    .order('created_at', { ascending: false })

  if (error) throw error
  return (data || []) as CompraDBExtended[]
}

// Mutation functions
async function registrarCompra(compraData: CompraFormInputExtended): Promise<RegistrarCompraResult> {
  const itemsParaRPC: CompraItemRPC[] = compraData.items.map(item => ({
    producto_id: item.productoId,
    cantidad: item.cantidad,
    costo_unitario: item.costoUnitario || 0,
    subtotal: item.subtotal || (item.cantidad * (item.costoUnitario || 0)),
    bonificacion: item.bonificacion || 0
  }))

  const { data, error } = await supabase.rpc('registrar_compra_completa', {
    p_proveedor_id: compraData.proveedorId || null,
    p_proveedor_nombre: compraData.proveedorNombre || null,
    p_numero_factura: compraData.numeroFactura || null,
    p_fecha_compra: compraData.fechaCompra || new Date().toISOString().split('T')[0],
    p_subtotal: compraData.subtotal || 0,
    p_iva: compraData.iva || 0,
    p_otros_impuestos: compraData.otrosImpuestos || 0,
    p_total: compraData.total || 0,
    p_forma_pago: compraData.formaPago || 'efectivo',
    p_notas: compraData.notas || null,
    p_usuario_id: compraData.usuarioId || null,
    p_items: itemsParaRPC
  })

  if (error) throw error

  const result = data as RPCResult
  if (!result.success) {
    throw new Error(result.error || 'Error al registrar compra')
  }

  return { success: true, compraId: result.compra_id }
}

async function anularCompra(compraId: string, compras: CompraDBExtended[]): Promise<void> {
  const compra = compras.find(c => c.id === compraId)
  if (!compra) throw new Error('Compra no encontrada')

  // Obtener stock ACTUAL de todos los productos afectados
  const productIds = (compra.items || []).map(i => i.producto_id).filter(Boolean)
  if (productIds.length > 0) {
    const { data: productosActuales } = await supabase
      .from('productos')
      .select('id, stock')
      .in('id', productIds)

    const stockMap: Record<string, number> = Object.fromEntries(
      ((productosActuales || []) as Array<{ id: string; stock: number }>).map(p => [p.id, p.stock || 0])
    )

    // Revertir stock de cada item (restar del stock ACTUAL)
    for (const item of (compra.items || [])) {
      const stockActual = stockMap[item.producto_id] || 0
      const nuevoStock = stockActual - item.cantidad
      await supabase
        .from('productos')
        .update({ stock: Math.max(0, nuevoStock) })
        .eq('id', item.producto_id)
    }
  }

  // Marcar compra como cancelada
  const { error } = await supabase
    .from('compras')
    .update({ estado: 'cancelada' })
    .eq('id', compraId)

  if (error) throw error
}

// Hooks

/**
 * Hook para obtener todas las compras
 */
export function useComprasQuery() {
  return useQuery({
    queryKey: comprasKeys.lists(),
    queryFn: fetchCompras,
    staleTime: 5 * 60 * 1000, // 5 minutos
  })
}

/**
 * Hook para obtener una compra por ID
 */
export function useCompraQuery(id: string) {
  return useQuery({
    queryKey: comprasKeys.detail(id),
    queryFn: () => fetchCompraById(id),
    enabled: !!id,
  })
}

/**
 * Hook para obtener compras por proveedor
 */
export function useComprasByProveedorQuery(proveedorId: string) {
  return useQuery({
    queryKey: comprasKeys.byProveedor(proveedorId),
    queryFn: () => fetchComprasByProveedor(proveedorId),
    enabled: !!proveedorId,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para registrar una compra
 */
export function useRegistrarCompraMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: registrarCompra,
    onSuccess: () => {
      // Invalidar compras y productos (stock actualizado)
      queryClient.invalidateQueries({ queryKey: comprasKeys.lists() })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}

/**
 * Hook para anular una compra
 */
export function useAnularCompraMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (compraId: string) => {
      const compras = queryClient.getQueryData<CompraDBExtended[]>(comprasKeys.lists()) || []
      await anularCompra(compraId, compras)
      return compraId
    },
    // Optimistic update
    onMutate: async (compraId: string) => {
      await queryClient.cancelQueries({ queryKey: comprasKeys.lists() })

      const previousCompras = queryClient.getQueryData<CompraDBExtended[]>(comprasKeys.lists())

      // Marcar como cancelada optimistamente
      queryClient.setQueryData<CompraDBExtended[]>(comprasKeys.lists(), (old) => {
        if (!old) return old
        return old.map(c => c.id === compraId ? { ...c, estado: 'cancelada' as const } : c)
      })

      return { previousCompras }
    },
    onError: (_, __, context) => {
      // Rollback on error
      if (context?.previousCompras) {
        queryClient.setQueryData(comprasKeys.lists(), context.previousCompras)
      }
    },
    onSettled: () => {
      // Revalidar
      queryClient.invalidateQueries({ queryKey: comprasKeys.lists() })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}
