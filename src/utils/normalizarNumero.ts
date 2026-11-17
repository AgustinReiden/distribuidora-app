/**
 * El lector de los números escritos a mano: lo tipeado en un campo, lo pegado y las celdas de
 * texto de una planilla (#1560, #1542, #1600). Una misma cadena vale lo mismo en toda la app.
 *
 * La regla es la del dueño (D17): en todo lo que se muestra, el separador de miles es el punto y
 * el de decimales la coma. Al tipear, el punto y la coma son decimales (la tecla del punto se ve
 * como coma) y el punto de miles lo pone el campo: «150000» tipeado se ve «150.000», y «150.000»
 * tipeado se ve «150,000» y es ciento cincuenta. Eso lo hace `formatearTecleo` en el campo, antes
 * de leer. Pegado (o en la planilla), «1.250» es mil doscientos cincuenta.
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

/** El cuerpo sin signo ni moneda → el número en notación JS («1250.50», «12.»), o null. */
function cuerpoAJs(cuerpo: string): string | null {
  if (!/\d/.test(cuerpo)) return null
  if (ENTERO.test(cuerpo)) return cuerpo
  if (COMA_DECIMAL.test(cuerpo)) return cuerpo.replace(',', '.')
  if (MILES_CON_PUNTO.test(cuerpo)) return cuerpo.replace(/\./g, '').replace(',', '.')
  if (MILES_CON_ESPACIO.test(cuerpo)) return cuerpo.replace(/ /g, '').replace(',', '.')
  if (MILES_CON_COMA.test(cuerpo)) return cuerpo.replace(/,/g, '')
  if (PUNTO_DECIMAL.test(cuerpo)) return cuerpo
  return null
}

/** El cuerpo sin signo ni moneda → el número, o null. */
function cuerpoANumero(cuerpo: string): number | null {
  const js = cuerpoAJs(cuerpo)
  if (js === null) return null
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
  const { inicio, insertado } = diferencia(anterior, nuevo)
  if (insertado !== '.') return nuevo
  return `${nuevo.slice(0, inicio)},${nuevo.slice(inicio + 1)}`
}

/** Qué cambió entre dos textos: dónde empieza, qué se quitó y qué entró. */
function diferencia(anterior: string, nuevo: string): { inicio: number; fin: number; quitado: string; insertado: string } {
  let inicio = 0
  while (inicio < anterior.length && inicio < nuevo.length && anterior[inicio] === nuevo[inicio]) inicio++
  let fin = 0
  while (
    fin < anterior.length - inicio &&
    fin < nuevo.length - inicio &&
    anterior[anterior.length - 1 - fin] === nuevo[nuevo.length - 1 - fin]
  ) fin++
  return {
    inicio,
    fin,
    quitado: anterior.slice(inicio, anterior.length - fin),
    insertado: nuevo.slice(inicio, nuevo.length - fin),
  }
}

/** Los dígitos de la parte entera con el punto de miles: «150000» → «150.000». */
const conMiles = (digitos: string): string => digitos.replace(/\B(?=(\d{3})+(?!\d))/g, '.')

/** La parte entera de un texto del campo: hasta la primera coma. */
const finDeEntero = (texto: string): number => {
  const coma = texto.indexOf(',')
  return coma === -1 ? texto.length : coma
}

/**
 * El texto del campo con los miles puestos: la parte entera (signo y dígitos) se agrupa con punto
 * y sin ceros adelante; lo que sigue a la primera coma queda como está (los decimales no se
 * formatean, y una segunda coma queda a la vista para que el lector la rechace). Lo que no tiene
 * esa forma vuelve tal cual. `cerosQuitados` es cuántos ceros de adelante se fueron.
 */
function agruparMiles(texto: string): { texto: string; cerosQuitados: number; agrupado: boolean } {
  const m = /^(-?)(\d*)(,[\s\S]*)?$/.exec(texto)
  if (!m) return { texto, cerosQuitados: 0, agrupado: false }
  const entero = m[2].replace(/^0+(?=\d)/, '')
  return {
    texto: m[1] + conMiles(entero) + (m[3] ?? ''),
    cerosQuitados: m[2].length - entero.length,
    agrupado: true,
  }
}

/** Un texto del campo ya formateado: su parte entera no tiene puntos o los tiene de a tres. */
const estaFormateado = (texto: string): boolean =>
  /^-?(\d{1,3}(\.\d{3})+|\d*)$/.test(texto.slice(0, finDeEntero(texto)))

/** Sin los puntos de miles: los que caen en la parte entera de `texto` desde la posición `desde`. */
function sinPuntosDeMiles(trozo: string, desde: number, limite: number): string {
  let salida = ''
  for (let i = 0; i < trozo.length; i++) {
    if (!(trozo[i] === '.' && desde + i < limite)) salida += trozo[i]
  }
  return salida
}

/**
 * Un número pegado, como lo escribe el campo: sin miles y con coma decimal («1.250,50» →
 * «1250,50», «12.50» → «12,50», «$ 150.000» → «150000»), o null si no se entiende.
 */
function pegadoComoCampo(texto: string): string | null {
  const { negativo, cuerpo } = sinSignoNiMoneda(texto)
  const js = cuerpoAJs(cuerpo)
  if (js === null) return null
  return (negativo ? '-' : '') + js.replace('.', ',')
}

export interface OpcionesTecleo {
  /** Para qué lado se borró (Backspace es 'atras', Supr es 'adelante'). Default 'atras'. */
  direccion?: 'atras' | 'adelante'
  /** Si el campo acepta un menos tipeado al principio. Default false. */
  negativo?: boolean
}

/**
 * Un número mientras se tipea (D17, #1560): la tecla del punto es la coma decimal y el punto de
 * miles lo pone el campo. «150000» se ve «150.000», «1500,5» se ve «1.500,5» y «150.000» tipeado
 * se ve «150,000» (ciento cincuenta). Los decimales no se formatean.
 *
 * `anterior` es lo que había, `nuevo` lo que dejó el navegador y `cursor` dónde quedó; devuelve el
 * texto a mostrar y dónde poner el cursor (después del mismo dígito, aunque entren o salgan
 * puntos).
 * - Una tecla que no es un dígito, la coma o el punto (ni el menos al principio, con `negativo`)
 *   no entra.
 * - Borrar sólo un punto de miles (Backspace o Supr al lado) borra el dígito de ese lado: si no,
 *   el punto volvería y el campo quedaría trabado. Borrar un cero de «1.500» da «150».
 * - Lo pegado (más de una tecla) se lee como se muestra la plata: «1.250,50» es 1250,5 y se ve
 *   igual. Lo que no se entiende entra tal cual, a la vista, para que el campo lo marque.
 * - Si el campo tiene algo que no está formateado (un pegado que no se entiende), no se reagrupa:
 *   sólo la tecla del punto se escribe como coma.
 */
export function formatearTecleo(
  anterior: string,
  nuevo: string,
  cursor: number = nuevo.length,
  { direccion = 'atras', negativo = false }: OpcionesTecleo = {},
): { texto: string; cursor: number } {
  if (!estaFormateado(anterior)) return { texto: teclearNumero(anterior, nuevo), cursor }
  const { inicio, fin, quitado, insertado } = diferencia(anterior, nuevo)
  const limite = finDeEntero(anterior)
  let prefijo = sinPuntosDeMiles(anterior.slice(0, inicio), 0, limite)
  let sufijo = sinPuntosDeMiles(anterior.slice(anterior.length - fin), anterior.length - fin, limite)
  // Se borró sólo un punto de miles: se borra el dígito de ese lado.
  if (insertado === '' && quitado === '.' && inicio < limite) {
    if (direccion === 'adelante') sufijo = sufijo.slice(1)
    else prefijo = prefijo.slice(0, -1)
  }

  let entra: string
  if (insertado.length <= 1) {
    entra = insertado === '.' ? ',' : insertado.replace(/−/g, '-')
    const menosAlPrincipio = entra === '-' && negativo && prefijo === '' && !sufijo.startsWith('-')
    if (entra !== '' && !/^[\d,]$/.test(entra) && !menosAlPrincipio) entra = ''
  } else {
    entra = pegadoComoCampo(insertado) ?? insertado
  }

  const izquierda = prefijo + entra
  const agrupado = agruparMiles(izquierda + sufijo)
  if (!agrupado.agrupado) return { texto: izquierda + sufijo, cursor: izquierda.length }

  // El cursor va después del mismo carácter (sin contar los puntos de miles), menos los ceros de
  // adelante que se fueron.
  const signo = izquierda.startsWith('-') ? 1 : 0
  const objetivo = izquierda.length - Math.min(agrupado.cerosQuitados, Math.max(0, izquierda.length - signo))
  const texto = agrupado.texto
  const limiteNuevo = finDeEntero(texto)
  let vistos = 0
  let posicion = 0
  while (posicion < texto.length && vistos < objetivo) {
    if (!(texto[posicion] === '.' && posicion < limiteNuevo)) vistos++
    posicion++
  }
  return { texto, cursor: posicion }
}

/**
 * Un número para precargar un campo que pone los miles (`formatearTecleo`): «1.500,5». Al
 * millonésimo, sin la cola del double. Un campo que no pone los miles precarga con
 * `numeroEditable` (sin miles), porque ahí borrar un cero de «1.500» dejaría «1.50».
 */
export function numeroConMiles(n: number | null | undefined): string {
  if (n === null || n === undefined || !Number.isFinite(n)) return ''
  const r = Math.abs(n) < 1e21 ? Number(n.toFixed(6)) : n
  return agruparMiles(String(r + 0).replace('.', ',')).texto
}

/**
 * `leerNumero` con 0 para lo vacío o lo que no se entiende. Lo usa el import de compras
 * (`ModalImportarCompra`, `parsearCantidadExcel`): una celda de texto «1.500» es mil quinientos
 * (STK-8, #1516), y «1,500.50» de una planilla en inglés también se lee.
 */
export function normalizarNumero(valor: string | number | null | undefined): number {
  return leerNumero(valor) ?? 0
}
