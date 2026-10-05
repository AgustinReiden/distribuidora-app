/**
 * #833 — ModalNotaCreditoVenta: la leyenda de comisión, el total en vivo, lo ya
 * acreditado y el payload que llega a la RPC (precio del pedido, ids numéricos,
 * sólo líneas con cantidad, sin regalos), y el paso final tras emitir: ofrecer
 * imputar el crédito a otro pedido (nunca al de origen) o dejarlo a favor.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'

const mutateAsync = vi.fn()
let notasPedido: unknown[] = []

vi.mock('../../hooks/queries/useNotasCreditoVentaQuery', () => ({
  useNotasCreditoVentaPedidoQuery: () => ({ data: notasPedido, isLoading: false }),
  useCrearNotaCreditoVentaMutation: () => ({ mutateAsync, isPending: false }),
}))
const imputarMutate = vi.fn()
let pedidosCliente: unknown[] = []
vi.mock('../../hooks/queries/useImputarCreditoQuery', () => ({
  usePedidosParaImputarQuery: () => ({ data: pedidosCliente, isLoading: false, error: null }),
  usePedidoOrigenNCQuery: () => ({ data: undefined, isLoading: false }),
  useImputarCreditoMutation: () => ({ mutateAsync: imputarMutate, isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn() }),
}))

import ModalNotaCreditoVenta, { notaCreditoVentaSchema } from './ModalNotaCreditoVenta'
import type { PedidoDB } from '../../types'

const pedido = {
  id: '6510',
  cliente_id: '858',
  estado: 'entregado',
  cliente: { nombre_fantasia: 'Kiosco' },
  items: [
    { id: '23807', producto_id: '10', cantidad: 1, precio_unitario: 11100, producto: { nombre: 'Fideos' } },
    { id: '23808', producto_id: '11', cantidad: 2, precio_unitario: 5600, producto: { nombre: 'Arroz' } },
    { id: '23811', producto_id: '12', cantidad: 2, precio_unitario: 0, es_bonificacion: true, producto: { nombre: 'Regalo' } },
  ],
} as unknown as PedidoDB

describe('ModalNotaCreditoVenta', () => {
  beforeEach(() => {
    mutateAsync.mockReset()
    mutateAsync.mockResolvedValue({ nota_credito_id: 1, pago_id: 901, total: 16700 })
    notasPedido = []
    imputarMutate.mockReset()
    pedidosCliente = []
  })

  it('muestra la leyenda de comisión y no ofrece los regalos', () => {
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    expect(screen.getByText('No afecta la comisión del vendedor')).toBeInTheDocument()
    expect(screen.queryByText('Regalo')).toBeNull()
  })

  // Antes de la imputación elegida el modal se cerraba al emitir. Ahora queda
  // abierto en un paso final (imputar ya o dejar a favor), así que este test
  // fija que NO cierra solo y que «Dejar como saldo a favor» es lo que cierra.
  it('manda a la RPC sólo las líneas elegidas y pasa al paso final', async () => {
    const onClose = vi.fn()
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={onClose} />)
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Fideos'), { target: { value: '1' } })
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Arroz'), { target: { value: '1' } })
    expect(screen.getByText(/16\.700/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /Emitir nota de crédito/ }))
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    const arg = mutateAsync.mock.calls[0][0]
    expect(arg).toMatchObject({
      pedidoId: '6510',
      clienteId: '858',
      motivo: 'producto_vencido',
      items: [{ pedido_item_id: 23807, cantidad: 1 }, { pedido_item_id: 23808, cantidad: 1 }],
    })
    expect(typeof arg.clientRequestId).toBe('string')
    expect(await screen.findByText(/emitido \(nota de crédito #1\)/)).toBeInTheDocument()
    expect(screen.getByText('¿Imputarlo ahora a un pedido?')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Dejar como saldo a favor' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('«Imputar a un pedido» muestra la imputación inline, sin el pedido de origen', async () => {
    pedidosCliente = [
      { id: 6510, fecha: '2026-09-01', total: 50000, monto_pagado: 0, estado: 'entregado' },
      { id: 7001, fecha: '2026-09-20', total: 12000, monto_pagado: 2000, estado: 'entregado' },
    ]
    imputarMutate.mockResolvedValue({ pagoId: '901', pedidoId: '7001', montoImputado: 10000, restoAFavor: 6700, pagoRestoId: '902', idempotentReplay: false })
    const onClose = vi.fn()
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={onClose} />)
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Fideos'), { target: { value: '1' } })
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Arroz'), { target: { value: '1' } })
    fireEvent.click(screen.getByRole('button', { name: /Emitir nota de crédito/ }))
    fireEvent.click(await screen.findByRole('button', { name: 'Imputar a un pedido' }))

    expect(await screen.findByRole('option', { name: /^Pedido #7001 / })).toBeInTheDocument()
    expect(screen.queryByRole('option', { name: /^Pedido #6510 / })).toBeNull()
    expect(screen.getByText('Una vez imputada, la nota de crédito ya no se puede anular.')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /^Imputar$/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Sí, imputar' }))
    await waitFor(() => expect(imputarMutate).toHaveBeenCalledTimes(1))
    expect(imputarMutate.mock.calls[0][0]).toMatchObject({ pagoId: '901', pedidoId: '7001', monto: 10000 })
    await waitFor(() => expect(onClose).toHaveBeenCalled())
  })

  it('el título y el pie dicen qué se emite y adónde va el crédito', () => {
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    expect(screen.getByText('Nota de crédito por mercadería vencida o dañada')).toBeInTheDocument()
    expect(screen.getByText('Total a acreditar:', { exact: false })).toBeInTheDocument()
    expect(screen.getByText('Pedido de origen #6510 · queda como saldo a favor del cliente')).toBeInTheDocument()
  })

  it('descuenta lo acreditado en NCs vigentes del mismo pedido', () => {
    notasPedido = [{ id: '1', fecha: '2026-09-29', anulada: false, items: [{ pedido_item_id: '23807', cantidad: 1 }] }]
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    expect(screen.getByLabelText('Cantidad a acreditar de Fideos')).toBeDisabled()
    expect(screen.getByText('1 ya acreditado')).toBeInTheDocument()
  })

  it('el schema co-locado acepta los motivos de la tabla', () => {
    expect(notaCreditoVentaSchema.safeParse({ motivo: 'producto_vencido' }).success).toBe(true)
    expect(notaCreditoVentaSchema.safeParse({ motivo: 'devolucion' }).success).toBe(false)
  })
})
