/**
 * TanStack Query hooks para Clientes
 * Reemplaza el hook useClientes con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { ClienteDB } from '../../types'

// Query keys
export const clientesKeys = {
  all: (sucursalId: number | null) => ['clientes', sucursalId] as const,
  lists: (sucursalId: number | null, includeInactivos = false) =>
    [...clientesKeys.all(sucursalId), 'list', includeInactivos] as const,
  list: (sucursalId: number | null, filters: Record<string, unknown>) => [...clientesKeys.lists(sucursalId), filters] as const,
  details: (sucursalId: number | null) => [...clientesKeys.all(sucursalId), 'detail'] as const,
  detail: (sucursalId: number | null, id: string) => [...clientesKeys.details(sucursalId), id] as const,
  byZona: (sucursalId: number | null, zona: string) => [...clientesKeys.all(sucursalId), 'zona', zona] as const,
  zonas: (sucursalId: number | null) => [...clientesKeys.all(sucursalId), 'zonas'] as const,
}

type ClienteRow = ClienteDB & {
  cliente_preventistas?: { preventista_id: string }[] | null
  cliente_descuentos_categoria?: { categoria: string; descuento_porcentaje: number }[] | null
}

function flattenClienteRow(row: ClienteRow): ClienteDB {
  const { cliente_preventistas, cliente_descuentos_categoria, ...rest } = row
  return {
    ...rest,
    preventista_ids: (cliente_preventistas || []).map(cp => cp.preventista_id),
    descuentos_categoria: (cliente_descuentos_categoria || []).map(d => ({
      categoria: d.categoria,
      descuento_porcentaje: Number(d.descuento_porcentaje) || 0,
    })),
  }
}

const CLIENTE_SELECT = '*, cliente_preventistas(preventista_id), cliente_descuentos_categoria(categoria, descuento_porcentaje)'

// Fetch functions

// Baja logica: `activo = false` es un cliente dado de baja. Se filtra ACA y no en
// cada consumidor porque este fetch alimenta el panel, los tres autocompletes de
// pedidos, el dashboard y los recorridos: un filtro por pantalla se olvida en la
// proxima. Hasta la mig 200 la app ofrecia desactivar y no filtraba en ningun
// lado, asi que el cliente "desactivado" seguia apareciendo entero y la accion
// parecia no hacer nada.
// El historial NO pasa por aca: los pedidos viejos resuelven el nombre por el
// embed `cliente:clientes(*)` de PedidosContainer, y los reportes por sus RPCs.
async function fetchClientes(includeInactivos = false): Promise<ClienteDB[]> {
  let query = supabase
    .from('clientes')
    .select(CLIENTE_SELECT)
    .order('nombre_fantasia')

  if (!includeInactivos) query = query.eq('activo', true)

  const { data, error } = await query

  if (error) throw error
  return ((data as ClienteRow[]) || []).map(flattenClienteRow)
}

async function fetchClienteById(id: string): Promise<ClienteDB | null> {
  const { data, error } = await supabase
    .from('clientes')
    .select(CLIENTE_SELECT)
    .eq('id', id)
    .single()

  if (error) throw error
  return data ? flattenClienteRow(data as ClienteRow) : null
}

/**
 * Reemplaza las filas en `cliente_preventistas` para un cliente dado.
 * Idempotente: si el array viene vacío borra todas las asignaciones.
 */
async function replacePreventistaAssignments(
  clienteId: string,
  preventistaIds: string[]
): Promise<void> {
  const { error: delError } = await supabase
    .from('cliente_preventistas')
    .delete()
    .eq('cliente_id', clienteId)
  if (delError) throw delError

  if (preventistaIds.length === 0) return

  const rows = preventistaIds.map(pid => ({ cliente_id: clienteId, preventista_id: pid }))
  const { error: insError } = await supabase
    .from('cliente_preventistas')
    .insert(rows)
  if (insError) throw insError
}

/**
 * Reemplaza los descuentos por categoría de un cliente (delete + insert).
 * Idempotente. Dedup por categoría normalizada (la última gana) para no chocar
 * con el UNIQUE (cliente_id, categoria). Filas sin categoría se descartan.
 */
async function replaceCategoriaDiscounts(
  clienteId: string,
  descuentos: { categoria: string; descuento_porcentaje: number }[]
): Promise<void> {
  const { error: delError } = await supabase
    .from('cliente_descuentos_categoria')
    .delete()
    .eq('cliente_id', clienteId)
  if (delError) throw delError

  const dedup = new Map<string, { cliente_id: string; categoria: string; descuento_porcentaje: number }>()
  for (const d of descuentos || []) {
    const categoria = (d.categoria || '').trim()
    if (!categoria) continue
    dedup.set(categoria.toUpperCase(), {
      cliente_id: clienteId,
      categoria,
      descuento_porcentaje: d.descuento_porcentaje,
    })
  }
  const rows = [...dedup.values()]
  if (rows.length === 0) return

  const { error: insError } = await supabase
    .from('cliente_descuentos_categoria')
    .insert(rows)
  if (insError) throw insError
}

async function fetchClientesByZona(zona: string): Promise<ClienteDB[]> {
  const { data, error } = await supabase
    .from('clientes')
    .select('*')
    .eq('zona', zona)
    .order('nombre_fantasia')

  if (error) throw error
  return (data as ClienteDB[]) || []
}

async function fetchZonasUnicas(): Promise<string[]> {
  const { data, error } = await supabase
    .from('clientes')
    .select('zona')
    .not('zona', 'is', null)

  if (error) throw error

  const zonas = [...new Set((data || []).map(c => c.zona).filter(Boolean) as string[])]
  return zonas.sort()
}

// Mutation types
interface ClienteCreateInput {
  razon_social: string
  nombre_fantasia: string
  direccion: string
  aclaracion_direccion?: string | null
  telefono?: string
  cuit?: string
  /** @deprecated usar zona_id (FK a tabla zonas). Se mantiene un release.
   *  Acepta null para que el container pueda limpiar el espejo legacy cuando
   *  el usuario selecciona "(Sin zona)". */
  zona?: string | null
  zona_id?: string | null
  latitud?: number | null
  longitud?: number | null
  limite_credito?: number
  dias_credito?: number
  descuento_porcentaje?: number
  contacto?: string
  horarios_atencion?: string
  /** Días que abre, bitmask Lunes→Domingo (mig 140). null = abre todos. */
  dias_atencion?: string | null
  horario_entrega?: string
  /** "No atiende con horario fijo": suprime el pedido de horario al cargar un pedido (mig 157). */
  sin_horario_fijo?: boolean
  /** Baja logica: se desactiva en vez de borrar cuando el cliente tiene pedidos. */
  activo?: boolean
  rubro?: string
  notas?: string
  preventista_id?: string | null
  preventista_ids?: string[]
  descuentos_categoria?: { categoria: string; descuento_porcentaje: number }[]
  /** FC/ZZ por defecto al crear pedidos de este cliente (mig 116) */
  tipo_factura_default?: 'ZZ' | 'FC'
  /** place_id de Google del lugar elegido, para auditar direcciones (mig 151) */
  place_id?: string | null
}

// Mutation functions
async function createCliente(cliente: ClienteCreateInput, sucursalId: number | null): Promise<ClienteDB> {
  // La RLS multi-tenant requiere sucursal_id = current_sucursal_id() y la
  // columna es NOT NULL. Sin esto el INSERT falla con "Error al crear cliente".
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }

  // Detección de duplicados por ubicación (~0.2 metros de tolerancia).
  // Mira TAMBIEN a los inactivos, y a proposito: el caso que origino todo el
  // incidente de los huerfanos (mig 199) fue una deduplicacion -- alguien creaba
  // el cliente nuevo y despues borraba el viejo. Si el de esa esquina esta
  // desactivado, lo que corresponde es reactivarlo, no crear un segundo cliente
  // con la misma direccion y partirle el historial al medio.
  if (cliente.latitud != null && cliente.longitud != null) {
    const TOLERANCE = 0.000002 // ~0.2 metros (6 decimales de precisión)
    const { data: cercanos } = await supabase
      .from('clientes')
      .select('id, nombre_fantasia, razon_social, activo')
      .gte('latitud', cliente.latitud - TOLERANCE)
      .lte('latitud', cliente.latitud + TOLERANCE)
      .gte('longitud', cliente.longitud - TOLERANCE)
      .lte('longitud', cliente.longitud + TOLERANCE)
      .limit(1)

    if (cercanos && cercanos.length > 0) {
      const encontrado = cercanos[0] as { nombre_fantasia?: string; razon_social?: string; activo?: boolean }
      const nombre = encontrado.nombre_fantasia || encontrado.razon_social
      if (encontrado.activo === false) {
        throw new Error(
          `Ya existe un cliente en esta ubicación, "${nombre}", pero está inactivo. ` +
          `Activá "Ver inactivos" en el panel de clientes y reactivalo, así conserva su historial.`
        )
      }
      throw new Error(
        `Ya existe un cliente en esta ubicación: ${nombre}. ` +
        `Si necesitás crear otro, modificá ligeramente la dirección.`
      )
    }
  }

  const { preventista_ids, descuentos_categoria, ...clienteFields } = cliente
  const { data, error } = await supabase
    .from('clientes')
    .insert([{
      razon_social: clienteFields.razon_social,
      nombre_fantasia: clienteFields.nombre_fantasia,
      direccion: clienteFields.direccion,
      aclaracion_direccion: clienteFields.aclaracion_direccion ?? null,
      telefono: clienteFields.telefono || null,
      cuit: clienteFields.cuit || null,
      // zona (texto) deprecada: se sigue escribiendo un release por compat de lecturas legacy.
      zona: clienteFields.zona || null,
      // zona_id es la FK canónica. '' (string vacío) y undefined → null para limpiar la FK.
      zona_id: clienteFields.zona_id ? clienteFields.zona_id : null,
      latitud: clienteFields.latitud || null,
      longitud: clienteFields.longitud || null,
      limite_credito: clienteFields.limite_credito || 0,
      dias_credito: clienteFields.dias_credito || 30,
      descuento_porcentaje: clienteFields.descuento_porcentaje ?? 0,
      contacto: clienteFields.contacto || null,
      horarios_atencion: clienteFields.horarios_atencion || null,
      dias_atencion: clienteFields.dias_atencion || null,
      horario_entrega: clienteFields.horario_entrega || null,
      rubro: clienteFields.rubro || null,
      notas: clienteFields.notas || null,
      tipo_factura_default: clienteFields.tipo_factura_default ?? 'ZZ',
      place_id: clienteFields.place_id || null,
      sucursal_id: sucursalId,
      ...(clienteFields.preventista_id ? { preventista_id: clienteFields.preventista_id } : {})
    }])
    .select()
    .single()

  if (error) throw error
  const newCliente = data as ClienteDB

  if (preventista_ids !== undefined) {
    await replacePreventistaAssignments(newCliente.id, preventista_ids)
    newCliente.preventista_ids = preventista_ids
  }

  if (descuentos_categoria !== undefined) {
    await replaceCategoriaDiscounts(newCliente.id, descuentos_categoria)
    newCliente.descuentos_categoria = descuentos_categoria
  }

  return newCliente
}

async function updateCliente({ id, data: cliente }: { id: string; data: Partial<ClienteCreateInput> }): Promise<ClienteDB> {
  const { preventista_ids, descuentos_categoria, ...clienteFields } = cliente

  // Coerce '' → null para zona_id (FK column). PostgREST rechaza '' en columnas FK.
  // Solo aplicamos si el campo viene en el patch (Partial), preservando undefined
  // para no sobrescribir campos no enviados.
  const payload: Partial<ClienteCreateInput> = { ...clienteFields }
  if ('zona_id' in payload) {
    payload.zona_id = payload.zona_id ? payload.zona_id : null
  }

  const { data, error } = await supabase
    .from('clientes')
    .update(payload)
    .eq('id', id)
    .select()
    .single()

  if (error) throw error
  const updated = data as ClienteDB

  if (preventista_ids !== undefined) {
    await replacePreventistaAssignments(id, preventista_ids)
    updated.preventista_ids = preventista_ids
  }

  if (descuentos_categoria !== undefined) {
    await replaceCategoriaDiscounts(id, descuentos_categoria)
    updated.descuentos_categoria = descuentos_categoria
  }

  return updated
}

async function deleteCliente(id: string): Promise<void> {
  const { error } = await supabase
    .from('clientes')
    .delete()
    .eq('id', id)

  if (!error) return

  // 23503 = foreign_key_violation. La base es la fuente de verdad: aunque el
  // container cuenta las referencias antes de preguntar, entre el conteo y el
  // DELETE puede entrar un pedido. Sin esta traduccion el usuario ve
  // "Error al eliminar cliente" y no tiene forma de saber que lo trabo.
  if (error.code === '23503') {
    const referencias = await contarReferenciasDeCliente(id).catch(() => null)
    const partes: string[] = []
    if (referencias) {
      const { cantidad } = referencias.pedidos
      if (cantidad > 0) partes.push(`${cantidad} pedido${cantidad === 1 ? '' : 's'}`)
      if (referencias.cambiosProductos > 0) {
        partes.push(`${referencias.cambiosProductos} cambio${referencias.cambiosProductos === 1 ? '' : 's'} de producto`)
      }
      if (referencias.recorridoCambios > 0) {
        partes.push(`${referencias.recorridoCambios} parada${referencias.recorridoCambios === 1 ? '' : 's'} de cambio`)
      }
    }
    const ref = partes.length > 0 ? partes.join(', ') : 'movimientos asociados'
    throw new Error(
      `No se puede eliminar: el cliente tiene ${ref}. Desactivalo para sacarlo de las listas sin perder el historial.`
    )
  }

  throw error
}

/**
 * Busca un cliente por razon social exacta (case-insensitive), INCLUIDOS los
 * inactivos, dentro de la sucursal activa (la RLS la acota sola).
 *
 * No alcanza con mirar el array que ya tiene el container: por defecto ese array
 * NO trae inactivos, asi que el chequeo de duplicados no los veia y dejaba crear
 * un clon exacto del cliente recien desactivado.
 *
 * `ilike` sin comodines es igualdad case-insensitive. Se escapan `%` y `_`
 * porque en un nombre son literales, no comodines.
 */
export async function buscarClientePorRazonSocial(
  razonSocial: string,
  excluirId?: string
): Promise<{ id: string; nombre_fantasia?: string; razon_social?: string; activo?: boolean } | null> {
  const patron = razonSocial.trim().replace(/[\\%_]/g, m => `\\${m}`)
  if (!patron) return null

  let query = supabase
    .from('clientes')
    .select('id, nombre_fantasia, razon_social, activo')
    .ilike('razon_social', patron)
    .limit(2)

  if (excluirId) query = query.neq('id', excluirId)

  const { data, error } = await query
  if (error) throw error
  return (data && data.length > 0) ? (data[0] as { id: string; nombre_fantasia?: string; razon_social?: string; activo?: boolean }) : null
}

export interface ReferenciasCliente {
  /** Pedidos del cliente y cuanto suman. Es la referencia que se le explica al usuario. */
  pedidos: { cantidad: number; total: number }
  /** Cambios de producto (mig 024). FK sin ON DELETE => RESTRICT. */
  cambiosProductos: number
  /** Paradas de cambio en recorridos (mig 089). FK sin ON DELETE => RESTRICT. */
  recorridoCambios: number
  /** true si alguna FK RESTRICT va a rechazar el DELETE. */
  bloqueanBorrado: boolean
}

/**
 * Cuenta todo lo que cuelga de un cliente, para poder avisar ANTES de borrarlo.
 *
 * Existe porque la FK de pedidos era ON DELETE SET NULL y borrar un cliente
 * desprendia sus pedidos en silencio: 9 pedidos por $200.070 quedaron sin dueno
 * asi (mig 199). Desde la mig 200 la FK es RESTRICT y la base rechaza el
 * borrado, pero el usuario merece saber por que antes de intentarlo, no despues.
 *
 * OJO: `pedidos` no es la unica FK que traba el DELETE. `cambios_productos`
 * (024) y `recorrido_cambios` (089) tampoco declaran ON DELETE, y en Postgres
 * eso es NO ACTION -- o sea RESTRICT. Contando solo pedidos, un cliente con un
 * cambio de producto y ningun pedido caia igual en el 23503, pero la app le
 * mostraba el confirm de "no tiene pedidos asociados" y despues un
 * "Error al eliminar cliente" sin explicacion.
 */
export async function contarReferenciasDeCliente(
  clienteId: string
): Promise<ReferenciasCliente> {
  const [pedidosRes, cambiosRes, recorridoRes] = await Promise.all([
    supabase.from('pedidos').select('total').eq('cliente_id', clienteId),
    supabase.from('cambios_productos').select('id').eq('cliente_id', clienteId),
    supabase.from('recorrido_cambios').select('id').eq('cliente_id', clienteId),
  ])

  if (pedidosRes.error) throw pedidosRes.error
  if (cambiosRes.error) throw cambiosRes.error
  if (recorridoRes.error) throw recorridoRes.error

  const filas = pedidosRes.data || []
  const cambiosProductos = (cambiosRes.data || []).length
  const recorridoCambios = (recorridoRes.data || []).length

  return {
    pedidos: {
      cantidad: filas.length,
      total: filas.reduce((acc, p) => acc + Number(p.total || 0), 0),
    },
    cambiosProductos,
    recorridoCambios,
    bloqueanBorrado: filas.length > 0 || cambiosProductos > 0 || recorridoCambios > 0,
  }
}

// Hooks

/**
 * Hook para obtener los clientes de la sucursal activa.
 *
 * Por defecto devuelve SOLO los activos: un cliente dado de baja no tiene que
 * aparecer en el panel ni en ningun selector. `includeInactivos` es para el
 * check "Ver inactivos" del panel de clientes, que es desde donde se los
 * reactiva -- sin eso, desactivar seria un viaje de ida.
 */
export function useClientesQuery(opts?: { includeInactivos?: boolean }) {
  const { currentSucursalId } = useSucursal()
  const includeInactivos = opts?.includeInactivos ?? false
  return useQuery({
    queryKey: clientesKeys.lists(currentSucursalId, includeInactivos),
    queryFn: () => fetchClientes(includeInactivos),
    staleTime: 5 * 60 * 1000, // 5 minutos
  })
}

/**
 * Hook para obtener un cliente por ID
 */
export function useClienteQuery(id: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: clientesKeys.detail(currentSucursalId, id),
    queryFn: () => fetchClienteById(id),
    enabled: !!id,
  })
}

/**
 * Hook para obtener clientes por zona
 */
export function useClientesByZonaQuery(zona: string) {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: clientesKeys.byZona(currentSucursalId, zona),
    queryFn: () => fetchClientesByZona(zona),
    enabled: !!zona,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Hook para obtener zonas únicas
 */
export function useZonasQuery() {
  const { currentSucursalId } = useSucursal()
  return useQuery({
    queryKey: clientesKeys.zonas(currentSucursalId),
    queryFn: fetchZonasUnicas,
    staleTime: 10 * 60 * 1000, // 10 minutos - zonas cambian poco
  })
}

/**
 * Hook para crear un cliente
 */
export function useCrearClienteMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: (cliente: ClienteCreateInput) => createCliente(cliente, currentSucursalId),
    onSuccess: (newCliente) => {
      // Actualizar cache de lista
      queryClient.setQueryData<ClienteDB[]>(clientesKeys.lists(currentSucursalId), (old) => {
        if (!old) return [newCliente]
        return [...old, newCliente].sort((a, b) =>
          (a.nombre_fantasia || '').localeCompare(b.nombre_fantasia || '')
        )
      })
      // Invalidar el prefijo: alcanza a las dos variantes de lista y a las zonas
      queryClient.invalidateQueries({ queryKey: clientesKeys.all(currentSucursalId) })
      // Invalidar clientes por zona si aplica
      if (newCliente.zona) {
        queryClient.invalidateQueries({ queryKey: clientesKeys.byZona(currentSucursalId, newCliente.zona) })
      }
    },
  })
}

/**
 * Hook para actualizar un cliente (con optimistic update)
 */
export function useActualizarClienteMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: updateCliente,
    // Optimistic update
    onMutate: async ({ id, data: cliente }) => {
      await queryClient.cancelQueries({ queryKey: clientesKeys.lists(currentSucursalId) })

      const previousClientes = queryClient.getQueryData<ClienteDB[]>(clientesKeys.lists(currentSucursalId))

      // Aplicar cambios optimistamente
      queryClient.setQueryData<ClienteDB[]>(clientesKeys.lists(currentSucursalId), (old) => {
        if (!old) return old
        return old.map(c => c.id === id ? { ...c, ...cliente } as ClienteDB : c)
      })

      return { previousClientes }
    },
    onError: (_, __, context) => {
      // Rollback on error
      if (context?.previousClientes) {
        queryClient.setQueryData(clientesKeys.lists(currentSucursalId), context.previousClientes)
      }
    },
    onSuccess: (updatedCliente) => {
      // Actualizar cache de detalle con datos reales del servidor
      queryClient.setQueryData(clientesKeys.detail(currentSucursalId, updatedCliente.id), updatedCliente)
    },
    onSettled: () => {
      // Se invalida el PREFIJO `all`, no `lists()`: desde que la lista tiene dos
      // variantes en cache (con y sin inactivos), invalidar solo la de activos
      // dejaba la otra vieja. Se notaba justo en el caso que importa: desactivar
      // un cliente y que siguiera figurando en "Ver inactivos" como activo.
      queryClient.invalidateQueries({ queryKey: clientesKeys.all(currentSucursalId) })
    },
  })
}

/**
 * Hook para eliminar (desactivar) un cliente
 */
export function useEliminarClienteMutation() {
  const queryClient = useQueryClient()
  const { currentSucursalId } = useSucursal()

  return useMutation({
    mutationFn: deleteCliente,
    onSuccess: (_, deletedId) => {
      // Remover de cache de detalle
      queryClient.removeQueries({ queryKey: clientesKeys.detail(currentSucursalId, deletedId) })
      // Sacarlo de las dos variantes de la lista (con y sin inactivos)
      for (const incluirInactivos of [false, true]) {
        queryClient.setQueryData<ClienteDB[]>(
          clientesKeys.lists(currentSucursalId, incluirInactivos),
          (old) => (old ? old.filter(c => c.id !== deletedId) : old)
        )
      }
    },
  })
}
