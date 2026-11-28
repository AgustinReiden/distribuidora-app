/**
 * T4 (#1710): cada cobro va a la caja de quien lo cobró. En «Entregar y registrar pago» la oficina
 * carga la entrega a nombre del chofer: el cobro es del chofer, y el admin puede elegir otro. En el
 * cobro de una boleta desde la oficina, sin elegir, es de quien lo carga.
 */
import React from 'react'
import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen, waitFor, fireEvent, cleanup } from '@testing-library/react'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
  useFechasMinimasPorCobrador: () => new Map(),
}))

import ModalPagoPedido, { type ModalPagoPedidoProps } from './ModalPagoPedido'
import type { PedidoDB } from '../../types'

const pedido = { id: '4625', cliente_id: '1', total: 10000, transportista_id: 'chofer-a' } as unknown as PedidoDB
const personas = [
  { id: 'admin-1', nombre: 'Admin' },
  { id: 'chofer-a', nombre: 'Chofer A' },
  { id: 'encargada', nombre: 'Encargada' },
]

function renderModal(extra: Partial<ModalPagoPedidoProps> = {}) {
  return render(
    <ModalPagoPedido
      pedido={pedido}
      pagosPrevios={[]}
      onConfirmar={vi.fn().mockResolvedValue(undefined)}
      onClose={vi.fn()}
      guardando={false}
      {...extra}
    />,
  )
}
const inputMonto = (): HTMLInputElement => screen.getAllByPlaceholderText(/0[.,]00/i)[0] as HTMLInputElement

afterEach(cleanup)

describe('ModalPagoPedido — quién cobró (T4)', () => {
  it('sin la lista (no es admin) no hay selector ni se manda quién cobró', async () => {
    const onConfirmar = vi.fn().mockResolvedValue(undefined)
    renderModal({ onConfirmar, modoEntregaTransportista: true, onEntregarSinPago: vi.fn() })
    expect(screen.queryByLabelText(/quién cobró/i)).toBeNull()
    await waitFor(() => expect(inputMonto().value).toBe('10.000'))
    fireEvent.click(screen.getByRole('button', { name: /^entregar y registrar pago$/i }))
    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0]).not.toHaveProperty('cobradoPor')
  })

  it('el admin, al entregar con pago, arranca en el chofer de la boleta: $ 10.000 a la caja de Chofer A', async () => {
    const onConfirmar = vi.fn().mockResolvedValue(undefined)
    renderModal({ onConfirmar, isAdmin: true, quienesCobran: personas, yoId: 'admin-1',
                  modoEntregaTransportista: true, onEntregarSinPago: vi.fn() })
    const select = screen.getByLabelText(/quién cobró/i) as HTMLSelectElement
    expect(select.value).toBe('chofer-a')
    await waitFor(() => expect(inputMonto().value).toBe('10.000'))
    fireEvent.click(screen.getByRole('button', { name: /^entregar y registrar pago$/i }))
    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0].cobradoPor).toBe('chofer-a')
  })

  it('el admin elige que lo cobró la encargada', async () => {
    const onConfirmar = vi.fn().mockResolvedValue(undefined)
    renderModal({ onConfirmar, isAdmin: true, quienesCobran: personas, yoId: 'admin-1',
                  modoEntregaTransportista: true, onEntregarSinPago: vi.fn() })
    fireEvent.change(screen.getByLabelText(/quién cobró/i), { target: { value: 'encargada' } })
    await waitFor(() => expect(inputMonto().value).toBe('10.000'))
    fireEvent.click(screen.getByRole('button', { name: /^entregar y registrar pago$/i }))
    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0].cobradoPor).toBe('encargada')
  })

  it('en el cobro de una boleta desde la oficina arranca en «Yo» (null)', async () => {
    const onConfirmar = vi.fn().mockResolvedValue(undefined)
    renderModal({ onConfirmar, isAdmin: true, quienesCobran: personas, yoId: 'admin-1' })
    const select = screen.getByLabelText(/quién cobró/i) as HTMLSelectElement
    expect(select.value).toBe('')
    // «Yo» no se repite en la lista.
    expect(Array.from(select.options).map(o => o.value)).toEqual(['', 'chofer-a', 'encargada'])
    await waitFor(() => expect(inputMonto().value).toBe('10.000'))
    fireEvent.click(screen.getByRole('button', { name: /registrar pago/i }))
    await waitFor(() => expect(onConfirmar).toHaveBeenCalledTimes(1))
    expect(onConfirmar.mock.calls[0][0].cobradoPor).toBeNull()
  })
})
