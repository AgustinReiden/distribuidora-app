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
 *
 * impuestos_internos es un porcentaje sobre el neto, no un precio: no se
 * escala ni se redondea con el resto. Siempre devuelve null para que el
 * RPC (COALESCE) preserve el valor existente en la tabla.
 */
export function calcularNuevosPrecios(producto: PreciosBase, porcentajePct: number): PreciosNuevos {
  const factor = 1 + porcentajePct / 100
  const aplicar = (valor: number | null | undefined): number | null => {
    if (!valor) return null
    return Math.max(0, redondearAMultiploDe10(valor * factor))
  }
  return {
    precio_neto: aplicar(producto.precio_sin_iva),
    imp_internos: null,
    precio_final: aplicar(producto.precio),
  }
}

/**
 * El mensaje de un lote de `actualizar_precios_masivo` que volvió con errores.
 *
 * El RPC no es todo o nada: actualiza los productos que puede y devuelve un
 * error por cada uno que no. Desde #1438 el de otra sucursal cuenta como el que
 * no existe ("no encontrado en la sucursal activa"); pasa si la sucursal cambió
 * con el modal abierto. Se nombran los primeros `max` y se cuenta el resto, para
 * que un lote de cien no sea un aviso de cien renglones, y se dice cuántos sí se
 * actualizaron, que ya quedaron guardados.
 */
export function mensajeErrorPreciosMasivo(
  resultado: { actualizados?: number | null; errores?: (string | null)[] | null },
  max = 3
): string {
  const errores = (resultado.errores ?? []).filter((e): e is string => !!e)
  if (errores.length === 0) return 'Error actualizando precios'
  const resto = errores.length - max
  const lista = errores.slice(0, max).join('; ') + (resto > 0 ? ` y ${resto} más` : '')
  const actualizados = resultado.actualizados ?? 0
  if (actualizados > 0) {
    return `Se actualizaron ${actualizados} producto(s), pero ${errores.length} no: ${lista}`
  }
  return lista
}
