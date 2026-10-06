import { describe, it, expect } from 'vitest'
import { esRegaloCompatible, filtrarRegalosCompatibles, type ProductoRegalo } from './regaloCompatible'

const p = (id: string, extra: Partial<ProductoRegalo> = {}): ProductoRegalo => ({ id, ...extra })

describe('esRegaloCompatible', () => {
  const casos: Array<[string, ProductoRegalo, ProductoRegalo, boolean]> = [
    ['mismo producto', p('1', { categoria_id: 'c1' }), p('1', { categoria_id: 'c1' }), true],
    ['mismo producto sin categoría', p('1'), p('1'), true],
    ['misma categoria_id', p('1', { categoria_id: 'c1' }), p('2', { categoria_id: 'c1' }), true],
    ['distinta categoria_id', p('1', { categoria_id: 'c1' }), p('2', { categoria_id: 'c2' }), false],
    ['categoria_id gana sobre el texto', p('1', { categoria_id: 'c1', categoria: 'Bebidas' }), p('2', { categoria_id: 'c2', categoria: 'Bebidas' }), false],
    ['mismo texto sin ids (#763)', p('1', { categoria: 'Bebidas' }), p('2', { categoria: 'Bebidas' }), true],
    ['texto normalizado (tildes, mayúsculas, espacios)', p('1', { categoria: 'Almacén' }), p('2', { categoria: '  almacen ' }), true],
    ['texto distinto', p('1', { categoria: 'Bebidas' }), p('2', { categoria: 'Snacks' }), false],
    ['un lado con id y el otro sólo texto: compara texto', p('1', { categoria_id: 'c1', categoria: 'Bebidas' }), p('2', { categoria: 'bebidas' }), true],
    ['misma subcategoría', p('1', { categoria_id: 'c1', subcategoria_id: 's1' }), p('2', { categoria_id: 'c1', subcategoria_id: 's1' }), true],
    ['subcategoría distinta', p('1', { categoria_id: 'c1', subcategoria_id: 's1' }), p('2', { categoria_id: 'c1', subcategoria_id: 's2' }), false],
    ['original con subcategoría, candidato sin', p('1', { categoria_id: 'c1', subcategoria_id: 's1' }), p('2', { categoria_id: 'c1' }), false],
    ['original sin subcategoría acepta cualquiera', p('1', { categoria_id: 'c1' }), p('2', { categoria_id: 'c1', subcategoria_id: 's9' }), true],
    ['original sin categoría: otro no', p('1'), p('2', { categoria: 'Bebidas' }), false],
    ['original sin categoría y candidato sin categoría: no', p('1'), p('2'), false],
    ['ids numéricos', p('1', { categoria_id: 5 }), p('2', { categoria_id: '5' }), true],
  ]
  it.each(casos)('%s', (_n, original, candidato, esperado) => {
    expect(esRegaloCompatible(original, candidato)).toBe(esperado)
  })
})

describe('filtrarRegalosCompatibles', () => {
  it('deja compatibles y operativos; saca desactivados y otras categorías', () => {
    const original = p('1', { categoria_id: 'c1' })
    const lista = [
      p('1', { categoria_id: 'c1' }),
      p('2', { categoria_id: 'c1' }),
      p('3', { categoria_id: 'c1', activo: false }),
      p('4', { categoria_id: 'c2' }),
    ]
    expect(filtrarRegalosCompatibles(original, lista).map(x => x.id)).toEqual(['1', '2'])
  })
})
