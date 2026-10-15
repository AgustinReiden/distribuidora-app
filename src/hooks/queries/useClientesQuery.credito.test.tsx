/**
 * El crédito en 0 sobrevive el alta (#1172).
 *
 * `createCliente` armaba `dias_credito || 30`: un admin que guardaba 0 (pago
 * contado) terminaba con 30. Con `??` sólo el `undefined` toma el default, que
 * es lo que manda un no-admin (ClientesContainer no incluye las claves).
 *
 * El caso de `updateCliente` es de protección, no prueba el arreglo: el patch
 * es un spread y un 0 ya viajaba bien. El defecto de la edición estaba en el
 * valor inicial del formulario (ver ModalCliente.credito.test.tsx).
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const insertSpy = vi.fn()
const updateSpy = vi.fn()
const from = vi.fn()

const SIN_DUPLICADO = {
  bloquea: false, avisa: false, motivo: null, distancia_m: null, cliente_visible: null,
}

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (...args: unknown[]) => from(...args),
    rpc: () => Promise.resolve({ data: SIN_DUPLICADO, error: null }),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearClienteMutation, useActualizarClienteMutation } from './useClientesQuery'

const CLIENTE_CREADO = { id: '77', nombre_fantasia: 'Contado SA' }

function montarSupabase(): void {
  from.mockImplementation(() => {
    const builder: Record<string, unknown> = {}
    builder.insert = (filas: unknown) => {
      insertSpy(filas)
      return builder
    }
    builder.update = (payload: unknown) => {
      updateSpy(payload)
      return builder
    }
    builder.delete = () => builder
    builder.select = () => builder
    builder.eq = () => builder
    builder.gte = () => builder
    builder.lte = () => builder
    builder.limit = () => Promise.resolve({ data: [], error: null })
    builder.single = () => Promise.resolve({ data: CLIENTE_CREADO, error: null })
    builder.then = (resolve: (v: unknown) => unknown) => resolve({ error: null })
    return builder
  })
}

function wrapper({ children }: { children: React.ReactNode }): React.ReactElement {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const BASE = { razon_social: 'Contado SA', nombre_fantasia: 'Contado SA', direccion: 'San Martín 100' }

function filaInsertada(): Record<string, unknown> {
  return (insertSpy.mock.calls[0][0] as Array<Record<string, unknown>>)[0]
}

describe('crédito en 0 en la capa de escritura (#1172)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    montarSupabase()
  })

  it('createCliente conserva dias_credito = 0 y limite_credito = 0 (contado)', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })
    await result.current.mutateAsync({ ...BASE, dias_credito: 0, limite_credito: 0 })

    await waitFor(() => expect(insertSpy).toHaveBeenCalled())
    expect(filaInsertada().dias_credito).toBe(0)
    expect(filaInsertada().limite_credito).toBe(0)
  })

  it('createCliente manda tal cual un crédito explícito', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })
    await result.current.mutateAsync({ ...BASE, dias_credito: 15, limite_credito: 5000 })

    await waitFor(() => expect(insertSpy).toHaveBeenCalled())
    expect(filaInsertada().dias_credito).toBe(15)
    expect(filaInsertada().limite_credito).toBe(5000)
  })

  it('sin las claves (alta de un no-admin) toma los defaults 30 y 0', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })
    await result.current.mutateAsync({ ...BASE })

    await waitFor(() => expect(insertSpy).toHaveBeenCalled())
    expect(filaInsertada().dias_credito).toBe(30)
    expect(filaInsertada().limite_credito).toBe(0)
  })

  it('updateCliente propaga un 0 en el patch (protección: ya pasaba antes)', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })
    await result.current.mutateAsync({ id: '77', data: { dias_credito: 0, limite_credito: 0 } })

    await waitFor(() => expect(updateSpy).toHaveBeenCalled())
    expect(updateSpy.mock.calls[0][0]).toMatchObject({ dias_credito: 0, limite_credito: 0 })
  })
})
