/**
 * Tests del contrato de alta de pedido con la base.
 *
 * EL INCIDENTE
 * ------------
 * El camino online llamaba a `crear_pedido_completo`, que NO tiene clave de
 * idempotencia. Y las mutations de react-query reintentan ante error de red. Si
 * la RPC commiteaba y la respuesta se perdía —señal débil, no caída: con 3G malo
 * `navigator.onLine` sigue en true— el pedido se creaba dos o tres veces,
 * descontando stock cada vez.
 *
 * `crear_pedido_idempotente` (mig 071, columna `pedidos.offline_id` con índice
 * único parcial) existía desde abril y sólo la usaba el replay offline: la
 * protección estaba escrita y sin usar justo en el camino por el que entra la
 * mayoría de los pedidos.
 *
 * Lo que estos tests fijan es el contrato, que es lo que se rompe en silencio:
 * el nombre de la RPC y el del parámetro. PostgREST resuelve la firma por
 * nombre de argumento, así que un typo no lo ve ni `tsc` ni el linter — falla
 * en runtime, con el preventista adelante del cliente.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const rpc = vi.fn()

// `from` lo usa la verificación del alta idempotente: cuando la RPC contesta
// "ya existía", el front lee ese pedido para saber si es el suyo.
const maybeSingle = vi.fn()

vi.mock('../supabase/base', () => ({
  supabase: {
    rpc: (...args: unknown[]) => rpc(...args),
    from: () => ({ select: () => ({ eq: () => ({ maybeSingle }) }) }),
  },
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import { useCrearPedidoMutation } from './usePedidosQuery'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function setup() {
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  return renderHook(() => useCrearPedidoMutation(), { wrapper: makeWrapper(qc) })
}

const input = {
  clienteId: '42',
  items: [{ productoId: '7', cantidad: 3, precioUnitario: 1200 }],
  total: 3600,
  usuarioId: 'user-1',
}

describe('alta de pedido — contrato con la base', () => {
  beforeEach(() => {
    rpc.mockReset()
    maybeSingle.mockReset()
    // El segundo rpc (registrar_origen_precio_items) también pasa por acá.
    rpc.mockResolvedValue({ data: { success: true, pedido_id: '5001' }, error: null })
    maybeSingle.mockResolvedValue({ data: { cliente_id: '42', total: 3600 }, error: null })
  })

  it('usa crear_pedido_idempotente, no la RPC cruda', async () => {
    const { result } = setup()
    await result.current.mutateAsync({ ...input, offlineId: 'uuid-alta-1' })

    await waitFor(() => expect(rpc).toHaveBeenCalled())
    expect(rpc.mock.calls[0][0]).toBe('crear_pedido_idempotente')
  })

  it('manda el offlineId como p_offline_id — el nombre exacto del parámetro', async () => {
    const { result } = setup()
    await result.current.mutateAsync({ ...input, offlineId: 'uuid-alta-1' })

    expect(rpc).toHaveBeenCalledWith(
      'crear_pedido_idempotente',
      expect.objectContaining({
        p_offline_id: 'uuid-alta-1',
        p_cliente_id: '42',
        p_total: 3600,
      }),
    )
  })

  it('sin offlineId manda null y se comporta como antes', async () => {
    const { result } = setup()
    await result.current.mutateAsync(input)

    expect(rpc).toHaveBeenCalledWith(
      'crear_pedido_idempotente',
      expect.objectContaining({ p_offline_id: null }),
    )
  })

  it('devuelve el id del pedido que la base reconoció como ya creado', async () => {
    // Lo que responde el short-circuit: el pedido de la PRIMERA vez.
    rpc.mockResolvedValueOnce({
      data: { success: true, pedido_id: '5001', idempotente: true },
      error: null,
    })

    const { result } = setup()
    const creado = await result.current.mutateAsync({ ...input, offlineId: 'uuid-alta-1' })

    // Viaja con qué pedido es, no solo con el id: `idempotente` significa "ya
    // había uno con esa clave", no "ese pedido es tuyo". Quien reintenta tiene
    // que poder verificarlo antes de darlo por sincronizado.
    expect(creado).toEqual({ id: '5001', idempotente: true, clienteId: '42', total: 3600 })
  })

  /**
   * La clave de idempotencia vieja era `op_<autoincrement de Dexie>`, que
   * arranca en 1 en cada instalación: dos teléfonos podían mandar `op_1` y el
   * segundo recibía el pedido del primero. Lo que no puede pasar nunca es que
   * el metadato de precios de un pedido se escriba encima del de otro.
   */
  it('no le registra los orígenes de precio a un pedido que no es este', async () => {
    rpc.mockResolvedValueOnce({
      data: { success: true, pedido_id: '5001', idempotente: true },
      error: null,
    })
    maybeSingle.mockResolvedValue({ data: { cliente_id: '999', total: 111 }, error: null })

    const { result } = setup()
    const creado = await result.current.mutateAsync({
      ...input,
      offlineId: 'uuid-alta-1',
      origenes: [{ producto_id: '7', es_bonificacion: false, origen_precio: 'mayorista' as const }],
    })

    expect(creado).toMatchObject({ idempotente: true, clienteId: '999', total: 111 })
    const llamadasOrigen = rpc.mock.calls.filter(c => c[0] === 'registrar_origen_precio_items')
    expect(llamadasOrigen).toHaveLength(0)
  })

  it('sí les registra los orígenes cuando el pedido que ya existía es este', async () => {
    rpc.mockResolvedValueOnce({
      data: { success: true, pedido_id: '5001', idempotente: true },
      error: null,
    })

    const { result } = setup()
    await result.current.mutateAsync({
      ...input,
      offlineId: 'uuid-alta-1',
      origenes: [{ producto_id: '7', es_bonificacion: false, origen_precio: 'mayorista' as const }],
    })

    const llamadasOrigen = rpc.mock.calls.filter(c => c[0] === 'registrar_origen_precio_items')
    expect(llamadasOrigen).toHaveLength(1)
  })

  it('propaga el error de negocio de la RPC', async () => {
    rpc.mockResolvedValueOnce({
      data: { success: false, errores: ['Stock insuficiente para MANAOS COLA 3LT'] },
      error: null,
    })

    const { result } = setup()
    await expect(
      result.current.mutateAsync({ ...input, offlineId: 'uuid-alta-1' }),
    ).rejects.toThrow(/stock insuficiente/i)
  })
})
