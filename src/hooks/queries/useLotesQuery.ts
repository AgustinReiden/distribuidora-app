/**
 * Lotes y vencimientos (migs 223/224/225).
 *
 * Un lote es una fecha de vencimiento con un contador que baja. Lo que NO está
 * en ningún lote es la "bolsa sin vencimiento", que no es una fila: es
 * `productos.stock` menos la suma de los contadores. Ver el encabezado de la
 * mig 223 para el modelo completo.
 *
 * TODA LA ESCRITURA VA POR RPC
 * ----------------------------
 * `producto_lotes` tiene RLS con policy de SELECT y ninguna de escritura: el
 * default-deny alcanza y el único camino es una RPC `SECURITY DEFINER`. No es
 * casual — el contador de un lote decide si algo se pinta en rojo y si se
 * descuenta stock, y eso no puede quedar en manos de un UPDATE suelto desde el
 * navegador (que es, justamente, cómo se registran las mermas hoy).
 *
 * LA LECTURA DE LA FICHA NO USA EMBEDS
 * ------------------------------------
 * `producto_lotes` tiene dos FKs, y aunque hoy apuntan a tablas distintas, un
 * embed ambiguo de PostgREST rompe la consulta ENTERA con PGRST201 y ni `tsc`
 * ni eslint ni los tests lo ven (ya rompió "Armar ruta" en producción). Como la
 * ficha ya conoce el producto, no hace falta ningún embed: un `select` plano
 * filtrado por `producto_id` alcanza.
 */
import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { productosKeys } from './useProductosQuery'
import { mermasKeys } from './useMermasQuery'

/** Una fila de `producto_lotes`, como llega de la base. */
export interface LoteDB {
  id: number
  producto_id: number
  sucursal_id: number
  fecha_vencimiento: string
  cantidad: number
  cantidad_restante: number
  compra_id: number | null
  origen: 'compra' | 'manual'
  created_at: string
}

/** Una fila de `reporte_vencimientos()`. */
export interface LoteReporte {
  lote_id: number
  producto_id: number
  producto_nombre: string
  producto_codigo: string | null
  fecha_vencimiento: string
  cantidad: number
  cantidad_restante: number
  /**
   * Días calculados por el servidor. El front NO lo usa para el semáforo — lo
   * recalcula con `diasHasta` para que la ficha y el panel no puedan diferir.
   * Queda acá porque es el orden natural de la lista y sirve para diagnosticar.
   */
  dias_restantes: number
  origen: 'compra' | 'manual'
  compra_id: number | null
  stock_producto: number
  bolsa_producto: number
}

/** Lo que viaja a `sincronizar_lotes_compra`, ya agrupado por producto y fecha. */
export interface LoteCompraInput {
  producto_id: number
  fecha_vencimiento: string
  cantidad: number
}

export interface SincronizarLotesResult {
  ok: boolean
  lotes: number
  /** Productos a los que hubo que recortarles lotes para que entraran en el stock. */
  warning_clamp: { producto_id: number; unidades: number }[]
}

export const lotesKeys = {
  all: (sucursalId: number | null) => ['lotes', sucursalId] as const,
  byProducto: (sucursalId: number | null, productoId: number | null) =>
    [...lotesKeys.all(sucursalId), 'producto', productoId] as const,
  reporte: (sucursalId: number | null) => [...lotesKeys.all(sucursalId), 'reporte'] as const,
}

// ---------------------------------------------------------------------------
// Lectura
// ---------------------------------------------------------------------------

/** Los lotes vivos de un producto, para el bloque de la ficha. */
export function useLotesProductoQuery(productoId: number | null, habilitado = true) {
  const { currentSucursalId } = useSucursal()

  return useQuery({
    queryKey: lotesKeys.byProducto(currentSucursalId, productoId),
    enabled: habilitado && productoId != null,
    staleTime: 30 * 1000,
    queryFn: async (): Promise<LoteDB[]> => {
      const { data, error } = await supabase
        .from('producto_lotes')
        .select('id, producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id, origen, created_at')
        .eq('producto_id', productoId as number)
        .gt('cantidad_restante', 0)
        .order('fecha_vencimiento', { ascending: true })

      if (error) throw error
      return (data ?? []) as LoteDB[]
    },
  })
}

/**
 * Los lotes cargados por UNA compra, para precargar el modal de edición.
 *
 * Sin esto, editar una compra borraría sus vencimientos en silencio:
 * `sincronizar_lotes_compra` recibe la foto completa de los lotes de la
 * factura, así que abrir el modal, tocar una cantidad y guardar mandaría una
 * lista vacía.
 *
 * Trae también los agotados (`cantidad_restante = 0`), a diferencia de la
 * ficha: son lotes que la compra sí cargó, y omitirlos al reenviar la foto los
 * borraría igual.
 */
export function useLotesCompraQuery(compraId: string | number | null, habilitado = true) {
  const { currentSucursalId } = useSucursal()

  return useQuery({
    queryKey: [...lotesKeys.all(currentSucursalId), 'compra', String(compraId)],
    enabled: habilitado && compraId != null,
    staleTime: 30 * 1000,
    queryFn: async (): Promise<LoteDB[]> => {
      const { data, error } = await supabase
        .from('producto_lotes')
        .select('id, producto_id, sucursal_id, fecha_vencimiento, cantidad, cantidad_restante, compra_id, origen, created_at')
        .eq('compra_id', compraId as string | number)
        .order('fecha_vencimiento', { ascending: true })

      if (error) throw error
      return (data ?? []) as LoteDB[]
    },
  })
}

/**
 * Todos los lotes vivos de la sucursal, para el panel.
 *
 * `p_dias_horizonte` recorta del lado del servidor: sin él, una distribuidora
 * con vencimientos cargados a dos años traería miles de filas para mostrar las
 * veinte que importan. Los ya vencidos entran siempre — su cuenta de días es
 * negativa, así que quedan por debajo de cualquier horizonte.
 */
export function useVencimientosQuery(diasHorizonte: number | null = null) {
  const { currentSucursalId } = useSucursal()

  return useQuery({
    queryKey: [...lotesKeys.reporte(currentSucursalId), diasHorizonte],
    staleTime: 60 * 1000,
    queryFn: async (): Promise<LoteReporte[]> => {
      const { data, error } = await supabase.rpc('reporte_vencimientos', {
        p_dias_horizonte: diasHorizonte,
      })
      if (error) throw error
      return (data ?? []) as LoteReporte[]
    },
  })
}

// ---------------------------------------------------------------------------
// Escritura
// ---------------------------------------------------------------------------

/**
 * Invalida todo lo que un movimiento de lote puede haber cambiado.
 *
 * `productos` entra porque dar de baja un lote baja el stock, y `mermas` porque
 * esa baja deja una fila en el historial.
 */
function useInvalidarLotes() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return () => {
    queryClient.invalidateQueries({ queryKey: lotesKeys.all(currentSucursalId) })
    queryClient.invalidateQueries({ queryKey: productosKeys.all(currentSucursalId) })
    queryClient.invalidateQueries({ queryKey: mermasKeys.all(currentSucursalId) })
  }
}

/**
 * Reescribe los lotes de una compra.
 *
 * La llama `useComprasQuery` justo después de registrar o editar la compra. Es
 * idempotente: manda la foto completa de los vencimientos de esa factura, no un
 * delta.
 */
export function useSincronizarLotesCompraMutation() {
  const invalidar = useInvalidarLotes()

  return useMutation({
    mutationFn: async (input: { compraId: number; lotes: LoteCompraInput[] }) => {
      const { data, error } = await supabase.rpc('sincronizar_lotes_compra', {
        p_compra_id: input.compraId,
        p_lotes: input.lotes,
      })
      if (error) throw error
      return data as unknown as SincronizarLotesResult
    },
    onSuccess: invalidar,
  })
}

/**
 * Etiqueta con una fecha parte del stock que no está en ningún lote.
 *
 * Es el camino del stock que ya existía cuando se prendió la feature: no hay
 * inventario inicial, se carga producto por producto cuando se pasa al lado de
 * la caja. No mueve stock — cambia lo que se sabe, no lo que hay.
 */
export function useCrearLoteManualMutation() {
  const invalidar = useInvalidarLotes()

  return useMutation({
    mutationFn: async (input: { productoId: number; fecha: string; cantidad: number }) => {
      const { data, error } = await supabase.rpc('crear_lote_manual', {
        p_producto_id: input.productoId,
        p_fecha_vencimiento: input.fecha,
        p_cantidad: input.cantidad,
      })
      if (error) throw error
      return data as unknown as { ok: boolean; lote_id: number; bolsa: number }
    },
    onSuccess: invalidar,
  })
}

/**
 * Corrige a mano el contador de un lote.
 *
 * "El sistema dice 12 y en la caja hay 5." Las 7 de diferencia no se pierden:
 * vuelven a la bolsa, que es la respuesta honesta a "existen pero no sé de qué
 * lote son". Si de verdad faltan, eso es una merma y va por el otro camino.
 */
export function useAjustarLoteMutation() {
  const invalidar = useInvalidarLotes()

  return useMutation({
    mutationFn: async (input: { loteId: number; cantidadRestante: number }) => {
      const { data, error } = await supabase.rpc('ajustar_lote', {
        p_lote_id: input.loteId,
        p_cantidad_restante: input.cantidadRestante,
      })
      if (error) throw error
      return data as unknown as { ok: boolean; lote_id: number; cantidad_restante: number; bolsa: number }
    },
    onSuccess: invalidar,
  })
}

/**
 * Da de baja unidades de un lote como merma por vencimiento.
 *
 * Es lo único de este módulo que mueve `productos.stock`, y lo hace por RPC
 * porque son tres escrituras que tienen que ir juntas y en orden: primero el
 * lote, después la merma, y recién ahí el stock. Al revés, el trigger de la
 * mig 223 consumiría por FEFO y podría comerse un lote distinto del que se está
 * dando de baja.
 */
export function useDarDeBajaLoteMutation() {
  const invalidar = useInvalidarLotes()

  return useMutation({
    mutationFn: async (input: { loteId: number; cantidad: number; observaciones?: string }) => {
      const { data, error } = await supabase.rpc('dar_de_baja_lote', {
        p_lote_id: input.loteId,
        p_cantidad: input.cantidad,
        p_observaciones: input.observaciones ?? null,
      })
      if (error) throw error
      return data as unknown as {
        ok: boolean
        lote_id: number
        merma_id: number
        cantidad: number
        cantidad_restante: number
        stock: number
      }
    },
    onSuccess: invalidar,
  })
}
