import { describe, it, expect } from 'vitest'
import {
  FILTROS_BONIF_VACIOS,
  SIN_DATO,
  filtrarDetalleBonificaciones,
  formatBultos,
  formatPct,
  pctSobreVenta,
  resumirBonificaciones,
} from './bonificaciones'
import type { LineaBonificacion } from '../hooks/queries/useBonificacionesReporteQuery'

function linea(over: Partial<LineaBonificacion> = {}): LineaBonificacion {
  return {
    pedido_id: 1, fecha: '2026-10-31', sucursal_nombre: 'Tucumán',
    cliente_id: 10, cliente_nombre: 'Almacén Doña Rosa', cliente_activo: true,
    usuario_id: 'u1', vendedor_nombre: 'Marcelo',
    promocion_id: 13, promocion_nombre: 'Promo Manaos 6 + 2',
    producto_id: 78, producto_nombre: 'Manaos Cola 3 L', producto_codigo: '100101',
    cantidad: 12, es_fraccion: true, factor: 6, bultos: 2,
    costo_unitario: 1123.68, costo: 13484.1, valor_venta: 22200, sin_costo: false,
    ...over,
  }
}

describe('filtrarDetalleBonificaciones', () => {
  const lineas = [
    linea(),
    linea({ pedido_id: 2, promocion_id: 19, usuario_id: 'u2', cliente_nombre: 'Kiosco Ana', producto_nombre: 'Placer 500' }),
    linea({ pedido_id: 3, promocion_id: null, usuario_id: null, cliente_nombre: null }),
  ]

  it('sin filtros devuelve todo', () => {
    expect(filtrarDetalleBonificaciones(lineas, FILTROS_BONIF_VACIOS)).toHaveLength(3)
  })

  it('filtra por promoción y por "sin promoción"', () => {
    expect(filtrarDetalleBonificaciones(lineas, { ...FILTROS_BONIF_VACIOS, promocion: '19' }).map((l) => l.pedido_id)).toEqual([2])
    expect(filtrarDetalleBonificaciones(lineas, { ...FILTROS_BONIF_VACIOS, promocion: SIN_DATO }).map((l) => l.pedido_id)).toEqual([3])
  })

  it('filtra por vendedor y por "sin vendedor"', () => {
    expect(filtrarDetalleBonificaciones(lineas, { ...FILTROS_BONIF_VACIOS, vendedor: 'u2' }).map((l) => l.pedido_id)).toEqual([2])
    expect(filtrarDetalleBonificaciones(lineas, { ...FILTROS_BONIF_VACIOS, vendedor: SIN_DATO }).map((l) => l.pedido_id)).toEqual([3])
  })

  it('busca por cliente, producto, código o pedido, sin acentos ni mayúsculas', () => {
    expect(filtrarDetalleBonificaciones(lineas, { ...FILTROS_BONIF_VACIOS, busqueda: 'dona rosa' }).map((l) => l.pedido_id)).toEqual([1])
    expect(filtrarDetalleBonificaciones(lineas, { ...FILTROS_BONIF_VACIOS, busqueda: 'PLACER' }).map((l) => l.pedido_id)).toEqual([2])
    expect(filtrarDetalleBonificaciones(lineas, { ...FILTROS_BONIF_VACIOS, busqueda: '100101' })).toHaveLength(3)
    expect(filtrarDetalleBonificaciones(lineas, { ...FILTROS_BONIF_VACIOS, busqueda: '3' }).map((l) => l.pedido_id)).toContain(3)
  })
})

describe('resumirBonificaciones', () => {
  it('cuenta pedidos distintos y suma los montos', () => {
    const r = resumirBonificaciones([linea(), linea({ producto_id: 5, bultos: 1, costo: 100, valor_venta: 200 }), linea({ pedido_id: 2 })])
    expect(r.lineas).toBe(3)
    expect(r.pedidos).toBe(2)
    expect(r.bultos).toBe(5)
    expect(r.costo).toBeCloseTo(13484.1 * 2 + 100)
    expect(r.valor_venta).toBe(22200 * 2 + 200)
  })

  it('vacío da ceros', () => {
    expect(resumirBonificaciones([])).toEqual({ lineas: 0, pedidos: 0, bultos: 0, costo: 0, valor_venta: 0 })
  })
})

describe('pctSobreVenta', () => {
  it('es el costo sobre la venta', () => {
    expect(pctSobreVenta(567375.79, 16198550)).toBeCloseTo(0.035, 3)
  })
  it('sin venta no es 0 %: es null', () => {
    expect(pctSobreVenta(100, 0)).toBeNull()
    expect(formatPct(null)).toBe('—')
  })
})

describe('formatos', () => {
  it('el porcentaje va con un decimal', () => {
    expect(formatPct(0.035)).toBe('3,5 %')
  })
  it('los bultos admiten fracción', () => {
    expect(formatBultos(2 / 6)).toBe('0,33')
    expect(formatBultos(65)).toBe('65')
  })
})
