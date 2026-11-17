/**
 * El lector de los números escritos a mano: lo tipeado en un campo, lo pegado y las celdas de
 * texto de una planilla (#1560, #1542, #1600). Una misma cadena vale lo mismo en toda la app.
 *
 * La regla es la del dueño (D17): en todo lo que se muestra, el separador de miles es el punto y
 * el de decimales la coma. Al tipear, la tecla del punto es el separador decimal y se ve como coma:
 * eso lo hace `teclearNumero` en el campo, antes de leer. Así, «1.250» tipeado queda «1,250» en
 * pantalla y es uno coma veinticinco; pegado (o en la planilla) es mil doscientos cincuenta.
 *
 * Lo que no sigue una forma clara no se adivina: es `null` («no se entiende»), y el campo lo
 * rechaza a la vista. Nunca da Infinity ni NaN.
 */

/** Signo menos tipográfico (U+2212): es un menos, no basura. */
const MENOS_UNICODE = /−/g

/**
 * Las formas que se entienden, sin el signo ni el «$». Las que llevan miles exigen grupos de tres
 * y un primer grupo que no empiece con 0 («0.500» es medio).
 */
const ENTERO = /^\d+$/
// Un solo separador, la coma: decimal («1,5», «1500,50», «12,» mientras se tipea, «,5»).
const COMA_DECIMAL = /^\d*,\d*$/
// Puntos de miles, con o sin coma decimal: «1.250», «1.234.567», «1.250,50», «1.500,».
const MILES_CON_PUNTO = /^[1-9]\d{0,2}(\.\d{3})+(,\d*)?$/
// Miles con espacio, como los escribe `parseMonto`: «280 000», «280 000,50».
const MILES_CON_ESPACIO = /^[1-9]\d{0,2}( \d{3})+(,\d*)?$/
// Las dos marcas al revés, como en una planilla en inglés: «1,500.50». Con los dos separadores no
// hay duda de cuál es el decimal (el último), y los miles tienen que estar bien agrupados.
const MILES_CON_COMA = /^[1-9]\d{0,2}(,\d{3})+\.\d+$/
// Un solo punto que no es de miles («12.50», «1.5», «0.500», «1234.567», «12.»): sólo puede ser
// decimal. Llega pegado, o de un campo que todavía no escribe la tecla del punto como coma.
const PUNTO_DECIMAL = /^\d*\.\d*$/

/** El cuerpo sin signo ni moneda → el número en notación JS, o null. */
function cuerpoANumero(cuerpo: string): number | null {
  if (!/\d/.test(cuerpo)) return null
  let js: string
  if (ENTERO.test(cuerpo)) js = cuerpo
  else if (COMA_DECIMAL.test(cuerpo)) js = cuerpo.replace(',', '.')
  else if (MILES_CON_PUNTO.test(cuerpo)) js = cuerpo.replace(/\./g, '').replace(',', '.')
  else if (MILES_CON_ESPACIO.test(cuerpo)) js = cuerpo.replace(/ /g, '').replace(',', '.')
  else if (MILES_CON_COMA.test(cuerpo)) js = cuerpo.replace(/,/g, '')
  else if (PUNTO_DECIMAL.test(cuerpo)) js = cuerpo
  else return null
  const n = Number(js.endsWith('.') ? js.slice(0, -1) : js)
  return Number.isFinite(n) ? n : null
}

/** Separa el signo y el símbolo de moneda («-$ 10», «$ -10», «$10»). */
function sinSignoNiMoneda(texto: string): { negativo: boolean; cuerpo: string } {
  let t = texto.trim().replace(MENOS_UNICODE, '-')
  let negativo = false
  if (t.startsWith('-')) { negativo = true; t = t.slice(1).trimStart() }
  t = t.replace(/^[$€£¥]\s*/, '')
  if (!negativo && t.startsWith('-')) { negativo = true; t = t.slice(1) }
  return { negativo, cuerpo: t }
}

/**
 * Un número escrito a mano, o `null` si está vacío o no se entiende (dos comas, puntos mal
 * agrupados, «1e5», «Infinity», «10-»). Ver la tabla en `numeroTipeado.tabla.test.ts`.
 */
export function leerNumero(valor: string | number | null | undefined): number | null {
  if (valor === null || valor === undefined) return null
  if (typeof valor === 'number') return Number.isFinite(valor) ? valor : null
  const { negativo, cuerpo } = sinSignoNiMoneda(String(valor))
  const n = cuerpoANumero(cuerpo)
  if (n === null) return null
  return negativo ? -n + 0 : n // el + 0 normaliza -0
}

/** Lo que dice un campo cuando no entiende lo escrito. */
export const NUMERO_ILEGIBLE = 'No se entiende el número: los decimales van con coma (la tecla del punto la escribe)'

/** Hay algo escrito y `leerNumero` no lo entiende: el campo lo marca en vez de leer otro número. */
export function esTextoIlegible(texto: string): boolean {
  return texto.trim() !== '' && leerNumero(texto) === null
}

/**
 * Una cantidad de unidades: un entero, con o sin puntos de miles («1.250»). Una coma —la tecla del
 * punto— no se redondea ni se borra: «1,5» o «1,250» no es una cantidad y da `null`.
 */
export function leerEntero(valor: string | number | null | undefined): number | null {
  if (typeof valor === 'string' && valor.includes(',')) return null
  const n = leerNumero(valor)
  return n !== null && Number.isInteger(n) ? n : null
}

/**
 * Para lo que no es plata y no llega a mil (porcentajes, litros, pesos): sin miles, así que el punto
 * y la coma son decimales («38.512» → 38,512) y con más de un separador no se sabe qué es (`null`).
 * Es el segundo lector, y existe por eso: un porcentaje pegado como «12.125» no es doce mil. Lo
 * tipeado (con la coma de `teclearNumero`) lo lee igual que `leerNumero`.
 */
export function leerDecimalSinMiles(valor: string | number | null | undefined): number | null {
  if (valor === null || valor === undefined) return null
  if (typeof valor === 'number') return Number.isFinite(valor) ? valor : null
  const { negativo, cuerpo } = sinSignoNiMoneda(String(valor))
  const t = cuerpo.replace(',', '.')
  if (!/^(\d+\.?\d*|\.\d+)$/.test(t)) return null
  const n = Number(t)
  if (!Number.isFinite(n)) return null
  return negativo ? -n + 0 : n
}

/**
 * La tecla del punto, escrita como coma (D17). `anterior` es lo que había en el campo y `nuevo` lo
 * que dejó el navegador: si lo único que entró es un punto (una tecla, también reemplazando lo
 * seleccionado), ese punto pasa a ser una coma. Lo pegado (más de un carácter) entra tal cual, y
 * borrar no toca nada: los puntos que ya estaban son de miles.
 */
export function teclearNumero(anterior: string, nuevo: string): string {
  let inicio = 0
  while (inicio < anterior.length && inicio < nuevo.length && anterior[inicio] === nuevo[inicio]) inicio++
  let fin = 0
  while (
    fin < anterior.length - inicio &&
    fin < nuevo.length - inicio &&
    anterior[anterior.length - 1 - fin] === nuevo[nuevo.length - 1 - fin]
  ) fin++
  if (nuevo.slice(inicio, nuevo.length - fin) !== '.') return nuevo
  return `${nuevo.slice(0, inicio)},${nuevo.slice(inicio + 1)}`
}

/**
 * `leerNumero` con 0 para lo vacío o lo que no se entiende. Lo usa el import de compras
 * (`ModalImportarCompra`, `parsearCantidadExcel`): una celda de texto «1.500» es mil quinientos
 * (STK-8, #1516), y «1,500.50» de una planilla en inglés también se lee.
 */
export function normalizarNumero(valor: string | number | null | undefined): number {
  return leerNumero(valor) ?? 0
}
