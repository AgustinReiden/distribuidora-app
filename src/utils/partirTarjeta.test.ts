import { describe, it, expect } from 'vitest'
import { partirTarjeta, type OpAlto } from './partirTarjeta'

interface Op extends OpAlto { t: string }
const op = (t: string, advance = 4, pie = false): Op => ({ t, advance, ...(pie ? { pie } : {}) })
const alto = (ops: Op[]) => ops.reduce((s, o) => s + o.advance, 0)
const opciones = (disponible: number, altoColumna: number) => ({
  disponible,
  altoColumna,
  encabezadoCont: () => [op('N. Cliente (cont.)', 5)],
  continua: () => op('sigue', 4),
})

describe('partirTarjeta', () => {
  const pedido50 = (): Op[] => [
    op('encabezado', 5),
    ...Array.from({ length: 50 }, (_, i) => op(`renglon ${i + 1}`)),
    op('', 1, true),
    op('Total pedido', 4.5),
    op('Entregado', 4.5),
    op('divider', 3),
  ]

  it('un pedido de 50 renglones no pierde ningún renglón, el total ni el casillero', () => {
    const ops = pedido50()
    const partes = partirTarjeta(ops, opciones(120, 190))
    const todos = partes.flat().map((o) => o.t)

    expect(partes.length).toBeGreaterThan(1)
    for (let i = 1; i <= 50; i++) expect(todos.filter((t) => t === `renglon ${i}`)).toHaveLength(1)
    expect(todos).toContain('Total pedido')
    expect(todos).toContain('Entregado')
    expect(partes.slice(1).every((p) => p[0].t === 'N. Cliente (cont.)')).toBe(true)
    expect(partes.slice(0, -1).every((p) => p[p.length - 1].t === 'sigue')).toBe(true)
    // El pie va entero en la última parte.
    const ultima = partes[partes.length - 1].map((o) => o.t)
    expect(ultima.slice(-3)).toEqual(['Total pedido', 'Entregado', 'divider'])
  })

  it('ninguna parte pasa el alto que tiene (columna actual o columna entera)', () => {
    const partes = partirTarjeta(pedido50(), opciones(120, 190))
    expect(alto(partes[0])).toBeLessThanOrEqual(120)
    partes.slice(1).forEach((p) => expect(alto(p)).toBeLessThanOrEqual(190))
  })

  it('un pedido que entra no se parte', () => {
    const ops = [op('a'), op('b'), op('', 1, true), op('Total pedido')]
    expect(partirTarjeta(ops, opciones(100, 190))).toEqual([ops])
  })
})
