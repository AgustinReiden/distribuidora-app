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
  const precioBase = formatMoneda(escala.precioUnitario)
  const total = escala.cantidadMinima

  const minProdDistintos = Math.max(1, escala.minProductosDistintos)
  const minimos = Array.from(escala.minimosPorProducto.entries())
    .filter(([, v]) => v.cantidad > 0)
    .sort(([a], [b]) => a.localeCompare(b))

  // Caso clásico: sin mínimos por producto y con K=1.
  if (minProdDistintos <= 1 && minimos.length === 0) {
    return `Si el grupo suma ${total}+ unidades, ${precioBase} c/u.`
  }

  const partes: string[] = [`${total}+ unidades totales`]
  if (minProdDistintos > 1) {
    partes.push(`al menos ${minProdDistintos} productos distintos`)
  }

  // Detectar si hay precios override heterogéneos vs un precio uniforme.
  const algunoConOverride = minimos.some(([, v]) => v.precioOverride != null && v.precioOverride > 0)
  if (minimos.length > 0) {
    if (algunoConOverride) {
      // Lista con precio individual por producto.
      const lista = minimos
        .map(([pid, v]) => {
          const precioProd = v.precioOverride != null && v.precioOverride > 0
            ? formatMoneda(v.precioOverride)
            : precioBase
          return `${getNombre(pid, opts)} ${v.cantidad}+ a ${precioProd}`
        })
        .join(', ')
      return `Si comprás ${partes.join(', ')}, con precios por producto (${lista}).`
    }
    // Precios uniformes: solo listar cantidades.
    const lista = minimos.map(([pid, v]) => `${getNombre(pid, opts)} ${v.cantidad}+`).join(', ')
    partes.push(`con mínimos (${lista})`)
  }
  return `Si comprás ${partes.join(', ')}, ${precioBase} c/u.`
}
