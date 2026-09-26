/**
 * `contarReferenciasDeCliente` decide si la app ofrece "Eliminar" o "Desactivar".
 *
 * EL INCIDENTE (mig 265)
 * ----------------------
 * `pagos_cliente_id_fkey` era ON DELETE CASCADE. Al deduplicar clientes se borró
 * la ficha vieja y se llevó puestos sus cobros: el trigger recalculó y boletas
 * pagadas volvieron a figurar como deuda (el #418, entre otras, por $92.400).
 * Desde la 265 la FK es RESTRICT, así que un pago también traba el DELETE — y si
 * este conteo no lo mirara, a un cliente con solo pagos a cuenta la app le
 * ofrecería "Eliminar" y la base lo rechazaría.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const filasPorTabla: Record<string, unknown[]> = {}

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => ({
      select: () => ({
        eq: () => Promise.resolve({ data: filasPorTabla[tabla] ?? [], error: null }),
      }),
    }),
    rpc: vi.fn(),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { contarReferenciasDeCliente } from './useClientesQuery'

beforeEach(() => {
  for (const k of Object.keys(filasPorTabla)) delete filasPorTabla[k]
})

describe('contarReferenciasDeCliente', () => {
  it('sin nada colgando, el borrado no está trabado', async () => {
    const r = await contarReferenciasDeCliente('7')
    expect(r.bloqueanBorrado).toBe(false)
    expect(r.pagos).toBe(0)
  })

  it('un pago solo, sin pedidos, traba el borrado (FK RESTRICT desde la 265)', async () => {
    filasPorTabla.pagos = [{ id: 1 }, { id: 2 }]
    const r = await contarReferenciasDeCliente('7')
    expect(r.pedidos.cantidad).toBe(0)
    expect(r.pagos).toBe(2)
    expect(r.bloqueanBorrado).toBe(true)
  })

  it('suma los pedidos y los cuenta junto con los pagos', async () => {
    filasPorTabla.pedidos = [{ total: 1000 }, { total: '250.50' }]
    filasPorTabla.pagos = [{ id: 1 }]
    const r = await contarReferenciasDeCliente('7')
    expect(r.pedidos).toEqual({ cantidad: 2, total: 1250.5 })
    expect(r.pagos).toBe(1)
    expect(r.bloqueanBorrado).toBe(true)
  })
})
