import { describe, it, expect } from 'vitest'
import { calcularEstadisticasSalvedades } from './salvedades'
import type { SalvedadItemDBExtended } from '../types'

function salvedad(overrides: Partial<SalvedadItemDBExtended> = {}): SalvedadItemDBExtended {
  return {
    id: '1',
    pedido_id: '1',
    pedido_item_id: '1',
    producto_id: '1',
    cantidad_original: 1,
    cantidad_afectada: 1,
    cantidad_entregada: 0,
    motivo: 'otro',
    estado_resolucion: 'pendiente',
    monto_afectado: 100,
    stock_devuelto: false,
    reportado_por: '1',
    created_at: '2026-01-01T00:00:00Z',
    ...overrides,
  } as SalvedadItemDBExtended
}

describe('calcularEstadisticasSalvedades', () => {
  it('cuenta total, pendientes, resueltas y anuladas por separado', () => {
    const stats = calcularEstadisticasSalvedades([
      salvedad({ id: '1', estado_resolucion: 'pendiente' }),
      salvedad({ id: '2', estado_resolucion: 'reprogramada' }),
      salvedad({ id: '3', estado_resolucion: 'anulada' }),
    ])

    expect(stats.total).toBe(3)
    expect(stats.pendientes).toBe(1)
    expect(stats.resueltas).toBe(1)
    expect(stats.anuladas).toBe(1)
  })

  it('suma el monto afectado total y el pendiente por separado', () => {
    const stats = calcularEstadisticasSalvedades([
      salvedad({ id: '1', estado_resolucion: 'pendiente', monto_afectado: 100 }),
      salvedad({ id: '2', estado_resolucion: 'reprogramada', monto_afectado: 50 }),
    ])

    expect(stats.monto_total_afectado).toBe(150)
    expect(stats.monto_pendiente).toBe(100)
  })

  it('cambia según la lista recibida: refleja el filtro aplicado por el caller', () => {
    const todas = [
      salvedad({ id: '1', estado_resolucion: 'pendiente', monto_afectado: 100 }),
      salvedad({ id: '2', estado_resolucion: 'pendiente', monto_afectado: 200 }),
    ]
    const filtradas = todas.slice(0, 1)

    expect(calcularEstadisticasSalvedades(todas).total).toBe(2)
    expect(calcularEstadisticasSalvedades(filtradas).total).toBe(1)
    expect(calcularEstadisticasSalvedades(filtradas).monto_total_afectado).toBe(100)
  })

  it('devuelve ceros para una lista vacía', () => {
    const stats = calcularEstadisticasSalvedades([])
    expect(stats).toEqual({
      total: 0,
      pendientes: 0,
      resueltas: 0,
      anuladas: 0,
      monto_total_afectado: 0,
      monto_pendiente: 0,
    })
  })
})
