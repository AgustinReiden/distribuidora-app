/**
 * 1601-b5 (#1601, D53): los emails de otros usuarios salen sólo de la RPC `emails_de_usuarios`
 * (desde los cierres de C6 la tabla ya no los da por REST). Un error se tira, para que la
 * pantalla lo muestre (H2 de la revisión de C6).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const rpc = vi.fn()
const from = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a), from: (...a: unknown[]) => from(...a) },
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import { fetchEmailsDeUsuarios } from './emailsDeUsuarios'

beforeEach(() => {
  rpc.mockReset()
  from.mockReset()
})

describe('fetchEmailsDeUsuarios', () => {
  it('pide los emails por la RPC, sin repetir ids, y no lee la tabla', async () => {
    rpc.mockResolvedValue({ data: [{ id: 'a', email: 'a@x.invalid' }, { id: 'b', email: null }], error: null })
    const mapa = await fetchEmailsDeUsuarios(['b', 'a', 'a', ''])
    expect(rpc).toHaveBeenCalledWith('emails_de_usuarios', { p_ids: ['a', 'b'] })
    expect(from).not.toHaveBeenCalled()
    expect([...mapa]).toEqual([['a', 'a@x.invalid']])
  })

  it('con un error (también si la RPC no existe) lo tira y no lee la tabla', async () => {
    rpc.mockResolvedValue({ data: null, error: { code: 'PGRST202', message: 'no existe' } })
    await expect(fetchEmailsDeUsuarios(['a'])).rejects.toThrow()
    rpc.mockResolvedValue({ data: null, error: { code: '42501', message: 'permission denied' } })
    await expect(fetchEmailsDeUsuarios(['a'])).rejects.toThrow()
    expect(from).not.toHaveBeenCalled()
  })

  it('sin red lo tira', async () => {
    rpc.mockRejectedValue(new TypeError('Failed to fetch'))
    await expect(fetchEmailsDeUsuarios(['a'])).rejects.toThrow()
  })

  it('sin ids no llama a nadie', async () => {
    expect((await fetchEmailsDeUsuarios([])).size).toBe(0)
    expect(rpc).not.toHaveBeenCalled()
  })
})
