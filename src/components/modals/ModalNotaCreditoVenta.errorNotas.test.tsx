/**
 * frv-B4 (tanda 6 de #1603): si la consulta de las notas del pedido falla, el modal no ofrece
 * todo como acreditable (con `[]` parecía que el pedido no tenía ninguna nota) y deja reintentar.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'

const reintentar = vi.fn()
const estado = { isError: true }

vi.mock('../../hooks/queries/useNotasCreditoVentaQuery', () => ({
  useNotasCreditoVentaPedidoQuery: () => ({ data: undefined, isLoading: false, isError: estado.isError, refetch: reintentar }),
  useCrearNotaCreditoVentaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock('../../hooks/queries/useImputarCreditoQuery', () => ({
  usePedidosParaImputarQuery: () => ({ data: [], isLoading: false, error: null }),
  usePedidoOrigenNCQuery: () => ({ data: undefined, isLoading: false }),
  useImputarCreditoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn() }),
}))

import ModalNotaCreditoVenta from './ModalNotaCreditoVenta'
import type { PedidoDB } from '../../types'

const pedido = {
  id: '6510',
  cliente_id: '858',
  estado: 'entregado',
  cliente: { nombre_fantasia: 'Kiosco' },
  items: [{ id: '23807', producto_id: '10', cantidad: 1, precio_unitario: 11100, producto: { nombre: 'Fideos' } }],
} as unknown as PedidoDB

beforeEach(() => {
  reintentar.mockReset()
  estado.isError = true
})

describe('ModalNotaCreditoVenta — la consulta de las notas del pedido falló (frv-B4)', () => {
  it('no ofrece las líneas como acreditables: avisa que no pudo cargar y deja reintentar', () => {
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    expect(screen.getByRole('alert')).toHaveTextContent(/No se pudo cargar/)
    expect(screen.getByRole('alert')).toHaveTextContent(/notas de crédito que ya tiene este pedido/)
    expect(screen.queryByLabelText(/Cantidad a acreditar de Fideos/)).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(reintentar).toHaveBeenCalledTimes(1)
  })

  it('no deja emitir mientras tanto', () => {
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    fireEvent.change(screen.getByRole('combobox'), { target: { value: 'cliente_rechaza' } })
    expect(screen.getByRole('button', { name: /Emitir nota de crédito/ })).toBeDisabled()
  })

  it('con la consulta sana ofrece las líneas, como siempre', () => {
    estado.isError = false
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    expect(screen.getByLabelText(/Cantidad a acreditar de Fideos/)).toBeInTheDocument()
    expect(screen.queryByText(/No se pudo cargar/)).toBeNull()
  })
})
