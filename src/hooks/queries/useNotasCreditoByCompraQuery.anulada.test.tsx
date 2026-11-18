/**
 * B18 (#1603), H8 de la revisión: el detalle de la compra trae las notas anuladas y el
 * nombre de quien anuló cada una sale de una consulta APARTE a `perfiles` (sin embed:
 * `anulada_por` no tiene FK desde la 524). Si esa consulta falla, las notas llegan igual,
 * sin el nombre; y sin anuladas no se consulta.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

type Respuesta = { data: unknown; error: { message: string; code?: string } | null }
const llamadas: Array<{ tabla: string; select?: string; in?: [string, unknown[]] }> = []
const respuestas: Record<string, Respuesta> = {}

/** Cadena de PostgREST: registra el select y el `in`, y `await` da la respuesta de la tabla. */
function cadena(tabla: string): unknown {
  const registro: (typeof llamadas)[number] = { tabla }
  llamadas.push(registro)
  const proxy: unknown = new Proxy(() => undefined, {
    get(_t, prop) {
      if (prop === 'then') {
        return (res: (v: unknown) => unknown, rej?: (e: unknown) => unknown) =>
          Promise.resolve(respuestas[tabla] ?? { data: [], error: null }).then(res, rej)
      }
      return (...args: unknown[]) => {
        if (prop === 'select') registro.select = String(args[0])
        if (prop === 'in') registro.in = [String(args[0]), args[1] as unknown[]]
        return proxy
      }
    },
  })
  return proxy
}

vi.mock('../supabase/base', () => ({
  supabase: { from: (tabla: string) => cadena(tabla) },
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useNotasCreditoByCompraQuery } from './useNotasCreditoQuery'

function cargar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return renderHook(() => useNotasCreditoByCompraQuery('304'), { wrapper })
}

const NOTAS = [
  { id: 5, compra_id: 304, total: 100, anulada: true, anulada_por: 'u-ana', motivo_anulacion: 'Era de otra compra' },
  { id: 6, compra_id: 304, total: 50, anulada: false, anulada_por: null },
]

describe('useNotasCreditoByCompraQuery · quién anuló', () => {
  beforeEach(() => {
    llamadas.length = 0
    for (const k of Object.keys(respuestas)) delete respuestas[k]
  })

  it('pide el nombre aparte (sin embed por anulada_por) y lo pone en la nota anulada', async () => {
    respuestas.notas_credito = { data: NOTAS, error: null }
    respuestas.perfiles = { data: [{ id: 'u-ana', nombre: 'Ana Depósito' }], error: null }
    const { result } = cargar()
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    const notas = llamadas.find(l => l.tabla === 'notas_credito')!
    expect(notas.select).not.toMatch(/anulada_por\s*\(|perfiles!notas_credito_anulada_por/)
    expect(notas.select).toMatch(/usuario:perfiles!notas_credito_usuario_id_fkey\(id, nombre\)/)
    const perfiles = llamadas.find(l => l.tabla === 'perfiles')!
    expect(perfiles.select).toBe('id, nombre')
    expect(perfiles.in).toEqual(['id', ['u-ana']])

    expect(result.current.data?.[0]).toMatchObject({ id: 5, anulada: true, anulada_por_nombre: 'Ana Depósito' })
    expect(result.current.data?.[1]).not.toHaveProperty('anulada_por_nombre')
  })

  it('si la consulta del nombre falla, las notas llegan igual, sin el nombre', async () => {
    respuestas.notas_credito = { data: NOTAS, error: null }
    respuestas.perfiles = { data: null, error: { message: 'permission denied', code: '42501' } }
    const { result } = cargar()
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toHaveLength(2)
    expect(result.current.data?.[0].anulada_por_nombre).toBeUndefined()
  })

  it('sin notas anuladas no consulta perfiles', async () => {
    respuestas.notas_credito = { data: [NOTAS[1]], error: null }
    const { result } = cargar()
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(llamadas.some(l => l.tabla === 'perfiles')).toBe(false)
  })
})
