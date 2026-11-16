/**
 * Qué hay que quitar y qué agregar para pasar de un conjunto de valores al otro.
 *
 * Sirve para escribir sólo lo que cambió en vez de borrar todo y volver a insertar
 * (#1561, 1561-b12): un fallo a mitad de camino deja a lo sumo una parte sin
 * hacer, no la entidad vacía. Ignora repetidos y el orden.
 */
export function diferenciaDeConjuntos<T>(
  actuales: readonly T[],
  nuevos: readonly T[],
): { quitar: T[]; agregar: T[] } {
  const enActuales = new Set(actuales)
  const enNuevos = new Set(nuevos)
  return {
    quitar: [...enActuales].filter(v => !enNuevos.has(v)),
    agregar: [...enNuevos].filter(v => !enActuales.has(v)),
  }
}
