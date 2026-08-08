/**
 * Márgenes de un precio mayorista, con las mismas dos definiciones que usan
 * los inputs de margen de la ficha (mig 123), para que los números sean
 * comparables entre el precio de lista y cada escala:
 *   · bruto = precio final vs costo total con IVA
 *   · neto  = precio neto (sin IVA) vs costo real (neto + II)
 *
 * Vive aparte del componente para poder testearlo sin renderizar la ficha.
 */
import { calcularMargenPorcentaje, calcularNetoDesdeTotal } from '../../utils/calculations'

export interface MargenesEscala {
  /** % sobre el costo total con IVA. `null` si falta el costo o el precio. */
  bruto: number | null
  /** % sobre el costo real (neto + II). `null` si falta alguno. */
  neto: number | null
}

export function margenesEscala(
  precioFinal: number,
  costoTotal: number,
  costoReal: number,
  porcentajeIva: number,
): MargenesEscala {
  const precioNeto = calcularNetoDesdeTotal(precioFinal, porcentajeIva, 0)
  return {
    bruto: costoTotal > 0 && precioFinal > 0 ? calcularMargenPorcentaje(precioFinal, costoTotal) : null,
    neto: costoReal > 0 && precioNeto > 0 ? calcularMargenPorcentaje(precioNeto, costoReal) : null,
  }
}

/**
 * Cuánto baja el precio mayorista respecto del de lista, en %.
 *
 * Positivo = por debajo de lista (lo normal). Negativo = por encima, que casi
 * siempre significa que la lista subió y la condición quedó sin actualizar.
 * `null` si no hay con qué compararlo.
 */
export function descuentoSobreLista(precio: number, precioLista: number): number | null {
  if (!(precioLista > 0) || !(precio > 0)) return null
  return (1 - precio / precioLista) * 100
}
