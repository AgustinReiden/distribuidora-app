import { describe, it, expect, beforeEach, vi } from 'vitest'
import {
  itemRegaloDosTokens,
  itemRegaloEnteroGranadina,
  itemRegaloFraccion,
  itemVenta,
  pedido,
} from './fixtures'

/**
 * jsPDF de mentira: registra el texto dibujado con su Y y el alto de página con
 * el que se creó el documento. El alto ES el formato del papel, así que lo que
 * se dibuje por debajo no se imprime nunca — de ahí el test de que todo entre.
 */
const capturado = vi.hoisted(() => ({ textos: [], alto: 0 }))

// Ancho útil del ticket a font 8 medido en caracteres. Alcanza para que el
// wrap del mock se parezca al real; el código no depende del número exacto.
const CHARS_POR_MM = 0.64

vi.mock('jspdf', () => ({
  jsPDF: class {
    constructor({ format }) {
      capturado.alto = format[1]
    }

    setFont() {}
    setFontSize(size) { this.fontSize = size }
    setTextColor() {}
    setDrawColor() {}
    setLineWidth() {}
    line() {}
    rect() {}
    save() {}

    splitTextToSize(texto, anchoMm) {
      const max = Math.max(Math.floor(anchoMm * CHARS_POR_MM), 10)
      const palabras = String(texto).split(' ')
      const lineas = ['']
      palabras.forEach((palabra) => {
        const actual = lineas[lineas.length - 1]
        const candidata = actual ? `${actual} ${palabra}` : palabra
        if (candidata.length <= max || !actual) lineas[lineas.length - 1] = candidata
        else lineas.push(palabra)
      })
      return lineas
    }

    text(texto, x, y) {
      capturado.textos.push({ texto, y })
    }
  },
}))

const { generarOrdenPreparacion } = await import('../ordenPreparacion')

const lineas = () => capturado.textos.map((t) => t.texto)

beforeEach(() => {
  capturado.textos = []
  capturado.alto = 0
})

describe('generarOrdenPreparacion', () => {
  it('marca el regalo de fracción como sueltas y no como unidades de venta', () => {
    generarOrdenPreparacion([pedido([itemRegaloFraccion()])])
    const texto = lineas().join(' ')

    // El bug: "392x Manaos Pomelo 3L" hacía preparar 392 unidades de venta.
    expect(texto).toContain('392x Botellas Manaos Pomelo 3L')
    expect(texto).toContain('(SUELTAS, NO FARDO = 65 FARDOS + 2)')
    expect(texto).toContain('(REGALO)')
  })

  it('usa el factor congelado y no el vivo de la promo', () => {
    generarOrdenPreparacion([pedido([itemRegaloFraccion()])])
    const texto = lineas().join(' ')

    // Congelado 6 → 65 fardos + 2. Vivo 12 → 32 fardos + 8: medio camión.
    expect(texto).toContain('65 FARDOS + 2')
    expect(texto).not.toContain('32 FARDOS')
  })

  it('marca el regalo de unidad entera con su aclaración de bulto', () => {
    generarOrdenPreparacion([pedido([itemRegaloEnteroGranadina()])])
    const texto = lineas().join(' ')

    expect(texto).toContain('12x Granadina 1L (2 FARDOS) (REGALO)')
    expect(texto).not.toContain('SUELTAS')
  })

  it('descarta el conteo inicial de una descripción de dos tokens', () => {
    generarOrdenPreparacion([pedido([itemRegaloDosTokens()])])
    const texto = lineas().join(' ')

    // "2 Granadina" describe un bloque, no las 3 botellas de la línea.
    expect(texto).toContain('3x Granadina')
    expect(texto).not.toContain('3x 2 Granadina')
  })

  it('la línea de venta no lleva marca de regalo', () => {
    generarOrdenPreparacion([pedido([itemVenta()])])
    const texto = lineas().join(' ')

    expect(texto).toContain('12x Granadina 1L (2 FARDOS)')
    expect(texto).not.toContain('REGALO')
  })

  it('el alto reservado alcanza para las líneas que envuelven', () => {
    generarOrdenPreparacion([
      pedido([itemVenta(), itemRegaloFraccion(), itemRegaloEnteroGranadina()]),
      pedido([itemRegaloFraccion(), itemRegaloDosTokens()], { id: 14 }),
    ])

    const ultimaY = Math.max(...capturado.textos.map((t) => t.y))
    expect(capturado.alto).toBeGreaterThan(ultimaY)
  })
})
