import { describe, it, expect } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import type { jsPDF } from 'jspdf'
import { construirListaPreciosPdf, textoPdf } from '../listaPrecios'
import { armarListaPrecios, type ProductoListaPrecios, type SeccionListaPrecios } from '../../../utils/listaPrecios'
import type { GrupoPrecioConDetalles } from '../../../types'

/**
 * Estos tests leen el PDF REAL que arma jsPDF (sin mock): jsPDF no comprime los
 * streams, así que el texto de cada hoja está en el contenido de su página como
 * `x y Td (texto) Tj`. Así se ve lo que de verdad se imprime, en qué hoja cae, a
 * qué altura y con qué caracteres.
 */
interface TextoDibujado {
  texto: string
  /** Altura de la línea base, en mm desde el borde de arriba de la hoja. */
  y: number
}

/** jsPDF escribe en puntos con el origen abajo a la izquierda. */
const PUNTOS_POR_MM = 72 / 25.4
const ALTO_A4 = 297

function lineasPorHoja(doc: jsPDF): TextoDibujado[][] {
  const salida = doc.output()
  const objetos = new Map<number, string>()
  for (const m of salida.matchAll(/(\d+) 0 obj\r?\n([\s\S]*?)endobj/g)) objetos.set(Number(m[1]), m[2])
  const contenidos = [...salida.matchAll(/\/Type \/Page\r?\n[\s\S]*?\/Contents (\d+) 0 R/g)]
    .map(m => objetos.get(Number(m[1])) ?? '')
  expect(contenidos).toHaveLength(doc.getNumberOfPages())
  return contenidos.map(contenido =>
    [...contenido.matchAll(/BT\r?\n[\s\S]*?(-?[\d.]+) (-?[\d.]+) Td\r?\n\(((?:\\[\s\S]|[^\\)])*)\)\s*Tj/g)]
      .map(m => ({ texto: decodificar(m[3]), y: ALTO_A4 - Number(m[2]) / PUNTOS_POR_MM })),
  )
}

const textosPorHoja = (doc: jsPDF): string[][] => lineasPorHoja(doc).map(h => h.map(l => l.texto))

const ESCAPES: Record<string, string> = { n: '\n', r: '\r', t: '\t', b: '\b', f: '\f' }

/** Literal de PDF → texto. Los bytes son WinAnsi, que en Latin-1 coincide con Unicode. */
function decodificar(literal: string): string {
  return literal
    .replace(/\\([0-7]{1,3}|[\s\S])/g, (_, e: string) =>
      /^[0-7]+$/.test(e) ? String.fromCharCode(parseInt(e, 8)) : (ESCAPES[e] ?? e))
    // El formato de moneda separa "$" del número con un espacio duro.
    .replace(/\u00a0/g, ' ')
}

const FECHA = new Date('2026-10-13T12:00:00-03:00')

function grupo(id: string, nombre: string, productoIds: string[], escalas: Array<[number, number]>): GrupoPrecioConDetalles {
  return {
    id,
    nombre,
    activo: true,
    productos: productoIds.map((pid, i) => ({ id: `${id}-p${i}`, grupo_precio_id: id, producto_id: pid })),
    escalas: escalas.map(([cantidad, precio], i) => ({
      id: `${id}-e${i}`,
      grupo_precio_id: id,
      cantidad_minima: cantidad,
      precio_unitario: precio,
      activo: true,
      min_productos_distintos: 1,
    })),
    escalaMinimos: {},
  }
}

const p = (id: string, nombre: string, precio: number, categoria: string | null, subcategoria_id: string | null = null): ProductoListaPrecios =>
  ({ id, nombre, precio, activo: true, categoria, subcategoria_id })

/** Una muestra de Tucumán como la arma `armarListaPrecios`. */
function seccionesDeMuestra(): SeccionListaPrecios[] {
  return armarListaPrecios({
    productos: [
      p('156', 'ALFATUC BLANCO x 18 u', 5800, 'ALFAJORES'),
      p('157', 'ALFATUC NEGRO x 18 u', 5800, 'ALFAJORES'),
      p('140', 'CODITO COTELLA 500GRS ', 1030, 'FIDEOS', 'sub-500'),
      p('142', 'MOÑO MEDIANO COTELLA 500GRS ', 1200, 'FIDEOS', 'sub-500'),
      p('103', 'PAPAS FRITAS CEBOLLA', 2860, 'SNACKS'),
      p('104', 'PAPAS FRITAS JAMON', 2860, 'SNACKS'),
      p('102', 'PAPAS FRITAS TOM & CHE', 2860, 'SNACKS'),
      p('900', 'VINAGRE DE ALCOHOL', 1234.5, null),
    ],
    grupos: [
      grupo('37', 'Alfatuc Mayorista', ['156', '157'], [[2, 5600]]),
      grupo('83', 'ALFATUC X 10 CAJAS', ['156', '157'], [[10, 5200]]),
      grupo('11', 'FIDEO X FARDO', ['140'], [[12, 950]]),
      grupo('12', 'CODITO 1/2 FARDO', ['140'], [[6, 990]]),
      grupo('1', 'PAPAS SABORIZADAS', ['103', '104', '102'], [[18, 2350]]),
    ],
    nombresSubrubro: new Map([['sub-500', 'FIDEOS x 500 gr']]),
  })
}

describe('construirListaPreciosPdf \u2014 contenido', () => {
  it('encabezado, secciones por rubro → subrubro, tabla y pie (snapshot del texto del PDF)', () => {
    const doc = construirListaPreciosPdf({ secciones: seccionesDeMuestra(), sucursal: 'Tucuman', fecha: FECHA, logo: null })
    expect(textosPorHoja(doc)).toMatchInlineSnapshot(`
      [
        [
          "Crecer Distribuciones",
          "Lista de precios",
          "Sucursal Tucuman",
          "Precios vigentes al 13/10/2026",
          "Precios con IVA incluido",
          "Producto",
          "Precio",
          "Condición mayorista",
          "ALFAJORES",
          "ALFATUC BLANCO x 18 u",
          "$ 5.800,00",
          "Desde 2 u. $ 5.600,00 c/u",
          "Desde 10 u. $ 5.200,00 c/u",
          "surtido con 2 sabores",
          "ALFATUC NEGRO x 18 u",
          "$ 5.800,00",
          "Desde 2 u. $ 5.600,00 c/u",
          "Desde 10 u. $ 5.200,00 c/u",
          "surtido con 2 sabores",
          "FIDEOS",
          "FIDEOS x 500 gr",
          "CODITO COTELLA 500GRS",
          "$ 1.030,00",
          "Desde 6 u. $ 990,00 c/u",
          "Desde 12 u. $ 950,00 c/u",
          "MOÑO MEDIANO COTELLA 500GRS",
          "$ 1.200,00",
          "SNACKS",
          "PAPAS FRITAS CEBOLLA",
          "$ 2.860,00",
          "Desde 18 u. $ 2.350,00 c/u",
          "surtido con 3 sabores",
          "PAPAS FRITAS JAMON",
          "$ 2.860,00",
          "Desde 18 u. $ 2.350,00 c/u",
          "surtido con 3 sabores",
          "PAPAS FRITAS TOM & CHE",
          "$ 2.860,00",
          "Desde 18 u. $ 2.350,00 c/u",
          "surtido con 3 sabores",
          "Otros",
          "VINAGRE DE ALCOHOL",
          "$ 1.234,50",
          "Crecer Distribuciones",
          "Página 1 de 1",
        ],
      ]
    `)
  })

  it('con el logo, la marca va como imagen y no como texto en el encabezado', () => {
    // PNG de 1×1 px.
    const logo = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
    const doc = construirListaPreciosPdf({ secciones: seccionesDeMuestra(), sucursal: 'Tucuman', fecha: FECHA, logo })
    expect(doc.output()).toContain('/Subtype /Image')
    const [hoja] = textosPorHoja(doc)
    // Sólo queda el del pie.
    expect(hoja.filter(t => t === 'Crecer Distribuciones')).toHaveLength(1)
    expect(hoja.slice(0, 4)).toEqual([
      'Lista de precios',
      'Sucursal Tucuman',
      'Precios vigentes al 13/10/2026',
      'Precios con IVA incluido',
    ])
  })

  it('el logo real va comprimido: el PDF no pesa por la imagen', () => {
    // Sin comprimir, los 768 × 502 px del logo son dos streams de 385 KB (color y
    // transparencia) y la lista de Tucumán pesaba 858 KB.
    const aqui = path.dirname(fileURLToPath(import.meta.url))
    const png = fs.readFileSync(path.resolve(aqui, '../../../assets/marca/crecer-logo.png'))
    const logo = `data:image/png;base64,${png.toString('base64')}`
    const doc = construirListaPreciosPdf({ secciones: seccionesDeMuestra(), sucursal: 'Tucuman', fecha: FECHA, logo })
    expect(doc.output().length).toBeLessThan(250_000)
  })

  it('una sucursal sin condiciones mayoristas (Taco Pozo) sale sólo con precios', () => {
    const secciones = armarListaPrecios({
      productos: [p('1', 'AGUA 2L', 900, 'AGUAS'), p('2', 'GASEOSA 2L', 1500, 'GASEOSAS')],
      grupos: [],
    })
    const doc = construirListaPreciosPdf({ secciones, sucursal: 'Taco Pozo', fecha: FECHA, logo: null })
    const [hoja] = textosPorHoja(doc)
    expect(hoja).toEqual(expect.arrayContaining(['Sucursal Taco Pozo', 'AGUA 2L', '$ 900,00', 'GASEOSA 2L', '$ 1.500,00']))
    expect(hoja.some(t => t.startsWith('Desde'))).toBe(false)
  })

  it('sin productos lo dice en vez de entregar una hoja vacía', () => {
    const doc = construirListaPreciosPdf({ secciones: [], sucursal: 'Tucuman', fecha: FECHA, logo: null })
    expect(textosPorHoja(doc)[0]).toContain('No hay productos activos con precio cargado.')
  })
})

describe('construirListaPreciosPdf \u2014 paginación', () => {
  // 3 rubros × 50 productos, cada uno con 3 líneas de condición: varias hojas.
  const RUBROS = ['ALFA', 'BETA', 'GAMMA']
  const productos: ProductoListaPrecios[] = []
  const grupos: GrupoPrecioConDetalles[] = []
  RUBROS.forEach((rubro, r) => {
    for (let i = 0; i < 50; i++) {
      const id = `${r}${String(i).padStart(3, '0')}`
      productos.push(p(id, `PROD ${id}`, 10000 + Number(id), rubro))
      grupos.push(grupo(`g${id}`, `G ${id}`, [id, `x${id}`], [[6, 9000 + Number(id)], [12, 8000 + Number(id)]]))
      productos.push(p(`x${id}`, `ZZZ SABOR ${id}`, 99999, null))
    }
  })
  const secciones = armarListaPrecios({ productos, grupos })
  const doc = construirListaPreciosPdf({ secciones, sucursal: 'Tucuman', fecha: FECHA, logo: null })
  const hojas = textosPorHoja(doc)
  const hojaDe = (texto: string) => hojas.findIndex(h => h.includes(texto))

  it('ocupa varias hojas, cada una con su pie "Página N de T"', () => {
    expect(hojas.length).toBeGreaterThan(3)
    hojas.forEach((hoja, i) => expect(hoja).toContain(`Página ${i + 1} de ${hojas.length}`))
  })

  it('ninguna fila se corta: el nombre, el precio y toda la condición de cada producto caen en la misma hoja', () => {
    for (const seccion of secciones) {
      for (const fila of seccion.filas) {
        const hoja = hojaDe(fila.nombre)
        expect(hoja).toBeGreaterThanOrEqual(0)
        for (const linea of fila.condicion) {
          expect(hojas[hoja]).toContain(linea.replace(/\u00a0/g, ' '))
        }
      }
    }
  })

  it('las hojas siguientes repiten un encabezado corto y las columnas de la tabla', () => {
    hojas.slice(1).forEach(hoja => {
      expect(hoja[0]).toBe('Crecer Distribuciones · Lista de precios · Sucursal Tucuman')
      expect(hoja).toContain('Precios vigentes al 13/10/2026 · Precios con IVA incluido')
      expect(hoja).toEqual(expect.arrayContaining(['Producto', 'Precio', 'Condición mayorista']))
    })
  })

  it('el título de un rubro cae en la misma hoja que su primer producto', () => {
    for (const seccion of secciones) {
      expect(hojas[hojaDe(seccion.filas[0].nombre)]).toContain(seccion.rubro)
    }
  })

  it('un rubro que sigue en otra hoja lo avisa', () => {
    const continuadas = hojas.filter(h => h.some(t => t.endsWith('(continuación)')))
    expect(continuadas.length).toBeGreaterThan(0)
  })

  it('nada del cuerpo baja hasta el pie: lo que no entra pasa a la hoja siguiente', () => {
    // El papel termina en 297 mm y el pie va en 288 con su línea en 284: una fila
    // dibujada más abajo de 279 se pisa con el pie o directamente no se imprime.
    for (const hoja of lineasPorHoja(doc)) {
      const pie = hoja.slice(-2)
      expect(pie[0].texto).toBe('Crecer Distribuciones')
      expect(pie[1].texto).toMatch(/^Página \d+ de \d+$/)
      for (const linea of hoja.slice(0, -2)) expect(linea.y).toBeLessThanOrEqual(279)
    }
  })
})

describe('construirListaPreciosPdf — títulos', () => {
  it('una hoja que empieza con un subrubro dice de qué rubro viene', () => {
    // FIDEOS x 5 kg ocupa una cantidad variable de filas: alguna vuelta deja a
    // FIDEOS x 500 gr arrancando la hoja siguiente, lejos del título FIDEOS.
    let vistas = 0
    for (let anteriores = 1; anteriores <= 45; anteriores++) {
      const productos = [
        ...Array.from({ length: anteriores }, (_, i) => p(`a${i}`, `CINTA ${String(i).padStart(2, '0')}`, 1000 + i, 'FIDEOS', 'sub-5k')),
        p('z1', 'CODITO', 500, 'FIDEOS', 'sub-500'),
      ]
      const hojas = textosPorHoja(construirListaPreciosPdf({
        secciones: armarListaPrecios({
          productos,
          grupos: [],
          nombresSubrubro: new Map([['sub-5k', 'FIDEOS x 5 kg'], ['sub-500', 'FIDEOS x 500 gr']]),
        }),
        sucursal: 'Tucuman',
        fecha: FECHA,
        logo: null,
      }))
      const hoja = hojas.find(h => h.includes('FIDEOS x 500 gr'))!
      expect(hoja).toContain('CODITO')
      if (!hoja.includes('FIDEOS')) {
        // "FIDEOS (continuación)", o "FIDEOS · FIDEOS x 5 kg (continuación)" si
        // la hoja arrancó con filas del subrubro anterior.
        expect(
          hoja.some(t => t.startsWith('FIDEOS') && t.endsWith('(continuación)')),
          `con ${anteriores} filas antes: ${JSON.stringify(hoja)}`,
        ).toBe(true)
        if (hoja.includes('FIDEOS (continuación)')) vistas++
      }
    }
    // Control: el caso de verdad se dio en alguna vuelta.
    expect(vistas).toBeGreaterThan(0)
  })

  it('un título nunca queda solo al pie de una hoja: baja con su primera fila', () => {
    // Según cuántas filas tenga el rubro anterior, el siguiente empieza a otra
    // altura; alguna de estas vueltas deja lugar para el título pero no para la fila.
    for (let anteriores = 1; anteriores <= 45; anteriores++) {
      const productos = [
        ...Array.from({ length: anteriores }, (_, i) => p(`a${i}`, `ALFA ${String(i).padStart(2, '0')}`, 1000 + i, 'ALFA')),
        p('z1', 'ZETA PRIMERO', 500, 'ZETA'),
        p('z2', 'ZETA SEGUNDO', 600, 'ZETA'),
      ]
      const doc = construirListaPreciosPdf({
        secciones: armarListaPrecios({ productos, grupos: [] }),
        sucursal: 'Tucuman',
        fecha: FECHA,
        logo: null,
      })
      const hojas = textosPorHoja(doc)
      const hojaDe = (texto: string) => hojas.findIndex(h => h.includes(texto))
      expect(hojaDe('ZETA'), `con ${anteriores} filas antes`).toBe(hojaDe('ZETA PRIMERO'))
    }
  })
})

describe('textoPdf', () => {
  it('cambia raya, comillas tipográficas y puntos suspensivos por su par ASCII', () => {
    expect(textoPdf('Agua \u2014 sin gas \u2013 2L \u201cclásica\u201d \u2018x\u2019\u2026')).toBe('Agua - sin gas - 2L "clásica" \'x\'...')
  })

  it('conserva tildes, ñ, "·" y el espacio duro, y saca lo que la fuente no tiene', () => {
    expect(textoPdf('MOÑO Condición · $\u00a01.234,50 \u{1F35D}')).toBe('MOÑO Condición · $\u00a01.234,50 ')
  })
})
