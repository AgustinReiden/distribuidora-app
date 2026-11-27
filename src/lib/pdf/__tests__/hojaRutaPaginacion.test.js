import { describe, it, expect, vi } from 'vitest'

vi.mock('../../supabase', () => ({ supabase: {} }))

import { dibujarHojaRuta, nuevoDocA4 } from '../hojaRutaOptimizada'
import { itemVenta, pedido } from './fixtures'

// #1715: un pedido de ~50 renglones más alto que una columna no se corta.
const transportista = { id: 1, nombre: 'Marcos' }
const renglones = (n) =>
  Array.from({ length: n }, (_, i) =>
    itemVenta({ producto_id: 100 + i, producto: { id: 100 + i, nombre: `PRODUCTO NUMERO ${i + 1}` }, cantidad: 2 }),
  )

const textoPorPagina = (doc) => doc.internal.pages.slice(1).map((p) => (p || []).join('\n'))

describe('hoja de ruta — pedido más largo que una columna (#1715)', () => {
  const largo = pedido(renglones(50), { id: 1, total: 2141640, cliente: { nombre_fantasia: 'Drugstore el tio' } })
  const corto = pedido(renglones(2), { id: 2, total: 5000, cliente: { nombre_fantasia: 'Kiosco chico' } })

  it('ningún renglón se pierde y el total y el casillero salen', () => {
    const doc = nuevoDocA4()
    dibujarHojaRuta(doc, transportista, [largo, corto], {})
    const texto = textoPorPagina(doc).join('\n')

    for (let i = 1; i <= 50; i++) expect(texto).toContain(`PRODUCTO NUMERO ${i})`)
    // El PDF escapa los paréntesis.
    expect(texto).toContain(String.raw`\(cont.\)`)
    expect(texto).toContain('sigue en la columna siguiente')
    expect(texto).toContain('Total pedido:')
    expect(texto).toContain('Entregado')
    expect(texto).toContain('Kiosco chico')
  })
})
