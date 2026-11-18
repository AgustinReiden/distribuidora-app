/**
 * El aviso amarillo de los decimales de más (H6 de la segunda lente de #1644; decisión del dueño,
 * 17/11: «Que guarde 1,50 pero salga un aviso en amarillo no grande sobre el campo»).
 *
 * Con la regla D17 la tecla del punto es la coma decimal, así que «1.500» tipeado por costumbre (el
 * punto de miles de antes) se escribe «1,500» y vale 1,5. En la plata, que va al centavo, eso son
 * tres decimales: no es un error (se guarda lo que dice la regla, al centavo), pero el campo avisa
 * qué se guarda y cómo se escribe lo otro. Sale sólo con lo TIPEADO: lo precargado y lo pegado con
 * formato de plata no tienen nada raro.
 */
import { decimalesTipeados, leerDecimalSinMiles, leerNumero, numeroConMiles } from './normalizarNumero'
import { redondear } from './calculations'
import { formatPrecio } from './formatters'

/**
 * El aviso de la plata con más decimales que los que guarda, o null: «Se guarda $ 1,50. Para
 * $ 1.500 escribí 1500.». Lo que dice que se guarda es el número al centavo (`redondear`, medio
 * hacia afuera), que es lo que guarda el campo.
 *
 * La segunda mitad sale sólo cuando lo tipeado parece la costumbre de los miles (N11 de la segunda
 * pasada de #1644): exactamente tres decimales detrás de uno a tres dígitos («1,500», «280,000»).
 * Con cuatro decimales («1,0049») o con «0,005» no hay un número de miles que sugerir. El signo se
 * conserva en los campos que aceptan negativos.
 */
export function avisoPlataDecimalesDeMas(texto: string, decimales = 2): string | null {
  const n = leerNumero(texto)
  if (n === null || decimalesTipeados(texto) <= decimales) return null
  const seGuarda = `Se guarda ${formatPrecio(redondear(n, decimales))}.`
  const costumbre = /^\s*[-−]?\s*\$?\s*-?([1-9]\d{0,2})[.,](\d{3})\s*$/.exec(texto)
  if (!costumbre) return seGuarda
  const digitos = `${costumbre[1]}${costumbre[2]}`
  const signo = n < 0 ? '-' : ''
  return `${seGuarda} Para ${formatPrecio(Number(signo + digitos))} escribí ${signo}${digitos}.`
}

/**
 * Lo mismo para un número sin miles con precisión fija (un porcentaje de dos decimales, como la
 * comisión, que la columna redondea): «Se guarda 10,56: hasta 2 decimales.».
 */
export function avisoSinMilesDecimalesDeMas(texto: string, decimales: number): string | null {
  const n = leerDecimalSinMiles(texto)
  if (n === null) return null
  const coma = texto.replace('.', ',').indexOf(',')
  if (coma < 0 || texto.trim().length - coma - 1 <= decimales) return null
  return `Se guarda ${numeroConMiles(redondear(n, decimales))}: hasta ${decimales} decimales.`
}

/** Las clases del aviso: el ámbar de los avisos de advertencia, legible en claro y en oscuro. */
export const CLASES_AVISO_DECIMALES = 'block w-full basis-full mb-1 text-xs font-medium text-amber-800 dark:text-amber-200'
