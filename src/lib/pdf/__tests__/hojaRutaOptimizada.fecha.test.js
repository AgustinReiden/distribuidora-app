import { describe, it, expect, beforeEach, vi } from 'vitest'
import { itemVenta, pedido } from './fixtures'

// Mismo motivo que hojaRutaOptimizada.test.js: horarioParaRutear arrastra el
// cliente de supabase.
vi.mock('../../supabase', () => ({ supabase: {} }))

const capturado = vi.hoisted(() => ({ textos: [] }))

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
    save() {}
    splitTextToSize(texto) { return [String(texto)] }
    text(texto) {
      const items = Array.isArray(texto) ? texto : [texto]
      items.forEach((t) => capturado.textos.push(t))
    }
  },
}))

const { generarHojaRutaOptimizada } = await import('../hojaRutaOptimizada')

beforeEach(() => {
  capturado.textos = []
})

describe('generarHojaRutaOptimizada — fecha del encabezado', () => {
  it('muestra la fecha de la ruta elegida, no la fecha de hoy', () => {
    const transportista = { nombre: 'Juan Perez' }
    const pedidos = [pedido([itemVenta()])]

    generarHojaRutaOptimizada(transportista, pedidos, { fecha: '2026-01-05' })

    const texto = capturado.textos.join(' ')
    expect(texto).toContain('05/01/2026')
    // No debe filtrarse la fecha de hoy en su lugar.
    const hoyFormateado = new Intl.DateTimeFormat('es-AR', {
      day: '2-digit', month: '2-digit', year: 'numeric', timeZone: 'America/Argentina/Buenos_Aires',
    }).format(new Date())
    if (hoyFormateado !== '05/01/2026') {
      expect(texto).not.toContain(hoyFormateado)
    }
  })
})
