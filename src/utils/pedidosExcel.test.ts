import { describe, it, expect } from 'vitest'
import { filasPedidosExcel } from './pedidosExcel'

const ped = (over: Record<string, unknown> = {}) => ({ id: 1, estado: 'entregado', total: 12500, ...over })

describe('filasPedidosExcel', () => {
  it('sin ningún pedido con cargo no hay columna Envío', () => {
    const f = filasPedidosExcel([ped(), ped({ id: 2, cargo_envio: 0 })])
    expect(f.every(r => !('Envío' in r))).toBe(true)
  })

  it('con un pedido con cargo la columna aparece en todas las filas', () => {
    const f = filasPedidosExcel([ped({ cargo_envio: 500 }), ped({ id: 2 })])
    expect(f[0]['Envío']).toBe(500)
    expect(f[1]['Envío']).toBe(0)
  })

  it('el Total no cambia con el cargo', () => {
    expect(filasPedidosExcel([ped({ cargo_envio: 500 })])[0].Total).toBe(12500)
  })

  it('las dos últimas columnas dicen quién marcó la entrega y cuándo', () => {
    const f = filasPedidosExcel([
      ped({ entregado_at: '2026-11-12T12:14:00Z', entregado_por_perfil: { nombre: 'Juan' } }),
      ped({ id: 2, entregado_at: '2026-11-12T12:14:00Z' }),
      ped({ id: 3, estado: 'pendiente' }),
    ])
    expect(Object.keys(f[0]).slice(-2)).toEqual(['Entrega marcada por', 'Entrega marcada el'])
    expect(f[0]['Entrega marcada por']).toBe('Juan')
    expect(f[0]['Entrega marcada el']).toContain('12/11/2026')
    expect(f[1]['Entrega marcada por']).toBe('')
    expect(f[1]['Entrega marcada el']).toContain('12/11/2026')
    expect(f[2]['Entrega marcada por']).toBe('')
    expect(f[2]['Entrega marcada el']).toBe('')
  })
})
