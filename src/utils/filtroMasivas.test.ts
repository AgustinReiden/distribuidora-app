import { describe, it, expect } from 'vitest'
import { filtrarPedidosMasivos, type FiltroMasivo } from './filtroMasivas'

const base: FiltroMasivo = { tipoFecha: 'entrega', desde: '', hasta: '', formaPago: '' }
const pedidos = [
  { id: 1, fecha: '2026-11-20', fecha_entrega_programada: '2026-11-26', forma_pago: 'efectivo' },
  { id: 2, fecha: '2026-11-26', fecha_entrega_programada: '2026-11-27', forma_pago: 'transferencia' },
  { id: 3, fecha: '2026-11-26', fecha_entrega_programada: null, forma_pago: 'efectivo' },
  { id: 4, fecha: null, created_at: '2026-11-26T03:00:00Z', fecha_entrega_programada: null, forma_pago: 'efectivo' },
]
const ids = (f: Partial<FiltroMasivo>) => filtrarPedidosMasivos(pedidos, { ...base, ...f }).map(p => p.id)

describe('filtroMasivas', () => {
  it('sin filtros entran todos', () => {
    expect(ids({})).toEqual([1, 2, 3, 4])
  })
  it('por fecha de entrega (default); sin entrega programada cae a la del pedido', () => {
    expect(ids({ desde: '2026-11-26', hasta: '2026-11-26' })).toEqual([1, 3, 4])
  })
  it('por fecha del pedido', () => {
    expect(ids({ tipoFecha: 'pedido', desde: '2026-11-26', hasta: '2026-11-26' })).toEqual([2, 3, 4])
  })
  it('por forma de pago', () => {
    expect(ids({ formaPago: 'efectivo' })).toEqual([1, 3, 4])
    expect(ids({ formaPago: 'transferencia' })).toEqual([2])
  })
  it('fecha de entrega 26/11 y efectivo', () => {
    expect(ids({ desde: '2026-11-26', hasta: '2026-11-26', formaPago: 'efectivo' })).toEqual([1, 3, 4])
  })
})
