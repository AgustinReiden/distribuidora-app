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
 * paquetes": el dueño decidió que la equivalencia es POR VALOR. Un regalo de $X
 * se cambia por lo que entra en $X del otro producto, redondeado para abajo (que no
 * valga más: es el tope de quien no es admin, #1592), y el admin puede corregir la
 * cantidad. Quien no es admin tiene ese tope, o todo el corte si el sustituto es del
 * mismo rubro que el regalo de la promo (`topeSustitutoRegalo`).
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

/** Un precio de lista en centavos, entero: la cuenta del tope no puede depender del float. */
const centavos = (n: number): number => Math.round(n * 100)

/**
 * Hasta cuántas unidades de un sustituto valen, a precio de lista, lo mismo o menos
 * que `corte` unidades del regalo de la promo: floor(corte × precio_suelta_regalo /
 * precio_suelta_sustituto), con precio_suelta = precio / factor. 0 si falta un precio.
 * Es la mitad «por valor» de `topeSustitutoRegalo`, y lo que sugiere la pantalla.
 */
export function topePorValor(args: {
  corte: number
  precioRegalo: number | string | null | undefined
  factorRegalo: number | null | undefined
  precioSustituto: number | string | null | undefined
  factorSustituto: number | null | undefined
}): number {
  const corte = positivo(args.corte)
  const pReg = positivo(args.precioRegalo)
  const pSus = positivo(args.precioSustituto)
  if (corte === null || pReg === null || pSus === null) return 0
  const fReg = Math.max(positivo(args.factorRegalo) ?? 1, 1)
  const fSus = Math.max(positivo(args.factorSustituto) ?? 1, 1)
  // En enteros (centavos), y el cociente corregido: el floor de una división de float
  // puede quedar una unidad abajo o arriba justo cuando el valor es exacto.
  const num = corte * centavos(pReg) * fSus
  const den = fReg * centavos(pSus)
  let q = Math.floor(num / den)
  if (q * den > num) q -= 1
  else if ((q + 1) * den <= num) q += 1
  return Math.max(q, 0)
}

/**
 * PRM-1 (#1592), decisión del dueño del 16/11: hasta cuántas unidades de un
 * sustituto puede poner quien no es admin en lugar del regalo que da la promo, con
 * su corte. Todo el corte si es del mismo rubro (un cambio de sabor, aunque sea algo
 * más caro), o lo que no valga más a precio de lista (`topePorValor`). Lo que sea
 * más. Espejo EXACTO de `regalo_tope_sustituto()` en el server: los dos corren
 * `topeSustituto.espejo.json` (vitest y `scripts/espejo-tope-sustituto.mjs`).
 */
export function topeSustitutoRegalo(args: {
  corte: number
  precioRegalo: number | string | null | undefined
  factorRegalo: number | null | undefined
  precioSustituto: number | string | null | undefined
  factorSustituto: number | null | undefined
  mismoRubro: boolean
}): number {
  const corte = positivo(args.corte)
  if (corte === null) return 0
  return Math.max(args.mismoRubro ? corte : 0, topePorValor(args))
}

/**
 * La cantidad que sugiere la pantalla en un cambio por valor: la misma cuenta que
 * el server (`topePorValor`, redondeada para abajo, para que no valga más), contra
 * el regalo que da la promo con el corte de la línea cuando se conocen, y mínimo 1.
 * null si falta un precio o un factor.
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
    cantidad: Math.max(1, topePorValor({
      corte: cantidad, precioRegalo: precioOrig, factorRegalo: fOrig,
      precioSustituto: precioSust, factorSustituto: fSust,
    })),
    valor,
    precioSueltaOriginal,
    precioSueltaSustituto,
  }
}

export type CambioRegalo =
  /** Mismo rubro y mismo factor: la cantidad sigue siendo la original (como siempre). */
  | { tipo: 'mismo_empaque'; factorSustituto: number }
  /**
   * Sin el dato del empaque y sin descontar del contenedor de la promo (otro rubro, o el
   * mismo rubro desde promos-B1): no se puede convertir. Hay que cargarlo.
   */
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
  /**
   * PRM-1 (#1592): el regalo que da la promo, el factor de su barra y el corte de la
   * línea. Con él, la cantidad por valor se sugiere contra ese regalo (como mide el
   * server), y no contra la línea de hoy.
   */
  referencia?: { regalo: ProductoConEmpaque; factor: number; corte: number } | null
  /**
   * promos-B1 (tanda 6 de #1603): el contenedor de la promo (`ajuste_producto_id`) y su
   * regalo. Un sustituto que descuenta de ese contenedor (o que es el regalo de la promo)
   * cuenta con el N de la promo aunque no tenga su bulto; cualquier otro, no.
   */
  contenedorPromoId?: string | number | null
  regaloPromoId?: string | number | null
}): CambioRegalo {
  const mismaCategoria = esRegaloCompatible(args.original, args.sustituto)
  const contenedor = args.contenedorSustituto ?? args.sustituto

  let factorSustituto: number | null
  if (args.regaloMueveStock) {
    factorSustituto = 1
  } else {
    const bulto = positivo(contenedor.unidades_por_bulto)
    const factorPromo = positivo(args.unidadesPorBloquePromo)
    const mismo = (a: unknown, b: string | number | null | undefined) => b != null && String(a) === String(b)
    const delContenedorDeLaPromo = mismo(contenedor.id, args.contenedorPromoId)
      || mismo(args.sustituto.id, args.regaloPromoId)
    // Sin el dato, la barra contaría con el N de la promo, que es el empaque del regalo
    // (#950): vale para el mismo rubro sólo si descuenta del contenedor de la promo, o si la
    // promo no tiene N (cuenta de a una). Igual que sustituir_regalo_pedido (promos-B1).
    factorSustituto = bulto
      ?? (mismaCategoria && (factorPromo === null || delContenedorDeLaPromo) ? (factorPromo ?? 1) : null)
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
    sugerencia: sugerirCantidadPorValor(args.referencia
      ? {
          cantidadOriginal: args.referencia.corte,
          precioOriginal: args.referencia.regalo.precio,
          factorOriginal: args.referencia.factor,
          precioSustituto: args.sustituto.precio,
          factorSustituto,
        }
      : {
          cantidadOriginal: args.cantidadOriginal,
          precioOriginal: args.original.precio,
          factorOriginal,
          precioSustituto: args.sustituto.precio,
          factorSustituto,
        }),
  }
}

/**
 * promos-B1 en el alta y la edición (tanda 6 bis de #1603): ¿este producto, puesto como
 * regalo de la promo, necesita su bulto y no lo tiene? Espejo de `_regalo_sin_bulto`: en una
 * promo de fracción con unidades por bloque, un regalo cuenta en la barra de SU contenedor
 * (`contenedor_de_barra`: el de la promo para su regalo, el de su fila de
 * `promo_acumuladores` si la tiene, o él mismo), con el bulto de ese contenedor; sin el dato
 * contaría con el N de la promo, que es el empaque del regalo. Sin bulto el server lo
 * rechaza, también al admin.
 *
 * Sin los acumuladores cargados (`acumuladores` undefined), o sin el contenedor en la lista
 * de productos, no decide (false): decide el server, con el mismo texto. Así la pantalla no
 * bloquea lo que el server acepta (F4 de la lente de la tarjeta I).
 */
export function regaloSinBulto(args: {
  promo: {
    regaloMueveStock?: boolean | null
    unidadesPorBloque?: number | null
    ajusteProductoId?: string | number | null
    productoRegaloId?: string | number | null
  }
  producto: { id: string | number; unidades_por_bulto?: number | null }
  /** Las filas de `promo_acumuladores` de ESTA promo; undefined = todavía no se sabe. */
  acumuladores: readonly { producto_regalo_id: string | number; ajuste_producto_id?: string | number | null }[] | undefined
  /** Para leer el bulto del contenedor. */
  productoPorId: (id: string) => { unidades_por_bulto?: number | null } | undefined
}): boolean {
  const { promo, producto, acumuladores } = args
  if (promo.regaloMueveStock) return false
  if (positivo(promo.unidadesPorBloque) === null) return false
  const id = (v: string | number | null | undefined) => (v == null ? null : String(v))
  if (id(producto.id) === id(promo.productoRegaloId)) return false
  if (acumuladores === undefined) return false
  const fila = acumuladores.find(a => id(a.producto_regalo_id) === id(producto.id))
  const contenedor = fila ? id(fila.ajuste_producto_id) : id(producto.id)
  if (contenedor === id(promo.ajusteProductoId)) return false
  if (contenedor === null) return true
  const c = contenedor === id(producto.id) ? producto : args.productoPorId(contenedor)
  if (!c) return false
  return positivo(c.unidades_por_bulto) === null
}

/** El texto del rechazo, el mismo que da el server (`_regalo_sin_bulto`). */
export function textoRegaloSinBulto(nombre: string): string {
  return `Para regalar ${nombre} hay que cargar en su ficha cuántas unidades sueltas trae cada unidad de stock (unidades por bulto).`
}
