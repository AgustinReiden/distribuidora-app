import { describe, it, expect } from 'vitest'
import { repartirPedidosSinRuta, type PedidoSinRuta, type RepartidorReparto } from './repartoRutaMulti'

const rep = (id: string, extra: Partial<RepartidorReparto> = {}): RepartidorReparto => ({ transportista_id: id, ...extra })
const ped = (id: string, zonaId: number | null = null): PedidoSinRuta => ({ id, zonaId })
const ruteadas = (o: Record<string, number>) => new Map(Object.entries(o))

const por = (r: ReturnType<typeof repartirPedidosSinRuta>, chofer: string) =>
  r.asignados.filter(a => a.transportistaId === chofer).map(a => a.pedidoId)

describe('repartirPedidosSinRuta — sólo sin coordenadas', () => {
  it('los reparte a turnos entre los choferes, aunque pasen su máximo (decisión anterior: todo pedido queda en alguna ruta)', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 2 }), rep('B', { max_paradas: 2 })],
      ruteadasPorChofer: ruteadas({ A: 2, B: 2 }), // ya llenos
      pedidosSinRuta: [ped('1'), ped('2'), ped('3')],
      skipped: [],
    })
    expect(r.sinAsignar).toEqual([])
    expect(r.asignados.map(a => [a.pedidoId, a.transportistaId, a.motivo])).toEqual([
      ['1', 'A', 'sin_coordenadas'],
      ['2', 'B', 'sin_coordenadas'],
      ['3', 'A', 'sin_coordenadas'],
    ])
  })

  it('la zona preferida manda sobre el turno, y el turno sólo avanza con los que no tienen preferido', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A'), rep('B', { zonas_preferidas: [7] })],
      ruteadasPorChofer: ruteadas({}),
      pedidosSinRuta: [ped('1', 7), ped('2'), ped('3', 7), ped('4')],
      skipped: [],
    })
    expect(por(r, 'B')).toEqual(['1', '3', '4'])
    expect(por(r, 'A')).toEqual(['2'])
  })
})

describe('repartirPedidosSinRuta — dejados afuera por el optimizador (skipped)', () => {
  it('con todos los choferes en su máximo, no se reparte nada y quedan sin asignar (el caso de la auditoría: 2 choferes de 10, 5 skipped)', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 10 }), rep('B', { max_paradas: 10 })],
      ruteadasPorChofer: ruteadas({ A: 10, B: 10 }),
      pedidosSinRuta: ['1', '2', '3', '4', '5'].map(id => ped(id)),
      skipped: ['1', '2', '3', '4', '5'],
    })
    expect(r.asignados).toEqual([])
    expect(r.sinAsignar).toEqual(['1', '2', '3', '4', '5'])
  })

  it('sólo se reparte hasta completar el cupo que le queda a cada uno, y el resto queda sin asignar', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 5 }), rep('B', { max_paradas: 4 })],
      ruteadasPorChofer: ruteadas({ A: 4, B: 2 }), // cupo: A 1, B 2
      pedidosSinRuta: ['1', '2', '3', '4', '5'].map(id => ped(id)),
      skipped: ['1', '2', '3', '4', '5'],
    })
    expect(r.asignados.filter(a => a.motivo === 'optimizador')).toHaveLength(3)
    expect(por(r, 'A')).toHaveLength(1)
    expect(por(r, 'B')).toHaveLength(2)
    expect(r.sinAsignar).toEqual(['4', '5'])
  })

  it('un cupo que alcanza justo asigna todos y no deja ninguno sin asignar', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 3 }), rep('B', { max_paradas: 3 })],
      ruteadasPorChofer: ruteadas({ A: 2, B: 2 }), // cupo: 1 + 1
      pedidosSinRuta: [ped('1'), ped('2')],
      skipped: ['1', '2'],
    })
    expect(r.sinAsignar).toEqual([])
    expect(por(r, 'A')).toHaveLength(1)
    expect(por(r, 'B')).toHaveLength(1)
  })

  it('un chofer sin tope siempre tiene cupo: recibe lo que el otro no puede', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 2 }), rep('B')],
      ruteadasPorChofer: ruteadas({ A: 2, B: 7 }),
      pedidosSinRuta: [ped('1'), ped('2'), ped('3')],
      skipped: ['1', '2', '3'],
    })
    expect(por(r, 'B')).toEqual(['1', '2', '3'])
    expect(r.sinAsignar).toEqual([])
  })

  it('con la zona preferida llena, no la fuerza: va al que tiene lugar', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 1, zonas_preferidas: [3] }), rep('B', { max_paradas: 5 })],
      ruteadasPorChofer: ruteadas({ A: 1, B: 0 }),
      pedidosSinRuta: [ped('1', 3)],
      skipped: ['1'],
    })
    expect(por(r, 'B')).toEqual(['1'])
  })

  it('con la zona preferida con lugar, va a ese chofer aunque el otro lleve menos', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 5, zonas_preferidas: [3] }), rep('B', { max_paradas: 5 })],
      ruteadasPorChofer: ruteadas({ A: 4, B: 0 }),
      pedidosSinRuta: [ped('1', 3)],
      skipped: ['1'],
    })
    expect(por(r, 'A')).toEqual(['1'])
  })

  it('sin preferencia, va al que lleva menos paradas', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 9 }), rep('B', { max_paradas: 9 })],
      ruteadasPorChofer: ruteadas({ A: 5, B: 1 }),
      pedidosSinRuta: [ped('1'), ped('2')],
      skipped: ['1', '2'],
    })
    expect(por(r, 'B')).toEqual(['1', '2'])
  })
})

describe('repartirPedidosSinRuta — mezcla', () => {
  it('los sin coordenadas se reparten siempre y ocupan cupo; los skipped usan lo que quede', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 4 }), rep('B', { max_paradas: 4 })],
      ruteadasPorChofer: ruteadas({ A: 3, B: 3 }), // cupo 1 + 1
      pedidosSinRuta: [ped('sc1'), ped('sk1'), ped('sk2'), ped('sk3')],
      skipped: ['sk1', 'sk2', 'sk3'],
    })
    // sc1 va a A (primer turno) y le gasta el cupo: A queda llena, B recibe un skipped.
    expect(r.asignados.find(a => a.pedidoId === 'sc1')).toMatchObject({ transportistaId: 'A', motivo: 'sin_coordenadas' })
    expect(r.asignados.filter(a => a.motivo === 'optimizador').map(a => [a.pedidoId, a.transportistaId])).toEqual([['sk1', 'B']])
    expect(r.sinAsignar).toEqual(['sk2', 'sk3'])
  })

  it('no mezcla los avisos: cada pedido sale con su motivo', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A'), rep('B')],
      ruteadasPorChofer: ruteadas({}),
      pedidosSinRuta: [ped('1'), ped('2'), ped('3')],
      skipped: ['2'],
    })
    const motivo = Object.fromEntries(r.asignados.map(a => [a.pedidoId, a.motivo]))
    expect(motivo).toEqual({ '1': 'sin_coordenadas', '3': 'sin_coordenadas', '2': 'optimizador' })
  })
})

describe('repartirPedidosSinRuta — bordes', () => {
  it('cupo en cero con max_paradas null/0: sin tope, no es cupo cero', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 0 }), rep('B', { max_paradas: null })],
      ruteadasPorChofer: ruteadas({ A: 50, B: 50 }),
      pedidosSinRuta: [ped('1')],
      skipped: ['1'],
    })
    expect(r.sinAsignar).toEqual([])
  })

  it('un máximo con decimales se trunca (como en la edge)', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 2.9 })],
      ruteadasPorChofer: ruteadas({ A: 1 }),
      pedidosSinRuta: [ped('1'), ped('2')],
      skipped: ['1', '2'],
    })
    expect(por(r, 'A')).toEqual(['1'])
    expect(r.sinAsignar).toEqual(['2'])
  })

  it('un skipped que no está entre los pedidos sin ruta se ignora', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 3 })],
      ruteadasPorChofer: ruteadas({ A: 0 }),
      pedidosSinRuta: [ped('1')],
      skipped: ['999'],
    })
    expect(r.asignados).toEqual([{ pedidoId: '1', transportistaId: 'A', motivo: 'sin_coordenadas' }])
    expect(r.sinAsignar).toEqual([])
  })

  it('los ids numéricos del skipped se comparan como texto', () => {
    const r = repartirPedidosSinRuta({
      repartidores: [rep('A', { max_paradas: 1 })],
      ruteadasPorChofer: ruteadas({ A: 1 }),
      pedidosSinRuta: [ped('12')],
      skipped: [12 as unknown as string],
    })
    expect(r.sinAsignar).toEqual(['12'])
  })
})
