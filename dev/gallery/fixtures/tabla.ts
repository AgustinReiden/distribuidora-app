/**
 * Compras de fixture para la sección de `Table` (WP-50, #774).
 *
 * Es el caso típico de back-office: proveedor, fecha, comprobante FC / ZZ, ítems,
 * estado y un total en pesos. No usa `CompraDB` a propósito: la galería muestra el
 * PRIMITIVO, no el dominio, y atar la fixture al tipo de compra la haría romper
 * (en `npm run typecheck`) por un campo que la tabla ni mira.
 *
 * Los importes salen de una sola cuenta, así que el pie de la tabla siempre
 * cierra con las filas:
 *  - FC (factura): `total = subtotal + IVA 21 % + internos + percepciones`.
 *  - ZZ (sin factura): lo pagado ya incluye IVA e impuestos internos, y nunca se
 *    suman encima: `total = subtotal`.
 *
 * Las fechas son relativas a hoy para que la tabla no envejezca sola; son `Date`
 * locales y no strings ISO, porque `new Date('2026-10-01')` se interpreta en UTC
 * y en Argentina cae el día anterior.
 */

export type EstadoCompraFixture = 'recibida' | 'parcial' | 'pendiente' | 'cancelada'
export type TipoFacturaFixture = 'FC' | 'ZZ'

export interface CompraFixture {
  id: string
  fecha: Date
  proveedor: string
  numeroFactura: string
  tipoFactura: TipoFacturaFixture
  estado: EstadoCompraFixture
  /** Líneas de la compra. */
  items: number
  /** Unidades sumadas de todas las líneas. */
  unidades: number
  subtotal: number
  iva: number
  impuestosInternos: number
  percepciones: number
  total: number
}

function hace(dias: number): Date {
  const d = new Date()
  d.setHours(12, 0, 0, 0)
  d.setDate(d.getDate() - dias)
  return d
}

/** Redondeo a centavos, para que las sumas no arrastren 0,000000001. */
function centavos(n: number): number {
  return Math.round(n * 100) / 100
}

function compra(
  id: string,
  diasAtras: number,
  proveedor: string,
  tipoFactura: TipoFacturaFixture,
  numeroFactura: string,
  estado: EstadoCompraFixture,
  items: number,
  unidades: number,
  subtotal: number,
  extra: { impuestosInternos?: number; percepciones?: number } = {},
): CompraFixture {
  const esFC = tipoFactura === 'FC'
  const iva = esFC ? centavos(subtotal * 0.21) : 0
  const impuestosInternos = esFC ? (extra.impuestosInternos ?? 0) : 0
  const percepciones = esFC ? (extra.percepciones ?? 0) : 0

  return {
    id,
    fecha: hace(diasAtras),
    proveedor,
    numeroFactura,
    tipoFactura,
    estado,
    items,
    unidades,
    subtotal,
    iva,
    impuestosInternos,
    percepciones,
    total: centavos(subtotal + iva + impuestosInternos + percepciones),
  }
}

export const COMPRAS_FIXTURE: CompraFixture[] = [
  compra('c-1', 1, 'Molinos del Norte S.A.', 'FC', '0004-00018234', 'recibida', 6, 480, 1_850_000, {
    percepciones: 27_750,
  }),
  compra('c-2', 2, 'Aceitera Tucumán S.R.L.', 'FC', '0012-00007781', 'recibida', 3, 240, 2_160_000, {
    percepciones: 32_400,
  }),
  compra('c-3', 4, 'Bebidas del NOA S.A.', 'FC', '0007-00104562', 'parcial', 9, 1_320, 3_420_000, {
    impuestosInternos: 184_680,
    percepciones: 51_300,
  }),
  compra('c-4', 6, 'Distribuidora Cruz del Sur', 'ZZ', 'ZZ-0231', 'recibida', 12, 610, 985_500),
  compra('c-5', 7, 'Yerbatera Misionera S.A.', 'FC', '0003-00055190', 'pendiente', 2, 360, 1_296_000, {
    percepciones: 19_440,
  }),
  compra('c-6', 9, 'Fideos La Estancia S.A.', 'FC', '0009-00031207', 'recibida', 4, 720, 1_144_000, {
    percepciones: 17_160,
  }),
  compra('c-7', 12, 'Distribuidora Cruz del Sur', 'ZZ', 'ZZ-0228', 'cancelada', 5, 150, 412_800),
  compra('c-8', 15, 'Bebidas del NOA S.A.', 'FC', '0007-00103988', 'recibida', 7, 980, 2_760_000, {
    impuestosInternos: 149_040,
    percepciones: 41_400,
  }),
]

export type CampoSumable =
  | 'items'
  | 'unidades'
  | 'subtotal'
  | 'iva'
  | 'impuestosInternos'
  | 'percepciones'
  | 'total'

/**
 * Suma de una columna para el pie de la tabla: las canceladas no entran en el
 * total del período, pero quedan a la vista en su fila.
 */
export function sumarCompras(compras: CompraFixture[], campo: CampoSumable): number {
  return centavos(
    compras.filter((c) => c.estado !== 'cancelada').reduce((suma, c) => suma + c[campo], 0),
  )
}
