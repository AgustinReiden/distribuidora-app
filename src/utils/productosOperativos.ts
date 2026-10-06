/**
 * Regla única de qué productos se ofrecen para OPERAR (vender, regalar,
 * entregar, alertar). Un producto desactivado (`activo = false`) se conserva por
 * su historial, pero deja de ofrecerse.
 *
 * Todo selector operativo pasa por acá: ningún componente filtra `activo` por
 * su cuenta. Las lecturas de historial (reportes, compras, backup, exportes, la
 * vista de Productos) NO filtran: usan la lista completa.
 *
 * `activo` ausente (dato viejo o caché previo a la columna) cuenta como activo.
 */
interface ConActivo {
  activo?: boolean | null
}
interface ConStock extends ConActivo {
  stock?: number | string | null
}

export function esProductoOperativo(p: ConActivo): boolean {
  return p.activo !== false
}

/**
 * Si el producto aparece en la lista para tomar un pedido. Con la política
 * `mostrarSinStock` apagada el agotado no se ofrece; prendida se ve (la UI lo
 * deshabilita).
 */
export function esProductoMostrable(
  p: ConStock,
  opts: { mostrarSinStock: boolean },
): boolean {
  if (!esProductoOperativo(p)) return false
  return Number(p.stock) > 0 || opts.mostrarSinStock
}

export function filtrarProductosOperativos<T extends ConActivo>(productos: readonly T[]): T[] {
  return productos.filter(esProductoOperativo)
}

/**
 * Si un error al BORRAR un producto es el rechazo del trigger por tener
 * historial. Se distingue por el mensaje ("historial"), que es lo que garantiza
 * el contrato de la base; el `code` puede variar. supabase-js devuelve un
 * objeto plano, no un Error, así que se lee `message` sin `instanceof`.
 */
export function esErrorPorHistorial(error: unknown): boolean {
  if (error == null) return false
  const mensaje = typeof error === 'string'
    ? error
    : (error as { message?: unknown }).message
  return typeof mensaje === 'string' && /historial/i.test(mensaje)
}

/**
 * Líneas de un pedido (incluidas las de regalo: un producto desactivado
 * tampoco se regala) cuyo producto está desactivado en el catálogo dado. Un
 * producto que no aparece en el catálogo no se juzga acá: no hay dato.
 */
export function itemsConProductoDesactivado<
  I extends { productoId: string; nombre?: string },
  P extends ConActivo & { id: string; nombre?: string },
>(items: readonly I[], productos: readonly P[]): Array<{ productoId: string; nombre: string }> {
  const vistos = new Set<string>()
  const resultado: Array<{ productoId: string; nombre: string }> = []
  for (const item of items) {
    const producto = productos.find(p => String(p.id) === String(item.productoId))
    if (!producto || esProductoOperativo(producto)) continue
    if (vistos.has(item.productoId)) continue
    vistos.add(item.productoId)
    resultado.push({
      productoId: item.productoId,
      nombre: producto.nombre || item.nombre || 'Producto desconocido',
    })
  }
  return resultado
}
