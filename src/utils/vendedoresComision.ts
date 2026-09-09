/**
 * Quién puede tener una regla de comisión cargada.
 *
 * EL BUG QUE ARREGLA
 * ------------------
 * El desplegable se armaba con `resultado.preventistas` del RPC, que es quien
 * vendió EN EL PERÍODO CONSULTADO. Eso hacía dos cosas malas a la vez: un admin
 * que no vendió no aparecía nunca, y la lista cambiaba al cambiar el rango de
 * fechas —Julio, con 2 pedidos en todo el año, aparecía o desaparecía según el
 * mes que estuvieras mirando—. Una lista de "a quién puedo configurarle el %"
 * no puede depender de qué mes estás mirando.
 *
 * LAS DOS FUENTES, Y POR QUÉ HACEN FALTA LAS DOS
 * ---------------------------------------------
 * · El PADRÓN —`perfiles` con rol admin/encargado/preventista, activos, de la
 *   sucursal— es el piso: son los que PUEDEN vender, hayan vendido o no. Es lo
 *   que hace que la lista sea estable.
 * · QUIEN VENDIÓ rescata al que ya no está en el padrón pero tiene plata
 *   acumulada: Christian es preventista inactivo con $804.249, sale del padrón
 *   por `activo = false` y igual hay que poder editarle la regla.
 *
 * Los transportistas quedan afuera de las dos: no pueden ser el `usuario_id` de
 * un pedido (`crear_pedido_completo` exige admin/preventista/encargado) y en los
 * datos no tienen ni un pedido, así que nunca aparecen por la segunda fuente.
 *
 * El % por defecto NO se decide acá: lo resuelve `calcular_comisiones` por rol
 * contra `politicas_comerciales`. Esta lista es sólo quién es elegible para la
 * EXCEPCIÓN, que es la regla individual.
 */

/** Lo mínimo que se necesita de cualquiera de las dos fuentes. */
export interface FuenteVendedor {
  id: string
  nombre?: string | null
  email?: string | null
}

export interface VendedorComision {
  id: string
  /** Siempre un string no vacío: es lo que se muestra en el desplegable. */
  nombre: string
}

/** Nombre → email → rótulo. Nunca undefined ni una cadena en blanco. */
function nombreLegible(v: FuenteVendedor): string {
  const nombre = v.nombre?.trim()
  if (nombre) return nombre
  const email = v.email?.trim()
  if (email) return email
  return 'Sin nombre'
}

/**
 * @param padron - Quienes PUEDEN vender: el piso estable de la lista.
 * @param vendieron - Quienes vendieron en el período consultado, del RPC.
 *   Aporta sólo a los que el padrón ya no tiene.
 */
export function vendedoresElegibles(
  padron: readonly FuenteVendedor[] | null | undefined,
  vendieron: readonly FuenteVendedor[] | null | undefined,
): VendedorComision[] {
  const porId = new Map<string, string>()

  // El padrón va primero a propósito: ante el mismo id, su nombre le gana al
  // del RPC, que es una foto del período consultado.
  for (const v of padron ?? []) porId.set(v.id, nombreLegible(v))
  for (const v of vendieron ?? []) {
    if (!porId.has(v.id)) porId.set(v.id, nombreLegible(v))
  }

  return [...porId]
    .map(([id, nombre]) => ({ id, nombre }))
    .sort((a, b) => a.nombre.localeCompare(b.nombre, 'es'))
}
