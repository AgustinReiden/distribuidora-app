/**
 * Los encuadres de impuestos internos los edita sólo un admin de todas las sucursales
 * (decisión del dueño D49, 1564-b4 del plan #1603). El rechazo del server (42501 de la policy en
 * el alta, PGRST116 de una edición que no encuentra la fila) no se muestra crudo.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'

const m = vi.hoisted(() => ({
  respuesta: { data: null, error: null } as { data: unknown; error: unknown },
}))

vi.mock('../supabase/base', () => {
  const single = () => Promise.resolve(m.respuesta)
  const conSelect = { select: () => ({ single }) }
  return {
    supabase: {
      from: () => ({
        insert: () => conSelect,
        update: () => ({ eq: () => conSelect }),
      }),
    },
  }
})

import { useGuardarEncuadreIIMutation } from './useImpuestosInternosQuery'

function wrapper({ children }: { children: ReactNode }) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const MENSAJE = 'Los encuadres de impuestos internos los edita sólo un administrador de todas las sucursales.'

beforeEach(() => {
  m.respuesta = { data: null, error: null }
})

describe('useGuardarEncuadreIIMutation — sólo un admin de todas las sucursales (1564-b4)', () => {
  it('el alta rechazada por la policy (42501) da un mensaje en castellano, no el del server', async () => {
    m.respuesta = { data: null, error: { code: '42501', message: 'new row violates row-level security policy for table "ii_encuadres"' } }
    const { result } = renderHook(() => useGuardarEncuadreIIMutation(), { wrapper })
    await act(async () => {
      await expect(result.current.mutateAsync({ data: { nombre: 'Bebidas' } })).rejects.toThrow(MENSAJE)
    })
  })

  it('la edición que no encuentra la fila (PGRST116) da el mismo mensaje', async () => {
    m.respuesta = { data: null, error: { code: 'PGRST116', message: 'JSON object requested, multiple (or no) rows returned' } }
    const { result } = renderHook(() => useGuardarEncuadreIIMutation(), { wrapper })
    await act(async () => {
      await expect(result.current.mutateAsync({ id: '3', data: { nombre: 'Bebidas' } })).rejects.toThrow(MENSAJE)
    })
  })

  it('el nombre repetido sigue con su mensaje', async () => {
    m.respuesta = { data: null, error: { code: '23505', message: 'duplicate key' } }
    const { result } = renderHook(() => useGuardarEncuadreIIMutation(), { wrapper })
    await act(async () => {
      await expect(result.current.mutateAsync({ data: { nombre: 'Bebidas' } })).rejects.toThrow('Ya existe un encuadre llamado "Bebidas"')
    })
  })

  it('un admin de todas guarda y devuelve el id', async () => {
    m.respuesta = { data: { id: 7 }, error: null }
    const { result } = renderHook(() => useGuardarEncuadreIIMutation(), { wrapper })
    let id: string | undefined
    await act(async () => {
      id = await result.current.mutateAsync({ data: { nombre: 'Bebidas' } })
    })
    expect(id).toBe('7')
  })
})
