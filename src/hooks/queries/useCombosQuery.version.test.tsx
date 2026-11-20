/**
 * «Otro lo cambió mientras lo editabas» en los combos (1599-b8, C4b de #1603). `guardarCombo` le
 * manda a `guardar_combo` la versión con la que se abrió el combo (`updated_at_esperado`) y la de
 * cada combo del orden que reescribe (`versiones`); si otro guardó en el medio, la RPC no escribe
 * nada y devuelve 'combo_cambiado' u 'orden_cambiado'. La lista de combos se vuelve a pedir, para
 * que el formulario abierto recalcule el orden con lo de ahora.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const m = vi.hoisted(() => ({
  rpcs: [] as Array<{ fn: string; args: Record<string, unknown> }>,
  respuesta: { data: { success: true, id: 7 } as unknown, error: null as unknown },
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      m.rpcs.push({ fn, args })
      return Promise.resolve(m.respuesta)
    },
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))
vi.mock('../../lib/offlineDb', () => ({ cacheData: vi.fn(() => Promise.resolve()), getCachedData: vi.fn(() => Promise.resolve(null)) }))

import { guardarCombo, useGuardarComboMutation, combosKeys, type ComboFormInput } from './useCombosQuery'
import { ConflictoDeVersionError } from '../../utils/conflictoDeVersion'

const BASE: ComboFormInput = {
  id: '7',
  nombre: 'Fernet + Coca',
  precio: 11000,
  fechaInicio: '2026-11-01',
  componentes: [{ cantidad: 1, sueltos: ['10'], categorias: [] }, { cantidad: 1, sueltos: ['11'], categorias: [] }],
}

beforeEach(() => {
  m.rpcs = []
  m.respuesta = { data: { success: true, id: 7 }, error: null }
})

describe('guardarCombo · versión (1599-b8)', () => {
  it('manda updated_at_esperado y las versiones del orden tal cual llegaron', async () => {
    await guardarCombo({
      ...BASE,
      updatedAtEsperado: '2026-11-18T10:00:00.123456+00:00',
      orden: [8, 7],
      versiones: { 8: '2026-11-18T09:00:00+00:00' },
    })

    const p = m.rpcs[0].args.p_combo as Record<string, unknown>
    expect(m.rpcs[0].fn).toBe('guardar_combo')
    expect(p.updated_at_esperado).toBe('2026-11-18T10:00:00.123456+00:00')
    expect(p.orden).toEqual([8, 7])
    expect(p.versiones).toEqual({ 8: '2026-11-18T09:00:00+00:00' })
  })

  it('manda los combos que tenía la lista (C4b v2)', async () => {
    await guardarCombo({ ...BASE, vistos: [7, 8, 9] })

    expect((m.rpcs[0].args.p_combo as Record<string, unknown>).vistos).toEqual([7, 8, 9])
  })

  it('un combo nuevo no manda versión propia; sin orden no manda versiones', async () => {
    await guardarCombo({ ...BASE, id: undefined, updatedAtEsperado: '2026-11-18T10:00:00+00:00', versiones: { 8: null } })

    const p = m.rpcs[0].args.p_combo as Record<string, unknown>
    expect(p).not.toHaveProperty('updated_at_esperado')
    expect(p).not.toHaveProperty('versiones')
  })

  it('si otro lo cambió, rechaza con un ConflictoDeVersionError con su código', async () => {
    m.respuesta = { data: { success: false, codigo: 'combo_cambiado', error: 'Otro usuario cambió este combo mientras lo editabas: no se guardó nada.' }, error: null }

    const error = await guardarCombo({ ...BASE, updatedAtEsperado: '2026-11-18T10:00:00+00:00' }).catch(e => e)

    expect(error).toBeInstanceOf(ConflictoDeVersionError)
    expect(error).toMatchObject({ codigo: 'combo_cambiado', status: 409 })
    expect((error as Error).message).toContain('Lo que cargaste sigue en esta ventana')
  })

  it('un rechazo que no es de versión sigue siendo un Error con el mensaje del server', async () => {
    m.respuesta = { data: { success: false, error: 'El combo necesita un nombre.' }, error: null }

    const error = await guardarCombo(BASE).catch(e => e)

    expect(error).not.toBeInstanceOf(ConflictoDeVersionError)
    expect((error as Error).message).toBe('El combo necesita un nombre.')
  })
})

describe('useGuardarComboMutation · si otro cambió el orden, vuelve a pedir los combos', () => {
  it('invalida la lista ante un conflicto', async () => {
    m.respuesta = { data: { success: false, codigo: 'orden_cambiado', error: 'Otro usuario cambió un combo que compite con éste.' }, error: null }
    const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useGuardarComboMutation(), {
      wrapper: ({ children }: { children: React.ReactNode }) => <QueryClientProvider client={qc}>{children}</QueryClientProvider>,
    })

    await result.current.mutateAsync({ ...BASE, orden: [7, 8], versiones: { 8: null } }).catch(() => {})

    await vi.waitFor(() => expect(invalidar).toHaveBeenCalledWith({ queryKey: combosKeys.all(1) }))
  })
})
