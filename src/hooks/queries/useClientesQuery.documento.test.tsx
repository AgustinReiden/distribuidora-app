/**
 * El documento de un cliente viaja con su tipo (B17, #1561 1561-b11).
 *
 * `createCliente` nombra las columnas una por una y no nombraba `tipo_documento`, y el
 * patch de la edición tampoco lo traía: todo cliente quedaba con el default 'CUIT',
 * también los DNI (en prod, 152 de 154). Ahora el tipo sale del valor
 * (`documentoParaGuardar`), en el alta y en toda edición que traiga el documento, y el
 * relleno de un DNI vacío (`00-00000000-0`) queda sin documento.
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

const CLIENTE = { id: '77', nombre_fantasia: 'Kiosco Inventado' }

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
    builder.in = () => builder
    builder.maybeSingle = () => Promise.resolve({ data: null, error: null })
    builder.single = () => Promise.resolve({ data: CLIENTE, error: null })
    builder.then = (resolve: (v: unknown) => unknown) => resolve({ data: [], error: null })
    return builder
  })
}

function wrapper({ children }: { children: React.ReactNode }): React.ReactElement {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
}

const BASE = { razon_social: 'Kiosco Inventado', nombre_fantasia: 'Kiosco Inventado', direccion: 'Calle Falsa 123' }

function filaInsertada(): Record<string, unknown> {
  return (insertSpy.mock.calls[0][0] as Array<Record<string, unknown>>)[0]
}

describe('el documento viaja con su tipo (B17)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    montarSupabase()
  })

  it('el alta de un DNI lo guarda con tipo DNI', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })
    await result.current.mutateAsync({ ...BASE, cuit: '00-30123456-0' })

    await waitFor(() => expect(insertSpy).toHaveBeenCalled())
    expect(filaInsertada()).toMatchObject({ cuit: '00-30123456-0', tipo_documento: 'DNI' })
  })

  it('el alta de un CUIT lo guarda con tipo CUIT', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })
    await result.current.mutateAsync({ ...BASE, cuit: '20-12345678-6' })

    await waitFor(() => expect(insertSpy).toHaveBeenCalled())
    expect(filaInsertada()).toMatchObject({ cuit: '20-12345678-6', tipo_documento: 'CUIT' })
  })

  it('el alta sin documento, o con el relleno de un DNI vacío, queda sin documento', async () => {
    const { result } = renderHook(() => useCrearClienteMutation(), { wrapper })
    await result.current.mutateAsync({ ...BASE, cuit: '00-00000000-0' })

    await waitFor(() => expect(insertSpy).toHaveBeenCalled())
    expect(filaInsertada()).toMatchObject({ cuit: null, tipo_documento: 'CUIT' })
  })

  it('la edición que pasa un CUIT a un DNI manda el tipo DNI', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })
    await result.current.mutateAsync({ id: '77', data: { cuit: '00-30123456-0' } })

    await waitFor(() => expect(updateSpy).toHaveBeenCalled())
    expect(updateSpy.mock.calls[0][0]).toMatchObject({ cuit: '00-30123456-0', tipo_documento: 'DNI' })
  })

  it('la edición que pasa un DNI a un CUIT manda el tipo CUIT', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })
    await result.current.mutateAsync({ id: '77', data: { cuit: '20-12345678-6', tipo_documento: 'DNI' } })

    await waitFor(() => expect(updateSpy).toHaveBeenCalled())
    expect(updateSpy.mock.calls[0][0]).toMatchObject({ cuit: '20-12345678-6', tipo_documento: 'CUIT' })
  })

  it('una edición sin documento (la del preventista, la baja) no manda el tipo', async () => {
    const { result } = renderHook(() => useActualizarClienteMutation(), { wrapper })
    await result.current.mutateAsync({ id: '77', data: { activo: false } })

    await waitFor(() => expect(updateSpy).toHaveBeenCalled())
    expect(updateSpy.mock.calls[0][0]).not.toHaveProperty('tipo_documento')
    expect(updateSpy.mock.calls[0][0]).not.toHaveProperty('cuit')
  })
})
