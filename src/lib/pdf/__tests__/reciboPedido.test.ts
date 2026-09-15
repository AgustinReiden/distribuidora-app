import { describe, it, expect, beforeEach, vi } from 'vitest'
import {
  itemRegaloDosTokens,
  itemRegaloEnteroGranadina,
  itemRegaloFraccion,
  itemVenta,
  pedido,
} from './fixtures'

/**
 * jsPDF de mentira multi-pagina: registra cada texto dibujado junto con la
 * pagina en la que cayo (addPage/setPage la mueven), para poder afirmar en
 * que hoja termino un bloque. El alto de la A4 ES el papel: lo que se dibuje
 * despues del pie sin haber pedido una hoja nueva no se imprime nunca.
 */
const capturado = vi.hoisted(() => ({ pages: [[] as string[]], currentPage: 0 }))

vi.mock('jspdf', () => ({
  jsPDF: class {
    internal: { getNumberOfPages: () => number }

    constructor() {
      capturado.pages = [[]]
      capturado.currentPage = 0
      this.internal = { getNumberOfPages: () => capturado.pages.length }
    }

    setFont() {}
    setFontSize() {}
    setTextColor() {}
    setDrawColor() {}
    setFillColor() {}
    setLineWidth() {}
    line() {}
    rect() {}
    roundedRect() {}
    save() {}
    getTextWidth(texto: string) { return String(texto).length * 2 }

    addPage() {
      capturado.pages.push([])
      capturado.currentPage = capturado.pages.length - 1
    }

    setPage(n: number) {
      capturado.currentPage = n - 1
    }

    // No envuelve: en los tests de unidad/regalo importa que la linea completa
    // llegue entera a `text()` sin cortarse a mitad de frase segun el ancho
    // exacto de columna, que no es lo que estos tests verifican.
    splitTextToSize(texto: string) {
      return [String(texto)]
    }

    text(texto: string | string[]) {
      const items = Array.isArray(texto) ? texto : [texto]
      items.forEach((t) => capturado.pages[capturado.currentPage].push(t))
    }
  },
}))

const { generarReciboPedido } = await import('../reciboPedido')

const paginaDe = (texto: string) => capturado.pages.findIndex((p) => p.some((t) => t.includes(texto)))

beforeEach(() => {
  capturado.pages = [[]]
  capturado.currentPage = 0
})

describe('generarReciboPedido — formato A4, paginación', () => {
  it('con 15 items, el bloque de pago (Saldo pendiente) cae en la segunda página', () => {
    const items = Array.from({ length: 15 }, () => itemVenta())
    const p = pedido(items, { estado_pago: 'parcial', monto_pagado: 1000, total: 100000 })

    generarReciboPedido(p, {}, { formato: 'a4' })

    expect(capturado.pages.length).toBeGreaterThan(1)
    expect(paginaDe('Saldo pendiente')).toBe(1)
    // El total y la informacion de pago viajan juntos con el saldo, no se
    // quedan pisados por el pie en la primera hoja.
    expect(paginaDe('TOTAL:')).toBe(1)
  })

  it('con pocos items, todo entra en una sola página', () => {
    const p = pedido([itemVenta()], { estado_pago: 'parcial', monto_pagado: 1000, total: 100000 })

    generarReciboPedido(p, {}, { formato: 'a4' })

    expect(capturado.pages.length).toBe(1)
    expect(paginaDe('Saldo pendiente')).toBe(0)
  })
})

describe('generarReciboPedido — formato comanda, parada de cambio', () => {
  it('sin el detalle del cambio (pedido.cambio ausente) no imprime el banner', () => {
    // canal='cambio' sin el embed cambio:recorrido_cambios: pasa en la
    // comanda individual de PedidoCard, que usa PEDIDO_SELECT sin ese join.
    const p = pedido([itemVenta()], { canal: 'cambio' })

    generarReciboPedido(p, {}, { formato: 'comanda' })

    const textoCompleto = capturado.pages.flat().join(' ')
    expect(textoCompleto).not.toContain('CAMBIO / DEVOLUCION')
  })

  it('con el detalle del cambio presente, imprime el banner y el detalle', () => {
    const p = pedido([itemVenta()], {
      canal: 'cambio',
      cambio: {
        cantidad_devuelta: 2,
        producto_devuelto_nombre: 'Coca 2L',
        cantidad_entregada: 2,
        producto_entregado_nombre: 'Sprite 2L',
      },
    })

    generarReciboPedido(p, {}, { formato: 'comanda' })

    const textoCompleto = capturado.pages.flat().join(' ')
    expect(textoCompleto).toContain('CAMBIO / DEVOLUCION')
    expect(textoCompleto).toContain('Retirar: 2x Coca 2L')
    expect(textoCompleto).toContain('Entregar: 2x Sprite 2L')
  })
})

describe('generarReciboPedido — comanda: fecha/hora del encabezado', () => {
  it('usa la hora real de created_at, no las 12:00 de una fecha date-only', () => {
    const p = pedido([itemVenta()], { fecha: '2026-03-05', created_at: '2026-03-05T08:30:00Z' })

    generarReciboPedido(p, {}, { formato: 'comanda' })

    const textoCompleto = capturado.pages.flat().join(' ')
    expect(textoCompleto).not.toContain('12:00')
  })

  it('sin created_at, una fecha date-only no muestra hora inventada', () => {
    const p = pedido([itemVenta()], { fecha: '2026-03-05', created_at: undefined })

    generarReciboPedido(p, {}, { formato: 'comanda' })

    const textoCompleto = capturado.pages.flat().join(' ')
    expect(textoCompleto).not.toContain('12:00')
    expect(textoCompleto).toContain('05/03/2026')
  })
})

/**
 * #591 arregló hojaRutaOptimizada y ordenPreparacion: la unidad de un regalo
 * de fracción tiene que leer el factor CONGELADO al crear la línea (mig 212),
 * no el vivo de la promo. reciboPedido armaba su propia línea con
 * `descripcion_regalo` y nunca leía ningún factor, así que un regalo fraccion
 * salía como "392x Manaos Pomelo 3L (REGALO)" sin aclarar que son botellas —
 * el depósito lo hubiese preparado como 392 unidades de venta. Estos tests
 * verifican que reciboPedido ahora arma la línea con lineaItemImpresion,
 * igual que los otros dos PDFs (#592).
 */
describe('generarReciboPedido — unidad del regalo de fracción (#591/#592)', () => {
  it('A4: aclara que la cantidad esta en subunidades con el factor congelado, no el vivo', () => {
    const p = pedido([itemRegaloFraccion()])

    generarReciboPedido(p, {}, { formato: 'a4' })

    const textoCompleto = capturado.pages.flat().join(' ')
    // Congelado 6 -> 65 fardos + 2. Vivo (promocion.unidades_por_bloque) 12 -> 32 fardos + 8.
    expect(textoCompleto).toContain('Botellas Manaos Pomelo 3L (SUELTAS, NO FARDO = 65 FARDOS + 2) (REGALO)')
    expect(textoCompleto).not.toContain('32 FARDOS')
  })

  it('comanda: aclara que la cantidad esta en subunidades con el factor congelado, no el vivo', () => {
    const p = pedido([itemRegaloFraccion()])

    generarReciboPedido(p, {}, { formato: 'comanda' })

    const textoCompleto = capturado.pages.flat().join(' ')
    expect(textoCompleto).toContain('392x Botellas Manaos Pomelo 3L (SUELTAS, NO FARDO = 65 FARDOS + 2) (REGALO)')
    expect(textoCompleto).not.toContain('32 FARDOS')
  })

  it('A4: un regalo de unidad entera lleva la aclaracion de bulto del producto', () => {
    const p = pedido([itemRegaloEnteroGranadina()])

    generarReciboPedido(p, {}, { formato: 'a4' })

    const textoCompleto = capturado.pages.flat().join(' ')
    expect(textoCompleto).toContain('Granadina 1L (2 FARDOS) (REGALO)')
    expect(textoCompleto).not.toContain('SUELTAS')
  })

  it('comanda: un regalo de unidad entera lleva la aclaracion de bulto del producto', () => {
    const p = pedido([itemRegaloEnteroGranadina()])

    generarReciboPedido(p, {}, { formato: 'comanda' })

    const textoCompleto = capturado.pages.flat().join(' ')
    expect(textoCompleto).toContain('12x Granadina 1L (2 FARDOS) (REGALO)')
    expect(textoCompleto).not.toContain('SUELTAS')
  })

  it('A4: descarta el conteo inicial de una descripcion de regalo de dos tokens', () => {
    const p = pedido([itemRegaloDosTokens()])

    generarReciboPedido(p, {}, { formato: 'a4' })

    // La columna CANT. lleva la cantidad de la linea (3); el nombre no repite
    // el conteo de bloque de la descripcion de la promo ("2 Granadina" describe
    // UN bloque, no las 3 botellas de la linea).
    expect(capturado.pages.flat()).toContain('3')
    const textoCompleto = capturado.pages.flat().join(' ')
    expect(textoCompleto).toContain('Granadina (SUELTAS, NO FARDO) (REGALO)')
    expect(textoCompleto).not.toContain('2 Granadina')
  })

  it('A4: la linea de venta no lleva marca de regalo', () => {
    const p = pedido([itemVenta()])

    generarReciboPedido(p, {}, { formato: 'a4' })

    const textoCompleto = capturado.pages.flat().join(' ')
    expect(textoCompleto).toContain('Granadina 1L (2 FARDOS)')
    expect(textoCompleto).not.toContain('REGALO')
  })

  it('comanda: la linea de venta no lleva marca de regalo', () => {
    const p = pedido([itemVenta()])

    generarReciboPedido(p, {}, { formato: 'comanda' })

    const textoCompleto = capturado.pages.flat().join(' ')
    expect(textoCompleto).toContain('12x Granadina 1L (2 FARDOS)')
    expect(textoCompleto).not.toContain('REGALO')
  })
})
