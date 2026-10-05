/**
 * Promociones de compra del proveedor (#908, tablas `promociones_proveedor` y
 * `promocion_proveedor_productos`).
 *
 * Las lee el modal de compra para sugerir la bonificación que la factura no
 * descontó (utils/sugerenciasBonificacion) y las edita admin desde la ficha del
 * proveedor (ModalPromocionesProveedor). Son POR SUCURSAL, como la ficha del
 * proveedor: la key lleva la sucursal.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { PromocionProveedor, TipoPromocionProveedor } from '../../utils/sugerenciasBonificacion'

export const promocionesProveedorKeys = {
  all: (sucursalId: number | null) => ['promociones_proveedor', sucursalId] as const,
  deProveedor: (sucursalId: number | null, proveedorId: string) =>
    [...promocionesProveedorKeys.all(sucursalId), proveedorId] as const,
}

/** Una promo con lo que sólo usa la pantalla de edición. */
export interface PromocionProveedorDetalle extends PromocionProveedor {
  proveedorId: string
  notas: string | null
}

interface FilaPromo {
  id: number | string
  proveedor_id: number | string
  nombre: string
  tipo: string
  monto_por_unidad: number | string | null
  porcentaje: number | string | null
  vigente_desde: string | null
  vigente_hasta: string | null
  activo: boolean | null
  notas: string | null
  promocion_proveedor_productos: Array<{ producto_id: number | string }> | null
}

/**
 * Antes de aplicar la migración la tabla no existe: la lista vacía deja el
 * modal de compra funcionando como antes, sin sugerencias.
 */
const noExiste = (error: { message?: string; code?: string } | null): boolean =>
  !!error && (error.code === '42P01' || error.code === 'PGRST205' || /does not exist|Could not find the table/i.test(error.message ?? ''))

const numeroONull = (v: number | string | null): number | null => {
  if (v === null || v === undefined || v === '') return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

export async function fetchPromocionesProveedor(proveedorId: string, sucursalId: number | null): Promise<PromocionProveedorDetalle[]> {
  let query = supabase
    .from('promociones_proveedor')
    .select('id, proveedor_id, nombre, tipo, monto_por_unidad, porcentaje, vigente_desde, vigente_hasta, activo, notas, promocion_proveedor_productos(producto_id)')
    .eq('proveedor_id', Number(proveedorId))
    .order('nombre')
  if (sucursalId !== null) query = query.eq('sucursal_id', sucursalId)
  const { data, error } = await query
  if (error) {
    if (noExiste(error)) return []
    throw error
  }
  return ((data ?? []) as FilaPromo[]).map(f => ({
    id: String(f.id),
    proveedorId: String(f.proveedor_id),
    nombre: f.nombre,
    tipo: (f.tipo === 'porcentaje' ? 'porcentaje' : 'monto_por_unidad') as TipoPromocionProveedor,
    montoPorUnidad: numeroONull(f.monto_por_unidad),
    porcentaje: numeroONull(f.porcentaje),
    vigenteDesde: f.vigente_desde,
    vigenteHasta: f.vigente_hasta,
    activo: f.activo ?? true,
    notas: f.notas,
    productoIds: (f.promocion_proveedor_productos ?? []).map(p => String(p.producto_id)),
  }))
}

/** Las promos de un proveedor (todas: activas e inactivas). `null` apaga la query. */
export function usePromocionesProveedorQuery(proveedorId: string | null | undefined) {
  const { currentSucursalId } = useSucursal()
  const id = proveedorId ? String(proveedorId) : ''
  return useQuery({
    queryKey: promocionesProveedorKeys.deProveedor(currentSucursalId, id),
    queryFn: () => fetchPromocionesProveedor(id, currentSucursalId),
    enabled: id !== '',
    staleTime: 5 * 60 * 1000,
  })
}

export interface GuardarPromocionProveedorInput {
  /** Sin id: alta. */
  id?: string | null
  proveedorId: string
  nombre: string
  tipo: TipoPromocionProveedor
  montoPorUnidad: number | null
  porcentaje: number | null
  vigenteDesde: string | null
  vigenteHasta: string | null
  activo: boolean
  notas: string | null
  productoIds: string[]
  /** El alcance que tenía al abrirla (para mandar sólo la diferencia). */
  productoIdsPrevios?: string[]
}

/**
 * Alta o edición, con su alcance. El alcance se sincroniza por diferencia
 * (inserta lo nuevo, borra lo que se sacó) en vez de borrar todo y volver a
 * insertar: si el segundo paso falla, la promo queda con el alcance de antes
 * y no vacía.
 */
export async function guardarPromocionProveedor(input: GuardarPromocionProveedorInput, sucursalId: number | null): Promise<string> {
  if (sucursalId === null) throw new Error('No hay sucursal activa.')
  const fila = {
    proveedor_id: Number(input.proveedorId),
    nombre: input.nombre.trim(),
    tipo: input.tipo,
    // El CHECK de la tabla exige el otro número vacío.
    monto_por_unidad: input.tipo === 'monto_por_unidad' ? input.montoPorUnidad : null,
    porcentaje: input.tipo === 'porcentaje' ? input.porcentaje : null,
    vigente_desde: input.vigenteDesde || null,
    vigente_hasta: input.vigenteHasta || null,
    activo: input.activo,
    notas: input.notas?.trim() || null,
  }

  let promoId: string
  if (input.id) {
    const { error } = await supabase
      .from('promociones_proveedor')
      .update({ ...fila, updated_at: new Date().toISOString() })
      .eq('id', Number(input.id))
    if (error) throw error
    promoId = String(input.id)
  } else {
    const { data, error } = await supabase
      .from('promociones_proveedor')
      .insert({ ...fila, sucursal_id: sucursalId })
      .select('id')
      .single()
    if (error) throw error
    promoId = String((data as { id: number | string }).id)
  }

  const previos = new Set((input.productoIdsPrevios ?? []).map(String))
  const nuevos = new Set(input.productoIds.map(String))
  const agregar = [...nuevos].filter(p => !previos.has(p))
  const quitar = [...previos].filter(p => !nuevos.has(p))
  if (agregar.length > 0) {
    const { error } = await supabase.from('promocion_proveedor_productos').insert(
      agregar.map(p => ({ promocion_id: Number(promoId), sucursal_id: sucursalId, producto_id: Number(p) }))
    )
    if (error) throw error
  }
  if (quitar.length > 0) {
    const { error } = await supabase
      .from('promocion_proveedor_productos')
      .delete()
      .eq('promocion_id', Number(promoId))
      .in('producto_id', quitar.map(Number))
    if (error) throw error
  }
  return promoId
}

export async function eliminarPromocionProveedor(id: string): Promise<void> {
  // El alcance se va por ON DELETE CASCADE.
  const { error } = await supabase.from('promociones_proveedor').delete().eq('id', Number(id))
  if (error) throw error
}

export function useGuardarPromocionProveedorMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: (input: GuardarPromocionProveedorInput) => guardarPromocionProveedor(input, currentSucursalId),
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: promocionesProveedorKeys.all(currentSucursalId) })
    },
  })
}

export function useEliminarPromocionProveedorMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: eliminarPromocionProveedor,
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: promocionesProveedorKeys.all(currentSucursalId) })
    },
  })
}
