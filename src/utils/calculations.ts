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
  neto: number;
  iva: number;
  impuestosInternos: number;
}

/**
 * Calcula el ingreso neto de una venta según tipo de factura
 *
 * ZZ (sin factura): todo el precio final es ingreso neto
 * FC (con factura): el neto es el precio sin IVA ni impuestos, el IVA se remite a AFIP
 *
 * @param precioFinal - Precio final al consumidor (incluye IVA + imp internos)
 * @param porcentajeIva - Porcentaje de IVA del producto (ej: 21, 10.5, 0)
 * @param porcentajeImpInternos - Porcentaje de impuestos internos (ej: 5, 8)
 * @param tipoFactura - 'ZZ' o 'FC'
 * @returns Desglose con neto, iva e impuestos internos
 */
export function calcularNetoVenta(
  precioFinal: number | string,
  porcentajeIva: number | string = 21,
  porcentajeImpInternos: number | string = 0,
  tipoFactura: 'ZZ' | 'FC' = 'ZZ'
): DesgloseNetoVenta {
  const precio = parseFloat(String(precioFinal)) || 0;

  if (tipoFactura === 'ZZ') {
    return { neto: precio, iva: 0, impuestosInternos: 0 };
  }

  // FC: back-calculate neto from final price
  const neto = calcularNetoDesdeTotal(precio, porcentajeIva, porcentajeImpInternos);
  const iva = calcularMontoIva(neto, porcentajeIva);
  const impInt = neto * (parseFloat(String(porcentajeImpInternos)) || 0) / 100;

  return { neto, iva, impuestosInternos: impInt };
}

/**
 * Calcula el costo neto de una compra según tipo de factura
 *
 * FC (con factura): costo neto = costo sin IVA (IVA es crédito fiscal)
 * ZZ (sin factura): costo neto = costo total (no hay IVA que descontar)
 *
 * @param costoSinIva - Costo neto sin IVA del producto
 * @param porcentajeIva - Porcentaje de IVA
 * @param tipoFactura - 'ZZ' o 'FC'
 * @returns Costo neto real
 */
export function calcularNetoCosto(
  costoSinIva: number | string,
  porcentajeIva: number | string = 21,
  tipoFactura: 'ZZ' | 'FC' = 'FC'
): number {
  const costo = parseFloat(String(costoSinIva)) || 0;
  const iva = parseFloat(String(porcentajeIva)) || 0;

  if (tipoFactura === 'FC') {
    return costo; // IVA es crédito fiscal, no es costo
  }
  // ZZ: IVA no existe, el costo total es el neto
  return costo * (1 + iva / 100);
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
 */
export function parsePrecio(input: string | number | null | undefined): number {
  if (input === null || input === undefined) return 0
  const str = typeof input === 'number' ? String(input) : input
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
  calcularNetoCosto,
  calcularSubtotalItem,
  calcularTotalPedido,
  calcularMargenPorcentaje,
  calcularGananciaBruta,
  calcularPrecioDesdeMargen,
  parsePrecio,
  redondear,
  redondearAMultiplo
};
