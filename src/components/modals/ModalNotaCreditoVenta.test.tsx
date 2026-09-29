/**
 * #833 — ModalNotaCreditoVenta: la leyenda de comisión, el total en vivo, lo ya
 * acreditado y el payload que llega a la RPC (precio del pedido, ids numéricos,
 * sólo líneas con cantidad, sin regalos).
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
    mutateAsync.mockResolvedValue({ nota_credito_id: 1, total: 16700 })
    notasPedido = []
  })

  it('muestra la leyenda de comisión y no ofrece los regalos', () => {
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    expect(screen.getByText('No afecta la comisión del vendedor')).toBeInTheDocument()
    expect(screen.queryByText('Regalo')).toBeNull()
  })

  it('manda a la RPC sólo las líneas elegidas y cierra', async () => {
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
    await waitFor(() => expect(onClose).toHaveBeenCalled())
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
