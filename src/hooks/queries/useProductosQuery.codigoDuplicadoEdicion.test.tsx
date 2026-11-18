/**
 * Editar un producto con el código de otro tiene que fallar antes de escribir
 * (#1561, 1561-b1; decisión D31: el código es único por sucursal, sin mirar mayúsculas
 * ni los espacios de los bordes).
 *
 * El chequeo estaba sólo en el alta: la ficha dejaba pisar el código de otro producto. Hoy
 * lo frena también el server (índice único y trigger); esto es su espejo.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const ilike = vi.fn()
const neq = vi.fn()
const candidatos = vi.fn()
// Lo que el producto tiene guardado hoy (select('codigo').eq('id').maybeSingle()).
const maybeSingleGuardado = vi.fn()
const update = vi.fn()
const resultadoUpdate = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: () => Promise.resolve({ data: [], error: null }),
    from: () => ({
      select: () => ({
        // Lo guardado: select('codigo').eq('id').maybeSingle()
        eq: () => ({ maybeSingle: maybeSingleGuardado }),
        // Los candidatos: select().ilike('codigo', patrón).neq('id').limit()
        ilike: (...args: unknown[]) => {
          ilike(...args)
          return {
            neq: (...a: unknown[]) => {
              neq(...a)
              return { limit: () => candidatos() }
            },
          }
        },
      }),
      update: (payload: unknown) => {
        update(payload)
        const b = {
          eq: () => b,
          select: () => b,
          maybeSingle: () => resultadoUpdate(),
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
    resultadoUpdate.mockResolvedValue({ data: { id: 7 }, error: null })
  })

  it('rechaza el código de otro producto, lo nombra y no escribe', async () => {
    candidatos.mockResolvedValue({ data: [{ id: 3, nombre: 'ARROZ LARGO x 1kg', codigo: '0802' }], error: null })
    const { result } = setup()

    await expect(
      result.current.mutateAsync({ id: '7', data: { codigo: '0802' } }),
    ).rejects.toThrow(/Ya existe un producto con código "0802".*ARROZ LARGO x 1kg.*dejale a este otro código/s)
    expect(neq).toHaveBeenCalledWith('id', '7')
    expect(update).not.toHaveBeenCalled()
  })

  it('choca sin mirar mayúsculas ni los espacios de los bordes', async () => {
    candidatos.mockResolvedValue({ data: [{ id: 3, nombre: 'PALITOS', codigo: ' abc-1' }], error: null })
    const { result } = setup()

    await expect(
      result.current.mutateAsync({ id: '7', data: { codigo: 'ABC-1 ' } }),
    ).rejects.toThrow(/PALITOS/)
    expect(ilike).toHaveBeenCalledWith('codigo', 'ABC-1')
    expect(update).not.toHaveBeenCalled()
  })

  it('el error lleva status 409 para que el retry global no lo repita', async () => {
    candidatos.mockResolvedValue({ data: [{ id: 3, nombre: 'ARROZ', codigo: '0802' }], error: null })
    const { result } = setup()

    const error = await result.current.mutateAsync({ id: '7', data: { codigo: '0802' } }).catch(e => e)
    expect((error as { status?: number }).status).toBe(409)
  })

  it('guarda cuando el código está libre (el propio producto no cuenta), sin los espacios de los bordes', async () => {
    candidatos.mockResolvedValue({ data: [], error: null })
    const { result } = setup()

    await result.current.mutateAsync({ id: '7', data: { codigo: ' 0802 ', precio: 10 } })

    expect(update).toHaveBeenCalledTimes(1)
    expect((update.mock.calls[0][0] as { codigo: string }).codigo).toBe('0802')
  })

  it('sin código en el payload no consulta nada', async () => {
    const { result } = setup()

    await result.current.mutateAsync({ id: '7', data: { precio: 10 } })

    expect(ilike).not.toHaveBeenCalled()
    expect(update).toHaveBeenCalledTimes(1)
  })

  it('un código que no cambió (ni en mayúsculas ni en los bordes) no se verifica', async () => {
    maybeSingleGuardado.mockResolvedValue({ data: { codigo: '0802' }, error: null })
    const { result } = setup()

    await result.current.mutateAsync({ id: '7', data: { codigo: '0802 ', precio: 10 } })

    expect(ilike).not.toHaveBeenCalled()
    expect(update).toHaveBeenCalledTimes(1)
  })

  it('si la lectura del código repetido falla, no da el código por libre y no escribe', async () => {
    candidatos.mockResolvedValue({ data: null, error: { code: 'P0001', message: 'timeout de lectura' } })
    const { result } = setup()

    await expect(result.current.mutateAsync({ id: '7', data: { codigo: '0802' } })).rejects.toThrow('timeout de lectura')
    expect(update).not.toHaveBeenCalled()
  })

  it('si el índice único lo frena (una carrera), avisa lo mismo, con 409', async () => {
    candidatos.mockResolvedValue({ data: [], error: null })
    resultadoUpdate.mockResolvedValue({
      data: null,
      error: { code: '23505', message: 'duplicate key value violates unique constraint "productos_codigo_unico_por_sucursal"' },
    })
    const { result } = setup()

    const error = await result.current.mutateAsync({ id: '7', data: { codigo: '0802' } }).catch(e => e)
    expect((error as Error).message).toMatch(/Ya existe un producto con código "0802" en esta sucursal.*dejale a este otro código/s)
    expect((error as { status?: number }).status).toBe(409)
  })
})
