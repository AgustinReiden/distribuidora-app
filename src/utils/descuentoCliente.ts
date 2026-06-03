/**
 * Descuentos por cliente: general + por categoría.
 *
 * Regla de negocio: si el cliente tiene un descuento por la categoría del
 * producto, ese prevalece sobre el descuento general (incluso si el de la
 * categoría es 0%, lo que sirve para excluir una categoría del general).
 *
 * El match es por NOMBRE de categoría normalizado (trim + mayúsculas) porque
 * `productos.categoria` es texto libre (no FK) y es el campo sobre el que se
 * calcula el precio. Centraliza la lógica para usarla en vivo (armado del
 * pedido) y al guardar, evitando duplicar la matemática.
 */

export interface DescuentoCategoriaCliente {
  categoria: string
  descuento_porcentaje: number
}

export interface ClienteConDescuentos {
  descuento_porcentaje?: number | null
  descuentos_categoria?: DescuentoCategoriaCliente[] | null
}

export interface ProductoConCategoria {
  id: string | number
  categoria?: string | null
}

/** Forma mínima de un item de pedido para aplicarle descuento. */
export interface ItemDescuentable {
  productoId?: string | number
  producto_id?: string | number
  cantidad: number
  precioUnitario: number
  precioOverride?: boolean
  esBonificacion?: boolean
}

const norm = (s?: string | null): string => (s ?? '').trim().toUpperCase()

/**
 * Devuelve el % de descuento efectivo para un producto de la categoría dada.
 * Categoría > general. Si no hay match de categoría, usa el general.
 */
export function resolverDescuentoPctCliente(
  cliente: ClienteConDescuentos | null | undefined,
  categoria: string | null | undefined,
): number {
  if (!cliente) return 0
  const general = Number(cliente.descuento_porcentaje ?? 0) || 0
  const cats = cliente.descuentos_categoria
  if (cats && cats.length > 0 && categoria) {
    const key = norm(categoria)
    const match = cats.find(c => norm(c.categoria) === key)
    // La categoría prevalece aunque sea 0 (exclusión explícita del general).
    if (match) return Number(match.descuento_porcentaje ?? 0) || 0
  }
  return general
}

/**
 * Aplica el descuento del cliente a los items ya resueltos (mayorista/promo).
 * No toca bonificaciones, líneas con precioOverride ni precio ≤ 0.
 * Devuelve los items con `precioUnitario` ajustado + total e info de ahorro.
 */
export function aplicarDescuentoClienteItems<T extends ItemDescuentable>(
  items: T[],
  productos: ProductoConCategoria[],
  cliente: ClienteConDescuentos | null | undefined,
): { items: T[]; total: number; ahorro: number; hayDescuento: boolean } {
  const general = Number(cliente?.descuento_porcentaje ?? 0) || 0
  const cats = cliente?.descuentos_categoria ?? []
  const sinDescuentos = general <= 0 && (!cats || cats.length === 0)

  let total = 0
  let totalOriginal = 0
  let hayDescuento = false

  const out = items.map(item => {
    const pid = String(item.productoId ?? item.producto_id ?? '')
    const precio = item.precioUnitario ?? 0
    const cantidad = item.cantidad ?? 0
    const esBonif = !!item.esBonificacion
    if (!esBonif) totalOriginal += precio * cantidad

    if (sinDescuentos || esBonif || item.precioOverride || precio <= 0) {
      if (!esBonif) total += precio * cantidad
      return item
    }

    const prod = productos.find(p => String(p.id) === pid)
    const pct = resolverDescuentoPctCliente(cliente, prod?.categoria)
    if (pct <= 0) {
      total += precio * cantidad
      return item
    }

    const nuevoPrecio = Math.round(precio * (1 - pct / 100) * 100) / 100
    hayDescuento = true
    total += nuevoPrecio * cantidad
    return { ...item, precioUnitario: nuevoPrecio }
  })

  return { items: out, total, ahorro: totalOriginal - total, hayDescuento }
}
