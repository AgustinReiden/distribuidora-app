/**
 * INF-2 (#1563): el replay de la cola manda cada pedido con SU sucursal, por
 * request, sin tocar el header global `X-Sucursal-ID`.
 *
 * Antes la fijaba en el global (`setSucursalHeader(op.sucursalId)`) en cada vuelta.
 * Si el usuario cambiaba a la sucursal 2 mientras se reenviaban pedidos de la 1,
 * la vuelta siguiente le volvía a poner la 1: las consultas de la pantalla de la 2
 * salían con la 1 y quedaban 5 minutos en caché bajo la clave de la 2. Con tres
 * pedidos encolados, las consultas del medio salieron con `[2, 1, 1]`.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'

const global = vi.hoisted(() => ({ header: 1 as number | null, escrituras: [] as Array<number | null> }))

vi.mock('../../lib/supabase', () => ({
  supabase: { from: vi.fn(), rpc: vi.fn(), rest: { headers: {} }, auth: { refreshSession: vi.fn() } },
  setSucursalHeader: (n: number | null) => { global.header = n; global.escrituras.push(n) },
  getSucursalHeader: () => global.header,
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ userId: 'user-A', currentSucursalId: 1, sucursales: [], loading: false, switchSucursal: vi.fn() }),
}))

import { useOfflineSync, type CrearPedidoFunction } from '../useOfflineSync'
import { clearAllData, queueOperation } from '../../lib/offlineDb'

type Input = Parameters<CrearPedidoFunction>[0]

/** Lo que hace `SucursalContext.switchSucursal` con el header. */
function elegirSucursal(id: number) {
  global.header = id
}

describe('INF-2: el replay no toca la sucursal de la pantalla', () => {
  beforeEach(async () => {
    await clearAllData()
    global.header = 1
    global.escrituras.length = 0
    Object.defineProperty(navigator, 'onLine', { value: true, writable: true, configurable: true })
  })

  it('cambiar a la 2 durante el reenvío de tres pedidos de la 1: la pantalla sigue en la 2', async () => {
    for (let i = 0; i < 3; i++) {
      await queueOperation(
        'CREATE_PEDIDO',
        { clienteId: '7', items: [{ productoId: 'p1', cantidad: 1, precioUnitario: 1 }], total: 1, offlineUuid: `u-${i}` },
        'user-A', 5, 1,
      )
    }
    const { result } = renderHook(() => useOfflineSync())
    await waitFor(() => expect(result.current.pedidosPendientes).toHaveLength(3))

    const sucursalDeCadaAlta: Array<number | null | undefined> = []
    const headerDeLaPantalla: Array<number | null> = []
    let n = 0
    const crear = vi.fn(async (input: Input) => {
      sucursalDeCadaAlta.push(input.sucursalId)
      n++
      if (n === 1) elegirSucursal(2)
      // Entre un pedido y el siguiente, la pantalla (ya en la 2) consulta.
      await new Promise(r => setTimeout(r, 5))
      headerDeLaPantalla.push(global.header)
      return { id: n }
    })

    await act(async () => { await result.current.sincronizarPedidos(crear as CrearPedidoFunction, []) })

    expect(crear).toHaveBeenCalledTimes(3)
    // Cada alta viaja con la sucursal en la que se encoló…
    expect(sucursalDeCadaAlta).toEqual([1, 1, 1])
    // …y la pantalla no la ve: sus consultas salen con la que eligió.
    expect(headerDeLaPantalla).toEqual([2, 2, 2])
    expect(global.header).toBe(2)
    // El replay no escribe el header global, ni siquiera para "restaurarlo".
    expect(global.escrituras).toEqual([])
  })
})
