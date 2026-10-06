/**
 * La letra de la factura de compra (mig 293).
 *
 * `tipo_factura` dice si la compra es con factura (FC) o sin (ZZ). La letra dice
 * QUÉ factura, y eso cambia el costo. Decisión del dueño:
 *
 *   A            FC   IVA crédito fiscal   costo = neto
 *   M            FC   IVA crédito fiscal   costo = neto  (hay que retenerle IVA y
 *                                                        Ganancias al pagar)
 *   B            FC   IVA NO computable    costo = lo pagado (IVA adentro), como ZZ
 *   C            FC   no tiene IVA         costo = lo pagado
 *   sin factura  ZZ   —                    costo = lo pagado
 *
 * B y C siguen siendo "con factura" para lo que cuenta comprobantes (percepciones,
 * no gravado, el control contra el papel); para el COSTO y el IVA se comportan
 * como ZZ. La regla se aplica en el mismo borde que la de ZZ: `tipoParaCosto` es
 * el tipo que ve el motor. Espejo de `v_sin_credito` en las RPCs de la mig 293.
 *
 * Una FC sin letra es A: así quedaron las compras de antes de la 293 y así
 * registra la RPC una FC que no la manda.
 */

export type LetraComprobante = 'A' | 'B' | 'C' | 'M'
export type TipoFacturaCompra = 'ZZ' | 'FC'
/** Lo que se elige en el modal: una letra o "sin factura" (ZZ). */
export type Comprobante = LetraComprobante | 'SF'

export const LETRAS_COMPROBANTE: readonly LetraComprobante[] = ['A', 'B', 'C', 'M']
export const COMPROBANTES: readonly Comprobante[] = ['A', 'B', 'C', 'M', 'SF']

/** Un valor cualquiera (de la base, del escáner, de un borrador) a letra o null. */
export function normalizarLetra(valor: unknown): LetraComprobante | null {
  if (typeof valor !== 'string') return null
  const v = valor.trim().toUpperCase()
  return (LETRAS_COMPROBANTE as readonly string[]).includes(v) ? (v as LetraComprobante) : null
}

/** La letra que vale: null en ZZ; en FC la guardada, o A si no hay (legado). */
export function letraEfectiva(
  tipoFactura: TipoFacturaCompra,
  letra: LetraComprobante | null | undefined,
): LetraComprobante | null {
  if (tipoFactura === 'ZZ') return null
  return normalizarLetra(letra) ?? 'A'
}

/** ¿El IVA de esta compra es crédito fiscal? Sólo FC A o M. */
export function ivaComputable(tipoFactura: TipoFacturaCompra, letra: LetraComprobante | null | undefined): boolean {
  const l = letraEfectiva(tipoFactura, letra)
  return l === 'A' || l === 'M'
}

/**
 * El tipo que ve el motor de costos: 'ZZ' cuando lo pagado es el costo (ZZ, B o
 * C), 'FC' cuando el IVA y el II se discriminan (A o M). Es el `v_sin_credito`
 * de la mig 293.
 */
export function tipoParaCosto(
  tipoFactura: TipoFacturaCompra,
  letra: LetraComprobante | null | undefined,
): TipoFacturaCompra {
  return ivaComputable(tipoFactura, letra) ? 'FC' : 'ZZ'
}

export function comprobanteDe(tipoFactura: TipoFacturaCompra, letra: LetraComprobante | null | undefined): Comprobante {
  return letraEfectiva(tipoFactura, letra) ?? 'SF'
}

export function desdeComprobante(c: Comprobante): { tipoFactura: TipoFacturaCompra; letraComprobante: LetraComprobante | null } {
  return c === 'SF' ? { tipoFactura: 'ZZ', letraComprobante: null } : { tipoFactura: 'FC', letraComprobante: c }
}

/** Lo que se muestra en un badge: "FC A", "FC B", "ZZ". */
export function etiquetaComprobante(tipoFactura: TipoFacturaCompra, letra: LetraComprobante | null | undefined): string {
  const l = letraEfectiva(tipoFactura, letra)
  return l ? `FC ${l}` : 'ZZ'
}

/** El aviso de la letra, o null si no hay nada que avisar. No bloquea. */
export function avisoLetra(tipoFactura: TipoFacturaCompra, letra: LetraComprobante | null | undefined): string | null {
  const l = letraEfectiva(tipoFactura, letra)
  if (l === 'B') return 'Una factura B a un responsable inscripto es un error: pedile al proveedor la factura A.'
  if (l === 'M') return 'Factura M: corresponde retenerle IVA y Ganancias al pagar (RG 1575).'
  return null
}

/** Para explicar el costo: qué pasa con el IVA según el comprobante. */
export function notaCostoComprobante(tipoFactura: TipoFacturaCompra, letra: LetraComprobante | null | undefined): string | null {
  const l = letraEfectiva(tipoFactura, letra)
  if (l === null) return 'En ZZ lo pagado ya incluye IVA e impuestos internos: por eso las dos columnas van en cero y el cargo suma igual.'
  if (l === 'B') return 'En una factura B el IVA no es crédito fiscal: lo pagado es el costo, como en ZZ.'
  if (l === 'C') return 'Una factura C no discrimina IVA: lo pagado es el costo, como en ZZ.'
  return null
}
