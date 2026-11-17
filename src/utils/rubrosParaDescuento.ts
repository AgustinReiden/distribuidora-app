/**
 * Los rubros que se ofrecen al cargar un descuento por rubro de un cliente.
 *
 * Desactivar un rubro sólo lo oculta (CAT-11 de #1596, decisión del dueño): deja de
 * ofrecerse para lo nuevo y lo que ya lo tiene lo conserva. Un descuento nuevo no se
 * ofrece sobre uno desactivado, pero el cliente que ya lo tiene lo sigue viendo.
 *
 * Son la unión de la tabla `categorias` y las categorías reales de los productos
 * (`productos.categoria` es texto libre): así lo elegido siempre calza con algún producto.
 */
export function rubrosParaDescuento(
  categoriasTabla: ReadonlyArray<{ nombre: string | null; activa?: boolean | null }>,
  categoriasDeProductos: ReadonlyArray<string | null | undefined>,
  yaUsados: ReadonlyArray<string> = [],
): string[] {
  const desactivados = new Set(
    categoriasTabla.filter(c => c.activa === false).map(c => (c.nombre || '').trim()),
  )
  const usados = new Set(yaUsados.map(n => n.trim()))
  const ofrecibles = new Set<string>()
  const sumar = (nombre: string | null | undefined): void => {
    const n = (nombre || '').trim()
    if (!n) return
    if (desactivados.has(n) && !usados.has(n)) return
    ofrecibles.add(n)
  }
  categoriasTabla.forEach(c => sumar(c.nombre))
  categoriasDeProductos.forEach(sumar)
  return [...ofrecibles].sort((a, b) => a.localeCompare(b))
}
