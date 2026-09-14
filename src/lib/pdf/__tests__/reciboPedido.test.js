import { describe, it, expect, beforeEach, vi } from 'vitest'
import { itemVenta, pedido } from './fixtures'

/**
 * jsPDF de mentira multi-pagina: registra cada texto dibujado junto con la
 * pagina en la que cayo (addPage/setPage la mueven), para poder afirmar en
 * que hoja termino un bloque. El alto de la A4 ES el papel: lo que se dibuje
 * despues del pie sin haber pedido una hoja nueva no se imprime nunca.
 */
const capturado = vi.hoisted(() => ({ pages: [[]], currentPage: 0 }))

const CHARS_POR_MM = 0.64

vi.mock('jspdf', () => ({
  jsPDF: class {
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
    getTextWidth(texto) { return String(texto).length * 2 }

    addPage() {
      capturado.pages.push([])
      capturado.currentPage = capturado.pages.length - 1
    }

    setPage(n) {
      capturado.currentPage = n - 1
    }

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

    text(texto) {
      const items = Array.isArray(texto) ? texto : [texto]
      items.forEach((t) => capturado.pages[capturado.currentPage].push(t))
    }
  },
}))

const { generarReciboPedido } = await import('../reciboPedido')

const paginaDe = (texto) => capturado.pages.findIndex((p) => p.some((t) => t.includes(texto)))

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
