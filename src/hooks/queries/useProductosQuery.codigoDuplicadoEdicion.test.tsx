/**
 * Editar un producto con el código de otro tiene que fallar antes de escribir
 * (#1561, 1561-b1; decisión D31: el código es único por sucursal).
 *
 * `productos.codigo` no tiene UNIQUE (mig 210) y el chequeo estaba sólo en el
 * alta: la ficha dejaba pisar el código de otro producto.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const neq = vi.fn()
const maybeSingleCodigo = vi.fn()
// Lo que el producto tiene guardado hoy (select('codigo').eq('id').maybeSingle()).
const maybeSingleGuardado = vi.fn()
const update = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: () => Promise.resolve({ data: [], error: null }),
    from: () => ({
      // Consulta del código: select().eq('codigo').neq('id').limit().maybeSingle()
      select: () => ({
        eq: () => ({
          maybeSingle: maybeSingleGuardado,
          neq: (...args: unknown[]) => {
            neq(...args)
            return { limit: () => ({ maybeSingle: maybeSingleCodigo }) }
          },
        }),
      }),
      update: (payload: unknown) => {
        update(payload)
        const b = {
          eq: () => b,
          select: () => b,
          maybeSingle: async () => ({ data: { id: 7 }, error: null }),
        }
        return b
      },
    }),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useActualizarProductoMutation } from './useProductosQuery'

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return renderHook(() => useActualizarProductoMutation(), {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  })
}

describe('editar producto con código duplicado', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    // Por defecto el producto tiene otro código guardado: el código del payload cambió.
    maybeSingleGuardado.mockResolvedValue({ data: { codigo: 'VIEJO' }, error: null })
  })

  it('rechaza el código de otro producto, lo nombra y no escribe', async () => {
    maybeSingleCodigo.mockResolvedValue({ data: { id: 3, nombre: 'ARROZ LARGO x 1kg' }, error: null })
    const { result } = setup()

    await expect(
      result.current.mutateAsync({ id: '7', data: { codigo: '0802' } }),
    ).rejects.toThrow(/Ya existe un producto con código "0802".*ARROZ LARGO x 1kg/s)
    expect(neq).toHaveBeenCalledWith('id', '7')
    expect(update).not.toHaveBeenCalled()
  })

  it('el error lleva status 409 para que el retry global no lo repita', async () => {
    maybeSingleCodigo.mockResolvedValue({ data: { id: 3, nombre: 'ARROZ' }, error: null })
    const { result } = setup()

    const error = await result.current.mutateAsync({ id: '7', data: { codigo: '0802' } }).catch(e => e)
    expect((error as { status?: number }).status).toBe(409)
  })

  it('guarda cuando el código está libre (el propio producto no cuenta)', async () => {
    maybeSingleCodigo.mockResolvedValue({ data: null, error: null })
    const { result } = setup()

    await result.current.mutateAsync({ id: '7', data: { codigo: '0802', precio: 10 } })

    expect(update).toHaveBeenCalledTimes(1)
  })

  it('sin código en el payload no consulta nada', async () => {
    const { result } = setup()

    await result.current.mutateAsync({ id: '7', data: { precio: 10 } })

    expect(neq).not.toHaveBeenCalled()
    expect(update).toHaveBeenCalledTimes(1)
  })

  it('un código que no cambió no se verifica: dos productos con el mismo código se siguen editando', async () => {
    maybeSingleGuardado.mockResolvedValue({ data: { codigo: '0802' }, error: null })
    maybeSingleCodigo.mockResolvedValue({ data: { id: 3, nombre: 'OTRO CON EL MISMO CÓDIGO' }, error: null })
    const { result } = setup()

    await result.current.mutateAsync({ id: '7', data: { codigo: '0802', precio: 10 } })

    expect(neq).not.toHaveBeenCalled()
    expect(update).toHaveBeenCalledTimes(1)
  })

  it('si la lectura del código repetido falla, no da el código por libre y no escribe', async () => {
    maybeSingleCodigo.mockResolvedValue({ data: null, error: { code: 'P0001', message: 'timeout de lectura' } })
    const { result } = setup()

    await expect(result.current.mutateAsync({ id: '7', data: { codigo: '0802' } })).rejects.toThrow('timeout de lectura')
    expect(update).not.toHaveBeenCalled()
  })
})
