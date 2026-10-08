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
const capturado = vi.hoisted(() => ({ pages: [[] as string[]], currentPage: 0, alto: 0, maxY: 0 }))

vi.mock('jspdf', () => ({
  jsPDF: class {
    internal: { getNumberOfPages: () => number }

    constructor(opts?: { format?: unknown }) {
      capturado.pages = [[]]
      capturado.currentPage = 0
      // Alto del papel de la comanda (format [ancho, alto]) y el texto mas bajo
      // dibujado: lo que caiga por debajo del alto no sale impreso.
      capturado.alto = Array.isArray(opts?.format) ? Number(opts.format[1]) : 0
      capturado.maxY = 0
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
    autoPrint() {}
    output() { return 'blob:comandas' }
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

    text(texto: string | string[], _x?: number, y?: number) {
      if (typeof y === 'number') capturado.maxY = Math.max(capturado.maxY, y)
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

describe('generarReciboPedido — comanda: firma del cliente', () => {
  it('lleva la linea de firma y aclaracion', () => {
    generarReciboPedido(pedido([itemVenta()]), {}, { formato: 'comanda' })

    expect(capturado.pages.flat()).toContain('Firma y aclaración')
  })

  it('el alto del ticket es lo dibujado mas el margen: ni corta el pie ni deja papel de sobra (#937)', () => {
    const p = pedido(Array.from({ length: 12 }, () => itemVenta()), {
      notas: 'Dejar en la puerta de atras',
      estado_pago: 'parcial',
      monto_pagado: 1000,
      deuda_previa: 30000,
      deuda_previa_detalle: [
        { id: 1, fecha: '2026-09-01', monto: 10000 },
        { id: 2, fecha: '2026-09-08', monto: 20000 },
      ],
    })

    generarReciboPedido(p, {}, { formato: 'comanda' })

    expect(capturado.pages.flat()).toContain('DOCUMENTO NO VALIDO COMO FACTURA')
    expect(capturado.maxY).toBeLessThanOrEqual(capturado.alto)
    // Se mide con el mismo dibujo: el pie queda a no mas del margen inferior
    // (5 mm, redondeado hacia arriba) del borde. Con la estimacion vieja
    // sobraban varios centimetros y sacarle la reserva a una seccion no se notaba.
    expect(capturado.alto - capturado.maxY).toBeLessThanOrEqual(6)
  })
})

describe('generarComandasMultiples — deuda anterior dentro de la tanda (#936)', () => {
  it('un pedido anterior impreso en la misma tanda no se suma a la deuda del otro', async () => {
    vi.stubGlobal('open', vi.fn())
    const { generarComandasMultiples } = await import('../reciboPedido')
    const anterior = pedido([itemVenta()], { id: 15, total: 20000 })
    const posterior = pedido([itemVenta()], {
      id: 20,
      deuda_previa: 50000,
      deuda_previa_detalle: [
        { id: 10, fecha: '2026-09-20', monto: 30000 },
        { id: 15, fecha: '2026-10-05', monto: 20000 },
      ],
    })

    generarComandasMultiples([anterior, posterior])

    const texto = capturado.pages.flat()
    // Sólo queda la boleta #10, que no viaja: $30.000, no $50.000.
    // Por línea exacta: "Recibo #15 05/10/2026" también contiene el texto.
    expect(texto).toContain('#10 20/09')
    expect(texto).not.toContain('#15 05/10')
    expect(texto.filter((t) => t.includes('50.000'))).toHaveLength(0)
    vi.unstubAllGlobals()
  })
})

describe('generarReciboPedido — vale blanco (consumo interno, N13)', () => {
  const vb = (over: Record<string, unknown> = {}) =>
    pedido([itemVenta({ precio_unitario: 812.5 })], {
      tipo_factura: 'VB',
      estado: 'entregado',
      estado_pago: 'pagado',
      forma_pago: 'efectivo',
      monto_pagado: 9750,
      total: 9750,
      ...over,
    })

  it('A4: leyenda del vale en lugar de PAGADO, sin bloque de pago, ítems a costo y "Recibí conforme"', () => {
    generarReciboPedido(vb(), {}, { formato: 'a4' })
    const texto = capturado.pages.flat()

    expect(texto).toContain('VALE BLANCO - CONSUMO INTERNO')
    expect(texto).toContain('VALE BLANCO')
    expect(texto).toContain('COSTO U.')
    expect(texto).toContain('TOTAL A COSTO:')
    expect(texto).toContain('Recibí conforme')
    expect(texto).not.toContain('PAGADO')
    expect(texto).not.toContain('PENDIENTE')
    expect(texto).not.toContain('INFORMACION DE PAGO')
    expect(texto.some(t => t.startsWith('Forma de pago'))).toBe(false)
    expect(texto.some(t => t.startsWith('Monto pagado'))).toBe(false)
  })

  it('comanda: leyenda, sin forma ni estado de pago, firma "Recibí conforme" y el pie entra en el ticket', () => {
    generarReciboPedido(vb({ notas: 'Para el local de ruta 9' }), {}, { formato: 'comanda' })
    const texto = capturado.pages.flat()

    expect(texto).toContain('VALE BLANCO - CONSUMO INTERNO')
    expect(texto).toContain('A COSTO:')
    expect(texto).toContain('Recibí conforme')
    expect(texto).not.toContain('Firma y aclaración')
    expect(texto).not.toContain('PAGADO')
    expect(texto).not.toContain('Efectivo')
    expect(capturado.maxY).toBeLessThanOrEqual(capturado.alto)
  })

  it('un ZZ pagado sigue igual: PAGADO, forma de pago y "Firma y aclaración"', () => {
    generarReciboPedido(pedido([itemVenta()], { tipo_factura: 'ZZ', estado_pago: 'pagado', forma_pago: 'efectivo' }), {}, { formato: 'comanda' })
    const texto = capturado.pages.flat()
    expect(texto).toContain('PAGADO')
    expect(texto).toContain('Efectivo')
    expect(texto).toContain('Firma y aclaración')
    expect(texto).not.toContain('VALE BLANCO - CONSUMO INTERNO')
  })
})
