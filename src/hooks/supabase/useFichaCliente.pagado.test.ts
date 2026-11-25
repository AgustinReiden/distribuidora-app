/**
 * frv-B3 (tanda 6 de #1603; decisión del dueño del 24/11): el «Pagado» de la ficha del cliente
 * cuenta sólo la plata cobrada. La nota de crédito y el adelanto de sueldo no son plata y van
 * aparte; lo cobrado que después se aplicó desde saldo a favor SÍ cuenta.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'

const m = vi.hoisted(() => ({
  pagos: [] as Array<Record<string, unknown>>,
  selectsPagos: [] as string[],
}))

vi.mock('./base', () => {
  const tabla = (nombre: string) => {
    const builder: Record<string, unknown> = {}
    const enc = () => builder
    builder.select = (cols: string) => { if (nombre === 'pagos') m.selectsPagos.push(cols); return builder }
    builder.eq = enc
    builder.order = enc
    builder.range = () => Promise.resolve({ data: nombre === 'pagos' ? m.pagos : [], error: null })
    builder.limit = () => Promise.resolve({ data: [], error: null })
    return builder
  }
  // La RPC de las notas del preventista (tanda 6 bis): sin notas.
  return { supabase: { from: (n: string) => tabla(n), rpc: () => tabla('rpc') }, notifyError: vi.fn() }
})

import { useFichaCliente } from './useFichaCliente'

beforeEach(() => { m.selectsPagos = []; m.pagos = [] })

async function ficha() {
  const { result } = renderHook(() => useFichaCliente('440'))
  await waitFor(() => expect(result.current.estadisticas).not.toBeNull())
  return result.current.estadisticas!
}

describe('useFichaCliente — «Pagado» (frv-B3)', () => {
  it('10.000 en efectivo y una nota de crédito de 5.000: Pagado 10.000, y la nota aparte', async () => {
    m.pagos = [
      { monto: 10000, forma_pago: 'efectivo', de_saldo_a_favor: false, pedido_id: 1 },
      { monto: 5000, forma_pago: 'nota_credito', de_saldo_a_favor: true, pedido_id: 1 },
    ]
    const e = await ficha()
    expect(e.montoPagado).toBe(10000)
    expect(e.notaCreditoAplicada).toBe(5000)
    expect(e.saldoAFavorAplicado).toBe(0)
  })

  it('pide la forma de pago y las marcas, que son las que distinguen', async () => {
    await ficha()
    expect(m.selectsPagos[0]).toEqual(expect.stringContaining('forma_pago'))
    expect(m.selectsPagos[0]).toEqual(expect.stringContaining('de_saldo_a_favor'))
  })

  it('el pago a cuenta que una boleta absorbió sigue en Pagado; el adelanto de sueldo va aparte', async () => {
    m.pagos = [
      { monto: 2000, forma_pago: 'efectivo', pedido_id: null },
      { monto: 8000, forma_pago: 'efectivo', de_saldo_a_favor: true, pedido_id: 2 },
      { monto: 3000, forma_pago: 'adelanto_sueldo', pedido_id: 3 },
    ]
    const e = await ficha()
    expect(e.montoPagado).toBe(10000)
    expect(e.saldoAFavorAplicado).toBe(8000)
    expect(e.adelantoSueldo).toBe(3000)
    expect(e.notaCreditoAplicada).toBe(0)
  })
})
