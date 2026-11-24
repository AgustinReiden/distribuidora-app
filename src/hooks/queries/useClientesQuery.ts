/**
 * TanStack Query hooks para Clientes
 * Reemplaza el hook useClientes con mejor cache y gestión de estado
 */
import { errorDeSupabase } from '../../utils/errorDeSupabase'
import { useMemo } from 'react'
import { useQuery, useMutation, useQueryClient } from '@tanstack/react-query'
import { supabase } from '../supabase/base'
import { useSucursal } from '../../contexts/SucursalContext'
import { useAuthData } from '../../contexts/AuthDataContext'
import { esClienteOperable } from '../../utils/clienteOperable'
import type { ClienteDB, TipoComprobanteVenta } from '../../types'
import { traerTodo } from '../../utils/paginacion'
import { documentoParaGuardar, type TipoDocumentoCliente } from '../../utils/documentoCliente'
import { nuevoRequestId } from '../../utils/idempotencia'
import { lanzarSiConflicto } from '../../utils/conflictoDeVersion'
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

  if (error) throw errorDeSupabase(error, 'Sin conexión: no se pudo cargar el cliente. Revisá la señal e intentá de nuevo.')
  return data ? flattenClienteRow(data as ClienteRow) : null
}

/**
 * El alta y la edición de un cliente con sus preventistas y sus descuentos por categoría, en UNA
 * llamada y una transacción (`guardar_cliente`, C4b v2 de #1603). Antes eran el INSERT o el PATCH
 * de `clientes`, después `cliente_preventistas` (un DELETE y un INSERT por preventista) y después
 * los descuentos (1598-b5), en llamadas REST separadas: si fallaba una del medio, el cliente
 * quedaba creado sin su preventista o sin sus descuentos. La RPC corre como quien llama, así que
 * rigen las mismas policies y triggers que con el REST (quién ve y quién edita, la zona que manda
 * la asignación, el crédito y el reservado sólo del admin, el documento con su tipo).
 */
interface RespuestaGuardarCliente {
  success: boolean
  replay?: boolean
  codigo?: string
  error?: string
  cliente?: ClienteDB
  preventista_ids?: string[]
}

async function guardarClienteRpc(
  payload: Record<string, unknown>,
  mensajeSinConexion: string,
): Promise<{ cliente: ClienteDB; preventistaIds: string[] }> {
  const { data, error } = await supabase.rpc('guardar_cliente', { p_cliente: payload })
  if (error) throw errorDeSupabase(error, mensajeSinConexion)
  const r = data as RespuestaGuardarCliente | null
  lanzarSiConflicto(r)
  if (!r?.success || !r.cliente) throw new Error(r?.error || 'No se pudo guardar el cliente')
  return { cliente: r.cliente, preventistaIds: (r.preventista_ids ?? []).map(String) }
}

// Mutation types
interface ClienteCreateInput {
  razon_social: string
  nombre_fantasia: string
  direccion: string
  aclaracion_direccion?: string | null
  telefono?: string | null
  cuit?: string | null
  /**
   * No hace falta mandarlo: sale de `cuit` (`documentoParaGuardar`, B17). Antes no
   * viajaba nunca y todo cliente quedaba 'CUIT', también los DNI.
   */
  tipo_documento?: TipoDocumentoCliente
  zona_id?: string | null
  latitud?: number | null
  longitud?: number | null
  limite_credito?: number
  dias_credito?: number
  descuento_porcentaje?: number
  contacto?: string | null
  horarios_atencion?: string | null
  /** Días que abre, bitmask Lunes→Domingo (mig 140). null = abre todos. */
  dias_atencion?: string | null
  horario_entrega?: string | null
  /** "No atiende con horario fijo": suprime el pedido de horario al cargar un pedido (mig 157). */
  sin_horario_fijo?: boolean
  /** Baja logica: se desactiva en vez de borrar cuando el cliente tiene pedidos. */
  activo?: boolean
  rubro?: string | null
  notas?: string | null
  preventista_ids?: string[]
  /**
   * Los `preventista_ids` que tenía el cliente cuando se abrió el formulario.
   * No es una columna: `updateCliente` guarda sólo la diferencia contra esto.
   */
  preventista_ids_previos?: string[]
  /**
   * "Solo administradores" (mig 214): tercer estado de asignacion, excluyente
   * con `preventista_ids`. Solo admin lo escribe.
   */
  reservado_admin?: boolean
  descuentos_categoria?: { categoria: string; descuento_porcentaje: number }[]
  /**
   * FC/ZZ/VB por defecto al crear pedidos de este cliente (mig 116). 'VB' = cliente de
   * consumo interno (vale blanco); sólo un admin lo pone o lo saca (trigger del servidor).
   */
  tipo_factura_default?: TipoComprobanteVenta
  /** place_id de Google del lugar elegido, para auditar direcciones (mig 151) */
  place_id?: string | null
  /**
   * El usuario ya vio el aviso de duplicado y confirmó que es otro comercio
   * (mig 250). Sólo levanta los AVISOS; los bloqueos duros no se confirman.
   * No es una columna: se descarta antes del INSERT.
   */
  duplicado_confirmado?: boolean
  /**
   * La clave del alta (C4b v2): el reintento de la misma alta devuelve el cliente que ya entró. No
   * es una columna.
   */
  clave?: string
  /**
   * La versión del cliente al abrir la ficha (`updated_at`): si otro lo guardó en el medio, la
   * edición no lo pisa ('cliente_cambiado'). No es una columna.
   */
  updated_at_esperado?: string | null
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

  const {
    preventista_ids, descuentos_categoria, duplicado_confirmado, clave, updated_at_esperado: _v, ...clienteFields
  } = cliente
  void _v
  const { cliente: newCliente, preventistaIds } = await guardarClienteRpc({
    // Sin la clave del formulario, una nueva: no hay reintento que reconocer.
    clave: clave ?? nuevoRequestId(),
    duplicado_confirmado: duplicado_confirmado ?? false,
    campos: {
      razon_social: clienteFields.razon_social,
      nombre_fantasia: clienteFields.nombre_fantasia,
      direccion: clienteFields.direccion,
      aclaracion_direccion: clienteFields.aclaracion_direccion ?? null,
      telefono: clienteFields.telefono || null,
      // El documento con su tipo, que sale del valor (B17, #1561).
      ...documentoParaGuardar(clienteFields.cuit),
      // zona_id es la FK canónica. '' (string vacío) y undefined → null para limpiar la FK.
      zona_id: clienteFields.zona_id ? clienteFields.zona_id : null,
      latitud: clienteFields.latitud || null,
      longitud: clienteFields.longitud || null,
      limite_credito: clienteFields.limite_credito ?? 0,
      dias_credito: clienteFields.dias_credito ?? 30,
      descuento_porcentaje: clienteFields.descuento_porcentaje ?? 0,
      contacto: clienteFields.contacto || null,
      horarios_atencion: clienteFields.horarios_atencion || null,
      dias_atencion: clienteFields.dias_atencion || null,
      horario_entrega: clienteFields.horario_entrega || null,
      // "No atiende con horario fijo" (mig 157): sin esto el cliente nacía con el horario
      // exigido aunque se hubiera tildado (FRV-1, tanda 6).
      sin_horario_fijo: clienteFields.sin_horario_fijo ?? false,
      rubro: clienteFields.rubro || null,
      notas: clienteFields.notas || null,
      tipo_factura_default: clienteFields.tipo_factura_default ?? 'ZZ',
      place_id: clienteFields.place_id || null,
      // "Solo administradores" (mig 214): la marca no se pierde en el alta. El trigger la acepta
      // en true sólo si el que crea es admin.
      reservado_admin: clienteFields.reservado_admin ?? false,
    },
    ...(preventista_ids !== undefined ? { preventista_ids } : {}),
    ...(descuentos_categoria !== undefined ? { descuentos_categoria } : {}),
  }, 'Sin conexión: no se pudo confirmar el alta del cliente. Podés volver a guardar: si ya había entrado, no se crea otro.')

  if (preventista_ids !== undefined) newCliente.preventista_ids = preventistaIds
  if (descuentos_categoria !== undefined) newCliente.descuentos_categoria = descuentos_categoria
  return newCliente
}

async function updateCliente({ id, data: cliente }: { id: string; data: Partial<ClienteCreateInput> }): Promise<ClienteDB> {
  // `duplicado_confirmado` NO es una columna: es la respuesta del usuario al
  // aviso del guard (mig 250). Acá el payload se arma por spread, así que si no
  // se descarta viaja como columna y PostgREST rechaza el UPDATE entero.
  // `createCliente` no lo sufre porque su insert nombra las columnas una por una.
  const {
    preventista_ids,
    preventista_ids_previos,
    descuentos_categoria,
    duplicado_confirmado: _confirmado,
    clave: _clave,
    updated_at_esperado,
    ...clienteFields
  } = cliente
  void _confirmado
  void _clave

  // Coerce '' → null para zona_id (FK column). PostgREST rechaza '' en columnas FK.
  // Solo aplicamos si el campo viene en el patch (Partial), preservando undefined
  // para no sobrescribir campos no enviados.
  const payload: Partial<ClienteCreateInput> = { ...clienteFields }
  if ('zona_id' in payload) {
    payload.zona_id = payload.zona_id ? payload.zona_id : null
  }
  // Si la edición trae el documento, viaja con su tipo (B17, #1561): el patch de
  // ClientesContainer nunca lo mandaba y un DNI quedaba 'CUIT'. Un patch sin
  // documento (el del preventista, la baja lógica) no lo toca.
  if ('cuit' in payload) {
    Object.assign(payload, documentoParaGuardar(payload.cuit))
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

  const { cliente: updated, preventistaIds } = await guardarClienteRpc({
    id: Number(id),
    duplicado_confirmado: cliente.duplicado_confirmado ?? false,
    ...(updated_at_esperado ? { updated_at_esperado } : {}),
    campos: payload,
    ...(preventista_ids !== undefined ? { preventista_ids } : {}),
    ...(preventista_ids !== undefined && preventista_ids_previos !== undefined ? { preventista_ids_previos } : {}),
    ...(descuentos_categoria !== undefined ? { descuentos_categoria } : {}),
  }, 'Sin conexión: no se pudo confirmar los cambios del cliente. Podés volver a guardar: deja el cliente como lo cargaste.')

  if (preventista_ids !== undefined) updated.preventista_ids = preventistaIds
  if (descuentos_categoria !== undefined) updated.descuentos_categoria = descuentos_categoria
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
      if (referencias.pagos > 0) {
        partes.push(`${referencias.pagos} pago${referencias.pagos === 1 ? '' : 's'}`)
      }
    }
    const ref = partes.length > 0 ? partes.join(', ') : 'movimientos asociados'
    throw new Error(
      `No se puede eliminar: el cliente tiene ${ref}. Desactivalo para sacarlo de las listas sin perder el historial.`
    )
  }

  throw errorDeSupabase(error, 'Sin conexión: no se pudo confirmar la eliminación del cliente. Revisá la lista de clientes antes de reintentar, puede haber quedado hecho.')
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
  /**
   * Pagos del cliente (mig 265). La FK era ON DELETE CASCADE: borrar la ficha
   * borraba los cobros, y las boletas volvian a figurar como deuda. Hoy RESTRICT.
   */
  pagos: number
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
  // frv-B5 (tanda 6): paginado. PostgREST corta en 1.000 filas sin avisar, y con más de 1.000
  // pedidos o pagos el aviso «tiene N pedidos por $X» salía cortado. Un cliente con tantas filas es
  // justo el que más importa contar bien. `traerTodo` exige un orden estable: por `id`.
  const [filas, cambios, recorrido, pagosFilas] = await Promise.all([
    traerTodo<{ total: number | string | null }>(
      () => supabase.from('pedidos').select('total').eq('cliente_id', clienteId).order('id'),
      { etiqueta: 'pedidos del cliente' },
    ),
    traerTodo<{ id: number }>(
      () => supabase.from('cambios_productos').select('id').eq('cliente_id', clienteId).order('id'),
      { etiqueta: 'cambios del cliente' },
    ),
    traerTodo<{ id: number }>(
      () => supabase.from('recorrido_cambios').select('id').eq('cliente_id', clienteId).order('id'),
      { etiqueta: 'cambios en ruta del cliente' },
    ),
    traerTodo<{ id: number }>(
      () => supabase.from('pagos').select('id').eq('cliente_id', clienteId).order('id'),
      { etiqueta: 'pagos del cliente' },
    ),
  ])

  const cambiosProductos = cambios.length
  const recorridoCambios = recorrido.length
  const pagos = pagosFilas.length

  return {
    pedidos: {
      cantidad: filas.length,
      total: filas.reduce((acc, p) => acc + Number(p.total || 0), 0),
    },
    cambiosProductos,
    recorridoCambios,
    pagos,
    bloqueanBorrado: filas.length > 0 || cambiosProductos > 0 || recorridoCambios > 0 || pagos > 0,
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
 * Los clientes con los que el usuario puede OPERAR: listados, selectores,
 * contadores de "mis clientes". Misma query y misma cache que
 * `useClientesQuery`; filtra con `esClienteOperable`.
 *
 * Desde la mig 358 un preventista VE además los clientes a los que ya les
 * vendió aunque hoy los atienda otro (historial). Esos tienen que seguir en
 * `useClientesQuery` para los lookups por id, pero no aparecer donde se elige
 * un cliente para trabajar.
 */
export function useClientesOperativosQuery(opts?: { includeInactivos?: boolean }) {
  const query = useClientesQuery(opts)
  const { perfil, user } = useAuthData()
  const rol = perfil?.rol
  const userId = user?.id
  const data = useMemo(
    () => query.data?.filter(c => esClienteOperable(c, { rol, userId })),
    [query.data, rol, userId],
  )
  return { ...query, data }
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
      // Invalidar el prefijo: alcanza a las dos variantes de lista
      queryClient.invalidateQueries({ queryKey: clientesKeys.all(currentSucursalId) })
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
