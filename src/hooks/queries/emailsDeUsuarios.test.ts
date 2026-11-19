/**
 * 1601-b5 (#1601, D53): los emails de otros usuarios salen de la RPC `emails_de_usuarios`, y
 * de la tabla sólo mientras la RPC no exista (PGRST202). Un error se tira, para que la pantalla
 * lo muestre (H2 de la revisión de C6): antes se tragaba y la lista quedaba sin emails sin aviso.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'

const rpc = vi.fn()
const inFn = vi.fn()
const select = vi.fn(() => ({ in: inFn }))
const from = vi.fn(() => ({ select }))

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a), from: (...a: unknown[]) => from(...(a as [])) },
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import { fetchEmailsDeUsuarios } from './emailsDeUsuarios'

beforeEach(() => {
  rpc.mockReset()
  inFn.mockReset()
  select.mockClear()
  from.mockClear()
})

describe('fetchEmailsDeUsuarios', () => {
  it('pide los emails por la RPC, sin repetir ids, y no lee la tabla', async () => {
    rpc.mockResolvedValue({ data: [{ id: 'a', email: 'a@x.invalid' }, { id: 'b', email: null }], error: null })
    const mapa = await fetchEmailsDeUsuarios(['b', 'a', 'a', ''])
    expect(rpc).toHaveBeenCalledWith('emails_de_usuarios', { p_ids: ['a', 'b'] })
    expect(from).not.toHaveBeenCalled()
    expect([...mapa]).toEqual([['a', 'a@x.invalid']])
  })

  it('sin la RPC (la migración todavía no está) los lee de la tabla, sólo id y email', async () => {
    rpc.mockResolvedValue({ data: null, error: { code: 'PGRST202', message: 'no existe' } })
    inFn.mockResolvedValue({ data: [{ id: 'a', email: 'a@x.invalid' }], error: null })
    const mapa = await fetchEmailsDeUsuarios(['a'])
    expect(from).toHaveBeenCalledWith('perfiles')
    expect(select).toHaveBeenCalledWith('id, email')
    expect(mapa.get('a')).toBe('a@x.invalid')
  })

  it('con otro error lo tira, en castellano, y no lee la tabla', async () => {
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
