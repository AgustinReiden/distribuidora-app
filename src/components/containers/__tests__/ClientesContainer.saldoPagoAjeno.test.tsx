/**
 * FRV-3 (#1598): «Registrar pago» desde la ficha abría el modal antes de que
 * llegara `obtenerResumenCuenta`, con el `saldoPendientePago` del estado: el del
 * cliente anterior. Mientras el resumen del cliente nuevo no llegó, el modal tiene
 * que decir que está cargando (sin saldo, sin «Total»), y una respuesta que llega
 * con el modal ya cerrado no tiene que abrirle nada a nadie.
 *
 * Mismo montaje que `ClientesContainer.registrarPagoFoco.test.tsx`: reales el
 * container, la ficha y el modal de pago; los datos, mockeados.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeAll, beforeEach } from 'vitest'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ClienteDB, ResumenCuenta } from '../../../types'

const { CLIENTE, resumenDe, obtenerResumenCuenta } = vi.hoisted(() => {
  const resumenDe = (saldo: number) => ({
    saldo_actual: saldo,
    limite_credito: 0,
    credito_disponible: 0,
    total_pedidos: 3,
    total_compras: 4500,
    total_pagos: 3000,
    pedidos_pendientes_pago: 1,
    ultimo_pedido: null,
    ultimo_pago: null,
  }) as ResumenCuenta
  return {
    CLIENTE: {
      id: '4118',
      nombre_fantasia: 'Almacén Don Ramón',
      razon_social: 'Ramón Ernesto Ledesma',
      activo: true,
    } as unknown as ClienteDB,
    resumenDe,
    obtenerResumenCuenta: vi.fn<(clienteId: string) => Promise<ResumenCuenta | null>>(),
  }
})

const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })

vi.mock('../../../hooks/queries', () => ({
  useClientesQuery: () => ({ data: [CLIENTE], isLoading: false, isError: false, refetch: vi.fn() }),
  useClientesOperativosQuery: () => ({ data: [CLIENTE], isLoading: false, isError: false, refetch: vi.fn() }),
  useClienteQuery: () => ({ data: CLIENTE }),
  useCrearClienteMutation: () => mutacion(),
  useActualizarClienteMutation: () => mutacion(),
  useEliminarClienteMutation: () => mutacion(),
  useCrearPedidoCambioEnRutaMutation: () => mutacion(),
  contarReferenciasDeCliente: vi.fn(),
  verificarDuplicadoCliente: vi.fn(),
  useZonasEstandarizadasQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useClienteAdmiteAdelantoQuery: () => ({ data: undefined }),
  useUsuariosQuery: () => ({ data: [] }),
}))

const usePagosMock = () => ({
  pagos: [],
  loading: false,
  fetchPagosCliente: vi.fn(),
  obtenerResumenCuenta,
  eliminarPago: vi.fn(),
  registrarPago: vi.fn(),
  registrarPagoFIFO: vi.fn(),
  registrarPagoCombinadoFIFO: vi.fn(),
})
const useFichaClienteMock = () => ({ pedidosCliente: [], estadisticas: null, loading: false })

vi.mock('../../../hooks/supabase', () => ({
  usePagos: () => usePagosMock(),
  useFichaCliente: () => useFichaClienteMock(),
}))
vi.mock('../../../hooks/supabase/useFichaCliente', () => ({
  useFichaCliente: () => useFichaClienteMock(),
}))
vi.mock('../../../hooks/queries/useNotasCreditoVentaQuery', () => ({
  useNotasCreditoVentaClienteQuery: () => ({ data: [], isLoading: false, error: null }),
  useAnularNotaCreditoVentaMutation: () => mutacion(),
}))
vi.mock('../../../hooks/queries/useCambiosProductosQuery', () => ({
  useCambiosProductosClienteQuery: () => ({ data: [], isLoading: false, error: null }),
}))
vi.mock('../../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))
vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    user: { id: 'u1' },
    perfil: { rol: 'admin' },
    isAdmin: true,
    isPreventista: false,
    isEncargado: false,
  }),
}))
vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))
vi.mock('../../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: () => undefined,
}))
vi.mock('../../vistas/VistaClientes', () => ({
  default: ({ onVerFichaCliente }: { onVerFichaCliente?: (c: ClienteDB) => void }) => (
    <button type="button" onClick={() => onVerFichaCliente?.(CLIENTE)}>
      Ver ficha
    </button>
  ),
}))

import ClientesContainer from '../ClientesContainer'

const dejarCorrerFocusScope = () => act(() => new Promise<void>(resolve => setTimeout(resolve, 0)))

function montar() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <ClientesContainer />
    </QueryClientProvider>,
  )
}

async function abrirFicha(user: ReturnType<typeof userEvent.setup>) {
  await user.click(await screen.findByRole('button', { name: 'Ver ficha' }))
  const ficha = await screen.findByRole('dialog', { name: 'Ficha Cliente' })
  await dejarCorrerFocusScope()
  return ficha
}

const tituloFicha = () => screen.queryByText('Ficha Cliente', { selector: 'h2' })
const esperarTituloPago = () => screen.findByText('Registrar Pago', { selector: 'h2' })

/** Abre el pago desde la ficha con un resumen que se resuelve cuando el test quiere. */
async function abrirPagoConResumenPendiente(user: ReturnType<typeof userEvent.setup>) {
  const ficha = await abrirFicha(user)
  let resolver: (r: ResumenCuenta | null) => void = () => {}
  obtenerResumenCuenta.mockImplementationOnce(
    () => new Promise<ResumenCuenta | null>(resolve => { resolver = resolve }),
  )
  await user.click(within(ficha).getByRole('button', { name: 'Registrar Pago' }))
  await esperarTituloPago()
  return { resolver: (r: ResumenCuenta | null) => act(async () => { resolver(r) }) }
}

/** Primer cliente: abre el pago con su saldo y lo cierra, dejando el saldo viejo en el estado. */
async function abrirYCerrarPagoConSaldo(user: ReturnType<typeof userEvent.setup>, saldo: number) {
  const { resolver } = await abrirPagoConResumenPendiente(user)
  await resolver(resumenDe(saldo))
  await waitFor(() => expect(tituloFicha()).toBeNull())
  await dejarCorrerFocusScope()
  const pago = screen.getByRole('dialog', { name: 'Registrar Pago' })
  expect(within(pago).getByText('Saldo pendiente:').parentElement).toHaveTextContent('1.500')
  await user.click(within(pago).getByRole('button', { name: 'Cerrar' }))
  await waitFor(() => expect(screen.queryByText('Registrar Pago', { selector: 'h2' })).toBeNull())
  await dejarCorrerFocusScope()
}

beforeAll(async () => {
  await Promise.all([
    import('../../modals/ModalFichaCliente'),
    import('../../modals/ModalRegistrarPago'),
  ])
}, 30_000)

beforeEach(() => {
  obtenerResumenCuenta.mockReset()
  obtenerResumenCuenta.mockResolvedValue(resumenDe(1500))
})

describe('ClientesContainer · Registrar Pago con el resumen todavía sin llegar (FRV-3)', () => {
  it('no muestra el saldo del cliente anterior ni deja usar «Total» mientras carga', async () => {
    const user = userEvent.setup()
    montar()
    await abrirYCerrarPagoConSaldo(user, 1500)

    const { resolver } = await abrirPagoConResumenPendiente(user)
    const pago = screen.getByRole('dialog', { name: 'Registrar Pago' })

    expect(within(pago).getByText(/cargando saldo/i)).toBeInTheDocument()
    expect(within(pago).queryByText('Saldo pendiente:')).toBeNull()
    expect(pago).not.toHaveTextContent('1.500')
    expect(within(pago).queryByRole('button', { name: 'Total' })).toBeNull()

    // Llega el resumen del cliente nuevo: ahora sí hay saldo y «Total».
    await resolver(resumenDe(700))
    await waitFor(() => expect(within(pago).queryByText(/cargando saldo/i)).toBeNull())
    expect(within(pago).getByText('Saldo pendiente:').parentElement).toHaveTextContent('700')
    expect(within(pago).getByRole('button', { name: 'Total' })).toBeInTheDocument()
  })

  it('si el resumen falla, dice «Saldo no disponible» y no queda cargando', async () => {
    const user = userEvent.setup()
    montar()
    await abrirYCerrarPagoConSaldo(user, 1500)

    const { resolver } = await abrirPagoConResumenPendiente(user)
    const pago = screen.getByRole('dialog', { name: 'Registrar Pago' })
    await resolver(null)

    await waitFor(() => expect(within(pago).queryByText(/cargando saldo/i)).toBeNull())
    expect(within(pago).getByText('Saldo no disponible')).toBeInTheDocument()
    expect(within(pago).queryByText('Saldo pendiente:')).toBeNull()
  })

  it('una respuesta que llega con el modal ya cerrado no cierra la ficha ni pisa el estado', async () => {
    const user = userEvent.setup()
    montar()

    const { resolver } = await abrirPagoConResumenPendiente(user)
    const pago = screen.getByRole('dialog', { name: 'Registrar Pago' })
    await user.click(within(pago).getByRole('button', { name: 'Cerrar' }))
    await waitFor(() => expect(screen.queryByText('Registrar Pago', { selector: 'h2' })).toBeNull())

    await resolver(resumenDe(999))
    await dejarCorrerFocusScope()
    // La ficha sigue abierta: la respuesta tardía no le cerró nada.
    expect(tituloFicha()).toBeInTheDocument()
    expect(screen.queryByText('Registrar Pago', { selector: 'h2' })).toBeNull()
  })
})
