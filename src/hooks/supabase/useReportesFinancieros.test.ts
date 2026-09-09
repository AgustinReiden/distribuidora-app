/**
 * Tests de los reportes financieros.
 *
 * QUÉ CAMBIÓ Y POR QUÉ ESTOS TESTS SON OTROS
 * ------------------------------------------
 * La versión anterior de este archivo probaba la cascada de costo de
 * Rentabilidad calculada en JS. Esa cascada ya no existe acá: se movió a SQL
 * (`reporte_rentabilidad`, mig 208), con la misma definición que
 * `reporte_gerencial` (mig 130).
 *
 * Reimplementarla en JS sólo para poder testearla sería volver a tener dos
 * definiciones del mismo número — que es exactamente el problema que este
 * trabajo vino a cerrar. La cascada en SQL se verificó contra prod comparando
 * el RPC con el cálculo manual sobre la misma foto de datos (203 productos,
 * $35.169.818 de costo, idénticos).
 *
 * Lo que queda para testear en JS es el contrato del wrapper: que llame al RPC
 * con los parámetros correctos, que desempaquete el JSON, y que un desvío de
 * consistencia se avise en vez de pasar desapercibido.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'

const mockRpc = vi.fn()
const mockNotifyError = vi.fn()

vi.mock('./base', () => ({
  supabase: { rpc: (...args: unknown[]) => mockRpc(...args) },
  notifyError: (...args: unknown[]) => mockNotifyError(...args),
}))

import { useReportesFinancieros } from './useReportesFinancieros'

describe('useReportesFinancieros', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  describe('generarReporteCuentasPorCobrar', () => {
    it('llama al RPC y devuelve las filas ya agregadas por la base', async () => {
      const clientes = [
        { cliente: { id: '1', nombre_fantasia: 'Kiosco' }, saldoPendiente: 6000 },
      ]
      mockRpc.mockResolvedValue({
        data: { clientes, consistencia: { clientes_con_desvio: [] } },
        error: null,
      })

      const { result } = renderHook(() => useReportesFinancieros())
      let filas!: unknown[]
      await act(async () => {
        filas = await result.current.generarReporteCuentasPorCobrar()
      })

      expect(mockRpc).toHaveBeenCalledWith('reporte_cuentas_por_cobrar', { p_sucursal_id: null })
      expect(filas).toEqual(clientes)
    })

    // El auto-chequeo del RPC no sirve de nada si el front lo ignora.
    it('avisa cuando el saldo del trigger no coincide con el calculado', async () => {
      mockRpc.mockResolvedValue({
        data: {
          clientes: [],
          consistencia: {
            clientes_con_desvio: [
              { cliente_id: '1', nombre: 'Kiosco', saldo_calculado: 100, saldo_cuenta: 900 },
            ],
          },
        },
        error: null,
      })

      const { result } = renderHook(() => useReportesFinancieros())
      await act(async () => {
        await result.current.generarReporteCuentasPorCobrar()
      })

      expect(mockNotifyError).toHaveBeenCalledWith(expect.stringContaining('1 cliente'))
    })

    it('sin desvíos no molesta al usuario', async () => {
      mockRpc.mockResolvedValue({
        data: { clientes: [], consistencia: { clientes_con_desvio: [] } },
        error: null,
      })

      const { result } = renderHook(() => useReportesFinancieros())
      await act(async () => {
        await result.current.generarReporteCuentasPorCobrar()
      })

      expect(mockNotifyError).not.toHaveBeenCalled()
    })

    it('un error del RPC se avisa y devuelve lista vacía, no rompe la pantalla', async () => {
      mockRpc.mockResolvedValue({ data: null, error: { message: 'boom' } })

      const { result } = renderHook(() => useReportesFinancieros())
      let filas!: unknown[]
      await act(async () => {
        filas = await result.current.generarReporteCuentasPorCobrar()
      })

      expect(filas).toEqual([])
      expect(mockNotifyError).toHaveBeenCalledWith(expect.stringContaining('boom'))
    })
  })

  describe('generarReporteRentabilidad', () => {
    it('le pasa el rango de fechas al RPC', async () => {
      mockRpc.mockResolvedValue({ data: { productos: [], totales: {} }, error: null })

      const { result } = renderHook(() => useReportesFinancieros())
      await act(async () => {
        await result.current.generarReporteRentabilidad('2026-08-01', '2026-08-31')
      })

      expect(mockRpc).toHaveBeenCalledWith('reporte_rentabilidad', {
        p_desde: '2026-08-01',
        p_hasta: '2026-08-31',
        p_sucursal_id: null,
      })
    })

    it('sin fechas manda null, que en el RPC significa todo el histórico', async () => {
      mockRpc.mockResolvedValue({ data: { productos: [], totales: {} }, error: null })

      const { result } = renderHook(() => useReportesFinancieros())
      await act(async () => {
        await result.current.generarReporteRentabilidad()
      })

      expect(mockRpc).toHaveBeenCalledWith('reporte_rentabilidad', {
        p_desde: null,
        p_hasta: null,
        p_sucursal_id: null,
      })
    })

    it('desempaqueta productos y totales', async () => {
      const productos = [{ id: '1', nombre: 'Coca', margen: 400 }]
      const totales = { ingresosTotales: 1000, costosTotales: 600, margenTotal: 400 }
      mockRpc.mockResolvedValue({ data: { productos, totales }, error: null })

      const { result } = renderHook(() => useReportesFinancieros())
      let reporte!: { productos: unknown[]; totales: unknown }
      await act(async () => {
        reporte = await result.current.generarReporteRentabilidad()
      })

      expect(reporte.productos).toEqual(productos)
      expect(reporte.totales).toEqual(totales)
    })

    it('una respuesta vacía no rompe: devuelve la forma esperada', async () => {
      mockRpc.mockResolvedValue({ data: null, error: null })

      const { result } = renderHook(() => useReportesFinancieros())
      let reporte!: { productos: unknown[]; totales: unknown }
      await act(async () => {
        reporte = await result.current.generarReporteRentabilidad()
      })

      expect(reporte.productos).toEqual([])
      expect(reporte.totales).toEqual({})
    })
  })
})
