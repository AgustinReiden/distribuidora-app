/**
 * Var-B1 (T8 de la ola 3): la visita lleva la clave del intento.
 *
 * Si la respuesta se pierde y el preventista vuelve a tocar el cliente, el reintento manda la
 * MISMA clave (aunque el GPS se haya vuelto a capturar) y el server devuelve la visita del
 * primero. Después de una visita que salió bien, la próxima al mismo cliente es otra visita.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []
let respuestas: Array<{ data: unknown; error: { message: string; code?: string } | null }> = []

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(respuestas.shift() ?? { data: { success: true, visita_id: 1 }, error: null })
    },
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useRegistrarVisitaMutation } from './useVisitasQuery'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

function montar() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return renderHook(() => useRegistrarVisitaMutation(), { wrapper }).result
}

const claves = () => rpcCalls.map(c => c.args.p_clave as string | undefined)

beforeEach(() => {
  rpcCalls.length = 0
  respuestas = []
})

describe('useRegistrarVisitaMutation › la clave de la visita (Var-B1)', () => {
  it('manda registrar_visita_cliente con una clave', async () => {
    const r = montar()
    await r.current.mutateAsync({ clienteId: 41, status: 'ok', lat: -26.8, lng: -65.2, accuracy: 9, capturadoAt: 'x' })
    expect(rpcCalls).toHaveLength(1)
    expect(rpcCalls[0].fn).toBe('registrar_visita_cliente')
    expect(claves()[0]).toMatch(UUID)
  })

  it('el reintento después de un error lleva la misma clave, aunque el GPS sea otro', async () => {
    respuestas = [{ data: null, error: { message: 'Failed to fetch' } }]
    const r = montar()
    await expect(r.current.mutateAsync({ clienteId: 41, status: 'ok', lat: -26.8, lng: -65.2 })).rejects.toThrow()
    await r.current.mutateAsync({ clienteId: 41, status: 'ok', lat: -26.81, lng: -65.21 })
    expect(claves()[0]).toMatch(UUID)
    expect(claves()[1]).toBe(claves()[0])
  })

  it('un rechazo del server (success false) no suelta la clave: el reintento lleva la misma', async () => {
    respuestas = [{ data: { success: false, error: 'No hay sucursal activa' }, error: null }]
    const r = montar()
    await r.current.mutateAsync({ clienteId: 41, status: 'timeout', motivoOmision: 'sin señal' })
    await r.current.mutateAsync({ clienteId: 41, status: 'timeout', motivoOmision: 'sin señal' })
    expect(claves()[1]).toBe(claves()[0])
  })

  it('después de una visita que salió bien, la próxima al mismo cliente lleva otra clave', async () => {
    const r = montar()
    await r.current.mutateAsync({ clienteId: 41, status: 'ok', lat: -26.8, lng: -65.2 })
    await r.current.mutateAsync({ clienteId: 41, status: 'ok', lat: -26.8, lng: -65.2 })
    expect(claves()[0]).toMatch(UUID)
    expect(claves()[1]).toMatch(UUID)
    expect(claves()[1]).not.toBe(claves()[0])
  })

  it('otro cliente es otra visita, con otra clave', async () => {
    respuestas = [{ data: null, error: { message: 'Failed to fetch' } }]
    const r = montar()
    await expect(r.current.mutateAsync({ clienteId: 41, status: 'ok', lat: -26.8, lng: -65.2 })).rejects.toThrow()
    await r.current.mutateAsync({ clienteId: 42, status: 'ok', lat: -26.8, lng: -65.2 })
    expect(claves()[1]).not.toBe(claves()[0])
  })
})
