/**
 * El alta con código repetido tiene que fallar rápido y decir qué hacer.
 *
 * `productos.codigo` no tiene UNIQUE (mig 210), así que esta comprobación en el
 * cliente es la única guarda que hay. Dos cosas se rompieron alrededor de ella:
 *
 * 1. El mensaje nombraba el producto existente pero no decía qué hacer con él.
 *    Quien lo lee está cargando una factura y lo que necesita es saber que el
 *    producto ya está y que lo busque, no que "ya existe".
 * 2. El `retry` global de mutations (main.tsx) sólo perdona los 4xx, y mira
 *    `error.status`. Un `new Error(...)` pelado no lo tiene: el rechazo se
 *    reintentaba tres veces con backoff de 1s y 2s antes de fallar igual. En los
 *    logs de prod cada click aparecía como tres consultas espaciadas así.
 *
 * El status va acá, en la capa que redacta el error, y no en el predicado de
 * main.tsx: el predicado no puede distinguir una regla de negocio de una caída
 * de red mirando un Error sin datos.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const maybeSingle = vi.fn()
const insert = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => ({
      select: () => ({ eq: () => ({ limit: () => ({ maybeSingle }) }) }),
      insert: (...args: unknown[]) => {
        insert(...args)
        return { select: () => ({ single: () => Promise.resolve({ data: { id: 1 }, error: null }) }) }
      },
    }),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearProductoMutation } from './useProductosQuery'

/** El mismo predicado de retry que corre en producción (main.tsx). */
function retryDeProduccion(failureCount: number, error: unknown): boolean {
  const status = (error as { status?: number })?.status
  if (status && status >= 400 && status < 500) return false
  return failureCount < 2
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: retryDeProduccion, retryDelay: 0 } } })
  return renderHook(() => useCrearProductoMutation(), {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  })
}

const productoNuevo = { nombre: 'MANI JAMON x 1kg', codigo: '0802', precio: 9115, stock: 0 }

describe('crear producto con código duplicado', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('nombra al producto que ya tiene ese código y dice qué hacer', async () => {
    maybeSingle.mockResolvedValue({ data: { id: 398, nombre: 'MANI JAMON x 1kg' }, error: null })
    const { result } = setup()

    await expect(result.current.mutateAsync(productoNuevo)).rejects.toThrow(
      /Ya existe un producto con código "0802".*MANI JAMON x 1kg.*Buscalo por nombre o código/s
    )
    expect(insert).not.toHaveBeenCalled()
  })

  it('no se reintenta: el código duplicado no se va a destrabar solo', async () => {
    maybeSingle.mockResolvedValue({ data: { id: 398, nombre: 'MANI JAMON x 1kg' }, error: null })
    const { result } = setup()

    await expect(result.current.mutateAsync(productoNuevo)).rejects.toThrow()

    // Una sola consulta = un solo intento. Tres serían los reintentos de 1s y 2s
    // que dejaban el botón mudo durante tres segundos.
    await waitFor(() => expect(maybeSingle).toHaveBeenCalledTimes(1))
  })

  it('inserta cuando el código está libre', async () => {
    maybeSingle.mockResolvedValue({ data: null, error: null })
    const { result } = setup()

    await result.current.mutateAsync(productoNuevo)

    expect(insert).toHaveBeenCalledTimes(1)
  })
})
