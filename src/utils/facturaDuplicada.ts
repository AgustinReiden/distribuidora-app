/**
 * ¿Esta factura ya está cargada? El aviso del cabezal de la compra.
 *
 * No hay UNIQUE sobre `compras.numero_factura` ni chequeo en la RPC, y no tiene
 * que haberlo: una factura partida entre dos sucursales es legal, y en prod hay
 * números basura ("0000", "00006") que chocarían entre sí. Por eso esto es un
 * AVISO al completar el cabezal y nunca un bloqueo al guardar.
 *
 * Lo que sí tiene que hacer bien es comparar números escritos de formas
 * distintas: "A0005-00467758", "0005-467758" y "5 467758" son la misma factura.
 */
import { sinAcentos } from './duplicadoCliente'
import { normalizarTexto } from './matchProducto'

/** El número de comprobante desarmado en sus tramos significativos. */
export interface NumeroFacturaNormalizado {
  /** Punto de venta sin ceros a la izquierda. null = el número no lo trae. */
  puntoVenta: string | null;
  /** Número del comprobante sin ceros a la izquierda. */
  numero: string;
  /** Dígitos significativos de los dos tramos juntos. */
  digitos: number;
}

/**
 * Por debajo de esto el número no identifica nada: "0000", "00006" o "12"
 * están repetidos en prod entre proveedores y facturas que no tienen nada que
 * ver, y avisar sobre ellos es ruido que enseña a ignorar el aviso.
 */
export const DIGITOS_MINIMOS_FACTURA = 4

/**
 * Largo del número de comprobante de AFIP. Sirve para partir un número pegado
 * sin guión ("000500467758"): los últimos 8 son el número y lo de adelante, el
 * punto de venta.
 */
const LARGO_NUMERO_AFIP = 8

const sinCerosIzq = (tramo: string): string => tramo.replace(/^0+/, '')

/**
 * Desarma un número de factura tal como lo tipeó alguien.
 *
 * La letra del tipo ("A", "B", "FC") se cae sola: sólo se miran los tramos de
 * dígitos. Con dos o más tramos el último es el número y el resto el punto de
 * venta; con uno solo y 12 dígitos o más se parte al estilo AFIP; con uno corto
 * no hay punto de venta.
 *
 * Devuelve null si no hay ningún dígito.
 */
export function normalizarNumeroFactura(texto: string | null | undefined): NumeroFacturaNormalizado | null {
  const tramos = (texto ?? '').match(/\d+/g)
  if (!tramos || tramos.length === 0) return null

  let puntoVenta: string | null
  let numero: string
  if (tramos.length >= 2) {
    numero = sinCerosIzq(tramos[tramos.length - 1])
    puntoVenta = sinCerosIzq(tramos.slice(0, -1).join(''))
  } else if (tramos[0].length >= LARGO_NUMERO_AFIP + 4) {
    numero = sinCerosIzq(tramos[0].slice(-LARGO_NUMERO_AFIP))
    puntoVenta = sinCerosIzq(tramos[0].slice(0, -LARGO_NUMERO_AFIP))
  } else {
    numero = sinCerosIzq(tramos[0])
    puntoVenta = null
  }
  return { puntoVenta, numero, digitos: (puntoVenta ?? '').length + numero.length }
}

/** ¿El número alcanza para buscar duplicados? */
export function numeroFacturaChequeable(n: NumeroFacturaNormalizado | null): n is NumeroFacturaNormalizado {
  return n !== null && n.numero !== '' && n.digitos >= DIGITOS_MINIMOS_FACTURA
}

/**
 * ¿Son el mismo comprobante?
 *
 * El número tiene que coincidir siempre. El punto de venta, sólo si los dos lo
 * traen: "467758" contra "0005-00467758" se avisa, porque es un aviso y no un
 * bloqueo, y quien cargó sin punto de venta probablemente se lo comió.
 */
export function mismoNumeroFactura(a: NumeroFacturaNormalizado, b: NumeroFacturaNormalizado): boolean {
  if (a.numero !== b.numero) return false
  if (a.puntoVenta === null || b.puntoVenta === null) return true
  return a.puntoVenta === b.puntoVenta
}

/** Nombre de proveedor para comparar: sin tildes, minúsculas, espacios colapsados. */
export function normalizarNombreProveedor(nombre: string | null | undefined): string {
  return sinAcentos(normalizarTexto(nombre))
}

/** Una compra candidata tal como vuelve de la query. */
export interface FilaCompraFactura {
  id: string | number;
  numero_factura: string | null;
  fecha_compra: string | null;
  total?: number | string | null;
  estado?: string | null;
  proveedor_id?: string | number | null;
  proveedor_nombre?: string | null;
  proveedor?: { nombre?: string | null } | null;
}

/** Lo que identifica a la factura que se está cargando. */
export interface CriterioFacturaDuplicada {
  /** '' o null = proveedor sin id (nuevo, o del escaneo). */
  proveedorId: string | null;
  proveedorNombre: string;
  numeroFactura: string;
}

/**
 * Las compras de `filas` que son la misma factura que `criterio`.
 *
 * Mismo proveedor por id cuando lo hay; sin id, por nombre normalizado contra
 * el nombre suelto de la compra o el del proveedor vinculado. Las canceladas no
 * cuentan: anular y volver a cargar es justamente la forma de corregir una
 * factura mal cargada.
 *
 * La query ya filtra por sucursal (y la RLS también), así que acá no se mira.
 */
export function comprasMismaFactura<T extends FilaCompraFactura>(
  filas: T[],
  criterio: CriterioFacturaDuplicada,
): T[] {
  const buscado = normalizarNumeroFactura(criterio.numeroFactura)
  if (!numeroFacturaChequeable(buscado)) return []
  const proveedorId = criterio.proveedorId ? String(criterio.proveedorId) : ''
  const nombre = normalizarNombreProveedor(criterio.proveedorNombre)
  if (!proveedorId && !nombre) return []

  return filas.filter(fila => {
    if (fila.estado === 'cancelada') return false
    if (proveedorId) {
      if (String(fila.proveedor_id ?? '') !== proveedorId) return false
    } else {
      const nombreFila = normalizarNombreProveedor(fila.proveedor_nombre || fila.proveedor?.nombre)
      if (nombreFila !== nombre) return false
    }
    const numeroFila = normalizarNumeroFactura(fila.numero_factura)
    return numeroFacturaChequeable(numeroFila) && mismoNumeroFactura(buscado, numeroFila)
  })
}

/**
 * 'YYYY-MM-DD' → 'dd/mm', con el año sólo si no es el de `hoyISO`.
 *
 * Se arma del texto y no con `Date`: una fecha sin hora parseada por `Date` es
 * medianoche UTC, que en Argentina es el día anterior.
 */
export function fechaCortaCompra(fechaISO: string | null | undefined, hoyISO: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(fechaISO ?? '')
  if (!m) return ''
  const [, anio, mes, dia] = m
  return anio === hoyISO.slice(0, 4) ? `${dia}/${mes}` : `${dia}/${mes}/${anio}`
}
