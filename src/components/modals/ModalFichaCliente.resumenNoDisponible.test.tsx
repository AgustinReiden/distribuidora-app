/**
 * COB-F-6 (#1476): si la RPC del resumen de cuenta falla, la ficha muestra
 * "Saldo no disponible", no un "$0 · Sin deuda" ni un saldo recalculado.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const { obtenerResumenCuenta } = vi.hoisted(() => ({ obtenerResumenCuenta: vi.fn() }))

vi.mock('../../hooks/supabase', () => ({
  useFichaCliente: () => ({ pedidosCliente: [], estadisticas: null, loading: false, refetch: vi.fn() }),
  usePagos: () => ({
    pagos: [], loading: false,
    fetchPagosCliente: vi.fn().mockResolvedValue([]),
    obtenerResumenCuenta,
    eliminarPago: vi.fn(),
  }),
}))
// Los sub-paneles de la ficha importan el cliente de Supabase; acá no se usa.
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

// La pestaña de notas de crédito, reducida al botón que dispara su `onCambio`
// (imputar o anular una NC).
vi.mock('./NotasCreditoVentaCliente', () => ({
  default: (props: { onCambio?: () => void }) => (
    <button type="button" onClick={() => props.onCambio?.()}>Simular cambio de NC</button>
  ),
}))

import ModalFichaCliente from './ModalFichaCliente'
import type { ClienteDB } from '../../types'

const CLIENTE = {
  id: '303', nombre_fantasia: 'MARCOS CHOFER', limite_credito: 50000,
} as unknown as ClienteDB

const RESUMEN = {
  saldo_actual: 1200, limite_credito: 50000, credito_disponible: 48800, total_pedidos: 3,
  total_compras: 5000, total_pagos: 3800, pedidos_pendientes_pago: 1, ultimo_pedido: null, ultimo_pago: null,
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('ModalFichaCliente — resumen de cuenta (COB-F-6)', () => {
  it('con el resumen del server muestra el saldo', async () => {
    obtenerResumenCuenta.mockResolvedValue(RESUMEN)
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    expect(await screen.findByText('Debe')).toBeTruthy()
    expect(screen.queryByText('Saldo no disponible')).toBeNull()
  })

  it('si la RPC falla (null) muestra "Saldo no disponible" y no "Sin deuda"', async () => {
    obtenerResumenCuenta.mockResolvedValue(null)
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    expect(await screen.findByText('Saldo no disponible')).toBeTruthy()
    expect(screen.queryByText('Sin deuda')).toBeNull()
    expect(screen.queryByText(/Disponible:/)).toBeNull()
  })

  it.each([
    ['devuelve null', () => obtenerResumenCuenta.mockResolvedValueOnce(null)],
    ['tira', () => obtenerResumenCuenta.mockRejectedValueOnce(new Error('rpc caída'))],
  ])('imputar o anular una NC con el resumen que %s deja "Saldo no disponible", no "Sin deuda"', async (_caso, fallar) => {
    obtenerResumenCuenta.mockResolvedValue(RESUMEN)
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} onRegistrarPago={vi.fn()} />)
    expect(await screen.findByText('Debe')).toBeTruthy()

    await user.click(screen.getByRole('button', { name: /Notas de crédito/ }))
    fallar()
    await user.click(await screen.findByRole('button', { name: 'Simular cambio de NC' }))
    await user.click(screen.getByRole('button', { name: /Resumen/ }))

    expect(await screen.findByText('Saldo no disponible')).toBeTruthy()
    expect(screen.queryByText('Sin deuda')).toBeNull()
    expect(screen.queryByText('Debe')).toBeNull()
  })
})
