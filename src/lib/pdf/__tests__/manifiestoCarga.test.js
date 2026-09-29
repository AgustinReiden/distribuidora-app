import { describe, it, expect, beforeEach, vi } from 'vitest'
import { itemVenta, pedido } from './fixtures'

// Mismo motivo que hojaRutaOptimizada.fecha.test.js: horarioParaRutear arrastra
// el cliente de supabase.
vi.mock('../../supabase', () => ({ supabase: {} }))

const capturado = vi.hoisted(() => ({ textos: [], archivos: [] }))

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
    addPage() {}
    save(nombre) { capturado.archivos.push(nombre) }
    splitTextToSize(texto) { return [String(texto)] }
    text(texto) {
      const items = Array.isArray(texto) ? texto : [texto]
      items.forEach((t) => capturado.textos.push(t))
    }
  },
}))

const { generarHojaRutaOptimizada, generarManifiestoCarga } = await import('../hojaRutaOptimizada')

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
