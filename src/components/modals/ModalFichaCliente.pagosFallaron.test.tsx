/**
 * 1598-b6 / 1544-b6: si no se pudieron cargar los pagos del cliente, la ficha lo dice
 * como error (con «Reintentar») en vez de «No hay pagos registrados», y la pestaña de
 * notas de crédito no calcula el crédito con `pagos = []`.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const { fetchPagosCliente, estadoPagos } = vi.hoisted(() => ({
  fetchPagosCliente: vi.fn(),
  estadoPagos: { errorPagos: false },
}))

vi.mock('../../hooks/supabase', () => ({
  useFichaCliente: () => ({ pedidosCliente: [], estadisticas: null, loading: false, refetch: vi.fn() }),
  usePagos: () => ({
    pagos: [], loading: false,
    errorPagos: estadoPagos.errorPagos,
    fetchPagosCliente,
    obtenerResumenCuenta: vi.fn().mockResolvedValue(null),
    eliminarPago: vi.fn(),
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
// La pestaña de NC, reducida a lo que la ficha le pasa sobre los pagos.
vi.mock('./NotasCreditoVentaCliente', () => ({
  default: (props: { pagosNoDisponibles?: boolean; onImputar?: unknown }) => (
    <p>{`NC pagosNoDisponibles=${String(props.pagosNoDisponibles)} imputar=${props.onImputar ? 'si' : 'no'}`}</p>
  ),
}))

import ModalFichaCliente from './ModalFichaCliente'
import type { ClienteDB } from '../../types'

const CLIENTE = { id: '303', nombre_fantasia: 'MARCOS CHOFER', limite_credito: 0 } as unknown as ClienteDB

beforeEach(() => {
  vi.clearAllMocks()
  estadoPagos.errorPagos = false
})

describe('ModalFichaCliente — los pagos no cargaron', () => {
  it('con los pagos cargados y vacíos dice «No hay pagos registrados»', async () => {
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
    await user.click(await screen.findByRole('button', { name: /Pagos/ }))

    expect(screen.getByText('No hay pagos registrados')).toBeTruthy()
    expect(screen.queryByText('No se pudo cargar.')).toBeNull()
  })

  it('si fallaron, la pestaña Pagos dice que no se pudo cargar, con Reintentar, y no «No hay pagos»', async () => {
    estadoPagos.errorPagos = true
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
    await user.click(await screen.findByRole('button', { name: /Pagos/ }))

    expect(screen.getByText('No se pudo cargar.')).toBeTruthy()
    expect(screen.queryByText('No hay pagos registrados')).toBeNull()

    fetchPagosCliente.mockClear()
    await user.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(fetchPagosCliente).toHaveBeenCalledWith('303')
  })

  it('si fallaron, las notas de crédito lo saben y no ofrecen imputar', async () => {
    estadoPagos.errorPagos = true
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} onRegistrarPago={vi.fn()} />)
    await user.click(await screen.findByRole('button', { name: /Notas de crédito/ }))

    expect(screen.getByText('NC pagosNoDisponibles=true imputar=no')).toBeTruthy()
  })
})
