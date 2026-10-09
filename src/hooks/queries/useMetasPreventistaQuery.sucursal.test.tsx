import React from 'react'
import { describe, expect, it, vi } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const mocks = vi.hoisted(() => ({
  currentSucursalId: null as number | null,
  from: vi.fn(),
  rpc: vi.fn(),
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (...args: unknown[]) => mocks.from(...args),
    rpc: (...args: unknown[]) => mocks.rpc(...args),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: mocks.currentSucursalId }),
}))

import { useAvanceMetasQuery, useMetasPreventistaQuery } from './useMetasPreventistaQuery'

function wrapper() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={client}>{children}</QueryClientProvider>
  }
}

describe('queries de metas por sucursal', () => {
  it('waits for the active branch before loading either query', async () => {
    mocks.currentSucursalId = null
    mocks.from.mockReset()
    mocks.rpc.mockReset()

    const { result: avance, rerender } = renderHook(
      () => [useAvanceMetasQuery(), useMetasPreventistaQuery()] as const,
      { wrapper: wrapper() },
    )

    expect(avance.current[0].fetchStatus).toBe('idle')
    expect(avance.current[1].fetchStatus).toBe('idle')
    expect(mocks.rpc).not.toHaveBeenCalled()
    expect(mocks.from).not.toHaveBeenCalled()

    mocks.rpc.mockResolvedValue({ data: null, error: null })
    const builder = new Proxy({} as Record<string, unknown>, {
      get(target, property) {
        if (property === 'then') {
          return (resolve: (value: unknown) => void) => resolve({ data: [], error: null })
        }
        return (..._args: unknown[]) => target
      },
    })
    mocks.from.mockReturnValue(builder)
    mocks.currentSucursalId = 3
    rerender()

    await waitFor(() => {
      expect(mocks.rpc).toHaveBeenCalledOnce()
      expect(mocks.from).toHaveBeenCalledOnce()
    })
  })
})
