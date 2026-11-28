/**
 * La respuesta TARDÍA de otro cliente no pisa el «Registrar pago» del cliente de ahora (#1598-b11).
 *
 * `handleAbrirRegistrarPago` pide el resumen de cuenta (`obtenerResumenCuenta`) con el modal ya
 * abierto, y cada pedido lleva un número de intento: una respuesta que vuelve con el modal cerrado
 * o reabierto para otro cliente no se aplica (`intentoPagoRef`). `ClientesContainer.saldoPagoAjeno`
 * cubre «el resumen todavía sin llegar» y «llegó con el modal ya cerrado»; lo que faltaba es el
 * cruce de DOS clientes: el pago de A queda en vuelo, se cierra, se abre el de B, y la respuesta
 * de A llega DESPUÉS de la de B. Si se aplicara, B vería el saldo de A, y «Total» cobraría de más
 * (o de menos) a B por el FIFO de su propia cuenta.
 *
 * Mismo montaje que `ClientesContainer.saldoPagoAjeno.test.tsx`: reales el container, la ficha y
 * el modal de pago; los datos, mockeados. Los clientes son inventados.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeAll, beforeEach } from 'vitest'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ClienteDB, ResumenCuenta } from '../../../types'

const { CLIENTE_A, CLIENTE_B, resumenDe, obtenerResumenCuenta } = vi.hoisted(() => {
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
    CLIENTE_A: { id: '4118', nombre_fantasia: 'Almacén Don Ramón', razon_social: 'Ramón Ledesma', activo: true } as unknown as ClienteDB,
    CLIENTE_B: { id: '4119', nombre_fantasia: 'Kiosco La Esquina', razon_social: 'Marta Suárez', activo: true } as unknown as ClienteDB,
    resumenDe,
    obtenerResumenCuenta: vi.fn<(clienteId: string) => Promise<ResumenCuenta | null>>(),
  }
})

const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
const porId = (id: string) => (id === CLIENTE_B.id ? CLIENTE_B : CLIENTE_A)

vi.mock('../../../hooks/queries', () => ({
  useClientesQuery: () => ({ data: [CLIENTE_A, CLIENTE_B], isLoading: false, isError: false, refetch: vi.fn() }),
  useClientesOperativosQuery: () => ({ data: [CLIENTE_A, CLIENTE_B], isLoading: false, isError: false, refetch: vi.fn() }),
  useClienteQuery: (id: string) => ({ data: porId(id) }),
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
  useFechasMinimasPorCobrador: () => new Map(),
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
    <>
      <button type="button" onClick={() => onVerFichaCliente?.(CLIENTE_A)}>Ver ficha A</button>
      <button type="button" onClick={() => onVerFichaCliente?.(CLIENTE_B)}>Ver ficha B</button>
    </>
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

/** Un resumen que se resuelve cuando el test quiere. */
function resumenPendiente() {
  let resolver: (r: ResumenCuenta | null) => void = () => {}
  const promesa = new Promise<ResumenCuenta | null>(resolve => { resolver = resolve })
  return { promesa, resolver: (r: ResumenCuenta | null) => act(async () => { resolver(r) }) }
}

async function abrirFicha(user: ReturnType<typeof userEvent.setup>, quien: 'A' | 'B') {
  await user.click(await screen.findByRole('button', { name: `Ver ficha ${quien}` }))
  const ficha = await screen.findByRole('dialog', { name: 'Ficha Cliente' })
  await dejarCorrerFocusScope()
  return ficha
}

const tituloPago = () => screen.queryByText('Registrar Pago', { selector: 'h2' })
const tituloFicha = () => screen.queryByText('Ficha Cliente', { selector: 'h2' })

// Los modales son lazy: el import en frío se come el segundo por defecto de `findBy*` y de `waitFor`.
beforeAll(async () => {
  await Promise.all([
    import('../../modals/ModalFichaCliente'),
    import('../../modals/ModalRegistrarPago'),
  ])
}, 120_000)

beforeEach(() => {
  obtenerResumenCuenta.mockReset()
})

describe('ClientesContainer · la respuesta tardía de otro cliente en «Registrar pago» (#1598-b11)', () => {
  it('el resumen de A llega DESPUÉS de abrir el pago de B: B conserva su saldo y no se cierra nada de más', async () => {
    const user = userEvent.setup()
    const deA = resumenPendiente()
    obtenerResumenCuenta.mockImplementation((id: string) => (id === CLIENTE_A.id ? deA.promesa : Promise.resolve(resumenDe(700))))
    montar()

    // El pago de A queda en vuelo (su resumen no llega) y se cierra.
    const fichaA = await abrirFicha(user, 'A')
    await user.click(within(fichaA).getByRole('button', { name: 'Registrar Pago' }))
    const pagoA = await screen.findByRole('dialog', { name: 'Registrar Pago' })
    expect(within(pagoA).getByText(/cargando saldo/i)).toBeInTheDocument()
    await user.click(within(pagoA).getByRole('button', { name: 'Cerrar' }))
    await waitFor(() => expect(tituloPago()).toBeNull())

    // Se cierra la ficha de A y se abre el pago de B, cuyo resumen llega enseguida.
    await user.keyboard('{Escape}')
    await waitFor(() => expect(tituloFicha()).toBeNull())
    const fichaB = await abrirFicha(user, 'B')
    await user.click(within(fichaB).getByRole('button', { name: 'Registrar Pago' }))
    const pagoB = await screen.findByRole('dialog', { name: 'Registrar Pago' })
    await waitFor(() => expect(within(pagoB).getByText('Saldo pendiente:').parentElement).toHaveTextContent('700'))
    expect(obtenerResumenCuenta).toHaveBeenCalledWith(CLIENTE_A.id)
    expect(obtenerResumenCuenta).toHaveBeenCalledWith(CLIENTE_B.id)

    // Recién ahora llega la respuesta vieja, la de A, con otro saldo.
    await deA.resolver(resumenDe(999))
    await dejarCorrerFocusScope()

    // El pago es el de B: con SU saldo, no el de A, y sigue abierto.
    const pagoDespues = screen.getByRole('dialog', { name: 'Registrar Pago' })
    expect(within(pagoDespues).getByText('Saldo pendiente:').parentElement).toHaveTextContent('700')
    expect(pagoDespues).not.toHaveTextContent('999')
    expect(pagoDespues).toHaveTextContent('Kiosco La Esquina')
    expect(pagoDespues).not.toHaveTextContent('Almacén Don Ramón')
  })

  it('el resumen de A que falla tarde tampoco marca «Saldo no disponible» en el pago de B', async () => {
    const user = userEvent.setup()
    const deA = resumenPendiente()
    obtenerResumenCuenta.mockImplementation((id: string) => (id === CLIENTE_A.id ? deA.promesa : Promise.resolve(resumenDe(700))))
    montar()

    const fichaA = await abrirFicha(user, 'A')
    await user.click(within(fichaA).getByRole('button', { name: 'Registrar Pago' }))
    const pagoA = await screen.findByRole('dialog', { name: 'Registrar Pago' })
    await user.click(within(pagoA).getByRole('button', { name: 'Cerrar' }))
    await waitFor(() => expect(tituloPago()).toBeNull())
    await user.keyboard('{Escape}')
    await waitFor(() => expect(tituloFicha()).toBeNull())

    const fichaB = await abrirFicha(user, 'B')
    await user.click(within(fichaB).getByRole('button', { name: 'Registrar Pago' }))
    const pagoB = await screen.findByRole('dialog', { name: 'Registrar Pago' })
    await waitFor(() => expect(within(pagoB).getByText('Saldo pendiente:').parentElement).toHaveTextContent('700'))

    // La consulta de A termina sin resumen (null: la red se cayó).
    await deA.resolver(null)
    await dejarCorrerFocusScope()

    const pagoDespues = screen.getByRole('dialog', { name: 'Registrar Pago' })
    expect(within(pagoDespues).queryByText('Saldo no disponible')).toBeNull()
    expect(within(pagoDespues).getByText('Saldo pendiente:').parentElement).toHaveTextContent('700')
  })
})
