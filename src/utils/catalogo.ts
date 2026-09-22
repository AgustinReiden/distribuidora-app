/**
 * Nombres de catálogo —categorías y marcas—: cuándo dos nombres son el mismo.
 *
 * La base no lo decide. El UNIQUE de las dos tablas es `(sucursal_id, nombre)`
 * a secas, así que "Nachos" y "NACHOS" entran como dos filas. Y el trigger que
 * le pone `categoria_id` al producto (mig 146) compara con `lower(trim(...))` y
 * se queda con la primera que encuentra: con dos filas así, cuál gana es azar.
 *
 * Por eso el alta desde la ficha o desde la compra reusa la que ya existe en vez
 * de crear una gemela. Se compara sin mayúsculas ni tildes —"Azucar" es
 * "AZÚCAR"— pero con la eñe, que en castellano es otra letra.
 */
const collator = new Intl.Collator('es', { sensitivity: 'base' })

/**
 * Lo tipeado, listo para guardar: sin espacios de más y en mayúsculas, que es
 * como está escrito todo el catálogo (las 25 categorías y las 24 marcas de prod
 * al 22/09/2026). Una "Frau" al lado de "FRAU" parece otra cosa aunque no lo sea.
 */
export function limpiarNombreCatalogo(nombre: string): string {
  return nombre.trim().replace(/\s+/g, ' ').toLocaleUpperCase('es')
}

/** El elemento de la lista que se llama igual que `nombre`, o undefined. */
export function buscarEnCatalogo<T extends { nombre: string }>(
  lista: readonly T[],
  nombre: string,
): T | undefined {
  const buscado = limpiarNombreCatalogo(nombre)
  if (!buscado) return undefined
  return lista.find(item => collator.compare(limpiarNombreCatalogo(item.nombre), buscado) === 0)
}
