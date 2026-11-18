/**
 * H2 de la revisión de B12a (ya pasaba; D56 lo vuelve rutina): el replay marcaba
 * «fallido · otro pedido» a un pedido PROPIO que sí había entrado.
 *
 * D56 manda por la cola justo el caso «entró y se perdió la respuesta». Si antes
 * del replay el pedido se editó, se canceló o difiere un centavo (`< 0.01` contra
 * el `mismoTotalDelAlta` del alta directa), la cola lo daba por «otro pedido» y
 * eso invitaba a cargarlo de nuevo a mano: ahí sí se duplicaba.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'

vi.mock('../../lib/supabase', () => ({
  supabase: { from: vi.fn(), rpc: vi.fn(), rest: { headers: {} }, auth: { refreshSession: vi.fn() } },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ userId: 'user-A', currentSucursalId: 1, sucursales: [], loading: false, switchSucursal: vi.fn() }),
}))

import {
  useOfflineSync,
  verificarRespuestaIdempotente,
  avisoPedidoQueYaHabiaEntrado,
  type CrearPedidoFunction,
} from '../useOfflineSync'
import { clearAllData, queueOperation, getFailedOperations } from '../../lib/offlineDb'

const CLAVE_UUID = '6f1c2a3b-4d5e-4f60-8a71-92b3c4d5e6f7'
const encolado = { clienteId: '7', total: 1000 }

describe('verificarRespuestaIdempotente (H2)', () => {
  it('un centavo de diferencia es el mismo pedido, como en el alta directa (`mismoTotalDelAlta`)', () => {
    const r = { idempotente: true, id: 42, clienteId: 7, total: 1000.01, cargoEnvio: 0 }
    expect(verificarRespuestaIdempotente(r, encolado, CLAVE_UUID)).toBeNull()
    expect(avisoPedidoQueYaHabiaEntrado(r, encolado)).toBeNull()
  })

  it('mismo cliente y otro total con una clave por intención: es el propio, cambiado después', () => {
    const cancelado = { idempotente: true, id: 42, clienteId: 7, total: 0, cargoEnvio: 0 }
    expect(verificarRespuestaIdempotente(cancelado, encolado, CLAVE_UUID)).toBeNull()
    expect(avisoPedidoQueYaHabiaEntrado(cancelado, encolado)).toMatch(/#42 ya estaba cargado.*cambió.*no se cargó otro/)
  })

  it('otro cliente sigue siendo «otro pedido», terminal', () => {
    const ajeno = { idempotente: true, id: 42, clienteId: 8, total: 1000, cargoEnvio: 0 }
    expect(verificarRespuestaIdempotente(ajeno, encolado, CLAVE_UUID)).toMatchObject({ terminal: true })
  })

  it('una clave heredada `…:op_<n>` (puede repetirse en el teléfono) con otro total sigue siendo terminal', () => {
    const r = { idempotente: true, id: 42, clienteId: 7, total: 500, cargoEnvio: 0 }
    expect(verificarRespuestaIdempotente(r, encolado, 'user-A:op_3')).toMatchObject({ terminal: true })
  })
})

describe('el replay de un pedido propio que ya había entrado y cambió (H2)', () => {
  beforeEach(async () => {
    await clearAllData()
    Object.defineProperty(navigator, 'onLine', { value: true, writable: true, configurable: true })
  })

  it('lo da por sincronizado (no «fallido») y avisa que ya estaba cargado', async () => {
    await queueOperation(
      'CREATE_PEDIDO',
      { clienteId: '7', items: [{ productoId: 'p1', cantidad: 1, precioUnitario: 1000 }], total: 1000, offlineUuid: CLAVE_UUID },
      'user-A', 5, 1,
    )
    const { result } = renderHook(() => useOfflineSync())
    await waitFor(() => expect(result.current.cantidadPendientes).toBe(1))

    // La rama idempotente: el pedido 42 entró en el intento directo y después se canceló.
    const crear = vi.fn(async () => ({ id: 42, idempotente: true, clienteId: '7', total: 0, cargoEnvio: 0 }))
    let resultado: Awaited<ReturnType<typeof result.current.sincronizarPedidos>> | undefined
    await act(async () => { resultado = await result.current.sincronizarPedidos(crear as unknown as CrearPedidoFunction, []) })

    expect(resultado?.sincronizados).toBe(1)
    expect(resultado?.errores).toEqual([])
    expect(resultado?.avisos).toEqual([expect.stringMatching(/#42 ya estaba cargado/)])
    expect(await getFailedOperations(50, 'user-A', 1)).toEqual([])
    expect(result.current.cantidadPendientes).toBe(0)
  })
})
