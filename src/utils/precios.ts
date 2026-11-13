/**
 * Helpers para cálculo de precios.
 *
 * Usado por la actualización masiva: aplica un % de aumento (o rebaja)
 * sobre el precio final del producto y lo redondea a un múltiplo
 * (`redondearPrecio`). El neto sale del final, como en la ficha.
 *
 * Si el valor base es null o 0, devuelve null para que el RPC
 * `actualizar_precios_masivo` use COALESCE y mantenga el valor previo
 * en lugar de sobrescribir con 0.
 */
import { alicuotaIvaVenta } from './alicuotaIvaVenta'
import type { CondicionIva } from './calculations'

/**
 * El múltiplo al que se redondea un precio en masa por defecto. Desde #1561
 * (CAT-8, decisión del dueño) es de la política comercial de cada sucursal
 * (`politicas_comerciales.multiplo_redondeo_precio`); esto es su default.
 */
export const MULTIPLO_REDONDEO_PRECIO = 10
/** El rango del múltiplo: el mismo del CHECK de la columna y de su RPC. */
export const MULTIPLO_REDONDEO_MINIMO = 0.01
export const MULTIPLO_REDONDEO_MAXIMO = 10000

/**
 * Por qué un múltiplo tipeado no vale, o null si vale. Espejo de
 * `actualizar_multiplo_redondeo_precio`: de 0,01 a 10.000, con hasta dos decimales.
 */
export function errorDeMultiploRedondeo(valor: number): string | null {
  if (!Number.isFinite(valor) || valor < MULTIPLO_REDONDEO_MINIMO || valor > MULTIPLO_REDONDEO_MAXIMO
      || Math.abs(valor * 100 - Math.round(valor * 100)) > 1e-9) {
    return 'El múltiplo va de 0,01 a 10.000, con hasta dos decimales'
  }
  return null
}

const aCentavos = (n: number): number => Math.round(n * 100) / 100

/**
 * El precio nuevo redondeado al múltiplo, salvo que el redondeo lo desvirtúe
 * (#1561, CAT-8): en ese caso queda al centavo. El redondeo se descarta si
 *   · da $0 o menos ($4 + 5 % daba $0);
 *   · mueve el precio tanto o más que el cambio pedido: $45 + 3 % daba $50
 *     (+11 %), y $7 − 10 % daba $10, una suba.
 * Con un precio que el múltiplo representa bien no cambia nada: $121 + 10 %
 * sigue dando $130.
 */
export function redondearPrecio(original: number, nuevo: number, multiplo = MULTIPLO_REDONDEO_PRECIO): number {
  if (!(nuevo > 0)) return 0
  const redondeado = Math.round(nuevo / multiplo) * multiplo
  if (redondeado <= 0 || Math.abs(redondeado - nuevo) >= Math.abs(nuevo - original)) {
    return aCentavos(nuevo)
  }
  return redondeado
}

export interface PreciosBase {
  precio_sin_iva?: number | null
  impuestos_internos?: number | null
  precio?: number | null
  condicion_iva?: CondicionIva | null
  porcentaje_iva?: number | null
}

export interface PreciosNuevos {
  precio_neto: number | null
  imp_internos: number | null
  precio_final: number | null
}

/**
 * @param porcentajePct - 3 para +3%, -5 para -5%
 *
 * El neto sale del final redondeado (final / (1 + IVA)), igual que en la ficha
 * del producto: antes se redondeaban por separado y quedaban desalineados
 * ($121 + 10 % daba final $130 y neto $110, que con 21 % son $133,10). Sin
 * precio final, el neto se escala solo.
 *
 * impuestos_internos es un porcentaje sobre el neto, no un precio: no se
 * escala ni se redondea con el resto. Siempre devuelve null para que el
 * RPC (COALESCE) preserve el valor existente en la tabla.
 */
export function calcularNuevosPrecios(
  producto: PreciosBase,
  porcentajePct: number,
  multiplo = MULTIPLO_REDONDEO_PRECIO,
): PreciosNuevos {
  const factor = 1 + porcentajePct / 100
  const aplicar = (valor: number | null | undefined): number | null => {
    if (!valor) return null
    return redondearPrecio(valor, valor * factor, multiplo)
  }
  const precioFinal = aplicar(producto.precio)
  const precioNeto = precioFinal != null
    ? aCentavos(precioFinal / (1 + alicuotaIvaVenta(producto) / 100))
    : aplicar(producto.precio_sin_iva)
  return {
    precio_neto: precioNeto,
    imp_internos: null,
    precio_final: precioFinal,
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
  resultado: {
    actualizados?: number | null
    errores?: (string | null)[] | null
    trabados?: ProductoTrabado[] | null
  },
  max = 3,
  maxTrabados = 10
): string {
  const trabados = resultado.trabados ?? []
  if (trabados.length > 0) return mensajeConTrabados(resultado, trabados, max, maxTrabados)
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

/** Un producto que el lote no pudo tomar porque otra operación lo tenía (#1473). */
export interface ProductoTrabado {
  producto_id: number | string
  nombre?: string | null
}

/**
 * Decisión del dueño (05/11, #1473): un producto trabado se saltea y al final se
 * avisa cuáles no se cambiaron. Se nombran todos (hasta `maxTrabados`), porque son
 * los que hay que volver a mandar; los demás errores van aparte, como siempre. El
 * servidor pone también a cada trabado en `errores` (para un bundle viejo): esos
 * renglones se reconocen por su "(ID n)" y no se repiten.
 */
function mensajeConTrabados(
  resultado: { actualizados?: number | null; errores?: (string | null)[] | null },
  trabados: ProductoTrabado[],
  max: number,
  maxTrabados: number
): string {
  const idsTrabados = trabados.map(t => String(t.producto_id))
  const otros = (resultado.errores ?? [])
    .filter((e): e is string => !!e)
    .filter(e => !idsTrabados.some(id => e.includes(`(ID ${id})`)))
  const nombres = trabados.map(t => t.nombre || `ID ${t.producto_id}`)
  const restoTrabados = nombres.length - maxTrabados
  const listaTrabados = nombres.slice(0, maxTrabados).join(', ') + (restoTrabados > 0 ? ` y ${restoTrabados} más` : '')
  const actualizados = resultado.actualizados ?? 0
  const partes = [
    actualizados > 0 ? `Se actualizaron ${actualizados} producto(s).` : 'No se actualizó ningún producto.',
    `${trabados.length} no se cambiaron porque otra operación los estaba usando: ${listaTrabados}. Quedaron seleccionados para volver a aplicar.`,
  ]
  if (otros.length > 0) {
    const resto = otros.length - max
    partes.push(`Además, ${otros.length} con error: ${otros.slice(0, max).join('; ')}${resto > 0 ? ` y ${resto} más` : ''}`)
  }
  return partes.join(' ')
}
