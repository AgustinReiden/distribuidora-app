/**
 * TanStack Query hooks para Compras
 * Reemplaza el hook useCompras con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { fechaLocalISO } from '../../utils/formatters'
import type {
  BaseProrrateoCompra,
  CargoPlantillaCompra,
  CompraCargoInput,
  CompraDBExtended,
  CompraFormInputExtended,
  CondicionIva,
  PlantillaCargosProveedor,
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
  /** mig 177: el RPC normaliza lo que no reconozca a 'gravado' */
  condicion_iva: CondicionIva
  impuestos_internos: number
}

interface RPCResult {
  success: boolean
  compra_id: string
  error?: string
  /** Avisos blandos: la compra se guardó igual. Ver RegistrarCompraResult. */
  warning_descuadre?: string | null
  warning_ii_declarado?: string | null
}

/**
 * Los cargos en el shape que espera la mig 194: snake_case y los pesos por
 * índice del array de items del mismo payload.
 *
 * La traducción de `lineaId` a índice ya vino hecha (`cargosParaRPC` del
 * reducer, o el remapeo de ModalEditarCompra): acá sólo se renombra.
 */
function serializarCargos(cargos: CompraCargoInput[]): Array<Record<string, unknown>> {
  return cargos.map(c => ({
    concepto: c.concepto,
    monto: c.monto,
    condicion_iva: c.condicionIva,
    en_factura: c.enFactura,
    prorratea_al_costo: c.prorrateaAlCosto,
    afecta_base_ii: c.afectaBaseII,
    base_prorrateo: c.baseProrrateo,
    pesos: c.pesos,
  }))
}

// Fetch functions
async function fetchCompras(): Promise<CompraDBExtended[]> {
  const { data, error } = await supabase
    .from('compras')
    .select(`
      *,
      proveedor:proveedores(*),
      items:compra_items(*, producto:productos(*)),
      usuario:perfiles(id, nombre),
      cargos:compra_cargos(
        id, orden, concepto, monto, condicion_iva, en_factura,
        prorratea_al_costo, afecta_base_ii, base_prorrateo,
        repartos:compra_cargo_repartos(compra_item_id, peso)
      )
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
      usuario:perfiles(id, nombre),
      cargos:compra_cargos(
        id, orden, concepto, monto, condicion_iva, en_factura,
        prorratea_al_costo, afecta_base_ii, base_prorrateo,
        repartos:compra_cargo_repartos(compra_item_id, peso)
      )
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

/** Las filas crudas que necesita la plantilla de cargos. */
interface FilaPlantillaCargos {
  id: string | number
  numero_factura: string | null
  fecha_compra: string | null
  items: Array<{ id: string | number; producto_id: string | number }> | null
  cargos: Array<{
    orden: number | null
    concepto: string
    condicion_iva: CondicionIva | null
    en_factura: boolean | null
    prorratea_al_costo: boolean | null
    afecta_base_ii: boolean | null
    base_prorrateo: BaseProrrateoCompra | null
    repartos: Array<{ compra_item_id: string | number; peso: number | string | null }> | null
  }> | null
}

/**
 * Los cargos de la última compra no cancelada de un proveedor, para reusarlos
 * en la que se está cargando.
 *
 * El `!inner` del embed no es decoración: sin él "la última compra" es la última
 * a secas, y el botón se queda mudo apenas el proveedor mete una factura sin
 * flete. Lo que sirve de plantilla es la última compra que TIENE cargos.
 *
 * Los pesos se traducen de `compra_item_id` a `producto_id` acá y no en el
 * modal: el id de la línea vieja sólo se puede resolver contra los items de
 * ESTA query, y afuera no significa nada.
 *
 * Devuelve null cuando el proveedor no tiene ninguna compra con cargos. La RLS
 * de `compra_cargos` pide admin o depósito, así que para otro rol el `!inner`
 * deja la lista vacía y el botón simplemente no aparece.
 */
async function fetchCargosPlantillaProveedor(proveedorId: string): Promise<PlantillaCargosProveedor | null> {
  const { data, error } = await supabase
    .from('compras')
    .select(`
      id,
      numero_factura,
      fecha_compra,
      items:compra_items(id, producto_id),
      cargos:compra_cargos!inner(
        orden,
        concepto,
        condicion_iva,
        en_factura,
        prorratea_al_costo,
        afecta_base_ii,
        base_prorrateo,
        repartos:compra_cargo_repartos(compra_item_id, peso)
      )
    `)
    .eq('proveedor_id', proveedorId)
    // En prod los estados son 'recibida' y 'cancelada'; no hay 'activa'.
    .neq('estado', 'cancelada')
    .order('fecha_compra', { ascending: false })
    .order('id', { ascending: false })
    .limit(1)

  if (error) throw error

  const compra = (data as FilaPlantillaCargos[] | null)?.[0]
  if (!compra) return null

  const productoPorItem = new Map<string, string>(
    (compra.items ?? []).map(i => [String(i.id), String(i.producto_id)])
  )

  // El orden de los cargos se ordena acá y no en la query: `orden` es una
  // columna de la tabla embebida y ordenar por ahí depende de la versión del
  // cliente. Son 6 cargos en la factura más grande.
  const cargos: CargoPlantillaCompra[] = [...(compra.cargos ?? [])]
    .sort((a, b) => (a.orden ?? 0) - (b.orden ?? 0))
    .map(c => {
      const pesosPorProducto: Record<string, number> = {}
      for (const r of c.repartos ?? []) {
        const productoId = productoPorItem.get(String(r.compra_item_id))
        if (productoId === undefined) continue
        // Dos líneas del mismo producto en la compra vieja: los pesos se suman.
        // En la compra nueva hay una sola línea por producto (AGREGAR_ITEM las
        // fusiona), así que lo que corresponde traer es el peso del producto
        // entero y no el de una de sus dos mitades.
        pesosPorProducto[productoId] = (pesosPorProducto[productoId] ?? 0) + Number(r.peso ?? 0)
      }
      return {
        concepto: c.concepto,
        condicionIva: c.condicion_iva ?? 'no_gravado',
        enFactura: c.en_factura ?? true,
        prorrateaAlCosto: c.prorratea_al_costo ?? true,
        afectaBaseII: c.afecta_base_ii ?? false,
        baseProrrateo: c.base_prorrateo ?? 'unidades',
        pesosPorProducto,
      }
    })

  return {
    compraId: String(compra.id),
    numeroFactura: compra.numero_factura ?? null,
    fechaCompra: compra.fecha_compra ?? null,
    cargos,
  }
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
    condicion_iva: item.condicionIva ?? 'gravado',
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
    p_no_gravado: compraData.noGravado || 0,
    // mig 195. Sin esto, una factura con bonificación general queda con el total
    // de cabecera por encima del papel (306.784,09 en la testigo) y COMPRA-A1
    // —severidad high— se pone rojo, que es lo que vuelve inútil al gate diario.
    p_bonificaciones: compraData.bonificaciones || 0,
    // mig 194. Sin estos dos la RPC no ejecuta una sola línea del camino nuevo
    // del costo: el flete no llega a ningún producto y el factor de ajuste del
    // impuesto interno se calcula en la vista previa y se tira a la basura.
    p_cargos: serializarCargos(compraData.cargos ?? []),
    p_ii_declarado: compraData.iiDeclarado ?? {}
  })

  if (error) throw error

  const result = data as RPCResult
  if (!result.success) {
    throw new Error(result.error || 'Error al registrar compra')
  }

  // Los avisos suben tal como los redactó la RPC, sin reinterpretarlos. Son
  // blandos por diseño —la compra está registrada— y decían dos cosas que
  // nadie estaba leyendo: que el total calculado no coincide con el informado,
  // y que la apertura del impuesto interno por alícuota no cierra contra el
  // total (o declara una tasa que ninguna línea usa, con lo cual ese importe
  // no llega a ningún costo).
  return {
    success: true,
    compraId: result.compra_id,
    warningDescuadre: result.warning_descuadre ?? null,
    warningIiDeclarado: result.warning_ii_declarado ?? null,
  }
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
 * Cargos de la última compra con cargos de un proveedor, como plantilla.
 *
 * Se dispara al elegir el proveedor y no al apretar el botón: así el modal sabe
 * ANTES si hay algo para traer y puede decir cuántos cargos y de qué factura,
 * en vez de ofrecer un botón que a veces no hace nada.
 */
export function useCargosPlantillaProveedorQuery(proveedorId: string | null | undefined) {
  const { currentSucursalId } = useSucursal()
  const id = proveedorId ? String(proveedorId) : ''
  return useQuery({
    queryKey: [...comprasKeys.byProveedor(currentSucursalId, id), 'cargos-plantilla'] as const,
    queryFn: () => fetchCargosPlantillaProveedor(id),
    enabled: !!id,
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
    condicionIva?: CondicionIva
    impuestosInternos?: number
  }>
  /**
   * Los cargos de la compra (mig 194). Obligatorio y no opcional a propósito:
   * `actualizar_compra_items` borra y recrea las líneas en cada edición y el
   * CASCADE se lleva puesto el vector de pesos, así que un cliente que no los
   * reenvía deja los cargos vivos con el vector vacío y el flete deja de
   * repartirse en silencio. Que el tipo lo exija obliga a cada llamador a
   * decidir, en vez de olvidarse.
   *
   * `null` significa "no los conozco" y es lo único que activa el guard de la
   * RPC; `[]` significa "esta compra no tiene ninguno" y es un dato. Mandar `[]`
   * cuando no se leyeron los borra, que es justo lo que el guard impide.
   *
   * Los pesos van por índice de `items` (base 0), ya remapeados a las líneas
   * que sobreviven a esta edición.
   */
  cargos: CompraCargoInput[] | null
  /** El II declarado por alícuota, con la misma distinción null/{}: sin él el factor de ajuste se revierte solo. */
  iiDeclarado: Record<number, number> | null
  /** Σ de los cargos gravados en factura, con su signo (mig 195). null = no tocar. */
  bonificaciones?: number | null
}

/** Producto cuyo CPP puede haber quedado distorsionado al editar una compra vieja (mig 128). */
export interface WarningCostoPromedio {
  producto_id: number
  costo_real_anterior: number
  costo_real_nuevo: number
}

async function actualizarCompraItems(
  input: ActualizarCompraItemsInput
): Promise<{ compraId: string; warningCostoPromedio: WarningCostoPromedio[]; warningIiDeclarado: string | null }> {
  const itemsParaRPC: CompraItemRPC[] = input.items.map(item => ({
    producto_id: item.productoId,
    cantidad: item.cantidad,
    costo_unitario: item.costoUnitario,
    subtotal: item.subtotal,
    bonificacion: item.bonificacion ?? 0,
    porcentaje_iva: item.porcentajeIva ?? 21,
    condicion_iva: item.condicionIva ?? 'gravado',
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
    // mig 195. `null` = "no lo mandes", y la RPC deja lo que ya tenía: un
    // cliente viejo no puede borrar la bonificación de cabecera sin querer.
    p_bonificaciones: input.bonificaciones ?? null,
    // mig 194. `null` viaja como null a propósito: es lo que hace que la RPC
    // rechace la edición de una compra con cargos hecha por un cliente que no
    // los leyó, en vez de borrárselos en silencio.
    p_cargos: input.cargos === null ? null : serializarCargos(input.cargos),
    p_ii_declarado: input.iiDeclarado,
  })

  if (error) throw error
  const result = data as {
    success: boolean
    compra_id: string
    error?: string
    warning_costo_promedio?: WarningCostoPromedio[] | null
    warning_ii_declarado?: string | null
  }
  if (!result.success) {
    throw new Error(result.error || 'Error al actualizar compra')
  }
  // `actualizar_compra_items` NO devuelve `warning_descuadre`: no recalcula el
  // total contra el informado, lo recibe ya hecho. Sólo el del II declarado.
  return {
    compraId: result.compra_id,
    warningCostoPromedio: result.warning_costo_promedio ?? [],
    warningIiDeclarado: result.warning_ii_declarado ?? null,
  }
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

/**
 * Input para cambiar el proveedor de una compra (admin only).
 * En vez de reescribir la fila, el RPC anula la compra vieja y crea una nueva
 * idéntica (mismos items, importes, fecha, factura) con el proveedor nuevo, sin
 * tocar stock ni costos. Analogo a cambiar_cliente_pedido. Ver mig 125.
 */
export interface CambiarProveedorCompraInput {
  compraId: string
  /** id del proveedor existente elegido; null si se usa un nombre nuevo. */
  nuevoProveedorId: string | null
  /** nombre denormalizado si no hay id (fallback). */
  nuevoProveedorNombre: string | null
  usuarioId: string | null
  motivo?: string
}

async function cambiarProveedorCompra(input: CambiarProveedorCompraInput): Promise<{ nuevaCompraId: string }> {
  const { data, error } = await supabase.rpc('cambiar_proveedor_compra', {
    p_compra_id: input.compraId,
    p_usuario_id: input.usuarioId,
    // ids son bigint: mandar numero, no string (ver cambio "Invalid input")
    p_nuevo_proveedor_id: input.nuevoProveedorId ? Number(input.nuevoProveedorId) : null,
    p_nuevo_proveedor_nombre: input.nuevoProveedorNombre || null,
    ...(input.motivo ? { p_motivo: input.motivo } : {}),
  })

  if (error) throw error
  const result = data as { success: boolean; nueva_compra_id?: string | number; error?: string }
  if (!result.success) {
    throw new Error(result.error || 'Error al cambiar el proveedor')
  }
  return { nuevaCompraId: String(result.nueva_compra_id) }
}

/**
 * Hook para cambiar el proveedor de una compra: anula la vieja y crea una nueva
 * idéntica con el proveedor correcto, vía RPC atómico. No mueve stock/costos.
 */
export function useCambiarProveedorCompraMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: cambiarProveedorCompra,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: comprasKeys.lists(currentSucursalId) })
      queryClient.invalidateQueries({ queryKey: ['productos'] })
    },
  })
}
