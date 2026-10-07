/**
 * Cambiar un regalo por otro empaque u otro producto (#950).
 *
 * La cantidad de una línea de regalo está en la unidad de SU barra: en una promo
 * de fracción (modo B), sueltas (botellas, paquetes); en una que mueve stock
 * (modo A), unidades de stock. El factor de la barra lo pone el contenedor:
 * `productos.unidades_por_bulto` si está cargado, si no el de la promo (mig
 * XXX, misma regla que `unidades_por_bloque_de_barra` en SQL).
 *
 * Cuando el sustituto es de otra categoría/subcategoría (`regaloCompatible`) o
 * viene en otro empaque (otro factor), "6 botellas" no se traduce a "6
 * paquetes": el dueño decidió que la equivalencia es APROXIMADA, POR VALOR. Un
 * regalo de $X se cambia por ≈ $X del otro producto, y el admin puede corregir
 * la cantidad.
 *
 * El precio es el de LISTA (`productos.precio`, por unidad de stock): es lo que
 * el cliente percibe que le regalan y es el mismo número para los dos productos.
 * El costo mediría nuestro margen, no el valor del regalo, y además falta en
 * productos sin compras; un precio mayorista depende del cliente y de la
 * cantidad, no del regalo.
 */
import { esRegaloCompatible, type ProductoRegalo } from './regaloCompatible'

export interface ProductoConEmpaque extends ProductoRegalo {
  nombre?: string | null
  precio?: number | string | null
  unidades_por_bulto?: number | null
}

const positivo = (n: unknown): number | null => {
  const v = Number(n)
  return Number.isFinite(v) && v > 0 ? v : null
}

/**
 * N de una barra: el bulto del contenedor si está cargado; si no, el de la
 * promo. null = ninguno de los dos.
 */
export function unidadesDeLaBarra(
  bultoContenedor: number | null | undefined,
  unidadesPorBloquePromo: number | null | undefined,
): number | null {
  return positivo(bultoContenedor) ?? positivo(unidadesPorBloquePromo)
}

export interface SugerenciaPorValor {
  /** Cantidad sugerida del sustituto, en su unidad. Mínimo 1. */
  cantidad: number
  /** Valor del regalo original, a precio de lista. */
  valor: number
  precioSueltaOriginal: number
  precioSueltaSustituto: number
}

/**
 * cantidad_nueva ≈ round(cantidad_original × precio_suelta_original / precio_suelta_sustituto),
 * con precio_suelta = precio / factor y mínimo 1. null si falta un precio o un factor.
 */
export function sugerirCantidadPorValor(args: {
  cantidadOriginal: number
  precioOriginal: number | string | null | undefined
  factorOriginal: number | null | undefined
  precioSustituto: number | string | null | undefined
  factorSustituto: number | null | undefined
}): SugerenciaPorValor | null {
  const cantidad = positivo(args.cantidadOriginal)
  const precioOrig = positivo(args.precioOriginal)
  const precioSust = positivo(args.precioSustituto)
  const fOrig = positivo(args.factorOriginal)
  const fSust = positivo(args.factorSustituto)
  if (cantidad === null || precioOrig === null || precioSust === null || fOrig === null || fSust === null) {
    return null
  }
  const precioSueltaOriginal = precioOrig / fOrig
  const precioSueltaSustituto = precioSust / fSust
  const valor = cantidad * precioSueltaOriginal
  return {
    cantidad: Math.max(1, Math.round(valor / precioSueltaSustituto)),
    valor,
    precioSueltaOriginal,
    precioSueltaSustituto,
  }
}

export type CambioRegalo =
  /** Mismo rubro y mismo factor: la cantidad sigue siendo la original (como siempre). */
  | { tipo: 'mismo_empaque'; factorSustituto: number }
  /** Otro rubro sin el dato del empaque: no se puede convertir. Hay que cargarlo. */
  | { tipo: 'falta_bulto'; productoACargar: ProductoConEmpaque }
  /** Otro rubro u otro empaque: la cantidad se sugiere por valor. */
  | { tipo: 'por_valor'; factorSustituto: number; mismaCategoria: boolean; sugerencia: SugerenciaPorValor | null }

/**
 * Qué pasa con la cantidad al cambiar el regalo `original` por `sustituto`.
 *
 * - `factorOriginal`: el factor de la línea (congelado, `factorDeLaLinea`).
 * - `contenedorSustituto`: el producto del que se va a descontar el sustituto
 *   (su fila de barra si ya tiene, el elegido en "avanzado" o él mismo). Su
 *   `unidades_por_bulto` es el factor del sustituto.
 * - Modo A (`regaloMueveStock`): la cantidad está en unidades de stock, factor 1.
 */
export function evaluarCambioRegalo(args: {
  original: ProductoConEmpaque
  sustituto: ProductoConEmpaque
  contenedorSustituto?: ProductoConEmpaque | null
  cantidadOriginal: number
  factorOriginal: number
  regaloMueveStock: boolean
  unidadesPorBloquePromo?: number | null
}): CambioRegalo {
  const mismaCategoria = esRegaloCompatible(args.original, args.sustituto)
  const contenedor = args.contenedorSustituto ?? args.sustituto

  let factorSustituto: number | null
  if (args.regaloMueveStock) {
    factorSustituto = 1
  } else {
    const bulto = positivo(contenedor.unidades_por_bulto)
    // Sin el dato, la barra contaría con el N de la promo, que es el empaque del
    // ORIGINAL: vale para el mismo rubro (como hasta ahora), no para otro.
    factorSustituto = bulto ?? (mismaCategoria ? unidadesDeLaBarra(null, args.unidadesPorBloquePromo) ?? 1 : null)
  }
  if (factorSustituto === null) {
    return { tipo: 'falta_bulto', productoACargar: contenedor }
  }

  const factorOriginal = positivo(args.factorOriginal) ?? 1
  if (mismaCategoria && factorSustituto === factorOriginal) {
    return { tipo: 'mismo_empaque', factorSustituto }
  }
  return {
    tipo: 'por_valor',
    factorSustituto,
    mismaCategoria,
    sugerencia: sugerirCantidadPorValor({
      cantidadOriginal: args.cantidadOriginal,
      precioOriginal: args.original.precio,
      factorOriginal,
      precioSustituto: args.sustituto.precio,
      factorSustituto,
    }),
  }
}
