/**
 * Qué promos activas se rompen si se desactiva un producto.
 *
 * Desde la mig que sigue a la 284 un producto inactivo no se vende NI se regala:
 * `crear_pedido_completo` rechaza el pedido entero. Si el producto es el regalo
 * por defecto (`producto_regalo_id`) de una promo activa, todo pedido que la
 * dispare falla y el preventista no puede resolverlo. El admin decide, pero hay
 * que decírselo antes de confirmar.
 */

export interface PromoParaAviso {
  nombre: string
  activo: boolean
  fecha_fin?: string | null
  producto_regalo_id?: string | number | null
  ajuste_producto_id?: string | number | null
}

export interface PromosAfectadas {
  /** Nombres de las promos activas que regalan este producto. */
  comoRegalo: string[]
  /** Nombres de las promos activas que lo usan como contenedor de ajuste. */
  comoContenedor: string[]
}

/** Activa = `activo` y sin fin vencido (fecha_fin YYYY-MM-DD, inclusive). */
function estaVigente(p: PromoParaAviso, hoy?: string): boolean {
  if (!p.activo) return false
  if (hoy && p.fecha_fin && p.fecha_fin < hoy) return false
  return true
}

export function promosAfectadasPorDesactivar(
  productoId: string | number,
  promos: readonly PromoParaAviso[],
  hoy?: string,
): PromosAfectadas {
  const id = String(productoId)
  const vigentes = promos.filter(p => estaVigente(p, hoy))
  const nombres = (campo: 'producto_regalo_id' | 'ajuste_producto_id') =>
    vigentes.filter(p => p[campo] != null && String(p[campo]) === id).map(p => p.nombre)
  return {
    comoRegalo: nombres('producto_regalo_id'),
    comoContenedor: nombres('ajuste_producto_id'),
  }
}

function listar(nombres: string[]): string {
  const q = nombres.map(n => `«${n}»`)
  if (q.length === 1) return q[0]
  return `${q.slice(0, -1).join(', ')} y ${q[q.length - 1]}`
}

/** Texto de advertencia para el confirm; '' si ninguna promo se ve afectada. */
export function avisoDesactivarProducto(afectadas: PromosAfectadas): string {
  const lineas: string[] = []
  const { comoRegalo, comoContenedor } = afectadas
  if (comoRegalo.length > 0) {
    lineas.push(
      `Es el regalo de la promo ${listar(comoRegalo)}. Mientras no cambies el regalo de ` +
        `${comoRegalo.length > 1 ? 'esas promos' : 'esa promo'}, los pedidos que ` +
        `${comoRegalo.length > 1 ? 'las' : 'la'} activen van a fallar.`,
    )
  }
  if (comoContenedor.length > 0) {
    lineas.push(`También es el contenedor de ajuste de la promo ${listar(comoContenedor)}.`)
  }
  return lineas.join('\n')
}
