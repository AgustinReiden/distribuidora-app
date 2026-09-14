/**
 * `ModalSalvedadItem` — idempotencia del submit (mig 174).
 *
 * El modal de salvedad del chofer en la ruta activa no mandaba
 * `clientRequestId`: cada reintento acuñaba un UUID nuevo y `registrar_salvedad`
 * (que dedupe por `client_request_id`) aplicaba la salvedad de nuevo. El total
 * bajaba dos veces, el stock volvía dos veces y el pago cobrado se recortaba dos
 * veces (mig 167). La regla que importa: mientras la huella (pedido + item +
 * cantidad + motivo) no cambie, dos submits mandan el MISMO UUID.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor, fireEvent } from '@testing-library/react'

vi.mock('../../hooks/queries', () => ({
  useSimularSalvedadPromoImpactoQuery: () => ({ data: [] }),
}))

import ModalSalvedadItem from './ModalSalvedadItem'
import type { PedidoItemDB } from '../../types'

const ITEM = {
  id: 'item-1',
  pedido_id: 'pedido-1',
  producto_id: 'prod-1',
  cantidad: 5,
  precio_unitario: 1000,
  producto: { id: 'prod-1', nombre: 'Yerba', codigo: 'Y1' },
} as unknown as PedidoItemDB

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i

describe('ModalSalvedadItem — clientRequestId', () => {
  it('dos submits con los mismos datos mandan el mismo clientRequestId', async () => {
    const onSave = vi.fn().mockResolvedValue({ success: false, error: 'Sin conexion, reintentá' })

    render(
      <ModalSalvedadItem pedidoId="pedido-1" item={ITEM} onSave={onSave} onClose={vi.fn()} />,
    )

    fireEvent.click(screen.getByText('Cliente Rechaza'))
    fireEvent.click(screen.getByRole('button', { name: /registrar salvedad/i }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    const primerId = onSave.mock.calls[0][0].clientRequestId as string
    expect(primerId).toMatch(UUID_RE)

    // Reintento: mismos datos (cantidad y motivo no cambiaron).
    fireEvent.click(screen.getByRole('button', { name: /registrar salvedad/i }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(2))
    const segundoId = onSave.mock.calls[1][0].clientRequestId as string
    expect(segundoId).toBe(primerId)
  })

  it('si cambia la cantidad (otra huella) el clientRequestId es distinto', async () => {
    const onSave = vi.fn().mockResolvedValue({ success: false, error: 'Sin conexion, reintentá' })

    render(
      <ModalSalvedadItem pedidoId="pedido-1" item={ITEM} onSave={onSave} onClose={vi.fn()} />,
    )

    fireEvent.click(screen.getByText('Cliente Rechaza'))
    fireEvent.click(screen.getByRole('button', { name: /registrar salvedad/i }))
    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    const primerId = onSave.mock.calls[0][0].clientRequestId as string

    // La cantidad arranca en item.cantidad (tope del spinner): restar una
    // unidad cambia la huella, es otra salvedad, no un reintento.
    fireEvent.click(screen.getByRole('button', { name: /restar uno/i }))
    fireEvent.click(screen.getByRole('button', { name: /registrar salvedad/i }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(2))
    const segundoId = onSave.mock.calls[1][0].clientRequestId as string
    expect(segundoId).not.toBe(primerId)
  })
})
