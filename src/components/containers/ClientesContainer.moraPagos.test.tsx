/**
 * H6 de la revisión de B11c (#1544, 1544-b1): cobrar a un cliente desde Clientes (pago simple, FIFO o
 * combinado) baja su deuda, pero los tres handlers invalidaban `pedidos`, `ficha-cliente` y `clientes`
 * y no la lista de deudores en mora: el recorrido natural de cobrar a los morosos uno por uno
 * reabría la lista (antes de 60 s) con el cliente cobrado todavía en mora.
 *
 * El modal de pago se reduce a tres botones que llaman cada confirmación.
 */
import { describe, it, expect, vi, beforeAll, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ClienteDB } from '../../types'

const { CLIENTE, invalidateQueries, pagos } = vi.hoisted(() => ({
  CLIENTE: { id: '4118', nombre_fantasia: 'Almacén Don Ramón', activo: true } as unknown as ClienteDB,
  invalidateQueries: vi.fn(),
  pagos: {
    obtenerResumenCuenta: vi.fn(),
    registrarPago: vi.fn(),
    registrarPagoFIFO: vi.fn(),
    registrarPagoCombinadoFIFO: vi.fn(),
  },
}))

vi.mock('@tanstack/react-query', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@tanstack/react-query')>()),
  useQueryClient: () => ({ invalidateQueries }),
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
  useUsuariosQuery: () => ({ data: [] }),
}))
vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
  useFechasMinimasPorCobrador: () => new Map(),
}))
vi.mock('../../hooks/supabase', () => ({
  usePagos: () => pagos,
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
vi.mock('../modals/ModalFichaCliente', () => ({
  default: (props: { cliente: ClienteDB | null; onRegistrarPago?: (c: ClienteDB) => void }) => (
    <button type="button" onClick={() => props.onRegistrarPago?.(props.cliente ?? CLIENTE)}>Registrar pago</button>
  ),
}))
vi.mock('../modals/ModalRegistrarPago', () => ({
  default: (props: {
    onConfirmar: (d: Record<string, unknown>) => Promise<unknown>
    onConfirmarFIFO: (d: Record<string, unknown>) => Promise<unknown>
    onConfirmarCombinadoFIFO: (d: Record<string, unknown>) => Promise<unknown>
  }) => (
    <>
      <button type="button" onClick={() => { void props.onConfirmar({ clienteId: '4118', pedidoId: '9', monto: 100, formaPago: 'efectivo', referencia: '', notas: '', fecha: '2026-11-10' }) }}>Cobrar simple</button>
      <button type="button" onClick={() => { void props.onConfirmarFIFO({ clienteId: '4118', monto: 100, formaPago: 'efectivo' }) }}>Cobrar FIFO</button>
      <button type="button" onClick={() => { void props.onConfirmarCombinadoFIFO({ clienteId: '4118', metodos: [{ monto: 100, formaPago: 'efectivo' }] }) }}>Cobrar combinado</button>
    </>
  ),
}))

import ClientesContainer from './ClientesContainer'

// Los lazy se importan antes, con su propio margen: los casos miden las invalidaciones, no la carga.
beforeAll(async () => {
  await Promise.all([
    import('../vistas/VistaClientes'),
    import('../modals/ModalFichaCliente'),
    import('../modals/ModalRegistrarPago'),
  ])
}, 120_000)

beforeEach(() => {
  vi.clearAllMocks()
  pagos.obtenerResumenCuenta.mockResolvedValue({ saldo_actual: 1200 })
  pagos.registrarPago.mockResolvedValue({ id: '1' })
  pagos.registrarPagoFIFO.mockResolvedValue({ sobrante: 0 })
  pagos.registrarPagoCombinadoFIFO.mockResolvedValue({ sobrante: 0 })
})

async function cobrar(boton: string) {
  const user = userEvent.setup()
  render(<ClientesContainer />)
  await user.click(await screen.findByRole('button', { name: 'Ver ficha' }))
  await user.click(await screen.findByRole('button', { name: 'Registrar pago' }))
  await user.click(await screen.findByRole('button', { name: boton }))
}

describe('ClientesContainer: cobrar invalida la lista de mora (1544-b1, H6)', () => {
  it.each([
    ['Cobrar simple', () => pagos.registrarPago],
    ['Cobrar FIFO', () => pagos.registrarPagoFIFO],
    ['Cobrar combinado', () => pagos.registrarPagoCombinadoFIFO],
  ])('%s invalida deudores-mora además de clientes y pedidos', async (boton, rpc) => {
    await cobrar(boton)

    await waitFor(() => expect(rpc()).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ['deudores-mora'] }))
    expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ['clientes'] })
    expect(invalidateQueries).toHaveBeenCalledWith({ queryKey: ['pedidos'] })
  })
})
