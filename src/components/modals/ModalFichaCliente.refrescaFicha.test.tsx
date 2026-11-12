/**
 * FRT-1 (#1544): la ficha del cliente refresca su propio estado tras quitar un pago o anular
 * una nota de crédito.
 *
 * `useFichaCliente` (pedidos y estadísticas, con el estado de pago de cada boleta) es estado
 * local, no TanStack: invalidar `['pedidos']` no lo toca. Antes, «Quitar de la boleta» y
 * anular una NC recargaban pagos y resumen pero no la ficha, y la boleta seguía «pagada».
 * `refrescarTrasImputar` era el único camino correcto.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const { eliminarPago, desimputarPago, fetchPagosCliente, refetchFicha, pagosMock } = vi.hoisted(() => ({
  eliminarPago: vi.fn(),
  desimputarPago: vi.fn(),
  fetchPagosCliente: vi.fn(),
  refetchFicha: vi.fn(),
  pagosMock: { lista: [] as Array<Record<string, unknown>> },
}))

vi.mock('../../hooks/supabase', () => ({
  // `refetch` estable: es lo que la ficha tiene que llamar.
  useFichaCliente: () => ({ pedidosCliente: [], estadisticas: null, loading: false, refetch: refetchFicha }),
  usePagos: () => ({
    pagos: pagosMock.lista, loading: false,
    fetchPagosCliente,
    obtenerResumenCuenta: vi.fn().mockResolvedValue(null),
    eliminarPago,
    desimputarPago,
  }),
}))
vi.mock('../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn(), auth: { getSession: vi.fn(), onAuthStateChange: vi.fn() } },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ perfil: { id: 'u1', rol: 'admin' } }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))
vi.mock('@tanstack/react-query', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@tanstack/react-query')>()),
  useQueryClient: () => ({ invalidateQueries: vi.fn() }),
}))
// La lista de NC tiene su propia consulta: acá sólo importa lo que la ficha hace con su `onCambio`.
vi.mock('./NotasCreditoVentaCliente', () => ({
  default: ({ onCambio }: { onCambio?: () => void }) => (
    <button onClick={onCambio}>Simular NC anulada</button>
  ),
}))

import ModalFichaCliente from './ModalFichaCliente'
import type { ClienteDB } from '../../types'

const CLIENTE = { id: '303', nombre_fantasia: 'MARCOS CHOFER' } as unknown as ClienteDB

const pago = (extra: Record<string, unknown>) => ({
  id: '10', cliente_id: '303', monto: 4000, forma_pago: 'efectivo',
  created_at: '2026-11-05T12:00:00Z', usuario: { id: 'u1', nombre: 'Ana' }, ...extra,
})

beforeEach(() => {
  vi.clearAllMocks()
  eliminarPago.mockResolvedValue(undefined)
  desimputarPago.mockResolvedValue({ yaEstabaSuelto: false, saldoAFavor: 4000 })
  fetchPagosCliente.mockResolvedValue([])
  refetchFicha.mockResolvedValue(undefined)
})

describe('ModalFichaCliente — refresca la ficha tras cambiar pagos (FRT-1)', () => {
  it('«Quitar de la boleta» vuelve a pedir la ficha', async () => {
    pagosMock.lista = [pago({ pedido_id: '5501', de_saldo_a_favor: true })]
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
    await user.click(screen.getByRole('button', { name: /^Pagos$/ }))
    refetchFicha.mockClear()

    await user.click(screen.getByRole('button', { name: 'Quitar de la boleta' }))
    await user.click(screen.getByRole('button', { name: 'Sí, quitar' }))

    await waitFor(() => expect(desimputarPago).toHaveBeenCalledWith('10', '5501'))
    await waitFor(() => expect(refetchFicha).toHaveBeenCalledTimes(1))
  })

  it('anular un cobro común también vuelve a pedir la ficha', async () => {
    pagosMock.lista = [pago({ pedido_id: '5501' })]
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
    await user.click(screen.getByRole('button', { name: /^Pagos$/ }))
    refetchFicha.mockClear()

    await user.click(screen.getByRole('button', { name: 'Anular pago' }))
    await user.click(screen.getByRole('button', { name: 'Sí, anular' }))

    await waitFor(() => expect(eliminarPago).toHaveBeenCalledWith('10'))
    await waitFor(() => expect(refetchFicha).toHaveBeenCalledTimes(1))
  })

  it('anular una nota de crédito vuelve a pedir la ficha, además de pagos y resumen', async () => {
    pagosMock.lista = []
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
    await user.click(screen.getByRole('button', { name: /Notas de crédito/ }))
    fetchPagosCliente.mockClear()
    refetchFicha.mockClear()

    await user.click(screen.getByRole('button', { name: 'Simular NC anulada' }))

    expect(refetchFicha).toHaveBeenCalledTimes(1)
    expect(fetchPagosCliente).toHaveBeenCalledWith('303')
  })
})
