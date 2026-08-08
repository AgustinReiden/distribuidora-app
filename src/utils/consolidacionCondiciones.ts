/**
 * Detecta condiciones mayoristas que en realidad son un solo fardo surtido.
 *
 * El modelo pide "creá una condición, ponele nombre, metéle productos", pero se
 * piensa al revés: "este fardo de fideos sale tanto". El resultado en prod son
 * 82 de 88 condiciones con un solo producto, y como `escalaAplica` suma lo que
 * el cliente lleve de los productos de UNA condición, un pedido de 4 coditos +
 * 4 mostachos + 4 tirabuzones nunca llega al mínimo de 12 y se cobra a lista.
 *
 * La detección agrupa por "perfil": el conjunto de (cantidad, precio) que le
 * corresponde a cada producto sumando todas sus condiciones. Dos productos con
 * el mismo perfil son el mismo fardo partido en pedazos. Eso resuelve de una
 * los dos patrones que hay cargados:
 *   · "CODITO 1/2 FARDO" (6u) + "FIDEO X FARDO" (12u) → una condición, 2 escalas
 *   · los 5 Cotella comunes, cada uno con lo suyo    → una condición, 5 productos
 */
import type { GrupoPrecioConDetalles } from '../types'

export interface EscalaConsolidada {
  cantidadMinima: number
  precioUnitario: number
  etiqueta: string | null
}

export interface GrupoConsolidable {
  /** Perfil serializado. Sirve de key estable en React. */
  firma: string
  /** Productos que comparten exactamente este perfil. */
  productoIds: string[]
  /** Condiciones que se fusionan. La primera es la que sobrevive. */
  condicionesOrigen: Array<{ id: string; nombre: string }>
  /** Escalas resultantes, ordenadas por cantidad. */
  escalas: EscalaConsolidada[]
  /** Nombre propuesto, editable antes de aplicar. */
  nombreSugerido: string
}

/** Palabras que comparten todos los nombres, en el orden del primero. */
function nombreComun(nombres: string[]): string {
  if (nombres.length === 0) return ''
  const enPalabras = nombres.map(n => n.trim().split(/\s+/).filter(Boolean))
  const [primero, ...resto] = enPalabras
  const comunes = primero.filter(palabra =>
    resto.every(otras => otras.some(o => o.toUpperCase() === palabra.toUpperCase())),
  )
  return comunes.join(' ').trim()
}

/**
 * Condiciones fusionables, listas para previsualizar. Solo entran las que:
 *   · están activas (una desactivada no aplica precio: fusionarla confundiría);
 *   · tienen exactamente UN producto — las multi-producto ya son un fardo
 *     surtido armado a propósito y no hay que tocarlas;
 *   · y cuyo producto no participa de ninguna condición multi-producto, para no
 *     dejarlo con el precio partido entre dos lugares.
 *
 * Devuelve solo los casos con algo real que fusionar (2 o más condiciones).
 */
export function detectarConsolidables(
  grupos: GrupoPrecioConDetalles[],
  nombresProductos: Map<string, string>,
): GrupoConsolidable[] {
  const activos = grupos.filter(g => g.activo !== false)

  const productosEnCondicionCompartida = new Set<string>()
  for (const g of activos) {
    if (g.productos.length > 1) {
      for (const p of g.productos) productosEnCondicionCompartida.add(String(p.producto_id))
    }
  }

  // productoId → sus condiciones de un solo producto, con sus escalas.
  const porProducto = new Map<string, { condiciones: Array<{ id: string; nombre: string }>; escalas: EscalaConsolidada[] }>()

  for (const g of activos) {
    if (g.productos.length !== 1) continue
    const pid = String(g.productos[0].producto_id)
    if (productosEnCondicionCompartida.has(pid)) continue

    const escalas = g.escalas
      .filter(e => e.activo !== false)
      .map((e): EscalaConsolidada => ({
        cantidadMinima: Number(e.cantidad_minima),
        precioUnitario: Number(e.precio_unitario),
        etiqueta: e.etiqueta ?? null,
      }))
    if (escalas.length === 0) continue

    const entrada = porProducto.get(pid) ?? { condiciones: [], escalas: [] }
    entrada.condiciones.push({ id: String(g.id), nombre: g.nombre })
    entrada.escalas.push(...escalas)
    porProducto.set(pid, entrada)
  }

  // Agrupar productos por perfil idéntico.
  const porFirma = new Map<string, { productoIds: string[]; condiciones: Array<{ id: string; nombre: string }>; escalas: EscalaConsolidada[] }>()

  for (const [pid, entrada] of porProducto) {
    const escalas = [...entrada.escalas].sort((a, b) => a.cantidadMinima - b.cantidadMinima)
    const firma = escalas.map(e => `${e.cantidadMinima}:${e.precioUnitario}`).join('|')

    const acumulado = porFirma.get(firma) ?? { productoIds: [], condiciones: [], escalas }
    acumulado.productoIds.push(pid)
    acumulado.condiciones.push(...entrada.condiciones)
    porFirma.set(firma, acumulado)
  }

  const salida: GrupoConsolidable[] = []
  for (const [firma, acumulado] of porFirma) {
    // Una sola condición no es una fusión: no hay nada que unificar.
    if (acumulado.condiciones.length < 2) continue

    const nombres = acumulado.productoIds
      .map(pid => nombresProductos.get(pid))
      .filter((n): n is string => !!n)

    salida.push({
      firma,
      productoIds: acumulado.productoIds,
      condicionesOrigen: acumulado.condiciones,
      escalas: acumulado.escalas,
      // "CODITO 1/2 FARDO" sería un mal nombre para 5 sabores; el denominador
      // común de los nombres describe mejor lo que quedó.
      nombreSugerido: nombreComun(nombres) || nombres[0] || acumulado.condiciones[0].nombre,
    })
  }

  return salida.sort((a, b) => b.productoIds.length - a.productoIds.length)
}
