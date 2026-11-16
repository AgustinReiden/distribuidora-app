import { describe, it, expect } from 'vitest'
import { combosAfectadosPorDesactivar, avisoCombosDesactivarProducto } from './combosAfectadosPorDesactivar'

const catalogo = [
  { id: '1', activo: true, categoria_id: 'rubroA' },
  { id: '2', activo: true, categoria_id: 'rubroA' },
  { id: '3', activo: false, categoria_id: 'rubroB' },
  { id: '4', activo: true, categoria_id: 'rubroB' },
]
const combo = (nombre: string, sueltos: string[], extra: Record<string, unknown> = {}, categorias: string[] = []) => ({
  nombre, activo: true, fechaFin: null, componentes: [{ cantidad: 1, sueltos, categorias }], ...extra,
})

describe('combosAfectadosPorDesactivar (1596-b11)', () => {
  it('el único producto de un lugar: el combo deja de poder armarse', () => {
    const r = combosAfectadosPorDesactivar('1', [combo('Solo', ['1'])], catalogo)
    expect(r).toEqual({ sinAlternativa: ['Solo'], conAlternativa: [] })
  })

  it('uno de varios productos activos de un lugar: el combo sigue', () => {
    const r = combosAfectadosPorDesactivar('1', [combo('Dos', ['1', '2'])], catalogo)
    expect(r).toEqual({ sinAlternativa: [], conAlternativa: ['Dos'] })
  })

  it('la otra opción ya inactiva no cuenta como alternativa', () => {
    const r = combosAfectadosPorDesactivar('4', [combo('Con inactivo', ['3', '4'])], catalogo)
    expect(r.sinAlternativa).toEqual(['Con inactivo'])
  })

  it('un lugar por categoría cuenta los productos activos de esa categoría', () => {
    const r = combosAfectadosPorDesactivar('1', [combo('Rubro', [], {}, ['rubroA'])], catalogo)
    expect(r).toEqual({ sinAlternativa: [], conAlternativa: ['Rubro'] })
    const r2 = combosAfectadosPorDesactivar('4', [combo('Rubro B', [], {}, ['rubroB'])], catalogo)
    expect(r2.sinAlternativa).toEqual(['Rubro B'])
  })

  it('el producto que el combo mueve también lo rompe', () => {
    const r = combosAfectadosPorDesactivar('2', [combo('Mueve', ['1'], { productoAMoverId: '2' })], catalogo)
    expect(r.sinAlternativa).toEqual(['Mueve'])
  })

  it('ignora los combos apagados, los vencidos y los que no lo usan', () => {
    const r = combosAfectadosPorDesactivar('1', [
      combo('Apagado', ['1'], { activo: false }),
      combo('Vencido', ['1'], { fechaFin: '2026-01-01' }),
      combo('Otro', ['2']),
    ], catalogo, '2026-11-16')
    expect(r).toEqual({ sinAlternativa: [], conAlternativa: [] })
  })
})

describe('avisoCombosDesactivarProducto', () => {
  it('sin combos afectados no dice nada', () => {
    expect(avisoCombosDesactivarProducto({ sinAlternativa: [], conAlternativa: [] })).toBe('')
  })

  it('nombra los combos, en singular y plural', () => {
    expect(avisoCombosDesactivarProducto({ sinAlternativa: ['A'], conAlternativa: [] }))
      .toBe('Es parte del combo «A» y no tiene otro producto que lo reemplace: ese combo deja de poder armarse.')
    expect(avisoCombosDesactivarProducto({ sinAlternativa: ['A', 'B'], conAlternativa: ['C'] }))
      .toContain('combo «A» y «B» y no tiene otro producto que lo reemplace: esos combos dejan de poder armarse.')
  })
})
