/**
 * TanStack Query hooks para el catálogo de cargos de compra (mig 278):
 * conceptos y medidas (GLOBALES, sin sucursal en la key) y las medidas de cada
 * producto (POR SUCURSAL: productos es por sucursal).
 *
 * Además las dos llamadas que hace la compra al guardar, por separado y sin
 * bloquear: el alta de conceptos nuevos (`asegurar_cargo_concepto`, antes de
 * la RPC de la compra, para que la compra ya guarde el id) y las medidas que
 * van a la ficha (`guardar_producto_medidas`, después, como los vencimientos).
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { ConceptoCargo, MedidaCargo, MedidaFichaInput, MedidasPorProducto } from '../../utils/medidasCargo'
import type { CompraCargoInput } from '../../types'

export const cargosCatalogoKeys = {
  conceptos: () => ['cargo_conceptos'] as const,
  medidas: () => ['cargo_medidas'] as const,
  productoMedidas: (sucursalId: number | null) => ['producto_medidas', sucursalId] as const,
}

const BASES = ['monto', 'cantidad', 'unidades', 'medida'] as const
const CONDICIONES = ['gravado', 'exento', 'no_gravado'] as const

interface FilaConcepto {
  id: number | string
  nombre: string
  signo: number | null
  condicion_iva: string | null
  en_factura: boolean | null
  prorratea_al_costo: boolean | null
  base_prorrateo: string | null
  medida_id: number | string | null
  activo: boolean | null
}

interface FilaMedida {
  id: number | string
  nombre: string
  unidad_singular: string | null
  medida_base_id: number | string | null
  activo: boolean | null
}

/**
 * Antes de aplicar la mig 278 la tabla no existe: la lista vacía deja el modal
 * funcionando como antes (concepto como texto libre, sin base 'medida').
 */
const noExiste = (error: { message?: string; code?: string } | null): boolean =>
  !!error && (error.code === '42P01' || error.code === 'PGRST205' || /does not exist|Could not find the table/i.test(error.message ?? ''))

async function fetchConceptos(): Promise<ConceptoCargo[]> {
  const { data, error } = await supabase
    .from('cargo_conceptos')
    .select('id, nombre, signo, condicion_iva, en_factura, prorratea_al_costo, base_prorrateo, medida_id, activo')
    .order('nombre')
  if (error) {
    if (noExiste(error)) return []
    throw error
  }
  return ((data ?? []) as FilaConcepto[]).map(f => ({
    id: String(f.id),
    nombre: f.nombre,
    signo: Number(f.signo) < 0 ? -1 : 1,
    condicionIva: (CONDICIONES as readonly string[]).includes(f.condicion_iva ?? '')
      ? (f.condicion_iva as ConceptoCargo['condicionIva'])
      : 'no_gravado',
    enFactura: f.en_factura ?? true,
    prorrateaAlCosto: f.prorratea_al_costo ?? true,
    baseProrrateo: (BASES as readonly string[]).includes(f.base_prorrateo ?? '')
      ? (f.base_prorrateo as ConceptoCargo['baseProrrateo'])
      : 'monto',
    medidaId: f.medida_id == null ? null : String(f.medida_id),
    activo: f.activo ?? true,
  }))
}

async function fetchMedidas(): Promise<MedidaCargo[]> {
  const { data, error } = await supabase
    .from('cargo_medidas')
    .select('id, nombre, unidad_singular, medida_base_id, activo')
    .order('id')
  if (error) {
    if (noExiste(error)) return []
    throw error
  }
  return ((data ?? []) as FilaMedida[]).map(f => ({
    id: String(f.id),
    nombre: f.nombre,
    unidadSingular: f.unidad_singular || f.nombre.toLowerCase(),
    medidaBaseId: f.medida_base_id == null ? null : String(f.medida_base_id),
    activo: f.activo ?? true,
  }))
}

/**
 * Las medidas de TODOS los productos de la sucursal activa, como
 * productoId → medidaId → unidades_por. Son pocas filas (una por producto y
 * medida que alguien cargó) y la compra las necesita para cualquier línea que
 * se agregue, así que se piden enteras una vez.
 */
async function fetchProductoMedidas(sucursalId: number | null): Promise<MedidasPorProducto<number>> {
  let query = supabase.from('producto_medidas').select('producto_id, medida_id, unidades_por')
  if (sucursalId !== null) query = query.eq('sucursal_id', sucursalId)
  const { data, error } = await query
  if (error) {
    if (noExiste(error)) return {}
    throw error
  }
  const salida: MedidasPorProducto<number> = {}
  for (const f of (data ?? []) as Array<{ producto_id: number | string; medida_id: number | string; unidades_por: number | string }>) {
    const n = Number(f.unidades_por)
    if (!Number.isFinite(n) || n <= 0) continue
    const producto = String(f.producto_id)
    salida[producto] = { ...(salida[producto] ?? {}), [String(f.medida_id)]: n }
  }
  return salida
}

export function useCargoConceptosQuery() {
  return useQuery({
    queryKey: cargosCatalogoKeys.conceptos(),
    queryFn: fetchConceptos,
    staleTime: 10 * 60 * 1000,
  })
}

export function useCargoMedidasQuery() {
  return useQuery({
    queryKey: cargosCatalogoKeys.medidas(),
    queryFn: fetchMedidas,
    staleTime: 10 * 60 * 1000,
  })
}

export function useProductoMedidasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: cargosCatalogoKeys.productoMedidas(currentSucursalId),
    queryFn: () => fetchProductoMedidas(currentSucursalId),
    staleTime: 5 * 60 * 1000,
  })
}

/** Una medida para la ficha. `unidadesPor: null` la borra. */
export type MedidaProductoInput = Omit<MedidaFichaInput, 'unidadesPor'> & { unidadesPor: number | null }

/** Llama a `guardar_producto_medidas`. Lanza si la RPC rechaza. */
export async function guardarProductoMedidas(items: MedidaProductoInput[]): Promise<void> {
  if (items.length === 0) return
  const { error } = await supabase.rpc('guardar_producto_medidas', {
    p_items: items.map(i => ({
      // bigint: número, no string (mismo criterio que cambiar_proveedor_compra).
      producto_id: Number(i.productoId),
      medida_id: Number(i.medidaId),
      unidades_por: i.unidadesPor,
    })),
  })
  if (error) throw error
}

export function useGuardarProductoMedidasMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: guardarProductoMedidas,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: cargosCatalogoKeys.productoMedidas(currentSucursalId) })
    },
  })
}

/**
 * Las medidas de la ficha que vienen de una compra, después de registrarla.
 * NO propaga: la compra ya está guardada. Devuelve el texto del aviso.
 */
export async function guardarMedidasDeFicha(items: MedidaFichaInput[] | undefined): Promise<string | null> {
  if (!items || items.length === 0) return null
  try {
    await guardarProductoMedidas(items)
    return null
  } catch (e) {
    return `La compra se registró, pero las unidades por pallet no se pudieron guardar en la ficha: ${
      e instanceof Error ? e.message : 'error desconocido'
    }. Se pueden cargar a mano desde la ficha del producto.`
  }
}

/**
 * Da de alta los conceptos nuevos ("+ Crear 'X'") y devuelve los cargos con su
 * id. Va ANTES de la RPC de la compra para que la compra guarde el id, pero no
 * la bloquea: si un alta falla, ese cargo viaja sin concepto_id y se avisa.
 *
 * El signo del concepto sale del monto (el toggle +/- del renglón): un monto
 * negativo es una bonificación.
 */
export async function asegurarConceptosDeCargos(
  cargos: CompraCargoInput[] | null | undefined,
): Promise<{ cargos: CompraCargoInput[] | null | undefined; warning: string | null }> {
  if (!cargos || !cargos.some(c => c.crearConcepto && !c.conceptoId)) return { cargos, warning: null }
  const fallidos: string[] = []
  const salida: CompraCargoInput[] = []
  for (const c of cargos) {
    if (!c.crearConcepto || c.conceptoId) {
      salida.push(c)
      continue
    }
    try {
      const { data, error } = await supabase.rpc('asegurar_cargo_concepto', {
        p_nombre: c.concepto,
        p_signo: c.monto < 0 ? -1 : 1,
        p_condicion_iva: c.condicionIva,
        p_en_factura: c.enFactura,
        p_prorratea_al_costo: c.prorrateaAlCosto,
        p_base_prorrateo: c.baseProrrateo,
        p_medida_id: c.baseProrrateo === 'medida' && c.medidaId ? Number(c.medidaId) : null,
      })
      if (error) throw error
      salida.push({ ...c, conceptoId: data == null ? null : String(data), crearConcepto: false })
    } catch {
      fallidos.push(c.concepto)
      salida.push({ ...c, crearConcepto: false })
    }
  }
  return {
    cargos: salida,
    warning: fallidos.length > 0
      ? `La compra se registró, pero ${fallidos.length === 1 ? 'el concepto' : 'los conceptos'} ${fallidos.map(f => `"${f}"`).join(', ')} no se pudo agregar al catálogo.`
      : null,
  }
}
