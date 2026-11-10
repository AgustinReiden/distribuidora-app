/**
 * COB-2 (#1512, mig 479): en la pestaña Pagos de la ficha, el saldo a favor aplicado a una
 * boleta no se borra: se quita de la boleta (`desimputarPago`) y vuelve a ser crédito
 * suelto. Un cobro común sigue anulándose con el DELETE (`eliminarPago`), y el crédito
 * suelto de una NC sigue sin botón (se anula anulando la NC).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const { eliminarPago, desimputarPago, fetchPagosCliente, success, pagosMock } = vi.hoisted(() => ({
  eliminarPago: vi.fn(),
  desimputarPago: vi.fn(),
  fetchPagosCliente: vi.fn(),
  success: vi.fn(),
  pagosMock: { lista: [] as Array<Record<string, unknown>> },
}))

vi.mock('../../hooks/supabase', () => ({
  useFichaCliente: () => ({ pedidosCliente: [], estadisticas: null, loading: false, refetch: vi.fn() }),
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
  useNotification: () => ({ error: vi.fn(), success, warning: vi.fn(), info: vi.fn() }),
}))
const invalidateQueries = vi.fn()
vi.mock('@tanstack/react-query', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@tanstack/react-query')>()),
  useQueryClient: () => ({ invalidateQueries }),
}))

import ModalFichaCliente from './ModalFichaCliente'
import type { ClienteDB } from '../../types'

const CLIENTE = { id: '303', nombre_fantasia: 'MARCOS CHOFER' } as unknown as ClienteDB

const pago = (extra: Record<string, unknown>) => ({
  id: '10', cliente_id: '303', monto: 4000, forma_pago: 'efectivo',
  created_at: '2026-11-05T12:00:00Z', usuario: { id: 'u1', nombre: 'Ana' }, ...extra,
})

async function abrirPagos(pagos: Array<Record<string, unknown>>) {
  pagosMock.lista = pagos
  const user = userEvent.setup()
  render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
  await user.click(screen.getByRole('button', { name: /^Pagos$/ }))
  return user
}

beforeEach(() => {
  vi.clearAllMocks()
  eliminarPago.mockResolvedValue(undefined)
  desimputarPago.mockResolvedValue({ yaEstabaSuelto: false, saldoAFavor: 4000 })
  fetchPagosCliente.mockResolvedValue([])
})

describe('ModalFichaCliente — quitar de la boleta el saldo a favor aplicado (COB-2)', () => {
  it('un pago de_saldo_a_favor en una boleta se quita con desimputarPago, no se borra', async () => {
    const user = await abrirPagos([pago({ pedido_id: '5501', de_saldo_a_favor: true })])

    await user.click(screen.getByRole('button', { name: 'Quitar de la boleta' }))
    expect(screen.getByText(/¿Quitar este pago de/)).toHaveTextContent(/de la boleta #5501/)
    expect(screen.getByText(/¿Quitar este pago de/)).toHaveTextContent(/el saldo no cambia/)
    expect(screen.getByText(/¿Quitar este pago de/)).toHaveTextContent(/hasta su próximo\s+pedido o pago a cuenta, o hasta que lo imputes a mano/)
    await user.click(screen.getByRole('button', { name: 'Sí, quitar' }))

    await waitFor(() => expect(desimputarPago).toHaveBeenCalledWith('10', '5501'))
    expect(eliminarPago).not.toHaveBeenCalled()
    expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ['clientes'] })
    expect(success).toHaveBeenCalledWith('Se quitó de la boleta: vuelve a saldo a favor del cliente.')
  })

  it('el crédito de una NC aplicado a una boleta también se quita, aunque tenga nota_credito_id', async () => {
    const user = await abrirPagos([
      pago({ forma_pago: 'nota_credito', nota_credito_id: '7', pedido_id: '5501', de_saldo_a_favor: true }),
    ])

    await user.click(screen.getByRole('button', { name: 'Quitar de la boleta' }))
    await user.click(screen.getByRole('button', { name: 'Sí, quitar' }))

    await waitFor(() => expect(desimputarPago).toHaveBeenCalledWith('10', '5501'))
    expect(eliminarPago).not.toHaveBeenCalled()
  })

  it('un cobro común de la boleta se anula con el DELETE y el texto dice qué pasa', async () => {
    const user = await abrirPagos([pago({ pedido_id: '5501' })])

    await user.click(screen.getByRole('button', { name: 'Anular pago' }))
    expect(screen.getByText(/¿Anular este pago de/)).toHaveTextContent(
      /Se borra el cobro: la boleta #5501 vuelve a deber ese monto y el saldo del cliente sube\./,
    )
    await user.click(screen.getByRole('button', { name: 'Sí, anular' }))

    await waitFor(() => expect(eliminarPago).toHaveBeenCalledWith('10'))
    expect(desimputarPago).not.toHaveBeenCalled()
  })

  it('un pago suelto (sin boleta) conserva el texto de siempre', async () => {
    const user = await abrirPagos([pago({ pedido_id: null, a_cuenta: true })])

    await user.click(screen.getByRole('button', { name: 'Anular pago' }))
    expect(screen.getByText(/¿Anular este pago de/)).toHaveTextContent(
      /Es un pago a cuenta \/ saldo a favor: se ajustará el saldo del cliente\./,
    )
  })

  it('el crédito suelto de una NC no tiene botón: se anula anulando la NC', async () => {
    await abrirPagos([pago({ forma_pago: 'nota_credito', nota_credito_id: '7', pedido_id: null })])

    expect(screen.queryByRole('button', { name: 'Anular pago' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Quitar de la boleta' })).toBeNull()
  })

  it('si el pago ya estaba fuera de la boleta lo dice', async () => {
    desimputarPago.mockResolvedValue({ yaEstabaSuelto: true, saldoAFavor: 4000 })
    const user = await abrirPagos([pago({ pedido_id: '5501', a_cuenta: true })])

    await user.click(screen.getByRole('button', { name: 'Quitar de la boleta' }))
    await user.click(screen.getByRole('button', { name: 'Sí, quitar' }))

    await waitFor(() => expect(success).toHaveBeenCalledWith('Ese pago ya estaba fuera de la boleta.'))
  })
})
