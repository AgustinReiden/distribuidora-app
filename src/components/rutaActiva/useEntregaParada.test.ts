/**
 * Tests de `useEntregaParada` — el cierre del modal de cobranza.
 *
 * El bug que cubren (Taco Pozo, 08/08/2026): el chofer cobraba, veía "Pago
 * registrado", y la parada le seguía apareciendo impaga y sin entregar.
 *
 * `pedidoParaCobrar` es una foto sacada al ABRIR el modal. Al cerrarlo se
 * llamaba a `onMarcarEntregado` con esa foto, donde `monto_pagado` seguía en 0.
 * El contenedor mira `estado_pago` para decidir: si no está pagado, en vez de
 * confirmar la entrega vuelve a abrir el modal de cobranza. Resultado: cobro
 * asentado en la base, parada pendiente en pantalla, y un loop.
 *
 * La regla que hay que sostener: al cerrar con un cobro exitoso, el pedido que
 * se manda ya tiene que reflejar lo cobrado.
 */
import { describe, it, expect, vi } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useEntregaParada, type PedidoConCliente, type DatosPago } from './useEntregaParada'

const pedido = (over: Partial<PedidoConCliente> = {}): PedidoConCliente => ({
  id: '4625',
  total: 21600,
  monto_pagado: 0,
  estado: 'asignado',
  estado_pago: 'pendiente',
  cliente: { id: '1', nombre_fantasia: 'SABRI ARIAS' },
  items: [],
  ...over,
} as unknown as PedidoConCliente)

const datosPago = (monto: number): DatosPago => ({
  clienteId: '1', pedidoId: '4625', monto, formaPago: 'efectivo',
  referencia: '', notas: '', fecha: '2026-08-08',
})

function setup() {
  const onMarcarEntregado = vi.fn()
  const onRegistrarPago = vi.fn().mockResolvedValue({ id: '1', monto: 0 })
  const { result } = renderHook(() =>
    useEntregaParada({ onMarcarEntregado, onRegistrarPago }),
  )
  return { onMarcarEntregado, onRegistrarPago, result }
}

describe('useEntregaParada — cierre del modal de cobranza', () => {
  it('al cobrar el total, marca entregado con el pedido YA pagado', async () => {
    const { onMarcarEntregado, result } = setup()

    act(() => result.current.marcarEntregado(pedido()))
    await act(async () => { await result.current.confirmarPago(datosPago(21600)) })
    act(() => result.current.cerrarModalPago())

    expect(onMarcarEntregado).toHaveBeenCalledTimes(1)
    // Sin esto el contenedor reabre el modal de cobranza en vez de entregar.
    expect(onMarcarEntregado.mock.calls[0][0]).toMatchObject({
      id: '4625', estado_pago: 'pagado', monto_pagado: 21600,
    })
  })

  it('suma las lineas de un pago dividido (una llamada por forma de pago)', async () => {
    const { onMarcarEntregado, result } = setup()

    act(() => result.current.marcarEntregado(pedido()))
    await act(async () => { await result.current.confirmarPago(datosPago(10000)) })
    await act(async () => { await result.current.confirmarPago(datosPago(11600)) })
    act(() => result.current.cerrarModalPago())

    expect(onMarcarEntregado.mock.calls[0][0]).toMatchObject({
      estado_pago: 'pagado', monto_pagado: 21600,
    })
  })

  it('cobro parcial: entrega marcada como parcial, no como pagada', async () => {
    const { onMarcarEntregado, result } = setup()

    act(() => result.current.marcarEntregado(pedido()))
    await act(async () => { await result.current.confirmarPago(datosPago(10000)) })
    act(() => result.current.cerrarModalPago())

    expect(onMarcarEntregado.mock.calls[0][0]).toMatchObject({
      estado_pago: 'parcial', monto_pagado: 10000,
    })
  })

  it('parte sobre un pedido que ya venia con un pago previo', async () => {
    const { onMarcarEntregado, result } = setup()

    act(() => result.current.marcarEntregado(pedido({ monto_pagado: 1600, estado_pago: 'parcial' })))
    await act(async () => { await result.current.confirmarPago(datosPago(20000)) })
    act(() => result.current.cerrarModalPago())

    expect(onMarcarEntregado.mock.calls[0][0]).toMatchObject({
      estado_pago: 'pagado', monto_pagado: 21600,
    })
  })

  it('si se cierra sin cobrar, no marca entregado', async () => {
    const { onMarcarEntregado, result } = setup()

    act(() => result.current.marcarEntregado(pedido()))
    act(() => result.current.cerrarModalPago())

    expect(onMarcarEntregado).not.toHaveBeenCalled()
  })

  it('no arrastra lo cobrado de una parada a la siguiente', async () => {
    const { onMarcarEntregado, result } = setup()

    act(() => result.current.marcarEntregado(pedido()))
    await act(async () => { await result.current.confirmarPago(datosPago(21600)) })
    act(() => result.current.cerrarModalPago())

    // Segunda parada, mismo monto de pedido, cobro parcial
    act(() => result.current.marcarEntregado(pedido({ id: '4626' })))
    await act(async () => { await result.current.confirmarPago(datosPago(5000)) })
    act(() => result.current.cerrarModalPago())

    expect(onMarcarEntregado.mock.calls[1][0]).toMatchObject({
      id: '4626', estado_pago: 'parcial', monto_pagado: 5000,
    })
  })

  it('un pedido ya pagado va derecho a entregar, sin abrir cobranza', () => {
    const { onMarcarEntregado, result } = setup()

    act(() => result.current.marcarEntregado(pedido({ estado_pago: 'pagado', monto_pagado: 21600 })))

    expect(result.current.pedidoParaCobrar).toBeNull()
    expect(onMarcarEntregado).toHaveBeenCalledTimes(1)
  })
})
