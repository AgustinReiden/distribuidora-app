/**
 * Tests de la pestaña "Rentabilidad" de /reportes.
 *
 * Foco: la cascada de costo. Este hook calculaba el CMV con
 * `costo_unitario_al_crear ?? costo_real ?? fórmula`, salteándose
 * `costo_promedio` — que es justamente la base de CMV del reporte gerencial
 * (mig 130). Las dos pantallas daban márgenes distintos para el mismo período.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'

// Cadena thenable: la query es .from().select().neq() y opcionalmente
// .gte().lte(), y ahora termina en .range() porque las lecturas se paginan.
// `range` devuelve la cadena, que es thenable: como el lote entra en una
// página, el paginador corta en la primera vuelta.
function createChainableMock(finalData: { data: unknown; error: unknown }) {
  const chain: Record<string, unknown> = {
    select: vi.fn(),
    neq: vi.fn(),
    gte: vi.fn(),
    lte: vi.fn(),
    eq: vi.fn(),
    in: vi.fn(),
    order: vi.fn(),
    range: vi.fn(),
  }
  Object.keys(chain).forEach(k => {
    ;(chain[k] as ReturnType<typeof vi.fn>).mockReturnValue(chain)
  })
  chain.then = vi.fn((resolve: (v: unknown) => void) => {
    resolve(finalData)
    return Promise.resolve(finalData)
  })
  return chain
}

const mockFrom = vi.fn()

vi.mock('./base', () => ({
  supabase: { from: (...args: unknown[]) => mockFrom(...args) },
  notifyError: vi.fn(),
}))

import { useReportesFinancieros } from './useReportesFinancieros'
import type { ReporteRentabilidad } from '../../types'

/** Un pedido de una línea, para aislar la cascada de costo. */
function pedidoConItem(item: Record<string, unknown>, producto: Record<string, unknown>) {
  return [
    {
      id: 'p1',
      cliente_id: 'c1',
      estado: 'entregado',
      total: 1000,
      created_at: '2026-01-15T10:00:00',
      tipo_factura: 'FC',
      items: [{ id: 'i1', ...item, producto: { id: 'prod1', nombre: 'Producto A', codigo: 'PA001', ...producto } }],
    },
  ]
}

async function correrReporte(pedidos: unknown[]): Promise<ReporteRentabilidad> {
  mockFrom.mockReturnValue(createChainableMock({ data: pedidos, error: null }))
  const { result } = renderHook(() => useReportesFinancieros())
  let reporte!: ReporteRentabilidad
  await act(async () => {
    reporte = await result.current.generarReporteRentabilidad()
  })
  return reporte
}

describe('useReportesFinancieros › generarReporteRentabilidad', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('cascada de costo canónica (mig 130)', () => {
    it('sin snapshot usa costo_promedio, no costo_real', async () => {
      // Los tres costos distintos a propósito: el número que sale dice en qué
      // escalón de la cascada se cayó el cálculo.
      const reporte = await correrReporte(
        pedidoConItem(
          { cantidad: 10, precio_unitario: 100, subtotal: 1000, costo_unitario_al_crear: null },
          { costo_promedio: 60, costo_real: 80, costo_con_iva: 95, costo_sin_iva: 70, impuestos_internos: 10 }
        )
      )

      expect(reporte.productos[0].costos).toBe(600)
      expect(reporte.productos[0].margen).toBe(400)
      expect(reporte.totales.costosTotales).toBe(600)
    })

    it('el snapshot congelado gana sobre costo_promedio', async () => {
      // Es lo que hace que el margen de un mes cerrado no se mueva cuando
      // cambia el costo de hoy.
      const reporte = await correrReporte(
        pedidoConItem(
          { cantidad: 10, precio_unitario: 100, subtotal: 1000, costo_unitario_al_crear: 45 },
          { costo_promedio: 60, costo_real: 80 }
        )
      )

      expect(reporte.productos[0].costos).toBe(450)
      expect(reporte.productos[0].margen).toBe(550)
    })

    it('sin snapshot ni promedio cae a costo_real', async () => {
      const reporte = await correrReporte(
        pedidoConItem(
          { cantidad: 10, precio_unitario: 100, subtotal: 1000, costo_unitario_al_crear: null },
          { costo_promedio: null, costo_real: 80, costo_sin_iva: 70, impuestos_internos: 10 }
        )
      )

      expect(reporte.productos[0].costos).toBe(800)
    })

    it('sin snapshot, promedio ni costo_real usa la fórmula con impuestos internos', async () => {
      const reporte = await correrReporte(
        pedidoConItem(
          { cantidad: 10, precio_unitario: 100, subtotal: 1000, costo_unitario_al_crear: null },
          { costo_promedio: null, costo_real: null, costo_sin_iva: 100, impuestos_internos: 10 }
        )
      )

      expect(reporte.productos[0].costos).toBe(1100)
    })

    it('un producto sin ningún costo cargado no rompe los totales', async () => {
      const reporte = await correrReporte(
        pedidoConItem(
          { cantidad: 10, precio_unitario: 100, subtotal: 1000, costo_unitario_al_crear: null },
          { costo_promedio: null, costo_real: null, costo_sin_iva: null }
        )
      )

      expect(reporte.productos[0].costos).toBe(0)
      expect(reporte.totales.margenTotal).toBe(1000)
      expect(Number.isNaN(reporte.totales.costosTotales)).toBe(false)
    })
  })

  describe('el ingreso sigue siendo el real (mig 123)', () => {
    it('en FC el margen se mide contra el neto, no contra el precio final', async () => {
      const reporte = await correrReporte(
        pedidoConItem(
          {
            cantidad: 10,
            precio_unitario: 121,
            subtotal: 1210,
            costo_unitario_al_crear: 50,
            ingreso_real_unitario: 100,
            neto_unitario: 100,
            iva_unitario: 21,
          },
          { costo_promedio: 60 }
        )
      )

      expect(reporte.productos[0].ingresos).toBe(1000)
      expect(reporte.productos[0].costos).toBe(500)
      expect(reporte.productos[0].margen).toBe(500)
      expect(reporte.totales.ivaDiscriminado).toBe(210)
      expect(reporte.totales.ventasBrutas).toBe(1210)
    })
  })
})
