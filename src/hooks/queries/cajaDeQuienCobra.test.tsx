/**
 * D6 (T5 de #1690, decisión del dueño 26/11): confirmar la rendición de un chofer traba sólo sus
 * cobros. La fecha mínima del cobro y el «rendición cerrada» de los masivos preguntan por la caja de
 * quien cobra (`p_cobrado_por`); sin quien, por la de la sucursal, como antes.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { ReactNode } from 'react'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a) },
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))

import { useFechaMinimaPago, useFechasMinimasPorCobrador } from './useUltimaFechaCajaCerradaQuery'
import { useRendicionCerradaQuery } from './useRendicionCerradaQuery'

function envoltorio() {
  const cliente = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={cliente}>{children}</QueryClientProvider>
  )
}

beforeEach(() => {
  rpc.mockReset()
})

describe('la caja de quien cobra (D6)', () => {
  it('la fecha mínima del cobro es la de la caja de quien cobra', async () => {
    rpc.mockResolvedValue({ data: '2026-11-27', error: null })
    const { result } = renderHook(() => useFechaMinimaPago(true, 'chofer-b'), { wrapper: envoltorio() })

    await waitFor(() => expect(result.current).toBe('2026-11-28'))
    expect(rpc).toHaveBeenCalledWith('ultima_fecha_caja_cerrada', { p_sucursal_id: 1, p_cobrado_por: 'chofer-b' })
  })

  it('sin quien cobra, la de la sucursal (no manda p_cobrado_por)', async () => {
    rpc.mockResolvedValue({ data: null, error: null })
    renderHook(() => useFechaMinimaPago(true, null), { wrapper: envoltorio() })

    await waitFor(() => expect(rpc).toHaveBeenCalled())
    expect(rpc).toHaveBeenCalledWith('ultima_fecha_caja_cerrada', { p_sucursal_id: 1 })
  })

  // Anular un cobro o cambiarle la forma: la caja de quien lo cobró (como el server); sin dueño, la de la sucursal.
  it('la fecha mínima de cada cobro hecho es la de la caja de quien lo cobró', async () => {
    rpc.mockImplementation(async (_fn: string, args: { p_cobrado_por?: string }) =>
      ({ data: args.p_cobrado_por === 'chofer-a' ? '2026-11-27' : null, error: null }))
    const { result } = renderHook(() => useFechasMinimasPorCobrador(['chofer-a', null, 'chofer-b', 'chofer-a']), { wrapper: envoltorio() })

    await waitFor(() => expect(result.current.get('chofer-a')).toBe('2026-11-28'))
    expect(result.current.has('chofer-b')).toBe(false)
    expect(result.current.has(null)).toBe(false)
    expect(rpc).toHaveBeenCalledTimes(3)
    expect(rpc).toHaveBeenCalledWith('ultima_fecha_caja_cerrada', { p_sucursal_id: 1 })
  })

  it('el «rendición cerrada» de los masivos pregunta por la rendición de quien cobra', async () => {
    rpc.mockResolvedValue({ data: false, error: null })
    const { result } = renderHook(() => useRendicionCerradaQuery('2026-11-27', true, 'enc-1'), { wrapper: envoltorio() })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toBe(false)
    expect(rpc).toHaveBeenCalledWith('rendicion_dia_cerrada', {
      p_fecha: '2026-11-27', p_sucursal_id: 1, p_cobrado_por: 'enc-1',
    })
  })

  it('sin quien cobra, cualquier rendición de la sucursal ese día', async () => {
    rpc.mockResolvedValue({ data: true, error: null })
    renderHook(() => useRendicionCerradaQuery('2026-11-27', true), { wrapper: envoltorio() })

    await waitFor(() => expect(rpc).toHaveBeenCalled())
    expect(rpc).toHaveBeenCalledWith('rendicion_dia_cerrada', { p_fecha: '2026-11-27', p_sucursal_id: 1 })
  })
})
