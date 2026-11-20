/**
 * El alta con código repetido tiene que fallar rápido y decir qué hacer.
 *
 * El código es único por sucursal (decisión D31 de #1561), sin mirar mayúsculas ni los
 * espacios de los bordes: lo frena el server (el índice `productos_codigo_unico_por_sucursal`
 * y un trigger que nombra el producto). Esta verificación previa es su espejo
 * (`src/utils/codigoProducto.ts`) y adelanta el aviso. Dos cosas se rompieron alrededor de ella:
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

// La búsqueda del código: select().ilike('codigo', patrón).limit() → candidatos.
const ilike = vi.fn()
const candidatos = vi.fn()
const insert = vi.fn()
const resultadoInsert = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    from: () => ({
      select: () => ({
        ilike: (...args: unknown[]) => {
          ilike(...args)
          return { limit: () => candidatos() }
        },
      }),
      insert: (...args: unknown[]) => {
        insert(...args)
        return { select: () => ({ single: () => resultadoInsert() }) }
      },
    }),
    // costos_productos (#974): cero filas, como para un rol sin acceso a costos.
    rpc: () => Promise.resolve({ data: [], error: null }),
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
    resultadoInsert.mockResolvedValue({ data: { id: 1 }, error: null })
  })

  it('nombra al producto que ya tiene ese código y dice qué hacer', async () => {
    candidatos.mockResolvedValue({ data: [{ id: 398, nombre: 'MANI JAMON x 1kg', codigo: '0802' }], error: null })
    const { result } = setup()

    await expect(result.current.mutateAsync(productoNuevo)).rejects.toThrow(
      /Ya existe un producto con código "0802".*MANI JAMON x 1kg.*Buscalo por nombre o código/s
    )
    expect(insert).not.toHaveBeenCalled()
  })

  it('no se reintenta: el código duplicado no se va a destrabar solo', async () => {
    candidatos.mockResolvedValue({ data: [{ id: 398, nombre: 'MANI JAMON x 1kg', codigo: '0802' }], error: null })
    const { result } = setup()

    await expect(result.current.mutateAsync(productoNuevo)).rejects.toThrow()

    // Una sola consulta = un solo intento. Tres serían los reintentos de 1s y 2s
    // que dejaban el botón mudo durante tres segundos.
    await waitFor(() => expect(candidatos).toHaveBeenCalledTimes(1))
  })

  it('choca sin mirar mayúsculas ni los espacios de los bordes, como el índice del server', async () => {
    candidatos.mockResolvedValue({ data: [{ id: 398, nombre: 'PALITOS', codigo: 'abc-1' }], error: null })
    const { result } = setup()

    await expect(result.current.mutateAsync({ ...productoNuevo, codigo: '  ABC-1 ' })).rejects.toThrow(
      /Ya existe un producto con código "ABC-1".*PALITOS/s
    )
    // La base achica con ilike sobre el código sin bordes.
    expect(ilike).toHaveBeenCalledWith('codigo', 'ABC-1')
    expect(insert).not.toHaveBeenCalled()
  })

  it('un candidato que no es el mismo código (un comodín que acertó de más) no frena', async () => {
    candidatos.mockResolvedValue({ data: [{ id: 5, nombre: 'OTRO', codigo: 'AXB' }], error: null })
    const { result } = setup()

    await result.current.mutateAsync({ ...productoNuevo, codigo: 'A_B' })

    expect(ilike).toHaveBeenCalledWith('codigo', 'A\\_B')
    expect(insert).toHaveBeenCalledTimes(1)
  })

  it('inserta cuando el código está libre, sin los espacios de los bordes', async () => {
    candidatos.mockResolvedValue({ data: [], error: null })
    const { result } = setup()

    await result.current.mutateAsync({ ...productoNuevo, codigo: ' 0802 ' })

    expect(insert).toHaveBeenCalledTimes(1)
    expect(insert.mock.calls[0][0][0].codigo).toBe('0802')
  })

  it('sin código no consulta nada y lo guarda vacío', async () => {
    const { result } = setup()

    await result.current.mutateAsync({ ...productoNuevo, codigo: '   ' })

    expect(ilike).not.toHaveBeenCalled()
    expect(insert.mock.calls[0][0][0].codigo).toBeNull()
  })

  it('si la lectura del código falla, no lo da por libre: no inserta', async () => {
    candidatos.mockResolvedValue({ data: null, error: { code: 'P0001', message: 'timeout de lectura' } })
    const { result } = setup()

    await expect(result.current.mutateAsync(productoNuevo)).rejects.toThrow('timeout de lectura')
    expect(insert).not.toHaveBeenCalled()
  })

  it('si dos altas se cruzan, el rechazo del índice único dice lo mismo (409)', async () => {
    candidatos.mockResolvedValue({ data: [], error: null })
    resultadoInsert.mockResolvedValue({
      data: null,
      error: { code: '23505', message: 'duplicate key value violates unique constraint "productos_codigo_unico_por_sucursal"' },
    })
    const { result } = setup()

    const error = await result.current.mutateAsync(productoNuevo).catch(e => e)
    expect((error as Error).message).toMatch(/Ya existe un producto con código "0802" en esta sucursal.*Buscalo por nombre o código/s)
    expect((error as { status?: number }).status).toBe(409)
  })

  it('el rechazo del trigger del server (23505 con el producto) llega tal cual', async () => {
    candidatos.mockResolvedValue({ data: [], error: null })
    resultadoInsert.mockResolvedValue({
      data: null,
      error: { code: '23505', message: 'Ya existe un producto con el código «0802» en esta sucursal: «MANI»' },
    })
    const { result } = setup()

    await expect(result.current.mutateAsync(productoNuevo)).rejects.toThrow('Ya existe un producto con el código «0802» en esta sucursal: «MANI»')
  })
})
