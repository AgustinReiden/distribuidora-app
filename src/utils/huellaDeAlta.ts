/**
 * La huella de un alta (reportes-R3, tanda 6 de #1603): qué se está dando de alta, para
 * pedir con `useRequestIdEstable` la misma clave mientras no cambie. `guardar_gasto` y
 * `guardar_empleado` reciben esa clave (`clave` en el JSON) y, si ya la vieron con el mismo
 * contenido, devuelven lo del primer intento en vez de darlo de alta otra vez.
 *
 * Una edición (con `id`) no lleva clave: devuelve null. La sucursal entra en la huella
 * porque la clave del server es de la sucursal en la que se dio el alta.
 */
export function huellaDeAlta(sucursalId: number | null, payload: { id?: number | null; clave?: string }): string | null {
  if (payload.id != null) return null
  const { clave: _clave, ...contenido } = payload
  return `${sucursalId ?? ''}|${JSON.stringify(contenido)}`
}
