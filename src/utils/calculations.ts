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
 * Calcula el total con IVA e impuestos internos
 * Fórmula: neto + (neto * porcentajeIva / 100) + impuestosInternos
 *
 * @param neto - Monto neto (sin IVA)
 * @param porcentajeIva - Porcentaje de IVA (ej: 21, 10.5, 0)
 * @param impuestosInternos - Monto fijo de impuestos internos
 * @returns Total calculado
 */
export function calcularTotalConIva(
  neto: number | string,
  porcentajeIva: number | string = 21,
  impuestosInternos: number | string = 0
): number {
  const montoNeto = parseFloat(String(neto)) || 0;
  const iva = montoNeto * (parseFloat(String(porcentajeIva)) || 0) / 100;
  const internos = parseFloat(String(impuestosInternos)) || 0;
  return montoNeto + iva + internos;
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
 * Calcula el monto neto desde un total con IVA
 * Fórmula inversa: (total - impuestosInternos) / (1 + porcentajeIva/100)
 *
 * @param total - Monto total (con IVA e impuestos)
 * @param porcentajeIva - Porcentaje de IVA
 * @param impuestosInternos - Monto fijo de impuestos internos
 * @returns Monto neto
 */
export function calcularNetoDesdeTotal(
  total: number | string,
  porcentajeIva: number | string = 21,
  impuestosInternos: number | string = 0
): number {
  const montoTotal = parseFloat(String(total)) || 0;
  const internos = parseFloat(String(impuestosInternos)) || 0;
  const iva = parseFloat(String(porcentajeIva)) || 0;

  if (iva === 0) return montoTotal - internos;
  return (montoTotal - internos) / (1 + iva / 100);
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
  calcularSubtotalItem,
  calcularTotalPedido,
  calcularMargenPorcentaje,
  calcularGananciaBruta,
  calcularPrecioDesdeMargen,
  redondear,
  redondearAMultiplo
};
