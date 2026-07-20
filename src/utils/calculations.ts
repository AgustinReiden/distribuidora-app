/**
 * Utilidades de cálculos monetarios centralizadas
 *
 * Incluye funciones para calcular:
 * - Precios con IVA e impuestos
 * - Totales de pedidos
 * - Márgenes de ganancia
 */

// ============================================
// CÁLCULOS CON IVA E IMPUESTOS
// ============================================

/**
 * Calcula el total con IVA e impuestos internos (ambos como porcentaje)
 * Fórmula: neto + (neto * porcentajeIva / 100) + (neto * porcentajeImpInternos / 100)
 *
 * @param neto - Monto neto (sin IVA)
 * @param porcentajeIva - Porcentaje de IVA (ej: 21, 10.5, 0)
 * @param porcentajeImpInternos - Porcentaje de impuestos internos (ej: 5, 8)
 * @returns Total calculado
 */
export function calcularTotalConIva(
  neto: number | string,
  porcentajeIva: number | string = 21,
  porcentajeImpInternos: number | string = 0
): number {
  const montoNeto = parseFloat(String(neto)) || 0;
  const iva = montoNeto * (parseFloat(String(porcentajeIva)) || 0) / 100;
  const impInternos = montoNeto * (parseFloat(String(porcentajeImpInternos)) || 0) / 100;
  return montoNeto + iva + impInternos;
}

/**
 * Alias para calcular costo total con IVA
 */
export const calcularCostoTotal = calcularTotalConIva;

/**
 * Alias para calcular precio total con IVA
 */
export const calcularPrecioTotal = calcularTotalConIva;

/**
 * Calcula el monto neto desde un total con IVA e impuestos internos (ambos %)
 * Fórmula inversa: total / (1 + porcentajeIva/100 + porcentajeImpInternos/100)
 *
 * @param total - Monto total (con IVA e impuestos)
 * @param porcentajeIva - Porcentaje de IVA
 * @param porcentajeImpInternos - Porcentaje de impuestos internos
 * @returns Monto neto
 */
export function calcularNetoDesdeTotal(
  total: number | string,
  porcentajeIva: number | string = 21,
  porcentajeImpInternos: number | string = 0
): number {
  const montoTotal = parseFloat(String(total)) || 0;
  const iva = parseFloat(String(porcentajeIva)) || 0;
  const impInt = parseFloat(String(porcentajeImpInternos)) || 0;

  const divisor = 1 + iva / 100 + impInt / 100;
  if (divisor === 0) return montoTotal;
  return montoTotal / divisor;
}

/**
 * Calcula solo el monto de IVA
 *
 * @param neto - Monto neto
 * @param porcentajeIva - Porcentaje de IVA
 * @returns Monto de IVA
 */
export function calcularMontoIva(
  neto: number | string,
  porcentajeIva: number | string = 21
): number {
  const montoNeto = parseFloat(String(neto)) || 0;
  const iva = parseFloat(String(porcentajeIva)) || 0;
  return montoNeto * (iva / 100);
}

// ============================================
// CÁLCULOS POR TIPO DE FACTURA (ZZ/FC)
// ============================================

export interface DesgloseNetoVenta {
  /** Precio sin IVA, SIEMPRE (teórico en ZZ) */
  neto: number;
  /** IVA discriminado: solo FC (débito real); 0 en ZZ */
  iva: number;
  /** Siempre 0: la venta no discrimina imp. internos (mig 122) */
  impuestosInternos: number;
  /** Ingreso REAL: FC = neto (el IVA se remite) · ZZ = precio final */
  ingresoReal: number;
}

/**
 * Terna de ingresos por unidad de venta (espejo del SQL calcular_desglose_venta,
 * mig 123):
 *
 *   · neto        = precio / (1 + IVA%) — SIEMPRE, también en ZZ (teórico)
 *   · iva         = IVA discriminado, solo FC (débito real); 0 en ZZ
 *   · ingresoReal = neto si FC (el IVA se remite) · precio final si ZZ
 *
 * La venta NUNCA discrimina impuestos internos: la distribuidora no es agente
 * de II — el II existe solo en el COSTO de compra (calcularCostoReal). El
 * parámetro porcentajeImpInternos se conserva por compatibilidad pero se
 * ignora (mig 122).
 *
 * @param precioFinal - Precio final al consumidor (incluye IVA)
 * @param porcentajeIva - Porcentaje de IVA del producto (ej: 21, 10.5, 0)
 * @param _porcentajeImpInternos - IGNORADO (compat de firma)
 * @param tipoFactura - 'ZZ' o 'FC'
 */
export function calcularNetoVenta(
  precioFinal: number | string,
  porcentajeIva: number | string = 21,
  _porcentajeImpInternos: number | string = 0,
  tipoFactura: 'ZZ' | 'FC' = 'ZZ'
): DesgloseNetoVenta {
  const precio = parseFloat(String(precioFinal)) || 0;
  const neto = calcularNetoDesdeTotal(precio, porcentajeIva, 0);

  if (tipoFactura === 'ZZ') {
    return { neto, iva: 0, impuestosInternos: 0, ingresoReal: precio };
  }

  const iva = calcularMontoIva(neto, porcentajeIva);
  return { neto, iva, impuestosInternos: 0, ingresoReal: neto };
}

/**
 * Costo REAL por unidad (canónico, espejo de la función SQL costo_real_unitario).
 *
 * FC: neto post-bonif + impuestos internos (el IVA y las percepciones son
 *     créditos fiscales, NO costo).
 * ZZ: lo pagado tal cual (nada recuperable; el precio informal ya incluye todo,
 *     no se agrega II encima).
 *
 * @param costoNeto - Costo unitario post-bonificación (FC: neto de factura; ZZ: pagado)
 * @param porcentajeImpInternos - Tasa efectiva de imp. internos (ej: 8.6956, 4.1667)
 * @param tipoFactura - 'ZZ' o 'FC'
 */
export function calcularCostoReal(
  costoNeto: number | string,
  porcentajeImpInternos: number | string = 0,
  tipoFactura: 'ZZ' | 'FC' = 'FC'
): number {
  const costo = parseFloat(String(costoNeto)) || 0;
  if (tipoFactura === 'ZZ') return costo;
  const impInt = parseFloat(String(porcentajeImpInternos)) || 0;
  return redondear(costo * (1 + impInt / 100), 4);
}

/**
 * Costo FINANCIERO por unidad (desembolso, sin percepciones; espejo SQL de
 * costo_financiero_unitario). Alimenta productos.costo_con_iva.
 * NO usar para margen real: para eso está calcularCostoReal.
 *
 * FC: neto × (1 + IVA% + II%). ZZ: lo pagado.
 */
export function calcularCostoFinanciero(
  costoNeto: number | string,
  porcentajeIva: number | string = 21,
  porcentajeImpInternos: number | string = 0,
  tipoFactura: 'ZZ' | 'FC' = 'FC'
): number {
  const costo = parseFloat(String(costoNeto)) || 0;
  if (tipoFactura === 'ZZ') return costo;
  const iva = parseFloat(String(porcentajeIva)) || 0;
  const impInt = parseFloat(String(porcentajeImpInternos)) || 0;
  return redondear(costo * (1 + iva / 100 + impInt / 100), 4);
}

/**
 * Costo PROMEDIO PONDERADO tras una compra (espejo de la fórmula SQL en
 * registrar_compra_completa, mig 128). Base de valuación de stock y CMV;
 * el costo de reposición (calcularCostoReal) sigue siendo la base de pricing.
 *
 * Guardas (mig 128): stock anterior ≤ 0 o CPP nulo/≤ 0 ⇒ el promedio se
 * resetea al costo real de la compra.
 *
 * @param stockAnterior - Stock antes de ingresar la compra
 * @param costoPromedioActual - CPP vigente del producto (null si nunca se calculó)
 * @param cantidad - Unidades que ingresan
 * @param costoRealNuevo - Costo real unitario de la compra (calcularCostoReal)
 */
export function calcularCostoPromedioPonderado(
  stockAnterior: number,
  costoPromedioActual: number | null | undefined,
  cantidad: number,
  costoRealNuevo: number
): number {
  const stock = Number(stockAnterior) || 0;
  const cant = Number(cantidad) || 0;
  const costoNuevo = Number(costoRealNuevo) || 0;
  const cppActual = Number(costoPromedioActual) || 0;
  if (cant <= 0) return redondear(cppActual > 0 ? cppActual : costoNuevo, 4);
  if (stock <= 0 || cppActual <= 0) return redondear(costoNuevo, 4);
  return redondear((stock * cppActual + cant * costoNuevo) / (stock + cant), 4);
}

// ============================================
// CÁLCULOS DE COMPRAS (desglose fiscal completo)
// ============================================

export interface CompraItemCalculo {
  cantidad: number;
  costoUnitario: number;
  bonificacion?: number;
  porcentajeIva?: number;
  /** Tasa efectiva de imp. internos (%) */
  impuestosInternos?: number;
}

export interface CompraExtras {
  percepcionIva?: number;
  percepcionIibb?: number;
  noGravado?: number;
  otrosImpuestos?: number;
}

export interface TotalesCompra {
  subtotalBruto: number;
  bonificacionTotal: number;
  /** Neto gravado (bruto − bonif) */
  subtotal: number;
  iva: number;
  impuestosInternos: number;
  percepcionIva: number;
  percepcionIibb: number;
  noGravado: number;
  otrosImpuestos: number;
  total: number;
}

/**
 * Totales de una compra según tipo de comprobante (fuente única del modal de
 * compras; estructura = factura A real: total = gravado + IVA + II +
 * percepciones + no gravado + otros).
 *
 * ZZ (sin factura): lo pagado es todo — sin IVA, sin II, sin percepciones ni
 * no gravado. total = subtotal.
 */
export function calcularTotalesCompra(
  items: CompraItemCalculo[],
  tipoFactura: 'ZZ' | 'FC' = 'FC',
  extras: CompraExtras = {}
): TotalesCompra {
  let subtotalBruto = 0;
  let bonificacionTotal = 0;
  let iva = 0;
  let impuestosInternos = 0;

  for (const item of items) {
    const bruto = (item.cantidad || 0) * (item.costoUnitario || 0);
    const bonif = bruto * (item.bonificacion || 0) / 100;
    const neto = bruto - bonif;
    subtotalBruto += bruto;
    bonificacionTotal += bonif;
    if (tipoFactura === 'FC') {
      iva += neto * ((item.porcentajeIva ?? 21) / 100);
      impuestosInternos += neto * ((item.impuestosInternos || 0) / 100);
    }
  }

  const subtotal = subtotalBruto - bonificacionTotal;
  const esFC = tipoFactura === 'FC';
  const percepcionIva = esFC ? (extras.percepcionIva || 0) : 0;
  const percepcionIibb = esFC ? (extras.percepcionIibb || 0) : 0;
  const noGravado = esFC ? (extras.noGravado || 0) : 0;
  const otrosImpuestos = esFC ? (extras.otrosImpuestos || 0) : 0;
  const total = subtotal + iva + impuestosInternos + percepcionIva + percepcionIibb + noGravado + otrosImpuestos;

  return {
    subtotalBruto, bonificacionTotal, subtotal, iva, impuestosInternos,
    percepcionIva, percepcionIibb, noGravado, otrosImpuestos, total,
  };
}

// ============================================
// CÁLCULOS DE PEDIDOS
// ============================================

interface ItemPedido {
  precio: number;
  cantidad: number;
  descuento?: number;
}

/**
 * Calcula el subtotal de un item de pedido
 *
 * @param precio - Precio unitario
 * @param cantidad - Cantidad
 * @param descuento - Descuento en porcentaje (opcional)
 * @returns Subtotal del item
 */
export function calcularSubtotalItem(
  precio: number | string,
  cantidad: number | string,
  descuento: number | string = 0
): number {
  const p = parseFloat(String(precio)) || 0;
  const c = parseFloat(String(cantidad)) || 0;
  const d = parseFloat(String(descuento)) || 0;

  const subtotal = p * c;
  if (d > 0) {
    return subtotal * (1 - d / 100);
  }
  return subtotal;
}

/**
 * Calcula el total de un pedido a partir de sus items
 *
 * @param items - Array de items del pedido
 * @returns Total del pedido
 */
export function calcularTotalPedido(items: ItemPedido[]): number {
  return items.reduce((total, item) => {
    return total + calcularSubtotalItem(item.precio, item.cantidad, item.descuento);
  }, 0);
}

// ============================================
// CÁLCULOS DE MÁRGENES
// ============================================

/**
 * Calcula el margen de ganancia en porcentaje
 * Fórmula: ((precioVenta - costo) / costo) * 100
 *
 * @param precioVenta - Precio de venta
 * @param costo - Costo del producto
 * @returns Porcentaje de margen
 */
export function calcularMargenPorcentaje(
  precioVenta: number | string,
  costo: number | string
): number {
  const pv = parseFloat(String(precioVenta)) || 0;
  const c = parseFloat(String(costo)) || 0;

  if (c === 0) return 0;
  return ((pv - c) / c) * 100;
}

/**
 * Calcula la ganancia bruta
 *
 * @param precioVenta - Precio de venta
 * @param costo - Costo del producto
 * @returns Ganancia bruta
 */
export function calcularGananciaBruta(
  precioVenta: number | string,
  costo: number | string
): number {
  const pv = parseFloat(String(precioVenta)) || 0;
  const c = parseFloat(String(costo)) || 0;
  return pv - c;
}

/**
 * Calcula el precio de venta a partir del costo y un margen deseado
 *
 * @param costo - Costo del producto
 * @param margenDeseado - Margen de ganancia deseado en porcentaje
 * @returns Precio de venta sugerido
 */
export function calcularPrecioDesdeMargen(
  costo: number | string,
  margenDeseado: number | string
): number {
  const c = parseFloat(String(costo)) || 0;
  const m = parseFloat(String(margenDeseado)) || 0;
  return c * (1 + m / 100);
}

// ============================================
// UTILIDADES DE REDONDEO
// ============================================

/**
 * Parsea un string (con coma o punto decimal) y devuelve un número redondeado a 2 decimales.
 * Devuelve 0 si el input no es parseable. Usa esta función en TODOS los inputs monetarios.
 *
 * Convenciones:
 * - Si hay coma: la coma es decimal y los puntos son separadores de miles (es-AR).
 *   Ej: "1.234,56" → 1234.56.
 * - Si NO hay coma: el punto se trata como decimal (es-US/int).
 *   Ej: "10.456" → 10.46. "1.234" → 1.23 (NO 1234). Si un usuario es-AR teclea
 *   miles sin coma, se interpretará como decimal.
 */
export function parsePrecio(input: string | number | null | undefined): number {
  if (input === null || input === undefined) return 0
  const str = typeof input === 'number' ? String(input) : input.trim()
  // Normalizar separador: si hay coma, tratamos los puntos como separador de miles
  // ("1.234,56" → "1234.56"). Si no hay coma, el punto es el separador decimal
  // ("10.456" → "10.456").
  const normalized = str.includes(',')
    ? str.replace(/\./g, '').replace(',', '.')
    : str
  const parsed = parseFloat(normalized)
  if (!Number.isFinite(parsed)) return 0
  return redondear(parsed, 2)
}

/**
 * Redondea un número a la cantidad de decimales especificada
 *
 * @param valor - Número a redondear
 * @param decimales - Cantidad de decimales (default: 2)
 * @returns Número redondeado
 */
export function redondear(valor: number, decimales: number = 2): number {
  const factor = Math.pow(10, decimales);
  return Math.round(valor * factor) / factor;
}

/**
 * Redondea al múltiplo más cercano (ej: redondear a 0.50, 1, 5, 10)
 *
 * @param valor - Número a redondear
 * @param multiplo - Múltiplo al que redondear
 * @returns Número redondeado al múltiplo
 */
export function redondearAMultiplo(valor: number, multiplo: number = 1): number {
  return Math.round(valor / multiplo) * multiplo;
}

// ============================================
// EXPORT DEFAULT
// ============================================

export default {
  calcularTotalConIva,
  calcularCostoTotal,
  calcularPrecioTotal,
  calcularNetoDesdeTotal,
  calcularMontoIva,
  calcularNetoVenta,
  calcularCostoReal,
  calcularCostoFinanciero,
  calcularTotalesCompra,
  calcularSubtotalItem,
  calcularTotalPedido,
  calcularMargenPorcentaje,
  calcularGananciaBruta,
  calcularPrecioDesdeMargen,
  parsePrecio,
  redondear,
  redondearAMultiplo
};
