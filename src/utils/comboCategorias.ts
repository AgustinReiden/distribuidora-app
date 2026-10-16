/**
 * Un lugar de combo puede ser productos sueltos y categorías (#1213). La
 * categoría es viva: el combo guarda la categoría, y lo que vende es lo que
 * la categoría tiene hoy.
 *
 * `resolverLugares` es el espejo de `_combo_definicion` (mig 386): sueltos tal
 * cual; una categoría trae los productos ACTIVOS con `categoria_id` o
 * `subcategoria_id` igual (un rubro trae también los de sus subrubros); y un
 * producto queda en un solo lugar, el de número más bajo. Lo usa el panel de
 * admin para mostrar y alertar; lo que se vende lo resuelve el server.
 */

export interface LugarCombo {
  cantidad: number
  /** Productos elegidos uno por uno. */
  sueltos: readonly string[]
  /** Categorías o subcategorías enteras (ids de `categorias`). */
  categorias: readonly string[]
}

export interface ProductoCatalogo {
  id: string | number
  activo?: boolean | null
  categoria_id?: string | null
  subcategoria_id?: string | null
}

export interface LugarResuelto {
  cantidad: number
  productos: string[]
}

const porId = (a: string, b: string): number => Number(a) - Number(b) || a.localeCompare(b)

/** Los productos activos de una categoría o subcategoría, hoy. */
export function productosDeCategoria(categoriaId: string, catalogo: readonly ProductoCatalogo[]): string[] {
  return catalogo
    .filter(p => p.activo !== false
      && (String(p.categoria_id ?? '') === categoriaId || String(p.subcategoria_id ?? '') === categoriaId))
    .map(p => String(p.id))
    .sort(porId)
}

/** Lo que cada lugar trae hoy, sin que un producto quede en dos lugares. */
export function resolverLugares(
  lugares: readonly LugarCombo[],
  catalogo: readonly ProductoCatalogo[],
): LugarResuelto[] {
  const tomados = new Set<string>()
  return lugares.map(l => {
    const miembros = new Set<string>(l.sueltos.map(String))
    for (const c of l.categorias) for (const p of productosDeCategoria(String(c), catalogo)) miembros.add(p)
    const productos = [...miembros].filter(p => !tomados.has(p)).sort(porId)
    productos.forEach(p => tomados.add(p))
    return { cantidad: l.cantidad, productos }
  })
}

/**
 * Productos que caen en más de un lugar (por un suelto o una categoría). Al
 * guardar, el server los rechaza; el formulario los avisa antes.
 */
export function productosEnVariosLugares(
  lugares: readonly LugarCombo[],
  catalogo: readonly ProductoCatalogo[],
): string[] {
  const lugaresDe = new Map<string, number>()
  for (const l of lugares) {
    const miembros = new Set<string>(l.sueltos.map(String))
    for (const c of l.categorias) for (const p of productosDeCategoria(String(c), catalogo)) miembros.add(p)
    for (const p of miembros) lugaresDe.set(p, (lugaresDe.get(p) ?? 0) + 1)
  }
  return [...lugaresDe].filter(([, n]) => n > 1).map(([p]) => p).sort(porId)
}
