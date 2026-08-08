/**
 * Tests de `useCambiarTransportistaRutaMutation` (mig 172).
 *
 * Lo que importa acá es el contrato con la RPC, no la lógica de negocio: las
 * guardas (permisos, sucursal, entregas hechas, ruta duplicada) viven en
 * `cambiar_transportista_recorrido` y se prueban contra la base.
 *
 * De este lado hay dos cosas que se pueden romper en silencio:
 *   1. Los nombres/tipos de los parámetros. `p_recorrido_id` es bigint: si se
 *      manda el id como string, PostgREST no resuelve la firma y falla en
 *      runtime, no en compilación.
 *   2. Que el mensaje del RAISE EXCEPTION llegue a la UI. Están redactados para
 *      el usuario ("ya tiene 3 entregas hechas por Marcos"); taparlos con un
 *      genérico deja al admin sin saber por qué no lo dejó.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: vi.fn(),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { useCambiarTransportistaRutaMutation } from './useCambiarTransportistaRutaMutation'

const JUAN = '9bba9f79-9563-4654-aa76-c56769fe1ce9'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const { result } = renderHook(() => useCambiarTransportistaRutaMutation(), {
    wrapper: makeWrapper(qc),
  })
  return { qc, result }
}

describe('useCambiarTransportistaRutaMutation', () => {
  beforeEach(() => rpc.mockReset())

  it('llama a la RPC con el id numerico y el uuid del chofer', async () => {
    rpc.mockResolvedValue({ data: 82, error: null })
    const { result } = setup()

    result.current.mutate({ recorridoId: '82', transportistaId: JUAN })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(rpc).toHaveBeenCalledWith('cambiar_transportista_recorrido', {
      p_recorrido_id: 82,
      p_transportista_id: JUAN,
    })
    expect(result.current.data).toBe('82')
  })

  it('propaga el mensaje de la RPC tal cual para mostrarlo en pantalla', async () => {
    rpc.mockResolvedValue({
      data: null,
      error: { message: 'La ruta #79 ya tiene 17 entrega(s) hecha(s) por pruebataco.' },
    })
    const { result } = setup()

    result.current.mutate({ recorridoId: '79', transportistaId: JUAN })

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.error?.message).toBe(
      'La ruta #79 ya tiene 17 entrega(s) hecha(s) por pruebataco.',
    )
  })

  it('cae en un mensaje generico si el error viene sin texto', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: '' } })
    const { result } = setup()

    result.current.mutate({ recorridoId: '82', transportistaId: JUAN })

    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(result.current.error?.message).toBe('No se pudo cambiar el transportista de la ruta')
  })

  it('invalida las queries de la ruta: la vieja y la nueva se indexan por transportista', async () => {
    rpc.mockResolvedValue({ data: 82, error: null })
    const { qc, result } = setup()
    const invalidate = vi.spyOn(qc, 'invalidateQueries')

    result.current.mutate({ recorridoId: '82', transportistaId: JUAN })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    const keys = invalidate.mock.calls.map(([arg]) => JSON.stringify(arg?.queryKey))
    // Por prefijo, sin el transportista: hay que refrescar tanto la ruta del
    // chofer que la pierde como la del que la recibe.
    expect(keys).toContain(JSON.stringify(['recorrido-existente']))
    expect(keys).toContain(JSON.stringify(['rutas-en-curso']))
    expect(keys).toContain(JSON.stringify(['recorrido-activo']))
    expect(keys).toContain(JSON.stringify(['recorridos-hoja-ruta']))
    expect(keys).toContain(JSON.stringify(['pedidos', 2]))
  })
})
