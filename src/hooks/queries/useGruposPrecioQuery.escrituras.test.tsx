/**
 * Alta y edición de una condición mayorista en UNA llamada (`guardar_condicion_mayorista`, C4b de
 * #1603; 1561-b12). Antes eran unas diez escrituras REST sin transacción y el front compensaba
 * (borraba lo recién creado, o avisaba que había quedado a medias). Ahora:
 *
 *  - el alta y la edición son una sola RPC, sin escrituras REST ni compensaciones;
 *  - el alta manda la clave del formulario (el reintento no crea otra) y la edición, el id;
 *  - los mínimos por producto viajan sólo los que tienen cantidad;
 *  - un rechazo del server llega con su motivo, sin «quedó a medias».
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const estado = vi.hoisted(() => ({
  log: [] as string[],
  rpcs: [] as Array<{ fn: string; args: Record<string, unknown> }>,
  respuestaRpc: { data: { id: 9, replay: false } as unknown, error: null as { code: string; message: string } | null },
}))

vi.mock('../supabase/base', () => ({
  supabase: {
    from: (tabla: string) => {
      const b: Record<string, unknown> = {}
      for (const nombre of ['insert', 'update', 'delete', 'upsert', 'select', 'eq', 'in', 'order']) {
        b[nombre] = () => {
          if (['insert', 'update', 'delete', 'upsert'].includes(nombre)) estado.log.push(`${tabla}.${nombre}`)
          return b
        }
      }
      b.single = () => Promise.resolve({ data: null, error: null })
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

import { useCrearGrupoPrecioMutation, useActualizarGrupoPrecioMutation } from './useGruposPrecioQuery'

function wrapper() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
}

const entrada = {
  clave: '00000000-0000-4000-8000-000000000001',
  nombre: 'Almacén',
  descripcion: '',
  productoIds: ['10', '11'],
  escalas: [
    { cantidadMinima: 10, precioUnitario: 900, etiqueta: 'x10', minimosPorProducto: {} },
    {
      cantidadMinima: 24, precioUnitario: 850, minProductosDistintos: 2,
      minimosPorProducto: { '10': { cantidad: 12, precioOverride: 840 }, '11': { cantidad: 12, precioOverride: null }, '12': { cantidad: 0 } },
    },
  ],
}

beforeEach(() => {
  estado.log = []
  estado.rpcs = []
  estado.respuestaRpc = { data: { id: 9, replay: false }, error: null }
})

describe('crear una condición en una sola llamada (1561-b12, C4b)', () => {
  it('llama a guardar_condicion_mayorista con la clave y la condición entera, sin escrituras REST', async () => {
    const { result } = renderHook(() => useCrearGrupoPrecioMutation(), { wrapper: wrapper() })

    const r = await result.current.mutateAsync(entrada as never)

    expect(r).toEqual({ id: '9', replay: false })
    expect(estado.log).toEqual([])
    expect(estado.rpcs).toHaveLength(1)
    expect(estado.rpcs[0].fn).toBe('guardar_condicion_mayorista')
    expect(estado.rpcs[0].args).toEqual({
      p_condicion: {
        clave: entrada.clave,
        nombre: 'Almacén',
        descripcion: null,
        producto_ids: [10, 11],
        escalas: [
          { cantidad_minima: 10, precio_unitario: 900, etiqueta: 'x10', min_productos_distintos: 1, minimos: [] },
          {
            cantidad_minima: 24, precio_unitario: 850, etiqueta: null, min_productos_distintos: 2,
            minimos: [
              { producto_id: 10, cantidad: 12, precio_override: 840 },
              { producto_id: 11, cantidad: 12, precio_override: null },
            ],
          },
        ],
      },
    })
  })

  it('un rechazo del server llega con su motivo y no se intenta deshacer nada', async () => {
    estado.respuestaRpc = { data: null, error: { code: '22023', message: 'No puede haber dos escalas con la misma cantidad mínima.' } }
    const { result } = renderHook(() => useCrearGrupoPrecioMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync(entrada as never).catch(e => e as Error)

    expect((error as Error).message).toBe('No puede haber dos escalas con la misma cantidad mínima.')
    expect(estado.log).toEqual([])
  })

  it('sin respuesta, dice que se puede volver a guardar sin duplicarla', async () => {
    estado.respuestaRpc = { data: null, error: { code: '', message: 'TypeError: Failed to fetch' } }
    const { result } = renderHook(() => useCrearGrupoPrecioMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync(entrada as never).catch(e => e as Error)

    expect((error as Error).message).toMatch(/Podés volver a guardar: si ya había entrado, no se crea otra/)
  })
})

describe('editar una condición en una sola llamada (1561-b12, C4b)', () => {
  it('manda el id y no la clave, sin escrituras REST', async () => {
    const { result } = renderHook(() => useActualizarGrupoPrecioMutation(), { wrapper: wrapper() })

    await result.current.mutateAsync({ id: '9', data: entrada } as never)

    expect(estado.log).toEqual([])
    expect(estado.rpcs).toHaveLength(1)
    const p = estado.rpcs[0].args.p_condicion as Record<string, unknown>
    expect(p.id).toBe(9)
    expect(p).not.toHaveProperty('clave')
    expect(p.producto_ids).toEqual([10, 11])
  })

  it('un rechazo llega tal cual, sin «quedó a medias»', async () => {
    estado.respuestaRpc = { data: null, error: { code: '22023', message: 'La condición no existe en esta sucursal (puede que otro la haya eliminado).' } }
    const { result } = renderHook(() => useActualizarGrupoPrecioMutation(), { wrapper: wrapper() })

    const error = await result.current.mutateAsync({ id: '9', data: entrada } as never).catch(e => e as Error)

    expect((error as Error).message).toBe('La condición no existe en esta sucursal (puede que otro la haya eliminado).')
  })
})
