/**
 * D13 (ola 3 de #1603, T9): el rechazo del server por un nombre de zona repetido nombra la zona que ya
 * existe («Ya existe la zona «Centro»…»): el alta y el renombre lo muestran tal cual, no «La zona X ya
 * existe» con lo que se tipeó. Un 23505 sin ese mensaje (dos altas cruzadas) sigue con el de siempre.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

let resultado: { data: unknown; error: { code: string; message: string } | null } = { data: null, error: null }

function cadena() {
  const c: Record<string, unknown> = {}
  for (const m of ['insert', 'update', 'select', 'eq', 'single']) c[m] = () => c
  c.then = (resolve: (v: unknown) => unknown) => Promise.resolve(resultado).then(resolve)
  return c
}

vi.mock('../supabase/base', () => ({
  supabase: { from: () => cadena(), rpc: vi.fn(), auth: { getUser: vi.fn() } },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearZonaMutation, useRenombrarZonaMutation } from './useZonasQuery'

const wrapper = ({ children }: { children: React.ReactNode }) => (
  <QueryClientProvider client={new QueryClient({ defaultOptions: { mutations: { retry: false } } })}>{children}</QueryClientProvider>
)

const DEL_SERVER = 'Ya existe la zona «Centro» en esta sucursal: es el mismo nombre que «CENTRO» (no se distinguen mayúsculas ni espacios). Usá esa zona o elegí otro nombre.'

beforeEach(() => {
  resultado = { data: null, error: null }
})

describe('zonas · el rechazo del nombre repetido (D13)', () => {
  it('el alta muestra el mensaje del server, que nombra la zona que ya existe', async () => {
    resultado = { data: null, error: { code: '23505', message: DEL_SERVER } }
    const { result } = renderHook(() => useCrearZonaMutation(), { wrapper })
    await expect(result.current.mutateAsync('CENTRO')).rejects.toThrow('Ya existe la zona «Centro»')
  })

  it('el renombre también', async () => {
    resultado = { data: null, error: { code: '23505', message: DEL_SERVER } }
    const { result } = renderHook(() => useRenombrarZonaMutation(), { wrapper })
    await expect(result.current.mutateAsync({ id: '20', nombre: 'CENTRO' })).rejects.toThrow('Ya existe la zona «Centro»')
  })

  it('un 23505 del índice sin el mensaje del trigger sigue con el de siempre', async () => {
    resultado = { data: null, error: { code: '23505', message: 'duplicate key value violates unique constraint "zonas_nombre_unico_por_sucursal"' } }
    const { result } = renderHook(() => useCrearZonaMutation(), { wrapper })
    await expect(result.current.mutateAsync('CENTRO')).rejects.toThrow('La zona "CENTRO" ya existe')
  })
})
