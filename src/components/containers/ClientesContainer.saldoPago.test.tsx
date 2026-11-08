/**
 * COB-F-6 (#1504): al abrir "Registrar pago" desde la ficha, si el resumen de
 * cuenta falla el modal dice "Saldo no disponible"; no muestra un saldo 0
 * inventado. Con el resumen sano muestra el saldo de siempre.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ClienteDB } from '../../types'

const { CLIENTE, obtenerResumenCuenta } = vi.hoisted(() => ({
  CLIENTE: { id: '4118', nombre_fantasia: 'Almacén Don Ramón', activo: true } as unknown as ClienteDB,
  obtenerResumenCuenta: vi.fn(),
}))

vi.mock('../../hooks/queries', () => ({
  useClientesOperativosQuery: () => ({ data: [CLIENTE], isLoading: false, isError: false, refetch: vi.fn() }),
  useClienteQuery: () => ({ data: undefined }),
  useCrearClienteMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarClienteMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useEliminarClienteMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearPedidoCambioEnRutaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  contarReferenciasDeCliente: vi.fn(),
  verificarDuplicadoCliente: vi.fn(),
  useZonasEstandarizadasQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useClienteAdmiteAdelantoQuery: () => ({ data: undefined }),
}))
vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))
vi.mock('../../hooks/supabase', () => ({
  usePagos: () => ({
    obtenerResumenCuenta,
    registrarPago: vi.fn(),
    registrarPagoFIFO: vi.fn(),
    registrarPagoCombinadoFIFO: vi.fn(),
  }),
}))
vi.mock('../../hooks/supabase/useFichaCliente', () => ({
  useFichaCliente: () => ({ pedidosCliente: [], estadisticas: null, loading: false }),
}))
vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ user: { id: 'u1' }, perfil: { rol: 'admin' }, isAdmin: true, isPreventista: false, isEncargado: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))

vi.mock('../vistas/VistaClientes', () => ({
  default: (props: { onVerFichaCliente: (c: ClienteDB) => void }) => (
    <button type="button" onClick={() => props.onVerFichaCliente(CLIENTE)}>Ver ficha</button>
  ),
}))
// La ficha, reducida al botón que abre "Registrar pago" como lo hace la real.
vi.mock('../modals/ModalFichaCliente', () => ({
  default: (props: { cliente: ClienteDB | null; onRegistrarPago?: (c: ClienteDB) => void }) => (
    <button type="button" onClick={() => props.onRegistrarPago?.(props.cliente ?? CLIENTE)}>Registrar pago</button>
  ),
}))

import ClientesContainer from './ClientesContainer'

async function abrirPago() {
  const user = userEvent.setup()
  render(
    <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
      <ClientesContainer />
    </QueryClientProvider>,
  )
  await user.click(await screen.findByRole('button', { name: 'Ver ficha' }))
  await user.click(await screen.findByRole('button', { name: 'Registrar pago' }))
}

describe('ClientesContainer: saldo del modal de pago (COB-F-6)', () => {
  beforeEach(() => { vi.clearAllMocks() })

  it('con el resumen del server muestra el saldo pendiente', async () => {
    obtenerResumenCuenta.mockResolvedValue({ saldo_actual: 1200 })
    await abrirPago()
    expect(await screen.findByText('Saldo pendiente:')).toBeTruthy()
    expect(screen.queryByText('Saldo no disponible')).toBeNull()
  })

  it.each([
    ['devuelve null', () => obtenerResumenCuenta.mockResolvedValue(null)],
    ['tira', () => obtenerResumenCuenta.mockRejectedValue(new Error('rpc caída'))],
  ])('con el resumen que %s dice "Saldo no disponible"', async (_caso, fallar) => {
    fallar()
    await abrirPago()
    expect(await screen.findByText('Saldo no disponible')).toBeTruthy()
    expect(screen.queryByText('Saldo pendiente:')).toBeNull()
  })
})
