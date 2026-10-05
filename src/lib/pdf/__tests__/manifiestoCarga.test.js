import { describe, it, expect, beforeEach, vi } from 'vitest'
import { itemVenta, pedido } from './fixtures'

// Mismo motivo que hojaRutaOptimizada.fecha.test.js: horarioParaRutear arrastra
// el cliente de supabase.
vi.mock('../../supabase', () => ({ supabase: {} }))

const capturado = vi.hoisted(() => ({ textos: [], archivos: [] }))
// Marca de salto de hoja en la secuencia de textos dibujados.
const PAGINA = '<<pagina>>'

vi.mock('jspdf', () => ({
  jsPDF: class {
    setFont() {}
    setFontSize() {}
    setTextColor() {}
    setDrawColor() {}
    setLineWidth() {}
    setFillColor() {}
    line() {}
    rect() {}
    roundedRect() {}
    addPage() { capturado.textos.push(PAGINA) }
    save(nombre) { capturado.archivos.push(nombre) }
    splitTextToSize(texto) { return [String(texto)] }
    getTextWidth(texto) { return String(texto).length * 2 }
    text(texto) {
      const items = Array.isArray(texto) ? texto : [texto]
      items.forEach((t) => capturado.textos.push(t))
    }
  },
}))

const { generarHojaRutaOptimizada, generarManifiestoCarga, generarHojaRutaYManifiesto } = await import('../hojaRutaOptimizada')

beforeEach(() => {
  capturado.textos = []
  capturado.archivos = []
})

const transportista = { nombre: 'Juan Perez' }
const pedidos = [pedido([itemVenta({ producto: { id: 9, nombre: 'Granadina 1L', categoria: 'Gaseosas', subcategoria_id: 's1' } })])]

describe('manifiesto de carga separado de la hoja de ruta (#829)', () => {
  it('la hoja de ruta ya no incluye el manifiesto', () => {
    generarHojaRutaOptimizada(transportista, pedidos, { fecha: '2026-01-05' })

    const texto = capturado.textos.join(' | ')
    expect(texto).toContain('HOJA DE RUTA')
    expect(texto).toContain('CIERRE DE JORNADA')
    expect(texto).not.toContain('Total de productos a cargar')
    expect(texto).not.toContain('Conforme de carga')
    expect(capturado.archivos[0]).toMatch(/^ruta-/)
  })

  it('la parada no pide firma: la firma va en la comanda; el cierre de jornada la conserva', () => {
    generarHojaRutaOptimizada(transportista, [pedido([itemVenta()], { forma_pago: 'efectivo' })], { fecha: '2026-01-05' })

    const firmas = capturado.textos.filter((t) => String(t).includes('Firma'))
    expect(firmas).toHaveLength(1)
    expect(firmas[0]).toMatch(/^Firma: _+$/)
    expect(capturado.textos).toContain('Efvo')
  })

  it('el manifiesto es un PDF propio, con su nombre de archivo y agrupado', () => {
    generarManifiestoCarga(transportista, pedidos, { fecha: '2026-01-05' }, { nombresSubrubro: { s1: 'Cola' } })

    const texto = capturado.textos.join(' | ')
    expect(texto).toContain('MANIFIESTO DE CARGA')
    expect(texto).toContain('GASEOSAS')
    expect(texto).toContain('Cola')
    expect(texto).toContain('Granadina 1L')
    expect(texto).toContain('Conforme de carga')
    expect(texto).toContain('05/01/2026')
    expect(texto).not.toContain('HOJA DE RUTA')
    expect(texto).not.toContain('CIERRE DE JORNADA')
    expect(capturado.archivos).toHaveLength(1)
    expect(capturado.archivos[0]).toMatch(/^manifiesto-carga-juan-perez-/)
  })
})

describe('hoja de ruta + manifiesto en un solo PDF', () => {
  const opciones = { nombresSubrubro: { s1: 'Cola' } }

  it('un solo archivo: la hoja con su cierre y, en hoja nueva, el manifiesto', () => {
    generarHojaRutaYManifiesto(transportista, pedidos, { fecha: '2026-01-05' }, opciones)

    const t = capturado.textos
    expect(capturado.archivos).toHaveLength(1)
    expect(capturado.archivos[0]).toMatch(/^ruta-manifiesto-juan-perez-/)

    const cierre = t.indexOf('CIERRE DE JORNADA')
    const salto = t.indexOf(PAGINA, cierre)
    const manifiesto = t.indexOf('MANIFIESTO DE CARGA')
    expect(t.indexOf('HOJA DE RUTA')).toBe(0)
    expect(cierre).toBeGreaterThan(0)
    // El manifiesto arranca en una hoja nueva, después del cierre.
    expect(salto).toBeGreaterThan(cierre)
    expect(manifiesto).toBeGreaterThan(salto)
    expect(t.slice(manifiesto)).toContain('GASEOSAS')
    expect(t.slice(manifiesto)).toContain('Conforme de carga - Firma: __________')
  })

  it('un manifiesto largo pagina con su propio encabezado, no con el de la hoja de ruta', () => {
    const muchos = Array.from({ length: 140 }, (_, i) => itemVenta({
      producto_id: 1000 + i,
      producto: { id: 1000 + i, nombre: `Producto ${i}`, categoria: 'Gaseosas', subcategoria_id: 's1' },
    }))
    generarHojaRutaYManifiesto(transportista, [pedido(muchos)], { fecha: '2026-01-05' }, opciones)

    const t = capturado.textos
    const inicioManifiesto = t.indexOf('MANIFIESTO DE CARGA')
    const paginasManifiesto = t.slice(inicioManifiesto).join('|').split(PAGINA).map((p) => p.split('|').filter(Boolean))
    // 140 filas no entran en las 3 columnas de una hoja.
    expect(paginasManifiesto.length).toBeGreaterThan(1)
    paginasManifiesto.forEach((pagina) => {
      expect(pagina[0]).toBe('MANIFIESTO DE CARGA')
      expect(pagina).not.toContain('HOJA DE RUTA')
    })
    // Ninguna fila se pierde en el salto.
    expect(t.filter((x) => /^Producto \d+$/.test(x)).length).toBeGreaterThanOrEqual(140)
    expect(t[t.length - 1]).toBe('Conforme de carga - Firma: __________')
  })
})

describe('hoja de ruta: deuda anterior dentro de la ruta (#936)', () => {
  it('un pedido anterior del mismo cliente que viaja en la ruta no va como deuda del otro', () => {
    const anterior = pedido([itemVenta()], { id: 15, total: 20000 })
    const posterior = pedido([itemVenta()], {
      id: 20,
      deuda_previa: 50000,
      deuda_previa_detalle: [
        { id: 10, fecha: '2026-09-20', monto: 30000 },
        { id: 15, fecha: '2026-10-05', monto: 20000 },
      ],
    })

    generarHojaRutaOptimizada(transportista, [anterior, posterior], { fecha: '2026-10-06' })

    const t = capturado.textos
    const deuda = t.indexOf('Deuda anterior:')
    expect(deuda).toBeGreaterThan(-1)
    expect(t[deuda + 1]).toContain('30.000')
    expect(t.filter((x) => x === 'Deuda anterior:')).toHaveLength(1)
  })

  it('si la única boleta adeudada viaja en la ruta, no hay línea de deuda', () => {
    const anterior = pedido([itemVenta()], { id: 15, total: 20000 })
    const posterior = pedido([itemVenta()], {
      id: 20,
      deuda_previa: 20000,
      deuda_previa_detalle: [{ id: 15, fecha: '2026-10-05', monto: 20000 }],
    })

    generarHojaRutaOptimizada(transportista, [anterior, posterior], { fecha: '2026-10-06' })

    expect(capturado.textos).not.toContain('Deuda anterior:')
  })
})
