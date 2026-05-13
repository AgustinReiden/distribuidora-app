/**
 * Helpers para cálculo de precios.
 *
 * Usado por la actualización masiva: aplica un % de aumento (o rebaja)
 * sobre los campos de precio del producto y redondea a múltiplo de 10.
 *
 * Si el valor base es null o 0, devuelve null para que el RPC
 * `actualizar_precios_masivo` use COALESCE y mantenga el valor previo
 * en lugar de sobrescribir con 0.
 */

export function redondearAMultiploDe10(n: number): number {
  return Math.round(n / 10) * 10
}

export interface PreciosBase {
  precio_sin_iva?: number | null
  impuestos_internos?: number | null
  precio?: number | null
}

export interface PreciosNuevos {
  precio_neto: number | null
  imp_internos: number | null
  precio_final: number | null
}

/**
 * @param porcentajePct - 3 para +3%, -5 para -5%
 */
export function calcularNuevosPrecios(producto: PreciosBase, porcentajePct: number): PreciosNuevos {
  const factor = 1 + porcentajePct / 100
  const aplicar = (valor: number | null | undefined): number | null => {
    if (!valor) return null
    return Math.max(0, redondearAMultiploDe10(valor * factor))
  }
  return {
    precio_neto: aplicar(producto.precio_sin_iva),
    imp_internos: aplicar(producto.impuestos_internos),
    precio_final: aplicar(producto.precio),
  }
}
