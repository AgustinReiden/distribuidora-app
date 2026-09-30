import { describe, it, expect } from 'vitest'
import { pedidosVisiblesRuta, separarPorFiltroFecha } from './pedidosVisiblesRuta'

describe('separarPorFiltroFecha', () => {
  const lista = [
    { id: '1', fecha: '2026-09-29', fecha_entrega_programada: '2026-09-30' },
    { id: '2', fecha: '2026-09-28', fecha_entrega_programada: '2026-09-29' },
    { id: '3', fecha: '2026-09-29', fecha_entrega_programada: null },
  ]

  it('por fecha de entrega 29/9 al 29/9 no muestra lo que se entrega el 30/9', () => {
    const { visibles, ocultas } = separarPorFiltroFecha(lista, { activo: true, tipo: 'entrega', desde: '2026-09-29', hasta: '2026-09-29' })
    expect(visibles.map(p => p.id)).toEqual(['2', '3'])
    expect(ocultas.map(p => p.id)).toEqual(['1'])
  })

  it('sin filtro activo no oculta nada', () => {
    const { visibles, ocultas } = separarPorFiltroFecha(lista, { activo: false, tipo: 'entrega', desde: '', hasta: '' })
    expect(visibles).toHaveLength(3)
    expect(ocultas).toHaveLength(0)
  })
})

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
