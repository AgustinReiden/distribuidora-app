import { describe, it, expect, vi } from 'vitest'
import { registrarOrigenPrecios, mensajeOrigenPendiente } from './origenPrecioPendiente'

describe('registrarOrigenPrecios (C4b v2)', () => {
  const origenes = [{ producto_id: 10, origen_precio: 'escala' }]

  it('llama a registrar_origen_precio_items con el pedido y los orígenes', async () => {
    const rpc = vi.fn().mockResolvedValue({ data: null, error: null })

    const r = await registrarOrigenPrecios(rpc, 7, origenes)

    expect(r).toEqual({ ok: true })
    expect(rpc).toHaveBeenCalledWith('registrar_origen_precio_items', { p_pedido_id: 7, p_origenes: origenes })
  })

  it('si el server falla, no lanza: devuelve el error para avisar y ofrecer reintentar', async () => {
    const error = { code: 'P0001', message: 'algo' }
    const rpc = vi.fn().mockResolvedValue({ data: null, error })

    const r = await registrarOrigenPrecios(rpc, 7, origenes)

    expect(r.ok).toBe(false)
  })

  it('si la red cae (la promesa se rechaza), tampoco lanza', async () => {
    const rpc = vi.fn().mockRejectedValue(new TypeError('Failed to fetch'))

    const r = await registrarOrigenPrecios(rpc, 7, origenes)

    expect(r.ok).toBe(false)
  })

  it('el aviso dice qué quedó guardado, qué no y qué afecta', () => {
    const m = mensajeOrigenPendiente(7)
    expect(m).toContain('#7')
    expect(m).toMatch(/se guardaron/)
    expect(m).toMatch(/de dónde salió el precio/)
    expect(m).toMatch(/comisión/)
  })
})
