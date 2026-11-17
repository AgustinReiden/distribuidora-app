/**
 * 1600-b8 (decisión D58 del dueño, #1600): una cola encolada en otra sucursal no
 * se veía ni se reenviaba mientras se trabajaba en la actual, y el contador
 * marcaba 0. Ahora se cuenta para avisarla; sigue sin mandarse cruzada, y al
 * cambiar a su sucursal se manda con ella.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'

const sesion = vi.hoisted(() => ({ sucursalId: 1 as number }))

vi.mock('../../lib/supabase', () => ({
  supabase: { from: vi.fn(), rpc: vi.fn(), rest: { headers: {} }, auth: { refreshSession: vi.fn() } },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ userId: 'user-A', currentSucursalId: sesion.sucursalId, sucursales: [], loading: false, switchSucursal: vi.fn() }),
}))

import { useOfflineSync, type CrearPedidoFunction } from '../useOfflineSync'
import { clearAllData, queueOperation } from '../../lib/offlineDb'

type Input = Parameters<CrearPedidoFunction>[0]

const pedido = (n: number) => ({
  clienteId: '7',
  items: [{ productoId: 'p1', cantidad: 1, precioUnitario: 1 }],
  total: 1,
  offlineUuid: `u-${n}`,
})

describe('1600-b8: la cola encolada en otra sucursal', () => {
  beforeEach(async () => {
    await clearAllData()
    sesion.sucursalId = 1
    Object.defineProperty(navigator, 'onLine', { value: true, writable: true, configurable: true })
  })

  it('se cuenta aparte, no entra al contador de la sucursal activa y no se manda cruzada', async () => {
    await queueOperation('CREATE_PEDIDO', pedido(1), 'user-A', 5, 1)
    await queueOperation('CREATE_PEDIDO', pedido(2), 'user-A', 5, 2)
    await queueOperation('CREATE_PEDIDO', pedido(3), 'user-A', 5, 2)

    const { result } = renderHook(() => useOfflineSync())
    await waitFor(() => expect(result.current.pendientesOtrasSucursales).toEqual([{ sucursalId: 2, cantidad: 2 }]))
    expect(result.current.cantidadPendientes).toBe(1)

    const crear = vi.fn(async (_input: Input) => ({ id: 1 }))
    await act(async () => { await result.current.sincronizarPedidos(crear as CrearPedidoFunction, []) })

    // Sólo el de la sucursal 1, con la sucursal 1.
    expect(crear).toHaveBeenCalledTimes(1)
    expect(crear.mock.calls[0][0]).toMatchObject({ offlineId: 'u-1', sucursalId: 1 })
    // Los de la 2 siguen esperando, y se siguen avisando.
    expect(result.current.pendientesOtrasSucursales).toEqual([{ sucursalId: 2, cantidad: 2 }])
  })

  it('al cambiar a su sucursal se ven en el contador y se mandan con ella', async () => {
    await queueOperation('CREATE_PEDIDO', pedido(2), 'user-A', 5, 2)

    const { result, rerender } = renderHook(() => useOfflineSync())
    await waitFor(() => expect(result.current.pendientesOtrasSucursales).toEqual([{ sucursalId: 2, cantidad: 1 }]))
    expect(result.current.cantidadPendientes).toBe(0)

    sesion.sucursalId = 2
    rerender()

    await waitFor(() => expect(result.current.cantidadPendientes).toBe(1))
    expect(result.current.pendientesOtrasSucursales).toEqual([])

    const crear = vi.fn(async (_input: Input) => ({ id: 9 }))
    await act(async () => { await result.current.sincronizarPedidos(crear as CrearPedidoFunction, []) })

    expect(crear).toHaveBeenCalledTimes(1)
    expect(crear.mock.calls[0][0]).toMatchObject({ offlineId: 'u-2', sucursalId: 2 })
    expect(result.current.cantidadPendientes).toBe(0)
  })
})
