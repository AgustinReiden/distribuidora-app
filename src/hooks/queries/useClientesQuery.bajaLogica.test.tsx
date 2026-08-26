/**
 * Tests de la baja lógica de clientes.
 *
 * EL INCIDENTE
 * ------------
 * Borrar un cliente con pedidos ya no se puede: desde la mig 200 la FK es
 * `ON DELETE RESTRICT` (antes era SET NULL, y así 9 pedidos por $200.070
 * quedaron sin dueño — mig 199). La app pasó a ofrecer "desactivar" en su lugar
 * y le decía al usuario, textualmente, que el cliente "deja de aparecer en las
 * listas".
 *
 * Era falso: `fetchClientes` no filtraba por `activo` y ningún consumidor lo
 * hacía tampoco. En prod había dos clientes con `activo = false` visibles en el
 * panel, en el selector de pedidos y en los recorridos. La única acción que la
 * app ofrecía no tenía ningún efecto observable, y por eso se percibía como
 * "no se pueden eliminar clientes".
 *
 * Lo que fijan estos tests es el filtro y su contracara: que por defecto no
 * vengan inactivos, que `includeInactivos` sí los traiga (es el único camino
 * para reactivar uno), y que las dos variantes no compartan entrada de caché
 * —si la compartieran, prender el check devolvería la lista filtrada—.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const eq = vi.fn()
const order = vi.fn()
const select = vi.fn()
const from = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (...args: unknown[]) => from(...args),
    rpc: vi.fn(),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useClientesQuery, clientesKeys } from './useClientesQuery'

const FILAS = [{ id: '1', nombre_fantasia: 'Activo', activo: true }]

/**
 * El builder de PostgREST es encadenable y "thenable": `fetchClientes` puede
 * terminar en `.order(...)` o en `.eq(...)` según el flag, así que las dos
 * puntas tienen que resolver a `{ data, error }`.
 */
function armarBuilder() {
  const resultado = Promise.resolve({ data: FILAS, error: null })
  const builder: Record<string, unknown> = {}
  builder.select = select.mockReturnValue(builder)
  builder.order = order.mockReturnValue(builder)
  builder.eq = eq.mockReturnValue(resultado)
  builder.then = resultado.then.bind(resultado)
  return builder
}

beforeEach(() => {
  vi.clearAllMocks()
  from.mockImplementation(() => armarBuilder())
})

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function nuevoQueryClient() {
  return new QueryClient({ defaultOptions: { queries: { retry: false } } })
}

describe('useClientesQuery — baja lógica', () => {
  it('por defecto pide solo los clientes activos', async () => {
    const qc = nuevoQueryClient()
    const { result } = renderHook(() => useClientesQuery(), { wrapper: makeWrapper(qc) })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(from).toHaveBeenCalledWith('clientes')
    expect(eq).toHaveBeenCalledWith('activo', true)
  })

  it('con includeInactivos NO filtra, que es como se llega a reactivar uno', async () => {
    const qc = nuevoQueryClient()
    const { result } = renderHook(
      () => useClientesQuery({ includeInactivos: true }),
      { wrapper: makeWrapper(qc) }
    )

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(from).toHaveBeenCalledWith('clientes')
    expect(eq).not.toHaveBeenCalledWith('activo', true)
  })

  it('las dos variantes no comparten entrada de caché', () => {
    // Si compartieran clave, prender "Ver inactivos" serviría la lista ya
    // filtrada desde la caché y el check parecería no hacer nada.
    expect(clientesKeys.lists(1, false)).not.toEqual(clientesKeys.lists(1, true))
  })
})
