/**
 * #1081 — `resolverSalvedad` mostraba en el toast el `error` crudo de supabase-js
 * ("TypeError: Failed to fetch") y después lanzaba el mensaje normalizado.
 * Misma regla que useRendiciones: el toast sale de `errorDeSupabase`.
 *
 * (Venía de `hooks/supabase/useSalvedades`; la resolución ahora es
 * `useResolverSalvedadMutation`, con las mismas aserciones.)
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import type { ReactNode } from 'react'
import { renderHook, act } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()
const notifyError = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: { rpc: (...a: unknown[]) => rpc(...a) },
  notifyError: (...a: unknown[]) => notifyError(...a),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 2 }),
}))

import { useResolverSalvedadMutation, salvedadesKeys } from './useSalvedadesQuery'

const INPUT = { salvedadId: '5', estadoResolucion: 'resuelta' } as never

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  const wrapper = ({ children }: { children: ReactNode }) => (
    <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  )
  return { qc, ...renderHook(() => useResolverSalvedadMutation(), { wrapper }) }
}

describe('useResolverSalvedadMutation — el toast no muestra el error crudo (#1081)', () => {
  beforeEach(() => {
    rpc.mockReset()
    notifyError.mockReset()
  })

  it('fallo de red: el toast dice "sin conexión", no "Failed to fetch", y coincide con el throw', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' } })
    const { result } = montar()

    let lanzado: Error | undefined
    await act(async () => {
      await result.current.mutateAsync(INPUT).catch((e: Error) => { lanzado = e })
    })

    expect(lanzado!.message).toMatch(/Sin conexión/)
    expect(notifyError).toHaveBeenCalledTimes(1)
    const toast = String(notifyError.mock.calls[0][0])
    expect(toast).not.toMatch(/failed to fetch/i)
    expect(toast).toContain(lanzado!.message)
  })

  it('error del servidor: el toast conserva el prefijo y el mensaje del servidor', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'Salvedad ya resuelta', details: '', hint: '', code: 'P0001' } })
    const { result } = montar()

    let lanzado: Error | undefined
    await act(async () => {
      await result.current.mutateAsync(INPUT).catch((e: Error) => { lanzado = e })
    })

    expect(lanzado!.message).toBe('Salvedad ya resuelta')
    expect(notifyError).toHaveBeenCalledWith('Error al resolver salvedad: Salvedad ya resuelta')
  })
})

describe('useResolverSalvedadMutation — invalida la lista en vez de re-traer todo', () => {
  beforeEach(() => {
    rpc.mockReset()
    notifyError.mockReset()
  })

  it('al resolver invalida salvedadesKeys.all (lista y KPIs, todas las páginas)', async () => {
    rpc.mockResolvedValue({ data: { success: true, nuevo_estado: 'nota_credito' }, error: null })
    const { qc, result } = montar()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')

    let r: unknown
    await act(async () => {
      r = await result.current.mutateAsync({ salvedadId: '5', estadoResolucion: 'nota_credito' } as never)
    })

    expect(r).toEqual({ success: true, nuevoEstado: 'nota_credito' })
    expect(invalidar).toHaveBeenCalledWith({ queryKey: salvedadesKeys.all })
  })

  // El modal se cierra cuando vuelve `mutateAsync`: si la invalidación no se
  // espera, por un momento la tarjeta resuelta sigue "pendiente" con su botón
  // Resolver activo (y un segundo clic contesta "ya resuelta").
  it('mutateAsync no vuelve hasta que terminó de refrescar la lista', async () => {
    rpc.mockResolvedValue({ data: { success: true, nuevo_estado: 'nota_credito' }, error: null })
    const { qc, result } = montar()
    let terminarRefresco: () => void = () => {}
    vi.spyOn(qc, 'invalidateQueries').mockImplementation(
      () => new Promise<void>(res => { terminarRefresco = res }),
    )

    let volvio = false
    let promesa: Promise<unknown> = Promise.resolve()
    await act(async () => {
      promesa = result.current.mutateAsync({ salvedadId: '5', estadoResolucion: 'nota_credito' } as never)
        .then(() => { volvio = true })
      await new Promise(r => setTimeout(r, 20))
    })
    expect(volvio).toBe(false)

    await act(async () => {
      terminarRefresco()
      await promesa
    })
    expect(volvio).toBe(true)
  })

  it('la negativa de negocio (success: false) avisa, lanza y NO invalida', async () => {
    rpc.mockResolvedValue({ data: { success: false, error: 'Solo admin o encargado' }, error: null })
    const { qc, result } = montar()
    const invalidar = vi.spyOn(qc, 'invalidateQueries')

    let lanzado: Error | undefined
    await act(async () => {
      await result.current.mutateAsync(INPUT).catch((e: Error) => { lanzado = e })
    })

    expect(lanzado!.message).toBe('Solo admin o encargado')
    expect(notifyError).toHaveBeenCalledWith('Solo admin o encargado')
    expect(invalidar).not.toHaveBeenCalled()
  })
})
