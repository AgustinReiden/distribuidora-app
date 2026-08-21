/**
 * Tests del contrato de stock al guardar la ficha de producto.
 *
 * EL INCIDENTE (Taco Pozo, 19/08/2026 — producto 340, COCA COLA X 3LTS)
 * ---------------------------------------------------------------------
 * El admin registró la compra de 20 unidades (stock 6 → 26). En los 90
 * segundos siguientes el preventista cargó los cuatro pedidos de los ONE
 * BLOCK: 5 + 5 + 5 + 5 = las 20 unidades, y el stock volvió a 6. Correcto.
 *
 * 29 segundos después, el admin guardó la ficha del producto — que seguía
 * abierta con el snapshot anterior a los pedidos. El form mandó `stock: 26`
 * como valor ABSOLUTO y el `UPDATE` lo escribió tal cual: 6 → 26. Las 20
 * unidades vendidas reaparecieron en stock y nadie vio un error. De yapa se
 * revirtió el precio (26700 → 25500 → 26700), porque el snapshot también era
 * viejo. En `stock_historico` quedó como `origen='auto'`, sin usuario: un
 * movimiento fantasma imposible de rastrear desde la app.
 *
 * DOS GUARDAS, que es lo que fijan estos tests:
 *   1. En una edición el stock viaja SOLO si el admin lo cambió a mano
 *      (`undefined` = "no tocar"). Guardar un precio no toca el saldo.
 *   2. Cuando sí viaja, va con `stock_esperado` y el update filtra por él
 *      (compare-and-swap). Si entró una venta en el medio no matchea ninguna
 *      fila y se aborta con un mensaje, en vez de pisar en silencio.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

/** Espía del builder de PostgREST: registra los `.eq()` y el payload. */
interface UpdateCall {
  payload: Record<string, unknown>
  eqs: Array<[string, unknown]>
}

const updateCalls: UpdateCall[] = []
/** Fila que devuelve el update; null simula "0 filas" (el CAS no matcheó). */
let updateResult: { stock: number } | null = { stock: 0 }
/** Stock que devuelve la relectura posterior al fallo del CAS. */
let stockActualEnBase: number | null = 26

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: vi.fn(),
    from: () => ({
      update: (payload: Record<string, unknown>) => {
        const call: UpdateCall = { payload, eqs: [] }
        updateCalls.push(call)
        const builder = {
          eq: (col: string, val: unknown) => {
            call.eqs.push([col, val])
            return builder
          },
          select: () => builder,
          maybeSingle: async () => ({ data: updateResult, error: null }),
        }
        return builder
      },
      // Relectura del stock actual cuando el CAS no matchea.
      select: () => {
        const builder = {
          eq: () => builder,
          maybeSingle: async () => ({
            data: stockActualEnBase === null ? null : { stock: stockActualEnBase },
            error: null,
          }),
        }
        return builder
      },
    }),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { useActualizarProductoMutation } from './useProductosQuery'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return renderHook(() => useActualizarProductoMutation(), { wrapper: makeWrapper(qc) })
}

describe('guardar la ficha de producto — contrato de stock', () => {
  beforeEach(() => {
    updateCalls.length = 0
    updateResult = { stock: 0 }
    stockActualEnBase = 26
  })

  it('sin stock en el payload no escribe la columna (guardar un precio no toca el saldo)', async () => {
    const { result } = setup()

    await result.current.mutateAsync({
      id: '340',
      data: { nombre: 'COCA COLA X 3LTS X 6UND', precio: 26700, stock: undefined },
    })

    await waitFor(() => expect(updateCalls).toHaveLength(1))
    expect(updateCalls[0].payload).not.toHaveProperty('stock')
    expect(updateCalls[0].payload.precio).toBe(26700)
    // Sin CAS: el único filtro es el id.
    expect(updateCalls[0].eqs).toEqual([['id', '340']])
  })

  it('con stock y stock_esperado filtra por el saldo esperado (compare-and-swap)', async () => {
    const { result } = setup()

    await result.current.mutateAsync({
      id: '340',
      data: { stock: 30, stock_esperado: 26 },
    })

    await waitFor(() => expect(updateCalls).toHaveLength(1))
    expect(updateCalls[0].payload.stock).toBe(30)
    // `stock_esperado` es del protocolo, no una columna: no se escribe.
    expect(updateCalls[0].payload).not.toHaveProperty('stock_esperado')
    expect(updateCalls[0].eqs).toEqual([
      ['id', '340'],
      ['stock', 26],
    ])
  })

  it('si el saldo cambió en el medio aborta con el valor real, sin pisar nada', async () => {
    updateResult = null // el CAS no matcheó ninguna fila
    stockActualEnBase = 6 // el preventista vendió las 20 mientras la ficha estaba abierta
    const { result } = setup()

    await expect(
      result.current.mutateAsync({ id: '340', data: { stock: 26, stock_esperado: 26 } }),
    ).rejects.toThrow(/ahora hay 6.*ten[ií]a 26/s)
  })

  it('sin CAS, 0 filas es "no existe o no tenés permiso", no un falso conflicto de stock', async () => {
    updateResult = null
    const { result } = setup()

    await expect(
      result.current.mutateAsync({ id: '999', data: { precio: 100 } }),
    ).rejects.toThrow(/no existe o no ten[eé]s permiso/)
  })
})
