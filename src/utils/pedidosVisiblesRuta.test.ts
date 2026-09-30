import { describe, it, expect } from 'vitest'
import { pedidosVisiblesRuta } from './pedidosVisiblesRuta'

const p = (id: string, estado: string, orden_entrega?: number) => ({ id, estado, orden_entrega })

describe('pedidosVisiblesRuta', () => {
  it('no lista las paradas ya entregadas de la ruta existente', () => {
    const visibles = pedidosVisiblesRuta({
      modoDividir: false,
      hayTransportista: true,
      paradasExistentes: [p('6621', 'entregado', 1), p('6706', 'asignado', 2)],
      disponibles: [p('6800', 'pendiente')],
    })
    expect(visibles.map(v => v.id)).toEqual(['6706', '6800'])
  })

  it('las paradas ganan sobre el mismo pedido en el pool y no se duplican', () => {
    const visibles = pedidosVisiblesRuta({
      modoDividir: false,
      hayTransportista: true,
      paradasExistentes: [p('1', 'asignado', 1)],
      disponibles: [p('1', 'pendiente'), p('2', 'pendiente')],
    })
    expect(visibles).toEqual([p('1', 'asignado', 1), p('2', 'pendiente')])
  })

  it('un entregado que se cuela en el pool tampoco se lista', () => {
    const visibles = pedidosVisiblesRuta({
      modoDividir: false,
      hayTransportista: true,
      paradasExistentes: [],
      disponibles: [p('1', 'entregado'), p('2', 'pendiente')],
    })
    expect(visibles.map(v => v.id)).toEqual(['2'])
  })

  it('sin transportista no hay lista; en modo dividir es todo el pool', () => {
    const disponibles = [p('2', 'pendiente', 2), p('1', 'pendiente', 1)]
    expect(pedidosVisiblesRuta({ modoDividir: false, hayTransportista: false, paradasExistentes: [], disponibles })).toEqual([])
    expect(pedidosVisiblesRuta({ modoDividir: true, hayTransportista: false, paradasExistentes: [], disponibles }).map(v => v.id)).toEqual(['1', '2'])
  })
})
