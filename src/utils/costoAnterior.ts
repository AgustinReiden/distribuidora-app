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
 *  - es ESTRICTAMENTE anterior por (fecha_compra, id). Para una compra que
 *    todavía no existe (modo 'nueva') el id es "infinito": cualquier compra de
 *    la misma fecha o antes cuenta;
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
import { fechaCortaCompra, mismoNumeroFactura, normalizarNumeroFactura, numeroFacturaChequeable } from './facturaDuplicada'
import { etiquetaComprobante, normalizarLetra, type LetraComprobante } from './letraComprobante'

/** Una línea candidata tal como vuelve de la query. */
export interface FilaCostoAnterior {
  producto_id: string | number
  compra_id: string | number
  costo_real_unitario: number | string | null
  compra: {
    id: string | number
    fecha_compra: string | null
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
  /** 'YYYY-MM-DD'. */
  fechaCompra: string
  numeroFactura: string | null
}

export interface CostoAnterior {
  compraId: string
  fechaCompra: string
  costoRealUnitario: number
  tipoFactura: 'ZZ' | 'FC'
  /** mig 293. null en ZZ. */
  letraComprobante?: LetraComprobante | null
}

/** ¿La fila es estrictamente anterior a la referencia, por (fecha, id)? */
function esAnterior(fecha: string, id: number, ref: ReferenciaCostoAnterior): boolean {
  if (fecha < ref.fechaCompra) return true
  if (fecha > ref.fechaCompra) return false
  // Misma fecha: desempata el id. Sin id (compra nueva) todo lo de ese día es anterior.
  return ref.compraId === null ? true : id < Number(ref.compraId)
}

/** ¿(fecha, id) de a es posterior al de b? Para quedarse con la más reciente. */
const masReciente = (a: CostoAnterior, b: CostoAnterior): boolean =>
  a.fechaCompra > b.fechaCompra ||
  (a.fechaCompra === b.fechaCompra && Number(a.compraId) > Number(b.compraId))

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
    const compraId = String(compra.id ?? fila.compra_id)
    if (ref.compraId !== null && compraId === String(ref.compraId)) continue
    const fecha = compra.fecha_compra.slice(0, 10)
    if (!esAnterior(fecha, Number(compraId), ref)) continue
    if (chequearFactura) {
      const facturaFila = normalizarNumeroFactura(compra.numero_factura)
      if (numeroFacturaChequeable(facturaFila) && mismoNumeroFactura(facturaRef, facturaFila)) continue
    }

    const candidata: CostoAnterior = {
      compraId,
      fechaCompra: fecha,
      costoRealUnitario: costo,
      tipoFactura: compra.tipo_factura === 'ZZ' ? 'ZZ' : 'FC',
      letraComprobante: compra.tipo_factura === 'ZZ' ? null : normalizarLetra(compra.letra_comprobante),
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
