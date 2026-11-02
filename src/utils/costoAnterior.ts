/**
 * Variación del costo de una línea contra la compra anterior del mismo producto.
 *
 * La query (useCostosAnterioresQuery) trae candidatas de más —todas las líneas
 * de esos productos hasta la fecha de referencia— y la ELECCIÓN vive acá, pura,
 * porque es donde están las reglas que se pueden equivocar en silencio:
 *
 *  - la anterior es de la MISMA sucursal (lo filtran la query y la RLS);
 *  - no está cancelada: una compra anulada no fue un costo;
 *  - tiene `costo_real_unitario`: las líneas viejas sin snapshot no comparan;
 *  - fija costo: un regalo suma stock pero no es un costo, igual que para
 *    `_reposicion_desde_ultima_compra`;
 *  - es ESTRICTAMENTE anterior por (fecha_compra, created_at, id), el orden de
 *    esa misma función (#1333). Para una compra que todavía no existe (modo
 *    'nueva') todo lo de su fecha o antes cuenta;
 *  - no es la misma compra, ni otra carga de la MISMA factura (número
 *    normalizado, utils/facturaDuplicada): una factura partida entre sucursales
 *    o cargada dos veces no es "la compra anterior", es ésta.
 *
 * El costo que se compara es el final (`costo_real_unitario`), en la base que
 * guarda la mig 194/196: en FC, neto bonificado + impuesto interno + cargos al
 * costo, sin IVA; en ZZ, lo pagado (que ya trae IVA e II) + cargos. Una
 * anterior en el otro tipo de comprobante se compara igual —es lo que le costó
 * a la empresa— y el tooltip lo dice.
 */
import { lineaFijaCosto } from './desgloseCostoCompra'
import { fechaCortaCompra, mismoNumeroFactura, normalizarNumeroFactura, numeroFacturaChequeable } from './facturaDuplicada'
import { etiquetaComprobante, normalizarLetra, type LetraComprobante } from './letraComprobante'

/** Una línea candidata tal como vuelve de la query. */
export interface FilaCostoAnterior {
  producto_id: string | number
  compra_id: string | number
  costo_real_unitario: number | string | null
  /** Neto de lista y bonificación de la línea: para la precarga (utils/precargaCostoCompra). */
  costo_unitario?: number | string | null
  bonificacion?: number | string | null
  compra: {
    id: string | number
    fecha_compra: string | null
    /** Hora del alta. Un clon de `cambiar_proveedor_compra` conserva la del original. */
    created_at?: string | null
    numero_factura: string | null
    tipo_factura: string | null
    /** mig 293. Ausente en un select viejo: FC sin letra = A. */
    letra_comprobante?: string | null
    estado: string | null
  } | null
}

/** Contra qué compra se busca la anterior. */
export interface ReferenciaCostoAnterior {
  /** null = la compra se está cargando y todavía no tiene id. */
  compraId: string | null
  /** `compras.created_at` de esa compra. Sin ella desempata el id. */
  createdAt?: string | null
  /** 'YYYY-MM-DD'. */
  fechaCompra: string
  numeroFactura: string | null
}

export interface CostoAnterior {
  compraId: string
  fechaCompra: string
  /** Hora del alta: desempata las compras de una misma fecha. */
  createdAt?: string | null
  costoRealUnitario: number
  tipoFactura: 'ZZ' | 'FC'
  /** mig 293. null en ZZ. */
  letraComprobante?: LetraComprobante | null
  /** Neto de lista de esa línea, antes de bonificar. Ausente en un select viejo. */
  costoUnitario?: number | null
  /** Bonificación (%) de esa línea. */
  bonificacion?: number | null
}

/**
 * Dos compras de la misma fecha, por (created_at, id): negativo si `a` va antes.
 * La hora se compara como instante y no como texto, y un select sin ella cae al
 * id. Date.parse corta en milisegundos: dos compras en el mismo milisegundo
 * también caen al id, que es lo que hace la base con la misma hora.
 */
function compararMismoDia(
  a: { createdAt?: string | null; id: number },
  b: { createdAt?: string | null; id: number },
): number {
  const horaA = Date.parse(a.createdAt ?? '')
  const horaB = Date.parse(b.createdAt ?? '')
  if (Number.isNaN(horaA) || Number.isNaN(horaB) || horaA === horaB) return a.id - b.id
  return horaA - horaB
}

/** ¿La fila es estrictamente anterior a la referencia, por (fecha, alta, id)? */
function esAnterior(fecha: string, createdAt: string | null | undefined, id: number, ref: ReferenciaCostoAnterior): boolean {
  if (fecha < ref.fechaCompra) return true
  if (fecha > ref.fechaCompra) return false
  // Misma fecha. Sin id (compra nueva) todo lo de ese día es anterior.
  if (ref.compraId === null) return true
  return compararMismoDia({ createdAt, id }, { createdAt: ref.createdAt, id: Number(ref.compraId) }) < 0
}

/** ¿(fecha, alta, id) de a es posterior al de b? Para quedarse con la más reciente. */
const masReciente = (a: CostoAnterior, b: CostoAnterior): boolean =>
  a.fechaCompra > b.fechaCompra ||
  (a.fechaCompra === b.fechaCompra &&
    compararMismoDia(
      { createdAt: a.createdAt, id: Number(a.compraId) },
      { createdAt: b.createdAt, id: Number(b.compraId) },
    ) > 0)

/** producto_id → la compra anterior que cumple las reglas. Sin entrada = no hay. */
export function elegirCostosAnteriores(
  filas: FilaCostoAnterior[],
  ref: ReferenciaCostoAnterior,
): Map<string, CostoAnterior> {
  const facturaRef = normalizarNumeroFactura(ref.numeroFactura)
  const chequearFactura = numeroFacturaChequeable(facturaRef)
  const salida = new Map<string, CostoAnterior>()

  for (const fila of filas) {
    const compra = fila.compra
    if (!compra || !compra.fecha_compra) continue
    if (compra.estado === 'cancelada') continue
    if (fila.costo_real_unitario === null || fila.costo_real_unitario === undefined) continue
    const costo = Number(fila.costo_real_unitario)
    if (!Number.isFinite(costo)) continue
    // Un select sin el neto de lista no dice si fue un regalo: la línea compara.
    if (fila.costo_unitario !== undefined && !lineaFijaCosto(fila)) continue
    const compraId = String(compra.id ?? fila.compra_id)
    if (ref.compraId !== null && compraId === String(ref.compraId)) continue
    const fecha = compra.fecha_compra.slice(0, 10)
    if (!esAnterior(fecha, compra.created_at, Number(compraId), ref)) continue
    if (chequearFactura) {
      const facturaFila = normalizarNumeroFactura(compra.numero_factura)
      if (numeroFacturaChequeable(facturaFila) && mismoNumeroFactura(facturaRef, facturaFila)) continue
    }

    const candidata: CostoAnterior = {
      compraId,
      fechaCompra: fecha,
      createdAt: compra.created_at,
      costoRealUnitario: costo,
      tipoFactura: compra.tipo_factura === 'ZZ' ? 'ZZ' : 'FC',
      letraComprobante: compra.tipo_factura === 'ZZ' ? null : normalizarLetra(compra.letra_comprobante),
      costoUnitario: fila.costo_unitario === null || fila.costo_unitario === undefined ? null : Number(fila.costo_unitario),
      bonificacion: fila.bonificacion === null || fila.bonificacion === undefined ? null : Number(fila.bonificacion),
    }
    const clave = String(fila.producto_id)
    const actual = salida.get(clave)
    if (!actual || masReciente(candidata, actual)) salida.set(clave, candidata)
  }
  return salida
}

/**
 * (actual − anterior) / anterior. null si no hay contra qué comparar. Un costo
 * actual en 0 (línea 100% bonificada, neto 0: regalo) tampoco compara: no es una
 * baja del 100%, es una línea que no pagó nada.
 */
export function variacionCosto(actual: number | null | undefined, anterior: number | null | undefined): number | null {
  if (actual === null || actual === undefined || anterior === null || anterior === undefined) return null
  if (!Number.isFinite(actual) || !Number.isFinite(anterior) || anterior <= 0 || actual <= 0) return null
  return (actual - anterior) / anterior
}

export type TonoVariacion = 'sube' | 'baja' | 'igual'

/**
 * "+12,3%" / "−4,1%" con un decimal y coma. El signo menos es el tipográfico
 * (U+2212), no el guion. Lo que redondea a 0,0% se muestra sin signo y sin
 * color: pintar de rojo un +0,04% sería alarmar por un redondeo.
 */
export function formatearVariacion(variacion: number): { texto: string; tono: TonoVariacion } {
  const pct = Math.round(variacion * 1000) / 10
  if (pct === 0) return { texto: '0,0%', tono: 'igual' }
  const cuerpo = Math.abs(pct).toFixed(1).replace('.', ',')
  return pct > 0
    ? { texto: `+${cuerpo}%`, tono: 'sube' }
    : { texto: `−${cuerpo}%`, tono: 'baja' }
}

/**
 * "compra anterior #N del dd/mm", más " (en ZZ)", " (en FC A)" o " (en FC B)" si
 * el comprobante es otro. La letra cuenta (mig 293): una B tiene el IVA adentro
 * del costo, como una ZZ, así que comparar contra una A sin decirlo engaña igual.
 */
export function tooltipCostoAnterior(
  anterior: CostoAnterior,
  tipoFacturaActual: 'ZZ' | 'FC',
  hoyISO: string,
  letraActual: LetraComprobante | null = null,
): string {
  const etiquetaAnterior = etiquetaComprobante(anterior.tipoFactura, anterior.letraComprobante)
  const tipo = etiquetaAnterior !== etiquetaComprobante(tipoFacturaActual, letraActual) ? ` (en ${etiquetaAnterior})` : ''
  return `compra anterior #${anterior.compraId} del ${fechaCortaCompra(anterior.fechaCompra, hoyISO)}${tipo}`
}
