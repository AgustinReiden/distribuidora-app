/**
 * Encargo de la lente de B12b (1600-b4 de #1600): el motivo de una clave que ya
 * tiene otro pedido iba al log (consola y Sentry) con el cliente y el total de
 * ese otro pedido. A Sentry y a la consola no van datos de clientes.
 */
import { describe, it, expect, vi } from 'vitest'

// Sin `.env` (como en CI) el cliente real de supabase no se puede crear al importar.
vi.mock('../../lib/supabase', () => ({
  supabase: { from: vi.fn(), rpc: vi.fn(), rest: { headers: {} }, auth: { refreshSession: vi.fn() } },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))

import { verificarRespuestaIdempotente } from '../useOfflineSync'

describe('verificarRespuestaIdempotente: el motivo no lleva datos del otro pedido', () => {
  it('sin el cliente ni el total del pedido que ya tenía la clave', () => {
    const sospecha = verificarRespuestaIdempotente(
      { idempotente: true, clienteId: 98765, total: 43210.5, cargoEnvio: 0 },
      { clienteId: '7', total: 100 },
    )
    expect(sospecha?.terminal).toBe(true)
    expect(sospecha?.motivo).toMatch(/ya la tiene otro pedido/)
    expect(sospecha?.motivo).not.toMatch(/98765/)
    expect(sospecha?.motivo).not.toMatch(/43210/)
    expect(sospecha?.motivo).not.toMatch(/cliente \d|total \d/)
  })
})
