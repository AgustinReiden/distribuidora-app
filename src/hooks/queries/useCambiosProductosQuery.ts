/**
 * TanStack Query hooks para Cambios de Productos cliente↔depósito
 *
 * Llama a la RPC atómica registrar_cambio_producto que:
 *   - Suma stock al producto devuelto
 *   - Resta stock al producto entregado
 *   - Guarda la diferencia de precio, que es informativa: no toca saldo_cuenta
 *   - Inserta el registro en cambios_productos
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useSucursal } from '../../contexts/SucursalContext'
import { productosKeys } from './useProductosQuery'
import { clientesKeys } from './useClientesQuery'

export const cambiosProductosKeys = {
  all: (sucursalId: number | null) => ['cambios_productos', sucursalId] as const,
  lists: (sucursalId: number | null) => [...cambiosProductosKeys.all(sucursalId), 'list'] as const,
  // Debajo de `lists`: las mutaciones que ya la invalidan refrescan también la ficha.
  byCliente: (sucursalId: number | null, clienteId: string) =>
    [...cambiosProductosKeys.lists(sucursalId), 'cliente', clienteId] as const,
}

// ============================================================================
// Canjes de un cliente, para su ficha (#1370)
// ============================================================================

// Dos FKs a productos (lo devuelto y lo entregado): cada embed va con su hint, o
// PGRST201 rompe la consulta entera (CLAUDE.md, trampa 5). De productos, sólo el
// nombre: un `*` sobre productos falla para todos (#974).
const CAMBIOS_CLIENTE_SELECT = 'id, created_at, motivo, observaciones, '
  + 'cantidad_devuelta, precio_devuelto, cantidad_entregada, precio_entregado, diferencia_monto, '
  + 'producto_devuelto:productos!cambios_productos_producto_devuelto_id_fkey(nombre), '
  + 'producto_entregado:productos!cambios_productos_producto_entregado_id_fkey(nombre)'

export interface CambioProductoCliente {
  id: number
  created_at: string
  motivo: string | null
  observaciones: string | null
  cantidad_devuelta: number
  precio_devuelto: number
  cantidad_entregada: number
  precio_entregado: number
  /** Entregado menos devuelto. Informativa: no toca saldo_cuenta (#1329). */
  diferencia_monto: number
  producto_devuelto: { nombre: string } | null
  producto_entregado: { nombre: string } | null
}

async function fetchCambiosCliente(clienteId: string): Promise<CambioProductoCliente[]> {
  const { data, error } = await supabase
    .from('cambios_productos')
    .select(CAMBIOS_CLIENTE_SELECT)
    .eq('cliente_id', clienteId)
    .order('created_at', { ascending: false })
    .order('id', { ascending: false })
  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudieron cargar los canjes. Revisá la señal e intentá de nuevo.')
  return (data || []) as unknown as CambioProductoCliente[]
}

/** Canjes del cliente. RLS: sólo admin y encargado de la sucursal los leen. */
export function useCambiosProductosClienteQuery(clienteId: string | undefined, enabled = true) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: cambiosProductosKeys.byCliente(currentSucursalId, clienteId || ''),
    queryFn: () => fetchCambiosCliente(clienteId!),
    enabled: !!clienteId && enabled,
    staleTime: 60 * 1000,
  })
}

export interface RegistrarCambioInput {
  clienteId: string
  productoDevueltoId: string
  cantidadDevuelta: number
  productoEntregadoId: string
  cantidadEntregada: number
  observaciones?: string
  /** Motivo del cambio (vencimiento/rotura/mal_estado → no reingresa el devuelto). */
  motivo?: 'vencimiento' | 'rotura' | 'mal_estado' | 'erroneo' | 'otro'
}

async function registrarCambio(input: RegistrarCambioInput): Promise<number> {
  const { data, error } = await supabase.rpc('registrar_cambio_producto', {
    p_cliente_id: Number(input.clienteId),
    p_producto_devuelto_id: Number(input.productoDevueltoId),
    p_cantidad_devuelta: input.cantidadDevuelta,
    p_producto_entregado_id: Number(input.productoEntregadoId),
    p_cantidad_entregada: input.cantidadEntregada,
    p_observaciones: input.observaciones || null,
    p_motivo: input.motivo || 'erroneo',
  })

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el cambio de productos. Revisá el stock antes de reintentar.')
  return data as number
}

/**
 * Hook para registrar un cambio de productos.
 * Invalida cache de productos (stock) y clientes.
 */
export function useRegistrarCambioProductoMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: registrarCambio,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: clientesKeys.listsPrefix(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: cambiosProductosKeys.lists(currentSucursalId) })
    },
  })
}

// ============================================================================
// Cambio como PARADA del recorrido (mig 089)
// ============================================================================

/**
 * Crea un pedido especial canal='cambio' (total 0) + su detalle en
 * recorrido_cambios para sumarlo como parada del recorrido. NO ajusta
 * stock/saldo todavía (eso ocurre al completar la parada). Devuelve el
 * pedido_id creado.
 */
async function crearPedidoCambioEnRuta(input: RegistrarCambioInput): Promise<number> {
  const { data, error } = await supabase.rpc('crear_pedido_cambio_en_ruta', {
    p_cliente_id: Number(input.clienteId),
    p_producto_devuelto_id: Number(input.productoDevueltoId),
    p_cantidad_devuelta: input.cantidadDevuelta,
    p_producto_entregado_id: Number(input.productoEntregadoId),
    p_cantidad_entregada: input.cantidadEntregada,
    p_observaciones: input.observaciones || null,
    p_motivo: input.motivo || 'erroneo',
  })

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la parada de cambio. Revisá el recorrido antes de reintentar.')
  return data as number
}

/**
 * Hook para crear una parada de cambio. Solo invalida pedidos (la parada
 * aparece en el pool rutable); stock/saldo no se tocan hasta completarla.
 */
export function useCrearPedidoCambioEnRutaMutation() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: crearPedidoCambioEnRuta,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
    },
  })
}

export interface AplicarCambioParadaInput {
  pedidoId: string
  /** El chofer de la entrega que viene después: su rendición de `fecha` se mira (#1343). */
  transportistaId: string | null
  /** El día de la entrega, `YYYY-MM-DD`. */
  fecha: string
}

/**
 * Aplica el cambio real de una parada al completarla (suma stock devuelto,
 * resta entregado, inserta cambios_productos). Idempotente
 * en el backend. Devuelve el cambio_producto_id.
 *
 * #1343: el server rechaza si la rendición de ese chofer y día ya fue controlada
 * (42501) o se está confirmando (40001), sin mover el stock: la entrega que viene
 * después se rechazaría igual.
 */
async function aplicarCambioDeParada(input: AplicarCambioParadaInput): Promise<number | null> {
  const { data, error } = await supabase.rpc('aplicar_cambio_de_parada', {
    p_pedido_id: Number(input.pedidoId),
    p_transportista_id: input.transportistaId,
    p_fecha: input.fecha,
  })

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar el cambio de la parada. Revisá el stock antes de reintentar.')
  return (data as number | null) ?? null
}

/**
 * Hook para aplicar el cambio de una parada. Invalida productos (stock),
 * clientes (saldo), la ruta activa del chofer y pedidos.
 */
export function useAplicarCambioParadaMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: aplicarCambioDeParada,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: productosKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: clientesKeys.listsPrefix(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: cambiosProductosKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['recorrido-activo'] })
      queryClient.invalidateQueries({ queryKey: ['pedidos'] })
    },
  })
}
