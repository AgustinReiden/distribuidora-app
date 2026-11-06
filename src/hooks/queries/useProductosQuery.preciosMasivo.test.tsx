/**
 * La actualización masiva de precios cuando el servidor rechaza productos (#1438).
 *
 * `actualizar_precios_masivo` sólo toca los productos de la sucursal activa: el
 * de otra vuelve como "no encontrado en la sucursal activa", igual que el que no
 * existe. El RPC no es todo o nada, así que un lote puede volver con unos
 * actualizados y otros no. Tres cosas tiene que hacer bien el hook:
 *
 * 1. Decir cuántos sí quedaron guardados y cuáles no, sin un aviso de cien
 *    renglones.
 * 2. No reintentar: el `retry` global de mutations (main.tsx) reintenta todo lo
 *    que no sea un 4xx, y un rechazo del servidor no se destraba solo.
 * 3. Refrescar la lista igual, porque los que pudo ya cambiaron.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...args: unknown[]) => rpc(...args) },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useActualizarPreciosMasivoMutation } from './useProductosQuery'

/** El mismo predicado de retry que corre en producción (main.tsx). */
function retryDeProduccion(failureCount: number, error: unknown): boolean {
  const status = (error as { status?: number })?.status
  if (status && status >= 400 && status < 500) return false
  return failureCount < 2
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: retryDeProduccion, retryDelay: 0 } } })
  const invalidar = vi.spyOn(qc, 'invalidateQueries')
  const hook = renderHook(() => useActualizarPreciosMasivoMutation(), {
    wrapper: ({ children }: { children: React.ReactNode }) => (
      <QueryClientProvider client={qc}>{children}</QueryClientProvider>
    ),
  })
  return { ...hook, invalidar }
}

const item = (id: number) => ({ producto_id: String(id), precio_neto: null, imp_internos: null, precio_final: 150 })
const ajeno = (id: number) => `Producto ID ${id} no encontrado en la sucursal activa`

describe('actualización masiva de precios con productos de otra sucursal', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('dice cuántos se actualizaron y cuál no, sin reintentar, y refresca la lista', async () => {
    rpc.mockResolvedValue({ data: { success: false, actualizados: 2, errores: [ajeno(7)] }, error: null })
    const { result, invalidar } = setup()

    await expect(result.current.mutateAsync([item(1), item(2), item(7)])).rejects.toThrow(
      `Se actualizaron 2 producto(s), pero 1 no: ${ajeno(7)}`
    )
    expect(rpc).toHaveBeenCalledTimes(1)
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['productos', 1, 'list'] })
  })

  it('un lote de muchos ajenos nombra los primeros y cuenta el resto', async () => {
    const errores = [11, 12, 13, 14, 15].map(ajeno)
    rpc.mockResolvedValue({ data: { success: false, actualizados: 0, errores }, error: null })
    const { result } = setup()

    await expect(result.current.mutateAsync([11, 12, 13, 14, 15].map(item))).rejects.toThrow(
      `${ajeno(11)}; ${ajeno(12)}; ${ajeno(13)} y 2 más`
    )
    expect(rpc).toHaveBeenCalledTimes(1)
  })

  // #1473: el trabado se saltea. El error lo lleva para que el modal reintente sólo ese,
  // y no se reintenta solo: el resto del lote ya cambió.
  it('un lote con un producto trabado lo nombra, lo lleva en el error y no reintenta', async () => {
    const trabados = [{ producto_id: 7, nombre: 'Aceite 900ml' }]
    rpc.mockResolvedValue({
      data: { success: false, actualizados: 2, errores: ['Aceite 900ml (ID 7): otra operación lo estaba usando y no se cambió'], trabados },
      error: null,
    })
    const { result, invalidar } = setup()

    const err = await result.current.mutateAsync([item(1), item(2), item(7)]).catch((e: unknown) => e)
    expect(err).toBeInstanceOf(Error)
    expect((err as Error).message).toBe(
      'Se actualizaron 2 producto(s). 1 no se cambiaron porque otra operación los estaba usando: Aceite 900ml. '
      + 'Quedaron seleccionados para volver a aplicar.'
    )
    expect((err as { trabados?: unknown }).trabados).toEqual(trabados)
    expect(rpc).toHaveBeenCalledTimes(1)
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['productos', 1, 'list'] })
  })

  it('sin errores devuelve el resultado y refresca la lista', async () => {
    rpc.mockResolvedValue({ data: { success: true, actualizados: 1, errores: [] }, error: null })
    const { result, invalidar } = setup()

    await expect(result.current.mutateAsync([item(1)])).resolves.toEqual({ success: true, actualizados: 1, errores: [] })
    expect(invalidar).toHaveBeenCalledWith({ queryKey: ['productos', 1, 'list'] })
  })
})
