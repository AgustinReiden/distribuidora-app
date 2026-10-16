import { describe, it, expect } from 'vitest'
import {
  ID_NUEVO,
  cabeEn,
  combosTapados,
  competidoresDirectos,
  grupoDe,
  moverEnOrden,
  ordenDelGrupo,
  ordenParaGuardar,
  ubicarEnOrden,
  type ComboConLugares,
  type ComboOrdenable,
} from './comboOrden'

const HOY = '2026-10-16'

function combo(id: string, prioridad: number, unidades: number, productos: string[], extra: Partial<ComboOrdenable> = {}): ComboOrdenable {
  return { id, prioridad, unidades, productos: new Set(productos), activo: true, fechaFin: null, ...extra }
}
const mapa = (cs: ComboOrdenable[]) => new Map(cs.map(c => [c.id, c]))

describe('competidoresDirectos y grupoDe', () => {
  const a = combo('1', 3, 2, ['m', 'p'])
  const b = combo('2', 2, 2, ['p', 'q'])
  const c = combo('3', 1, 2, ['q'])
  const inactivo = combo('4', 9, 2, ['m'], { activo: false })
  const vencido = combo('5', 9, 2, ['m'], { fechaFin: '2026-10-01' })

  it('sólo cuentan los que comparten producto y están en juego', () => {
    expect(competidoresDirectos(a, [b, c, inactivo, vencido], HOY).map(x => x.id)).toEqual(['2'])
  })
  it('el grupo es conexo aunque A y C no compitan, y va por prioridad', () => {
    expect(grupoDe(a, [c, b, inactivo], HOY).map(x => x.id)).toEqual(['1', '2', '3'])
  })
})

describe('ubicarEnOrden', () => {
  // A = 1 Manaos + 1 Pindapoy (2 u.), B = 2 Manaos + 1 Pindapoy (3 u.).
  const a = combo('10', 1, 2, ['m', 'p'])

  it('el que lleva más unidades queda arriba, se cargue antes o después', () => {
    const b = combo(ID_NUEVO, 0, 3, ['m', 'p'])
    expect(ubicarEnOrden(['10'], b, mapa([a, b]))).toEqual([ID_NUEVO, '10'])
    const chico = combo(ID_NUEVO, 0, 2, ['m', 'p'])
    const grande = combo('10', 1, 3, ['m', 'p'])
    // Mismo tamaño: el nuevo arriba; más chico que el viejo: abajo.
    expect(ubicarEnOrden(['10'], chico, mapa([grande, chico]))).toEqual(['10', ID_NUEVO])
  })
  it('a igual cantidad, el más nuevo arriba', () => {
    const nuevo = combo(ID_NUEVO, 0, 2, ['m', 'p'])
    expect(ubicarEnOrden(['10'], nuevo, mapa([a, nuevo]))).toEqual([ID_NUEVO, '10'])
  })
  it('no mueve a los que no compiten con él directamente', () => {
    const x = combo('20', 5, 9, ['z'])
    const y = combo('21', 4, 1, ['m'])
    const nuevo = combo(ID_NUEVO, 0, 2, ['m'])
    expect(ubicarEnOrden(['20', '21'], nuevo, mapa([x, y, nuevo]))).toEqual(['20', ID_NUEVO, '21'])
  })
  it('al editar no pisa el orden manual de los demás', () => {
    const b = combo('11', 2, 2, ['m'])
    const c = combo('12', 1, 2, ['m'])
    // El admin dejó C arriba de B a mano; A cambia de lugares y se reubica sólo él.
    const a2 = combo('10', 0, 1, ['m'])
    expect(ubicarEnOrden(['12', '10', '11'], a2, mapa([a2, b, c]))).toEqual(['12', '11', '10'])
  })
})

describe('moverEnOrden', () => {
  const a = combo('1', 3, 2, ['m'])
  const x = combo('2', 2, 2, ['z'])
  const b = combo('3', 1, 2, ['m'])
  const porId = mapa([a, x, b])

  it('sube pasando al competidor directo de arriba, saltando a los que no compiten', () => {
    expect(moverEnOrden(['1', '2', '3'], b, 'arriba', porId)).toEqual(['3', '1', '2'])
  })
  it('baja pasando al competidor directo de abajo', () => {
    expect(moverEnOrden(['1', '2', '3'], a, 'abajo', porId)).toEqual(['2', '3', '1'])
  })
  it('sin competidor en esa dirección no cambia', () => {
    expect(moverEnOrden(['1', '2', '3'], a, 'arriba', porId)).toEqual(['1', '2', '3'])
  })
})

describe('ordenDelGrupo', () => {
  const a = combo('1', 2, 2, ['m'])
  const b = combo('2', 1, 3, ['m'])

  it('sin reubicar conserva la posición guardada', () => {
    expect(ordenDelGrupo(a, [b], HOY, { reubicar: false })).toEqual(['1', '2'])
  })
  it('al reubicar (reactivado, lugares nuevos) aplica la regla: el de más unidades arriba', () => {
    expect(ordenDelGrupo(combo('2', 0, 3, ['m']), [a], HOY, { reubicar: true })).toEqual(['2', '1'])
  })
  it('el orden manual vale mientras el grupo sea el mismo', () => {
    expect(ordenDelGrupo(a, [b], HOY, { reubicar: true, manual: ['2', '1'] })).toEqual(['2', '1'])
    const c = combo('3', 0, 1, ['m'])
    expect(ordenDelGrupo(a, [b, c], HOY, { reubicar: false, manual: ['2', '1'] })).toEqual(['1', '2', '3'])
  })
  it('un combo inactivo o vencido no tiene orden', () => {
    expect(ordenDelGrupo(combo('1', 2, 2, ['m'], { activo: false }), [b], HOY, { reubicar: true })).toBeNull()
  })
})

describe('ordenParaGuardar', () => {
  it('el combo nuevo va como 0', () => {
    expect(ordenParaGuardar(['5', ID_NUEVO, '2'])).toEqual([5, 0, 2])
  })
})

describe('cabeEn y combosTapados', () => {
  const lug = (cantidad: number, productos: string[]) => ({ cantidad, productos })
  const con = (id: string, prioridad: number, lugares: { cantidad: number; productos: string[] }[], extra: Partial<ComboOrdenable> = {}): ComboConLugares => ({
    ...combo(id, prioridad, lugares.reduce((s, l) => s + l.cantidad, 0), lugares.flatMap(l => l.productos), extra),
    lugares,
  })

  it('1 Manaos + 1 Pindapoy arriba de 2 + 1: el de abajo nunca se arma', () => {
    const chico = con('1', 2, [lug(1, ['m']), lug(1, ['p'])])
    const grande = con('2', 1, [lug(2, ['m']), lug(1, ['p'])])
    expect(combosTapados([chico, grande], HOY)).toEqual([{ arriba: '1', abajo: '2' }])
  })
  it('con el grande arriba no hay aviso', () => {
    const chico = con('1', 1, [lug(1, ['m']), lug(1, ['p'])])
    const grande = con('2', 2, [lug(2, ['m']), lug(1, ['p'])])
    expect(combosTapados([chico, grande], HOY)).toEqual([])
  })
  it('si el de abajo acepta productos que el de arriba no, no está tapado', () => {
    // Abajo: cualquier Alpha (a1 o a2); arriba: sólo a1.
    expect(cabeEn([lug(1, ['a1'])], [lug(1, ['a1', 'a2'])])).toBe(false)
    // Al revés sí: arriba acepta cualquier Alpha, abajo sólo a1.
    expect(cabeEn([lug(1, ['a1', 'a2'])], [lug(1, ['a1'])])).toBe(true)
  })
  it('cada lugar de arriba necesita un lugar distinto de abajo', () => {
    expect(cabeEn([lug(1, ['m']), lug(1, ['m'])], [lug(2, ['m'])])).toBe(false)
  })
  it('un combo fuera de juego no tapa ni queda tapado', () => {
    const chico = con('1', 2, [lug(1, ['m'])], { activo: false })
    const grande = con('2', 1, [lug(2, ['m'])])
    expect(combosTapados([chico, grande], HOY)).toEqual([])
  })
})
