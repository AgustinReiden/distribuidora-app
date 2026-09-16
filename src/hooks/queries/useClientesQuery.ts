/**
 * TanStack Query hooks para Clientes
 * Reemplaza el hook useClientes con mejor cache y gestión de estado
 */
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import type { ClienteDB } from '../../types'
import { traerTodo } from '../../utils/paginacion'
import {
  cambiaIdentidadDuplicado,
  mensajeDuplicado,
  type IdentidadDuplicado,
  type VeredictoDuplicadoRPC,
} from '../../utils/duplicadoCliente'

// Query keys
export const clientesKeys = {
  all: (sucursalId: number | null) => ['clientes', sucursalId] as const,
  /**
   * OJO: la lista tiene DOS variantes en cache (con y sin inactivos), y el
   * segundo argumento tiene default. `lists(sucursalId)` compila y apunta a la
   * de activos, asi que usarla como filtro de invalidacion deja la otra vieja
   * -- y `tsc` no lo ve. Para invalidar o escribir sobre "la lista", usá
   * `listsPrefix` con las APIs plurales (`setQueriesData`/`getQueriesData`),
   * que alcanzan a las dos.
   */
  lists: (sucursalId: number | null, includeInactivos = false) =>
    [...clientesKeys.all(sucursalId), 'list', includeInactivos] as const,
  listsPrefix: (sucursalId: number | null) => [...clientesKeys.all(sucursalId), 'list'] as const,
  list: (sucursalId: number | null, filters: Record<string, unknown>) => [...clientesKeys.listsPrefix(sucursalId), filters] as const,
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
  // Paginado: son 720 clientes y el tope de PostgREST es 1.000. Todavía entra,
  // pero esta consulta alimenta los selectores de toda la app —si se corta, un
  // cliente deja de poder elegirse y no hay ningún error que lo delate—. El
  // desempate por `id` hace falta porque `nombre_fantasia` no es único.
  const data = await traerTodo<ClienteRow>(
    () => {
      let query = supabase
        .from('clientes')
        .select(CLIENTE_SELECT)
        .order('nombre_fantasia')
        .order('id')
      if (!includeInactivos) query = query.eq('activo', true)
      return query
    },
    { etiqueta: 'clientes' },
  )

  return data.map(flattenClienteRow)
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
  // Lee una fila por cliente para quedarse con 13 zonas distintas. Paginado
  // porque `clientes` es la tabla que más cerca está del tope: hoy 461 filas
  // con zona de las 722 totales. Pasado el tope no degrada de a poco —se
  // pierde una zona entera del filtro, sin aviso—, y una zona que desaparece
  // de la lista es un pedazo del reparto que deja de poder elegirse.
  //
  // Lo correcto sería que la base devuelva las zonas distintas en vez de las
  // filas (como `reporte_ventas_por_cliente`, mig 197). Mientras tanto esto es
  // correcto para cualquier volumen, que es lo que estaba en juego.
  const data = await traerTodo<{ zona: string | null }>(
    () => supabase
      .from('clientes')
      .select('zona')
      .not('zona', 'is', null)
      .order('id'),
    { etiqueta: 'zonas de clientes' },
  )

  const zonas = [...new Set(data.map(c => c.zona).filter(Boolean) as string[])]
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
  /**
   * "Solo administradores" (mig 214): tercer estado de asignacion, excluyente
   * con `preventista_ids`. Solo admin lo escribe.
   */
  reservado_admin?: boolean
  descuentos_categoria?: { categoria: string; descuento_porcentaje: number }[]
  /** FC/ZZ por defecto al crear pedidos de este cliente (mig 116) */
  tipo_factura_default?: 'ZZ' | 'FC'
  /** place_id de Google del lugar elegido, para auditar direcciones (mig 151) */
  place_id?: string | null
  /**
   * El usuario ya vio el aviso de duplicado y confirmó que es otro comercio
   * (mig 250). Sólo levanta los AVISOS; los bloqueos duros no se confirman.
   * No es una columna: se descarta antes del INSERT.
   */
  duplicado_confirmado?: boolean
  /**
   * @deprecated Sin uso desde la mig 260, que sacó el nombre del criterio. Se
   * sigue aceptando y DESCARTANDO a propósito: `ClientesContainer` es un chunk
   * lazy, así que un bundle viejo cacheado en el PWA lo puede seguir mandando,
   * y si la mutation deja de descartarlo viaja como columna y PostgREST
   * rechaza el UPDATE entero. Se borra cuando no queden bundles viejos (#688).
   */
  duplicado_nombre_fantasia?: string | null
}

// Mutation functions
async function createCliente(cliente: ClienteCreateInput, sucursalId: number | null): Promise<ClienteDB> {
  // La RLS multi-tenant requiere sucursal_id = current_sucursal_id() y la
  // columna es NOT NULL. Sin esto el INSERT falla con "Error al crear cliente".
  if (sucursalId == null) {
    throw new Error('No hay sucursal activa. Recargá la página e intentá de nuevo.')
  }

  // Guard de duplicados. Una sola puerta: `verificar_duplicado_cliente` (mig
  // 250). Acá es la ULTIMA linea de defensa -- el modal ya preguntó y resolvió
  // la confirmación --, así que un aviso sin confirmar tambien frena el alta.
  //
  // Mira TAMBIEN a los inactivos, y a proposito: el caso que origino todo el
  // incidente de los huerfanos (mig 199) fue una deduplicacion -- alguien creaba
  // el cliente nuevo y despues borraba el viejo. Si el de esa puerta esta
  // desactivado, lo que corresponde es reactivarlo, no crear un segundo cliente
  // con la misma direccion y partirle el historial al medio.
  const veredicto = await verificarDuplicadoCliente({
    latitud: cliente.latitud ?? null,
    longitud: cliente.longitud ?? null,
    direccion: cliente.direccion ?? null,
  })

  if (veredicto.bloquea) {
    throw new Error(mensajeDuplicado(veredicto).mensaje)
  }
  if (veredicto.avisa && !cliente.duplicado_confirmado) {
    throw new Error(
      `${mensajeDuplicado(veredicto).mensaje} No se creó nada: volvé a guardar y confirmá.`
    )
  }

  const { preventista_ids, descuentos_categoria, duplicado_confirmado: _confirmadoAlta, ...clienteFields } = cliente
  void _confirmadoAlta
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
      // "Solo administradores" (mig 214). Esta lista es explicita, asi que sin
      // esta linea la marca se perderia en silencio al crear. La RLS de INSERT
      // solo la acepta en true si el que crea es admin.
      reservado_admin: clienteFields.reservado_admin ?? false,
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
  // `duplicado_confirmado` NO es una columna: es la respuesta del usuario al
  // aviso del guard (mig 250). Acá el payload se arma por spread, así que si no
  // se descarta viaja como columna y PostgREST rechaza el UPDATE entero.
  // `createCliente` no lo sufre porque su insert nombra las columnas una por una.
  // `duplicado_nombre_fantasia` ya no se usa (mig 260) pero se sigue sacando por
  // la misma razón: un bundle viejo del chunk lazy del container lo manda igual.
  const {
    preventista_ids,
    descuentos_categoria,
    duplicado_confirmado: _confirmado,
    duplicado_nombre_fantasia: _nombreFantasiaDelGuard,
    ...clienteFields
  } = cliente
  void _confirmado
  void _nombreFantasiaDelGuard

  // Coerce '' → null para zona_id (FK column). PostgREST rechaza '' en columnas FK.
  // Solo aplicamos si el campo viene en el patch (Partial), preservando undefined
  // para no sobrescribir campos no enviados.
  const payload: Partial<ClienteCreateInput> = { ...clienteFields }
  if ('zona_id' in payload) {
    payload.zona_id = payload.zona_id ? payload.zona_id : null
  }

  // Mismo guard que createCliente, para la edición. ModalCliente ya lo llama
  // con excluir_id antes de guardar, pero cualquier otra mutation futura que
  // edite estos campos sin pasar por el modal entraría sin chequeo.
  //
  // Dispara si la edición CAMBIA alguno de los campos que la RPC compara, no si
  // el patch los menciona: el patch que arma ClientesContainer los manda
  // siempre, cambien o no, así que "está en el payload" daba true en TODA
  // edición y el guard opinaba sobre vecinos con los que el cliente ya convivía.
  // Ver `cambiaIdentidadDuplicado`.
  const tocaCamposDuplicado = ['direccion', 'latitud', 'longitud']
    .some((campo) => campo in payload)
  if (tocaCamposDuplicado) {
    // Lo que hay hoy en la base, para poder comparar. Si no se pudo leer, se
    // verifica igual: fail-closed, un guard ciego no aprueba.
    const actual = await leerIdentidadCliente(id)
    // El "después" efectivo: lo que trae el patch, y lo de la base para lo que
    // el patch no toca. Un patch acotado que sólo manda la dirección no deja al
    // nombre en null -- eso evaluaba media identidad contra la otra media.
    const despues: IdentidadDuplicado = {
      latitud: 'latitud' in payload ? payload.latitud ?? null : actual?.latitud ?? null,
      longitud: 'longitud' in payload ? payload.longitud ?? null : actual?.longitud ?? null,
      direccion: 'direccion' in payload ? payload.direccion ?? null : actual?.direccion ?? null,
    }

    if (!actual || cambiaIdentidadDuplicado(actual, despues)) {
      const veredicto = await verificarDuplicadoCliente({
        latitud: despues.latitud ?? null,
        longitud: despues.longitud ?? null,
        direccion: despues.direccion ?? null,
        excluir_id: id,
      })

      if (veredicto.bloquea) {
        throw new Error(mensajeDuplicado(veredicto).mensaje)
      }
      if (veredicto.avisa && !cliente.duplicado_confirmado) {
        throw new Error(
          `${mensajeDuplicado(veredicto).mensaje} No se guardó nada: volvé a guardar y confirmá.`
        )
      }
    }
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
 * Los tres campos que el guard compara, como están HOY en la base.
 *
 * Existe para que la edición pueda preguntarse "¿esto cambia algo?" antes de
 * llamar al guard. Sin la foto previa, la mutation sólo puede mirar qué campos
 * vienen en el patch -- y el patch los trae siempre.
 *
 * Devuelve `null` si no se pudo leer (error, o la RLS tapa la fila). El caller
 * verifica igual en ese caso: no saber si cambió no es lo mismo que saber que
 * no cambió.
 */
async function leerIdentidadCliente(id: string): Promise<IdentidadDuplicado | null> {
  try {
    const { data, error } = await supabase
      .from('clientes')
      .select('direccion, latitud, longitud')
      .eq('id', id)
      .maybeSingle()
    if (error || !data) return null
    return data as IdentidadDuplicado
  } catch {
    return null
  }
}

/**
 * Entrada del guard de duplicados. La decide `verificar_duplicado_cliente`
 * (mig 250) y NO se puede replicar del lado del cliente: la RLS le tapa al
 * preventista los clientes de otro preventista y los reservados a
 * administración, así que una consulta desde acá es ciega para la mayoría de la
 * base -- con 598 de 722 clientes asignados, el detector viejo dejaba crear el
 * clon sin avisar nada (#543). La RPC es SECURITY DEFINER y ve por encima de la
 * policy, pero no devuelve la identidad de lo que la policy tapa.
 */
export interface EntradaVerificacionDuplicado {
  latitud: number | null
  longitud: number | null
  direccion: string | null
  /** Id del cliente que se está editando, para que no choque consigo mismo. */
  excluir_id?: string | null
}

/**
 * Llama al guard. FAIL-CLOSED: si no se pudo verificar, tira. Seguir de largo
 * ante el error es volver al bug -- un guard que no puede mirar y aprueba igual.
 */
export async function verificarDuplicadoCliente(
  entrada: EntradaVerificacionDuplicado
): Promise<VeredictoDuplicadoRPC> {
  // Los dos parámetros de nombre siguen existiendo en la RPC con DEFAULT NULL y
  // no se mandan: la mig 260 los dejó sin uso pero no los dropeó, para que un
  // bundle viejo del PWA —que sí los manda— no se encuentre con un PGRST202 y
  // deje de poder dar de alta clientes. Se sacan de la firma en #688.
  const { data, error } = await supabase.rpc('verificar_duplicado_cliente', {
    p_latitud: entrada.latitud,
    p_longitud: entrada.longitud,
    p_direccion: entrada.direccion,
    p_excluir_id: entrada.excluir_id ?? null,
  })

  if (error || !data) {
    throw new Error(
      'No se pudo verificar si ya existe un cliente igual. No se guardó nada; probá de nuevo.'
    )
  }

  return data as VeredictoDuplicadoRPC
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
      queryClient.setQueriesData<ClienteDB[]>({ queryKey: clientesKeys.listsPrefix(currentSucursalId) }, (old) => {
        if (!old) return old
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
      // Plural y por prefijo: la mutacion mas comun de esta pantalla es
      // desactivar/reactivar, que es justo la que cambia de que variante de la
      // lista tiene que salir el cliente. Tocando una sola, la otra queda vieja.
      const prefijo = clientesKeys.listsPrefix(currentSucursalId)
      await queryClient.cancelQueries({ queryKey: prefijo })

      const previousClientes = queryClient.getQueriesData<ClienteDB[]>({ queryKey: prefijo })

      queryClient.setQueriesData<ClienteDB[]>({ queryKey: prefijo }, (old) => {
        if (!old) return old
        return old.map(c => c.id === id ? { ...c, ...cliente } as ClienteDB : c)
      })

      return { previousClientes }
    },
    onError: (_, __, context) => {
      // Rollback: se restaura cada variante con lo que tenia antes.
      for (const [queryKey, data] of context?.previousClientes ?? []) {
        queryClient.setQueryData(queryKey, data)
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
 * Hook para ELIMINAR de verdad un cliente (DELETE).
 *
 * Solo admin (policy `mt_clientes_delete`) y solo si el cliente no tiene ninguna
 * referencia: desde la mig 200 la FK de pedidos es RESTRICT, y `cambios_productos`
 * y `recorrido_cambios` tampoco declaran ON DELETE. En la practica casi nunca
 * aplica -- 678 de los 712 clientes tienen pedidos.
 *
 * **La baja logica NO pasa por aca**: desactivar es
 * `useActualizarClienteMutation` con `{ activo: false }`, y reactivar con
 * `{ activo: true }`. El "(desactivar)" que decia antes este docstring era de
 * cuando eliminar y desactivar eran la misma cosa.
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
      queryClient.setQueriesData<ClienteDB[]>(
        { queryKey: clientesKeys.listsPrefix(currentSucursalId) },
        (old) => (old ? old.filter(c => c.id !== deletedId) : old)
      )
    },
  })
}
