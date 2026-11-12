/**
 * #1543 — `verificarClaveDeAlta` pregunta si un alta en duda entró. Sólo una
 * respuesta limpia sin fila es "no entró": si un error se leyera así, se
 * acuñaría otra clave y volvería el pedido duplicado.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const { from, maybeSingle, select, eq } = vi.hoisted(() => {
  const maybeSingle = vi.fn()
  const builder: Record<string, unknown> = {}
  const select = vi.fn(() => builder)
  const eq = vi.fn(() => builder)
  builder.select = select
  builder.eq = eq
  builder.abortSignal = vi.fn(() => builder)
  builder.maybeSingle = maybeSingle
  return { from: vi.fn(() => builder), maybeSingle, select, eq }
})

vi.mock('../supabase/base', () => ({ supabase: { from, rpc: vi.fn() } }))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import { verificarClaveDeAlta } from './usePedidosQuery'

describe('verificarClaveDeAlta', () => {
  beforeEach(() => vi.clearAllMocks())

  it('pide sólo el id de pedidos por offline_id', async () => {
    maybeSingle.mockResolvedValue({ data: null, error: null })
    await verificarClaveDeAlta('clave-1')
    expect(from).toHaveBeenCalledWith('pedidos')
    expect(select).toHaveBeenCalledWith('id')
    expect(eq).toHaveBeenCalledWith('offline_id', 'clave-1')
  })

  it('con la fila: entró, con su número', async () => {
    maybeSingle.mockResolvedValue({ data: { id: 501 }, error: null })
    expect(await verificarClaveDeAlta('clave-1')).toEqual({ resultado: 'entro', pedidoId: '501' })
  })

  it('respuesta limpia sin fila: no entró', async () => {
    maybeSingle.mockResolvedValue({ data: null, error: null })
    expect(await verificarClaveDeAlta('clave-1')).toEqual({ resultado: 'no_entro' })
  })

  it('un error, aun con código, no es "no entró"', async () => {
    maybeSingle.mockResolvedValue({ data: null, error: { message: 'TypeError: Failed to fetch', code: '' } })
    expect(await verificarClaveDeAlta('clave-1')).toEqual({ resultado: 'sin_respuesta' })
    maybeSingle.mockResolvedValue({ data: null, error: { message: 'permission denied', code: '42501' } })
    expect(await verificarClaveDeAlta('clave-1')).toEqual({ resultado: 'sin_respuesta' })
  })

  it('si tira, tampoco', async () => {
    maybeSingle.mockRejectedValue(new Error('boom'))
    expect(await verificarClaveDeAlta('clave-1')).toEqual({ resultado: 'sin_respuesta' })
  })
})
