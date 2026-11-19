/**
 * 1601-b5 (#1601, D53): los emails de otros usuarios salen sólo de la RPC `emails_de_usuarios`
 * (la tabla ya no los da por REST), y nunca rompen la pantalla.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const rpc = vi.fn()
const from = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a), from: (...a: unknown[]) => from(...a) },
}))

import { fetchEmailsDeUsuarios } from './emailsDeUsuarios'

beforeEach(() => {
  rpc.mockReset()
  from.mockReset()
})

describe('fetchEmailsDeUsuarios', () => {
  it('pide los emails por la RPC, sin repetir ids, y no lee la tabla', async () => {
    rpc.mockResolvedValue({ data: [{ id: 'a', email: 'a@x.invalid' }, { id: 'b', email: null }], error: null })
    const mapa = await fetchEmailsDeUsuarios(['a', 'b', 'a', ''])
    expect(rpc).toHaveBeenCalledWith('emails_de_usuarios', { p_ids: ['a', 'b'] })
    expect(from).not.toHaveBeenCalled()
    expect([...mapa]).toEqual([['a', 'a@x.invalid']])
  })

  it('con un error (también si la RPC no existe), o sin red, devuelve vacío y no lee la tabla', async () => {
    rpc.mockResolvedValue({ data: null, error: { code: 'PGRST202', message: 'no existe' } })
    expect((await fetchEmailsDeUsuarios(['a'])).size).toBe(0)
    rpc.mockResolvedValue({ data: null, error: { code: '42501', message: 'permiso' } })
    expect((await fetchEmailsDeUsuarios(['a'])).size).toBe(0)
    rpc.mockRejectedValue(new TypeError('Failed to fetch'))
    expect((await fetchEmailsDeUsuarios(['a'])).size).toBe(0)
    expect(from).not.toHaveBeenCalled()
  })

  it('sin ids no llama a nadie', async () => {
    expect((await fetchEmailsDeUsuarios([])).size).toBe(0)
    expect(rpc).not.toHaveBeenCalled()
  })
})
