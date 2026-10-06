/**
 * Escáner de facturas, Entrega B (mig 292): los datos que necesita el matcher
 * (`utils/matchEscaneo`) y la escritura de lo aprendido.
 *
 *   - `candidatos_escaneo(proveedor)`: equivalencias aprendidas + productos ya
 *     comprados a ese proveedor con el último costo. SECURITY INVOKER: un rol
 *     que no lee compras recibe el historial vacío, y el matcher sigue andando
 *     con el catálogo solo.
 *   - `registrar_equivalencias_proveedor`: va DESPUÉS de guardar la compra y no
 *     la bloquea, como los vencimientos. Si falla, se avisa y nada más.
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { CompradoAntes, EquivalenciaARegistrar, EquivalenciaProveedor } from '../../utils/matchEscaneo'

export const escaneoKeys = {
  all: (sucursalId: number | null) => ['escaneo', sucursalId] as const,
  candidatos: (sucursalId: number | null, proveedorId: string | null) =>
    [...escaneoKeys.all(sucursalId), 'candidatos', proveedorId] as const,
}

export interface CandidatosEscaneo {
  equivalencias: EquivalenciaProveedor[];
  comprados: CompradoAntes[];
}

export const CANDIDATOS_VACIOS: CandidatosEscaneo = { equivalencias: [], comprados: [] }

interface FilaEquivalencia {
  producto_id: number | string
  codigo_proveedor: string | null
  descripcion_normalizada: string
  unidades_por_bulto: number | string | null
}

interface FilaComprado {
  producto_id: number | string
  ultimo_costo_unitario: number | string | null
}

/** Antes de aplicar la mig 292 la función no existe: sin candidatos, como antes. */
const noExiste = (error: { message?: string; code?: string } | null): boolean =>
  !!error && (error.code === '42883' || error.code === 'PGRST202' || /does not exist|Could not find the function/i.test(error.message ?? ''))

const numeroONull = (v: number | string | null | undefined): number | null => {
  if (v === null || v === undefined || v === '') return null
  const n = Number(v)
  return Number.isFinite(n) ? n : null
}

export async function fetchCandidatosEscaneo(proveedorId: string): Promise<CandidatosEscaneo> {
  const { data, error } = await supabase.rpc('candidatos_escaneo', { p_proveedor_id: proveedorId })
  if (error) {
    if (noExiste(error)) return CANDIDATOS_VACIOS
    throw error
  }
  const res = (data ?? {}) as { equivalencias?: FilaEquivalencia[]; comprados?: FilaComprado[] }
  return {
    equivalencias: (res.equivalencias ?? []).map(e => ({
      productoId: String(e.producto_id),
      codigoProveedor: e.codigo_proveedor,
      descripcionNormalizada: e.descripcion_normalizada,
      unidadesPorBulto: numeroONull(e.unidades_por_bulto),
    })),
    comprados: (res.comprados ?? []).map(c => ({
      productoId: String(c.producto_id),
      ultimoCosto: numeroONull(c.ultimo_costo_unitario),
    })),
  }
}

/** Candidatos del proveedor en la sucursal activa. Sin proveedor no consulta. */
export function useCandidatosEscaneoQuery(proveedorId: string | null | undefined) {
  const { currentSucursalId } = useSucursal()
  const id = proveedorId ? String(proveedorId) : null
  return useQuery({
    queryKey: escaneoKeys.candidatos(currentSucursalId, id),
    queryFn: () => fetchCandidatosEscaneo(id as string),
    enabled: !!id && currentSucursalId != null,
    staleTime: 5 * 60 * 1000,
  })
}

export async function registrarEquivalenciasProveedor(
  proveedorId: string | number,
  items: EquivalenciaARegistrar[],
): Promise<{ insertadas: number; actualizadas: number }> {
  if (items.length === 0) return { insertadas: 0, actualizadas: 0 }
  const { data, error } = await supabase.rpc('registrar_equivalencias_proveedor', {
    p_proveedor_id: proveedorId,
    p_items: items,
  })
  if (error) throw error
  const res = (data ?? {}) as { insertadas?: number; actualizadas?: number }
  return { insertadas: res.insertadas ?? 0, actualizadas: res.actualizadas ?? 0 }
}

/**
 * La versión que usa el alta de la compra: nunca tira. Devuelve el texto del
 * aviso si falló — la compra ya está guardada y no se deshace por esto; lo
 * único que se pierde es que la próxima factura no lo reconozca sola.
 */
export async function guardarEquivalenciasDeCompra(
  proveedorId: string | number | null | undefined,
  items: EquivalenciaARegistrar[] | undefined,
): Promise<string | null> {
  if (!proveedorId || !items || items.length === 0) return null
  try {
    await registrarEquivalenciasProveedor(proveedorId, items)
    return null
  } catch (e) {
    // El error de PostgREST puede llegar como objeto plano, no como Error.
    const mensaje = (e as { message?: unknown } | null)?.message
    return `La compra se registró, pero no se pudo guardar qué producto es cada línea de la factura: ${
      typeof mensaje === 'string' && mensaje ? mensaje : 'error desconocido'
    }. La próxima factura de este proveedor no las va a reconocer solas.`
  }
}

export function useRegistrarEquivalenciasMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()
  return useMutation({
    mutationFn: ({ proveedorId, items }: { proveedorId: string | number; items: EquivalenciaARegistrar[] }) =>
      registrarEquivalenciasProveedor(proveedorId, items),
    onSuccess: (_data, { proveedorId }) => {
      queryClient.invalidateQueries({ queryKey: escaneoKeys.candidatos(currentSucursalId, String(proveedorId)) })
    },
  })
}
