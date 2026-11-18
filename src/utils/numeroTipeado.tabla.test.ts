/**
 * La tabla de los números tipeados (#1542 STK-18, #1560 b1-b5, #1600 b11). Regla del dueño (D17,
 * confirmada el 17/11): en todo lo que se muestra, el separador de miles es el punto y el de
 * decimales la coma. Al tipear, el punto y la coma son decimales (la tecla del punto se ve como
 * coma) y el punto de miles lo pone el campo: para 150.000 se escribe «150000» y se ve «150.000».
 *
 * Cada fila dice qué pasa con una misma cadena por las dos puertas de un campo:
 * - **tipeada** tecla por tecla (`formatearTecleo`): lo que queda en el campo es lo que se lee;
 * - **pegada** de una sola vez (de una planilla, de un mensaje): no hay tecla del punto, así que la
 *   cadena se lee con la regla de lo que se muestra.
 * `null` es «no se entiende»: el campo lo rechaza a la vista, nunca lo guarda como otro número.
 */
import { describe, it, expect } from 'vitest'
import {
  NUMERO_ILEGIBLE,
  esCeldaIlegible,
  formatearTecleo,
  leerEntero,
  motivoEnteroTipeado,
  leerNumero,
  normalizarNumero,
  numeroConMiles,
  teclearNumero,
} from './normalizarNumero'
import {
  leerPlataTipeada,
  numeroEditable,
  parseDecimal,
  parsePrecio,
  redondear,
  redondearSQL,
} from './calculations'
import { formatCurrency } from './formatters'
import { parseMonto } from './personal'

/** Lo que se ve en el campo después de cada tecla, tipeando `texto` al final. */
function pasos(texto: string): string[] {
  const vistos: string[] = []
  let campo = ''
  for (const tecla of texto) {
    campo = formatearTecleo(campo, campo + tecla, campo.length + 1, { negativo: true }).texto
    vistos.push(campo)
  }
  return vistos
}

/** Lo que queda en el campo después de tipear `texto` tecla por tecla. */
const tipear = (texto: string): string => pasos(texto).pop() ?? ''

/** Cómo se muestra lo leído: miles con punto, decimales con coma. */
const mostrar = (n: number | null): string | null => (n === null ? null : formatCurrency(redondear(n, 2)))

const MENOS_UNICODE = '−10'
const NUEVE_400 = '9'.repeat(400)
const NUEVE_400_CON_MILES = NUEVE_400.replace(/\B(?=(\d{3})+(?!\d))/g, '.')

// [lo que el usuario escribe, lo que queda en el campo al tipearlo, leído al tipear, leído al pegar]
const TABLA: Array<[string, string, number | null, number | null]> = [
  // Los cuatro issues.
  ['1.250', '1,250', 1.25, 1250],
  ['1,5', '1,5', 1.5, 1.5],
  ['1.5', '1,5', 1.5, 1.5],
  ['12.375', '12,375', 12.375, 12375],
  ['1.250,50', '1,250,50', null, 1250.5],
  ['1,234,567', '1,234,567', null, null],
  ['1..5', '1,,5', null, null],
  // Una tecla que no es dígito, coma ni punto no entra (el menos, sólo al principio).
  ['10-', '10', 10, null],
  ['1e5', '15', 15, null],
  ['Infinity', '', null, null],
  ['', '', null, null],
  [MENOS_UNICODE, '-10', -10, -10],
  ['150.000', '150,000', 150, 150000],
  ['1.500', '1,500', 1.5, 1500],
  ['1.500,50', '1,500,50', null, 1500.5],
  ['0,5', '0,5', 0.5, 0.5],
  ['12.50', '12,50', 12.5, 12.5],
  ['1.234.567', '1,234,567', null, 1234567],
  ['1.000.00', '1,000,00', null, null],
  ['1.50.0', '1,50,0', null, null],
  // Los miles los pone el campo.
  ['150000', '150.000', 150000, 150000],
  ['1500,50', '1.500,50', 1500.5, 1500.5],
  ['1234567', '1.234.567', 1234567, 1234567],
  ['1234567,891', '1.234.567,891', 1234567.891, 1234567.891],
  ['007', '7', 7, 7],
  // Más formas que llegan pegadas.
  ['1,500.50', '1,500,50', null, 1500.5],
  ['0.500', '0,500', 0.5, 0.5],
  ['$ 150.000', '150,000', 150, 150000],
  ['280 000', '280.000', 280000, 280000],
  ['-10', '-10', -10, -10],
  ['1.500,', '1,500,', null, 1500],
  [',', ',', null, null],
  ['.', ',', null, null],
  ['12abc', '12', 12, null],
  ['NaN', '', null, null],
  [NUEVE_400, NUEVE_400_CON_MILES, null, null],
]

// Lo que se VE en el campo después de cada tecla.
describe('tecla por tecla: los miles los pone el campo', () => {
  it.each([
    ['150000', ['1', '15', '150', '1.500', '15.000', '150.000']],
    ['1500,5', ['1', '15', '150', '1.500', '1.500,', '1.500,5']],
    ['1.250', ['1', '1,', '1,2', '1,25', '1,250']],
    ['150.000', ['1', '15', '150', '150,', '150,0', '150,00', '150,000']],
    ['1234,5678', ['1', '12', '123', '1.234', '1.234,', '1.234,5', '1.234,56', '1.234,567', '1.234,5678']],
    ['0,05', ['0', '0,', '0,0', '0,05']],
    ['-1500', ['-', '-1', '-15', '-150', '-1.500']],
  ])('%j se ve %j', (texto, vistos) => {
    expect(pasos(texto)).toEqual(vistos)
  })
})

/**
 * Una tecla como la manda el navegador: inserta (o borra) en el cursor y deja el cursor ahí.
 * Devuelve lo que el campo muestra y dónde queda el cursor.
 */
function tecla(campo: { texto: string; cursor: number }, t: string): { texto: string; cursor: number } {
  const { texto, cursor } = campo
  if (t === 'Backspace') {
    if (cursor === 0) return campo
    return formatearTecleo(texto, texto.slice(0, cursor - 1) + texto.slice(cursor), cursor - 1, { direccion: 'atras' })
  }
  if (t === 'Delete') {
    if (cursor >= texto.length) return campo
    return formatearTecleo(texto, texto.slice(0, cursor) + texto.slice(cursor + 1), cursor, { direccion: 'adelante' })
  }
  return formatearTecleo(texto, texto.slice(0, cursor) + t + texto.slice(cursor), cursor + t.length)
}

/** «1.0|00» → { texto: '1.000', cursor: 3 }. */
const conCursor = (marcado: string) => ({ texto: marcado.replace('|', ''), cursor: marcado.indexOf('|') })
const marcar = ({ texto, cursor }: { texto: string; cursor: number }) => `${texto.slice(0, cursor)}|${texto.slice(cursor)}`

// H2 de la lente de #1644: con dígitos repetidos, el cambio se atribuía al final de la tira de
// dígitos iguales y el cursor quedaba corrido. 1.000 → 1.500 terminaba en 1.005.
describe('dígitos repetidos: cada tecla cae donde está el cursor', () => {
  it.each([
    ['1.0|00', ['Backspace', '5'], ['1|00', '1.5|00'], 1500],
    ['10.0|00', ['Backspace', '5'], ['1.0|00', '10.5|00'], 10500],
    ['1.0|00', ['0', '5'], ['10.0|00', '100.5|00'], 100500],
    ['2|2.222', ['2', '3'], ['22|2.222', '2.23|2.222'], 2232222],
    ['1.00|0', ['Backspace', 'Backspace', '9'], ['10|0', '1|0', '19|0'], 190],
    ['|1.000', ['Delete', '2'], ['|0', '2|0'], 20],
    ['111.1|11', ['Backspace', '9'], ['11.1|11', '111.9|11'], 111911],
    ['111.111|', ['Backspace', 'Backspace', '0'], ['11.111|', '1.111|', '11.110|'], 11110],
    ['2.2|22', ['Backspace'], ['2|22'], 222],
    ['2.2|22', ['Delete'], ['22|2'], 222],
    ['2|.222', ['Delete'], ['2|22'], 222],
    ['2.|222', ['Backspace'], ['|222'], 222],
    ['1.000.0|00', ['Backspace', '7'], ['100.0|00', '1.000.7|00'], 1000700],
    ['5|5,55', ['5'], ['55|5,55'], 555.55],
    ['5,5|5', ['5'], ['5,55|5'], 5.555],
  ])('«%s» + %j: se ve %j, y vale %d', (inicio, teclas, vistos, valor) => {
    let campo = conCursor(inicio)
    const paso: string[] = []
    for (const t of teclas) {
      campo = tecla(campo, t)
      paso.push(marcar(campo))
    }
    expect(paso).toEqual(vistos)
    expect(leerNumero(campo.texto)).toBe(valor)
  })
})

// H5: un pegado ilegible que se vuelve legible al editarlo se reescribe como lo escribe el campo.
describe('editar un pegado que no se entendía', () => {
  it('«12.345.67» y borrar el segundo punto: «12,34567», no «12.34567» sin rojo', () => {
    const pegado = formatearTecleo('', '12.345.67', 9)
    expect(pegado.texto).toBe('12.345.67')
    expect(leerNumero(pegado.texto)).toBeNull()
    const borrado = tecla({ texto: '12.345.67', cursor: 7 }, 'Backspace')
    expect(borrado.texto).toBe('12,34567')
    expect(leerNumero(borrado.texto)).toBe(12.34567)
  })

  it('si sigue sin entenderse, queda tal cual', () => {
    expect(tecla({ texto: '1,234,567', cursor: 9 }, '8').texto).toBe('1,234,5678')
  })
})

// Regla del dueño: la coma es decimal. «15,000» pegado (un SMS en inglés) es quince, no quince mil.
it('«15,000» pegado (formato inglés) se lee 15: la coma es decimal', () => {
  expect(formatearTecleo('', '15,000', 6).texto).toBe('15,000')
  expect(leerNumero('15,000')).toBe(15)
})

describe('formatearTecleo: borrar, el cursor, seleccionar y pegar', () => {
  it('borrar un cero de «1.500» da «150»', () => {
    expect(formatearTecleo('1.500', '1.50', 4)).toEqual({ texto: '150', cursor: 3 })
  })

  it('Backspace justo después de un punto de miles borra el dígito de antes, no se traba', () => {
    // «1.|500»: el navegador quita el punto; el campo quita el 1.
    expect(formatearTecleo('1.500', '1500', 1, { direccion: 'atras' })).toEqual({ texto: '500', cursor: 0 })
    // «15.|000»
    expect(formatearTecleo('15.000', '15000', 2, { direccion: 'atras' })).toEqual({ texto: '1.000', cursor: 1 })
  })

  it('Supr justo antes de un punto de miles borra el dígito de después', () => {
    // «1|.500»
    expect(formatearTecleo('1.500', '1500', 1, { direccion: 'adelante' })).toEqual({ texto: '100', cursor: 1 })
  })

  it('el cursor queda después del mismo dígito aunque entre o salga un punto', () => {
    // «1|.000» + 5 → «15|.000»
    expect(formatearTecleo('1.000', '15.000', 2)).toEqual({ texto: '15.000', cursor: 2 })
    // «150|» + 0 → «1.500|»
    expect(formatearTecleo('150', '1500', 4)).toEqual({ texto: '1.500', cursor: 5 })
    // «1.500|» borrar → «150|»
    expect(formatearTecleo('1.500', '1.50', 4)).toEqual({ texto: '150', cursor: 3 })
    // «|1.500» + 2 → «2|1.500»
    expect(formatearTecleo('1.500', '21.500', 1)).toEqual({ texto: '21.500', cursor: 1 })
    // «12.345|,5» borrar el 5 → «1.234|,5»
    expect(formatearTecleo('12.345,5', '12.34,5', 5)).toEqual({ texto: '1.234,5', cursor: 5 })
  })

  it('seleccionar todo y tipear reemplaza', () => {
    expect(formatearTecleo('1.500,50', '7', 1)).toEqual({ texto: '7', cursor: 1 })
    expect(formatearTecleo('1.500,50', ',', 1)).toEqual({ texto: ',', cursor: 1 })
  })

  it('lo pegado se lee como se muestra la plata y se ve con miles', () => {
    expect(formatearTecleo('', '1.250,50', 8).texto).toBe('1.250,50')
    expect(formatearTecleo('', '1250,5', 6).texto).toBe('1.250,5')
    expect(formatearTecleo('', '12.50', 5).texto).toBe('12,50')
    expect(formatearTecleo('', '$ 150.000', 9).texto).toBe('150.000')
    expect(formatearTecleo('', '1,500.50', 8).texto).toBe('1.500,50')
    expect(leerNumero(formatearTecleo('', '1.250,50', 8).texto)).toBe(1250.5)
  })

  it('lo pegado que no se entiende entra tal cual (el campo lo marca) y no se reagrupa', () => {
    expect(formatearTecleo('', '1,234,567', 9).texto).toBe('1,234,567')
    expect(formatearTecleo('', '1.50.0', 6).texto).toBe('1.50.0')
    // Seguir tipeando sobre eso no lo reinterpreta: sólo la tecla del punto es coma.
    expect(formatearTecleo('1.50.0', '1.50.05', 7).texto).toBe('1.50.05')
    expect(leerNumero('1.50.05')).toBeNull()
  })

  it('una segunda coma queda a la vista; los decimales no se formatean', () => {
    expect(formatearTecleo('1.000,5', '1.000,5,', 8).texto).toBe('1.000,5,')
    expect(formatearTecleo('1,2345', '1,23456', 7).texto).toBe('1,23456')
  })

  it('el menos sólo al principio y sólo si el campo lo acepta', () => {
    expect(formatearTecleo('', '-', 1).texto).toBe('')
    expect(formatearTecleo('', '-', 1, { negativo: true }).texto).toBe('-')
    expect(formatearTecleo('15', '1-5', 2, { negativo: true }).texto).toBe('15')
    expect(formatearTecleo('', '−', 1, { negativo: true }).texto).toBe('-')
  })

  it('el campo vacío queda vacío', () => {
    expect(formatearTecleo('5', '', 0)).toEqual({ texto: '', cursor: 0 })
    expect(formatearTecleo('1.500', '', 0)).toEqual({ texto: '', cursor: 0 })
  })
})

describe('numeroConMiles (la precarga de un campo que pone los miles)', () => {
  it.each([
    [1500.5, '1.500,5'],
    [1500, '1.500'],
    [150000, '150.000'],
    [1234567.891, '1.234.567,891'],
    [0.5, '0,5'],
    [0.1 + 0.2, '0,3'],
    [-1500, '-1.500'],
    [999, '999'],
  ])('%d se precarga %j', (n, texto) => {
    expect(numeroConMiles(n)).toBe(texto)
    expect(leerNumero(numeroConMiles(n))).toBe(Number(n.toFixed(6)))
  })

  it('null, undefined y NaN dan el campo vacío', () => {
    expect(numeroConMiles(null)).toBe('')
    expect(numeroConMiles(undefined)).toBe('')
    expect(numeroConMiles(NaN)).toBe('')
  })
})

describe('tabla de números tipeados (D17)', () => {
  it.each(TABLA)('%j: tipeado queda %j y se lee %s; pegado se lee %s', (entrada, campo, alTipear, alPegar) => {
    expect(tipear(entrada)).toBe(campo)
    expect(leerNumero(tipear(entrada))).toBe(alTipear)
    expect(leerNumero(entrada)).toBe(alPegar)
  })

  it.each(TABLA)('%j nunca da Infinity ni NaN', entrada => {
    for (const leido of [leerNumero(entrada), leerNumero(tipear(entrada))]) {
      if (leido !== null) expect(Number.isFinite(leido)).toBe(true)
    }
    expect(Number.isFinite(parsePrecio(entrada))).toBe(true)
    expect(Number.isFinite(normalizarNumero(entrada))).toBe(true)
  })

  it.each([
    ['1.250', '$1,25', '$1.250,00'],
    ['150.000', '$150,00', '$150.000,00'],
    ['1.250,50', null, '$1.250,50'],
    ['1.234.567', null, '$1.234.567,00'],
    ['0,145', '$0,15', '$0,15'],
  ])('%j se muestra %s tipeado y %s pegado', (entrada, tipeado, pegado) => {
    expect(mostrar(leerNumero(tipear(entrada)))).toBe(tipeado)
    expect(mostrar(leerNumero(entrada))).toBe(pegado)
  })

  // STK-18: «1.250» en un costo. Tipeado es uno coma veinticinco (D17: el punto tipeado es
  // decimal); en una celda de texto de la planilla o pegado es mil doscientos cincuenta (D17: el
  // punto que se muestra es de miles). A CONFIRMAR con el dueño.
  it('STK-18: «12.375» tipeado en un costo es 12,375; pegado o en la planilla, 12.375', () => {
    expect(leerNumero(tipear('12.375'))).toBe(12.375)
    expect(normalizarNumero('12.375')).toBe(12375)
  })
})

describe('los lectores que quedan leen la tabla igual', () => {
  it.each(TABLA)('%j', entrada => {
    for (const texto of [entrada, tipear(entrada)]) {
      const leido = leerNumero(texto)
      // parsePrecio: lo que no se entiende es 0 (no puede devolver otra cosa); lo demás, al centavo.
      expect(parsePrecio(texto)).toBe(leido === null ? 0 : redondear(leido, 2))
      // leerPlataTipeada: lo mismo sin redondear, y NaN para lo que no se entiende.
      if (leido === null) expect(leerPlataTipeada(texto)).toBeNaN()
      else expect(leerPlataTipeada(texto)).toBe(leido)
      // normalizarNumero (el import de compras): 0 para lo que no se entiende.
      expect(normalizarNumero(texto)).toBe(leido ?? 0)
      // parseMonto (gastos y personal) es más estricto —sin signo, hasta dos decimales— pero lo
      // que acepta lo lee igual (y desde B20 tampoco da Infinity con la tira de 400 nueves).
      const monto = parseMonto(texto)
      if (monto !== null) expect(monto).toBe(leido)
    }
  })

  it('#1600-b11: leerPlataTipeada rechaza «1,234,567», «1.50.0» y «1e5»', () => {
    expect(leerPlataTipeada('1,234,567')).toBeNaN()
    expect(leerPlataTipeada('1.50.0')).toBeNaN()
    expect(leerPlataTipeada('1e5')).toBeNaN()
  })

  it('#1560-b2: parsePrecio no inventa un número para las cadenas raras', () => {
    expect(parsePrecio('1,234,567')).toBe(0)
    expect(parsePrecio('1.000.00')).toBe(0)
    expect(parsePrecio('1..5')).toBe(0)
    expect(parsePrecio('10-')).toBe(0)
    expect(parsePrecio(MENOS_UNICODE)).toBe(-10)
  })

  it('#1542 STK-18: normalizarNumero nunca devuelve Infinity', () => {
    expect(normalizarNumero('Infinity')).toBe(0)
    expect(normalizarNumero('-Infinity')).toBe(0)
    expect(normalizarNumero(Infinity)).toBe(0)
    expect(normalizarNumero(NUEVE_400)).toBe(0)
  })

  // parseDecimal es el segundo lector, para lo que no es plata y no llega a mil (porcentajes,
  // litros): ahí el punto nunca es de miles. Lo tipeado (con coma) lo lee igual que leerNumero.
  it.each(TABLA)('parseDecimal lee lo tipeado de %j como leerNumero', entrada => {
    const campo = tipear(entrada)
    const leido = leerNumero(campo)
    if (leido !== null && Math.abs(leido) < 1000) expect(parseDecimal(campo)).toBe(redondear(leido, 2))
  })
})

describe('leerEntero', () => {
  it.each([
    ['12', 12],
    ['1.250', 1250],
    ['1.234.567', 1234567],
    [' 7 ', 7],
  ])('%j es %d', (texto, esperado) => {
    expect(leerEntero(texto)).toBe(esperado)
  })

  // Una cantidad no tiene decimales: una coma (la tecla del punto) no se redondea ni se borra.
  it.each(['1,5', '1,250', '1,0', '12.5', '', 'abc', '1e3', tipear('1.250')])('%j no es una cantidad: null', texto => {
    expect(leerEntero(texto)).toBeNull()
  })
})

describe('teclearNumero', () => {
  it('sólo la tecla del punto se vuelve coma, también en el medio', () => {
    expect(teclearNumero('15', '1.5')).toBe('1,5')
    expect(teclearNumero('', '.')).toBe(',')
    expect(teclearNumero('12', '12,')).toBe('12,')
  })

  it('lo pegado entra tal cual', () => {
    expect(teclearNumero('', '1.250,50')).toBe('1.250,50')
    expect(teclearNumero('1', '11.250')).toBe('11.250')
  })

  it('reemplazar lo seleccionado por un punto también es la tecla del punto', () => {
    expect(teclearNumero('150', '.')).toBe(',')
  })

  it('borrar no toca los puntos que ya estaban', () => {
    expect(teclearNumero('1.250', '1.25')).toBe('1.25')
  })
})

// #1560-b1: el server compara al centavo con round(numeric, 2), que redondea medio hacia afuera.
describe('redondear es round(numeric, n) de Postgres', () => {
  it.each([
    [1.005, 2, 1.01],
    [0.145, 2, 0.15],
    [2.675, 2, 2.68],
    [1.255, 2, 1.26],
    [-1.005, 2, -1.01],
    [-0.5, 0, -1],
    [0.5, 0, 1],
    [1.15 * 0.9, 2, 1.04],
    [10.456, 2, 10.46],
    [-0.001, 2, 0],
  ])('redondear(%d, %d) = %d', (valor, decimales, esperado) => {
    expect(redondear(valor, decimales)).toBe(esperado)
    expect(redondear(valor, decimales)).toBe(redondearSQL(valor, decimales))
  })

  it('parsePrecio redondea igual: «0,145» es 0,15', () => {
    expect(parsePrecio('0,145')).toBe(0.15)
    expect(parsePrecio(1.005)).toBe(1.01)
  })
})

// #1560-b4: lo que se precarga en un campo no muestra la cola del double.
describe('numeroEditable', () => {
  it.each([
    [0.1 + 0.2, '0,3'],
    [1.1 * 3, '3,3'],
    [125.125, '125,125'],
    [1500, '1500'],
  ])('%d se precarga %j', (n, texto) => {
    expect(numeroEditable(n)).toBe(texto)
  })
})

// B20: lo que usan los formularios y el import para decir por qué un número no sirve.
describe('motivoEnteroTipeado y esCeldaIlegible', () => {
  it.each([
    ['', null],
    ['12', null],
    ['1.500', null],
    ['1,5', 'Las cantidades van sin coma'],
    ['abc', NUMERO_ILEGIBLE],
  ])('motivoEnteroTipeado(%j) = %j', (texto, motivo) => {
    expect(motivoEnteroTipeado(texto)).toBe(motivo)
  })

  it.each([
    [null, false],
    ['', false],
    [1250.5, false],
    ['1.250,50', false],
    ['150000', false],
    ['1,234,567', true],
    ['abc', true],
    [Infinity, true],
  ])('esCeldaIlegible(%j) = %s', (celda, ilegible) => {
    expect(esCeldaIlegible(celda as string | number | null)).toBe(ilegible)
  })
})
