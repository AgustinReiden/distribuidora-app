/**
 * Describe una escala de grupo_precio en un texto humano corto, pensado para
 * mostrar abajo del formulario del modal y en chips de la vista lista.
 *
 * Para escalas clásicas produce algo como:
 *   "Si el grupo suma 12+ unidades, $800 c/u."
 *
 * Para escalas combinadas incorpora los mínimos y la cantidad de productos
 * distintos exigidos:
 *   "Si comprás 12+ unidades totales con al menos 2 productos distintos
 *    (Fideo A 6+, Fideo B 6+, Fideo C 6+), $800 c/u."
 */
import type { EscalaPrecio } from './precioMayorista'

function formatMoneda(precio: number): string {
  return new Intl.NumberFormat('es-AR', { style: 'currency', currency: 'ARS', maximumFractionDigits: 0 }).format(precio || 0)
}

export interface DescribirReglaOpts {
  /** Mapa productoId -> nombre legible. Si falta un nombre, cae al id. */
  nombresProductos?: Map<string, string> | Record<string, string>
}

function getNombre(id: string, opts: DescribirReglaOpts): string {
  const src = opts.nombresProductos
  if (src instanceof Map) return src.get(id) ?? `#${id}`
  if (src && typeof src === 'object') return src[id] ?? `#${id}`
  return `#${id}`
}

export function describirReglaEscala(escala: EscalaPrecio, opts: DescribirReglaOpts = {}): string {
  const precio = formatMoneda(escala.precioUnitario)
  const total = escala.cantidadMinima

  const minProdDistintos = Math.max(1, escala.minProductosDistintos)
  const minimos = Array.from(escala.minimosPorProducto.entries())
    .filter(([, v]) => v > 0)
    .sort(([a], [b]) => a.localeCompare(b))

  // Caso clásico: sin mínimos por producto y con K=1.
  if (minProdDistintos <= 1 && minimos.length === 0) {
    return `Si el grupo suma ${total}+ unidades, ${precio} c/u.`
  }

  const partes: string[] = [`${total}+ unidades totales`]
  if (minProdDistintos > 1) {
    partes.push(`al menos ${minProdDistintos} productos distintos`)
  }
  if (minimos.length > 0) {
    const lista = minimos.map(([pid, cant]) => `${getNombre(pid, opts)} ${cant}+`).join(', ')
    partes.push(`con mínimos (${lista})`)
  }
  return `Si comprás ${partes.join(', ')}, ${precio} c/u.`
}
