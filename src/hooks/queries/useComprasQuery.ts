/**
 * TanStack Query hooks para Compras
 * Reemplaza el hook useCompras con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { fechaLocalISO } from '../../utils/formatters'
import type {
  CompraDBExtended,
  CompraFormInputExtended,
  RegistrarCompraResult
} from '../../types'

// Query keys
export const comprasKeys = {
  all: (sucursalId: number | null) => ['compras', sucursalId] as const,
  lists: (sucursalId: number | null) => [...comprasKeys.all(sucursalId), 'list'] as const,
  list: (sucursalId: number | null, filters: Record<string, unknown>) => [...comprasKeys.lists(sucursalId), filters] as const,
  details: (sucursalId: number | null) => [...comprasKeys.all(sucursalId), 'detail'] as const,
  detail: (sucursalId: number | null, id: string) => [...comprasKeys.details(sucursalId), id] as const,
  byProveedor: (sucursalId: number | null, proveedorId: string) => [...comprasKeys.all(sucursalId), 'proveedor', proveedorId] as const,
  byProducto: (sucursalId: number | null, productoId: string) => [...comprasKeys.all(sucursalId), 'producto', productoId] as const,
}

interface CompraItemRPC {
  producto_id: string
  cantidad: number
  costo_unitario: number
  subtotal: number
  bonificacion: number
  porcentaje_iva: number
  impuestos_internos: number
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
    bonificacion: item.bonificacion || 0,
    porcentaje_iva: item.porcentajeIva ?? 21,
    impuestos_internos: item.impuestosInternos ?? 0
  }))

  const { data, error } = await supabase.rpc('registrar_compra_completa', {
    p_proveedor_id: compraData.proveedorId || null,
    p_proveedor_nombre: compraData.proveedorNombre || null,
    p_numero_factura: compraData.numeroFactura || null,
    p_fecha_compra: compraData.fechaCompra || fechaLocalISO(),
    p_subtotal: compraData.subtotal || 0,
    p_iva: compraData.iva || 0,
    p_otros_impuestos: compraData.otrosImpuestos || 0,
    p_total: compraData.total || 0,
    p_forma_pago: compraData.formaPago || 'efectivo',
    p_notas: compraData.notas || null,
    p_usuario_id: compraData.usuarioId || null,
    p_items: itemsParaRPC,
    p_tipo_factura: compraData.tipoFactura || 'FC',
    p_impuestos_internos: compraData.impuestosInternos || 0,
    p_percepcion_iva: compraData.percepcionIva || 0,
    p_percepcion_iibb: compraData.percepcionIibb || 0,
    p_no_gravado: compraData.noGravado || 0
  })

  if (error) throw error

  const result = data as RPCResult
  if (!result.success) {
    throw new Error(result.error || 'Error al registrar compra')
  }

  return { success: true, compraId: result.compra_id }
}

/**
 * Anula una compra via RPC atómico (mig 115): reversa de stock con invariante
 * de no-negatividad + restauración del costo del producto desde la última
 * compra restante. Reemplaza el loop client-side no atómico que clampeaba el
 * stock en 0 (perdía reversa) y no restauraba costos.
 */
async function anularCompra(compraId: string): Promise<void> {
  const { data: { user } } = await supabase.auth.getUser()

  const { data, error } = await supabase.rpc('anular_compra_atomica', {
    p_compra_id: compraId,
    p_usuario_id: user?.id ?? null,
  })

  if (error) throw error
  const result = data as { success: boolean; error?: string }
  if (!result.success) {
    throw new Error(result.error || 'Error al anular la compra')
  }
}

// Hooks

/**
 * Hook para obtener todas las compras
 */
export function useComprasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: comprasKeys.lists(currentSucursalId),
    queryFn: fetchCompras,
    staleTime: 5 * 60 * 1000, // 5 minutos
  })
}

/**
 * Hook para obtener una compra por ID
 */
export function useCompraQuery(id: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: comprasKeys.detail(currentSucursalId, id),
    queryFn: () => fetchCompraById(id),
    enabled: !!id,
  })
}

/**
 * Hook para obtener compras por proveedor
 */
export function useComprasByProveedorQuery(proveedorId: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: comprasKeys.byProveedor(currentSucursalId, proveedorId),
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
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: registrarCompra,
    onSuccess: () => {
      // Invalidar compras y productos (stock actualizado)
      queryClient.invalidateQueries({ queryKey: comprasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}

/**
 * Input para editar items de una compra (admin only, ventana 7 dias).
 * La cabecera de la compra (proveedor, fecha, factura, tipo_factura, forma_pago)
 * queda inmutable; solo se actualizan los items y los totales recalculados.
 */
export interface ActualizarCompraItemsInput {
  compraId: string
  usuarioId: string | null
  subtotal: number
  iva: number
  total: number
  /** Cabecera fiscal (mig 114). undefined = conservar el valor actual. */
  impuestosInternos?: number
  percepcionIva?: number
  percepcionIibb?: number
  noGravado?: number
  items: Array<{
    productoId: string
    cantidad: number
    costoUnitario: number
    subtotal: number
    bonificacion?: number
    porcentajeIva?: number
    impuestosInternos?: number
  }>
}

async function actualizarCompraItems(input: ActualizarCompraItemsInput): Promise<{ compraId: string }> {
  const itemsParaRPC: CompraItemRPC[] = input.items.map(item => ({
    producto_id: item.productoId,
    cantidad: item.cantidad,
    costo_unitario: item.costoUnitario,
    subtotal: item.subtotal,
    bonificacion: item.bonificacion ?? 0,
    porcentaje_iva: item.porcentajeIva ?? 21,
    impuestos_internos: item.impuestosInternos ?? 0,
  }))

  const { data, error } = await supabase.rpc('actualizar_compra_items', {
    p_compra_id: input.compraId,
    p_items_nuevos: itemsParaRPC,
    p_subtotal: input.subtotal,
    p_iva: input.iva,
    p_total: input.total,
    p_usuario_id: input.usuarioId,
    p_impuestos_internos: input.impuestosInternos ?? null,
    p_percepcion_iva: input.percepcionIva ?? null,
    p_percepcion_iibb: input.percepcionIibb ?? null,
    p_no_gravado: input.noGravado ?? null,
  })

  if (error) throw error
  const result = data as { success: boolean; compra_id: string; error?: string }
  if (!result.success) {
    throw new Error(result.error || 'Error al actualizar compra')
  }
  return { compraId: result.compra_id }
}

/**
 * Hook para editar items de una compra existente (admin, 7 dias).
 * Solo modifica items y totales — cabecera queda intacta.
 */
export function useActualizarCompraMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: actualizarCompraItems,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: comprasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}

/**
 * Hook para anular una compra
 */
export function useAnularCompraMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: async (compraId: string) => {
      await anularCompra(compraId)
      return compraId
    },
    // Optimistic update
    onMutate: async (compraId: string) => {
      await queryClient.cancelQueries({ queryKey: comprasKeys.lists(currentSucursalId) })

      const previousCompras = queryClient.getQueryData<CompraDBExtended[]>(comprasKeys.lists(currentSucursalId))

      // Marcar como cancelada optimistamente
      queryClient.setQueryData<CompraDBExtended[]>(comprasKeys.lists(currentSucursalId), (old) => {
        if (!old) return old
        return old.map(c => c.id === compraId ? { ...c, estado: 'cancelada' as const } : c)
      })

      return { previousCompras }
    },
    onError: (_, __, context) => {
      // Rollback on error
      if (context?.previousCompras) {
        queryClient.setQueryData(comprasKeys.lists(currentSucursalId), context.previousCompras)
      }
    },
    onSettled: () => {
      // Revalidar
      queryClient.invalidateQueries({ queryKey: comprasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}
