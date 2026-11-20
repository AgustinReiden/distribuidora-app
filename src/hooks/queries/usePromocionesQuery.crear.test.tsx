/**
 * Crear una promo en UNA llamada (`crear_promocion`, C4b de #1603; 1561-b12). Antes eran tres
 * INSERT REST (promo, productos y reglas) y, si fallaban los productos o las reglas, el front
 * borraba la promo recién creada o avisaba que había quedado a medias. Ahora es una RPC, con la
 * clave del formulario: el reintento después de una respuesta perdida no crea otra.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const estado = vi.hoisted(() => ({
  escrituras: [] as string[],
  rpcs: [] as Array<{ fn: string; args: Record<string, unknown> }>,
  respuestaRpc: { data: null as unknown, error: null as { code: string; message: string } | null },
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      const b: Record<string, unknown> = {}
      for (const nombre of ['insert', 'delete', 'update', 'upsert']) b[nombre] = () => { estado.escrituras.push(`${tabla}.${nombre}`); return b }
      for (const nombre of ['select', 'eq']) b[nombre] = () => b
      b.then = (ok: (v: unknown) => unknown) => Promise.resolve({ data: [], error: null }).then(ok)
      return b
    },
    rpc: (fn: string, args: Record<string, unknown>) => {
      estado.rpcs.push({ fn, args })
      return Promise.resolve(estado.respuestaRpc)
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearPromocionMutation } from './usePromocionesQuery'

function wrapper(qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })) {
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
}

const entrada = {
  clave: '00000000-0000-4000-8000-000000000005',
  nombre: 'Promo', tipo: 'bonificacion', fechaInicio: '2026-11-01', fechaFin: null,
  productoIds: ['1', '2'], productoRegaloId: '3', regaloMueveStock: true, ajusteAutomatico: false,
  reglas: [{ clave: 'cantidad_compra', valor: 6 }, { clave: 'cantidad_bonificacion', valor: 1 }],
}

beforeEach(() => {
  estado.escrituras = []
  estado.rpcs = []
  estado.respuestaRpc = { data: { id: 5, replay: false, promocion: { id: 5, nombre: 'Promo' } }, error: null }
})

describe('crear una promo en una sola llamada (1561-b12, C4b)', () => {
  it('llama a crear_promocion con la clave, los productos y las reglas, sin escrituras REST', async () => {
    const { result } = renderHook(() => useCrearPromocionMutation(), { wrapper: wrapper() })

    const promo = await result.current.mutateAsync(entrada as never)

    expect(promo.id).toBe(5)
    expect(estado.escrituras).toEqual([])
    expect(estado.rpcs).toHaveLength(1)
    expect(estado.rpcs[0].fn).toBe('crear_promocion')
    expect(estado.rpcs[0].args.p_promocion).toMatchObject({
      clave: entrada.clave,
      nombre: 'Promo',
      fecha_inicio: '2026-11-01',
      producto_ids: [1, 2],
      producto_regalo_id: 3,
      regalo_mueve_stock: true,
      ajuste_automatico: false,
      reglas: entrada.reglas,
    })
  })

  it('un rechazo del server llega con su motivo y no se borra nada', async () => {
    estado.respuestaRpc = { data: null, error: { code: '22023', message: 'Algún producto de la promoción no existe en esta sucursal.' } }
    const { result } = renderHook(() => useCrearPromocionMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync(entrada as never).catch(e => e as Error)

    expect((error as Error).message).toBe('Algún producto de la promoción no existe en esta sucursal.')
    expect(estado.escrituras).toEqual([])
  })

  it('sin respuesta invalida la lista igual (puede haber entrado) y dice que se puede volver a guardar', async () => {
    estado.respuestaRpc = { data: null, error: { code: '', message: 'TypeError: Failed to fetch' } }
    const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
    const invalidar = vi.spyOn(qc, 'invalidateQueries')
    const { result } = renderHook(() => useCrearPromocionMutation(), { wrapper: wrapper(qc) })

    const error = await result.current.mutateAsync(entrada as never).catch(e => e as Error)

    expect((error as Error).message).toMatch(/Podés volver a guardar: si ya había entrado, no se crea otra/)
    await vi.waitFor(() => expect(invalidar).toHaveBeenCalled())
  })
})
