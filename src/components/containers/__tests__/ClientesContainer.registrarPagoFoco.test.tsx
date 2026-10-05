/**
 * Ficha Cliente → «Registrar Pago»: al cerrarse la ficha, el foco queda ADENTRO
 * del modal de pago y no en «Ver ficha», detrás de su overlay (#810).
 *
 * EL FLUJO
 * --------
 * `handleAbrirRegistrarPago` (ClientesContainer) hace tres cosas en orden:
 * monta ModalRegistrarPago, espera `obtenerResumenCuenta` y recién ahí cierra
 * la ficha. La ficha es un `ModalBase` (`ui/Dialog`): al desmontarse, FocusScope
 * dispara su `setTimeout(0)` y `devolverFoco` devuelve el foco al que la abrió
 * —«Ver ficha»— SÓLO si quedó perdido en <body>. Con el modal de pago hecho a
 * mano (sin trap ni foco inicial) el foco quedaba en <body> y volvía a «Ver
 * ficha», detrás del overlay de pago: un Enter reabría la ficha encima del pago.
 * Con el pago como diálogo de `ui/Dialog`, su FocusScope mete el foco adentro al
 * montarse y la guarda de `devolverFoco` lo respeta. Contra el modal hecho a
 * mano los tres casos fallan en `expect(verFicha).not.toHaveFocus()`.
 *
 * QUÉ ES REAL Y QUÉ NO
 * --------------------
 * Reales: ClientesContainer (con su `handleAbrirRegistrarPago`), la ficha
 * (ModalFichaCliente → ModalBase → ui/Dialog) y ModalRegistrarPago. La vista de
 * fondo es un botón «Ver ficha» que hace lo mismo que el de la tarjeta. Se
 * mockean los datos (queries, pagos, sesión, avisos) para no tocar Supabase.
 *
 * `obtenerResumenCuenta` se controla a mano en el primer caso para reproducir
 * el orden del issue tal cual: el modal de pago ya montado y la ficha todavía
 * abierta mientras se espera el resumen.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { act, render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ClienteDB, ResumenCuenta } from '../../../types'

const { CLIENTE, RESUMEN, obtenerResumenCuenta } = vi.hoisted(() => {
  const resumen = {
    saldo_actual: 1500,
    limite_credito: 0,
    credito_disponible: 0,
    total_pedidos: 3,
    total_compras: 4500,
    total_pagos: 3000,
    pedidos_pendientes_pago: 1,
    ultimo_pedido: null,
    ultimo_pago: null,
  }
  return {
    CLIENTE: {
      id: '4118',
      nombre_fantasia: 'Almacén Don Ramón',
      razon_social: 'Ramón Ernesto Ledesma',
      activo: true,
    } as unknown as ClienteDB,
    RESUMEN: resumen as ResumenCuenta,
    obtenerResumenCuenta: vi.fn<(clienteId: string) => Promise<ResumenCuenta | null>>(),
  }
})

// Las factories de vi.mock corren antes que las constantes de este módulo: lo
// que usan de acá va envuelto en una flecha, que lo lee recién al renderizar.
const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })

vi.mock('../../../hooks/queries', () => ({
  useClientesQuery: () => ({ data: [CLIENTE], isLoading: false, isError: false, refetch: vi.fn() }),
  useClienteQuery: () => ({ data: CLIENTE }),
  useCrearClienteMutation: () => mutacion(),
  useActualizarClienteMutation: () => mutacion(),
  useEliminarClienteMutation: () => mutacion(),
  useCrearPedidoCambioEnRutaMutation: () => mutacion(),
  contarReferenciasDeCliente: vi.fn(),
  verificarDuplicadoCliente: vi.fn(),
  useZonasEstandarizadasQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
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

// La pestaña de notas de crédito de la ficha no se abre, pero su módulo se
// importa y arrastra el cliente de Supabase, que sin .env no se construye.
vi.mock('../../../hooks/queries/useNotasCreditoVentaQuery', () => ({
  useNotasCreditoVentaClienteQuery: () => ({ data: [], isLoading: false, error: null }),
  useAnularNotaCreditoVentaMutation: () => mutacion(),
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

// La tarjeta del cliente, reducida a su botón «Ver ficha».
vi.mock('../../vistas/VistaClientes', () => ({
  default: ({ onVerFichaCliente }: { onVerFichaCliente?: (c: ClienteDB) => void }) => (
    <button type="button" onClick={() => onVerFichaCliente?.(CLIENTE)}>
      Ver ficha
    </button>
  ),
}))

import ClientesContainer from '../ClientesContainer'

/** FocusScope decide a dónde va el foco en un setTimeout(0) después del desmontaje. */
const dejarCorrerFocusScope = () => act(() => new Promise<void>(resolve => setTimeout(resolve, 0)))

function montar() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <ClientesContainer />
    </QueryClientProvider>,
  )
}

/** Abre la ficha desde «Ver ficha» y espera a que tenga el foco. */
async function abrirFicha(user: ReturnType<typeof userEvent.setup>) {
  const verFicha = await screen.findByRole('button', { name: 'Ver ficha' })
  await user.click(verFicha)
  const ficha = await screen.findByRole('dialog', { name: 'Ficha Cliente' })
  await dejarCorrerFocusScope()
  expect(ficha).toContainElement(document.activeElement as HTMLElement)
  return { verFicha, ficha }
}

/*
 * Mientras la ficha y el pago conviven, uno deja al otro `aria-hidden`, y
 * Testing Library no le calcula el nombre a un diálogo escondido (da "" aunque
 * se pida `hidden: true`): un `queryByRole('dialog', { name })` daría "ya se
 * cerró" con la ficha todavía montada. Por eso, para saber si cada uno está, se
 * mira el texto de su título (un h2, en el modal viejo y en el nuevo).
 */
const tituloFicha = () => screen.queryByText('Ficha Cliente', { selector: 'h2' })
const esperarTituloPago = () => screen.findByText('Registrar Pago', { selector: 'h2' })

/** Click en «Registrar Pago» de la ficha y espera a que el pago monte y la ficha se cierre. */
async function registrarPagoDesdeLaFicha(user: ReturnType<typeof userEvent.setup>, ficha: HTMLElement) {
  await user.click(within(ficha).getByRole('button', { name: 'Registrar Pago' }))
  await esperarTituloPago()
  await waitFor(() => expect(tituloFicha()).toBeNull())
  await dejarCorrerFocusScope()
}

beforeEach(() => {
  obtenerResumenCuenta.mockReset()
  obtenerResumenCuenta.mockResolvedValue(RESUMEN)
})

describe('ClientesContainer · Ficha Cliente → Registrar Pago (#810)', () => {
  it('con la ficha todavía abierta mientras llega el resumen: al cerrarse la ficha el foco queda en el pago', async () => {
    const user = userEvent.setup()
    montar()
    const { verFicha, ficha } = await abrirFicha(user)

    // El resumen del container queda pendiente hasta que el pago se monte.
    let resolverResumen: (r: ResumenCuenta) => void = () => {}
    obtenerResumenCuenta.mockImplementationOnce(
      () => new Promise<ResumenCuenta>(resolve => { resolverResumen = resolve }),
    )
    await user.click(within(ficha).getByRole('button', { name: 'Registrar Pago' }))

    // El modal de pago (chunk lazy) se monta con la ficha todavía abierta.
    await esperarTituloPago()
    expect(tituloFicha()).toBeInTheDocument()

    await act(async () => { resolverResumen(RESUMEN) })
    await waitFor(() => expect(tituloFicha()).toBeNull())
    await dejarCorrerFocusScope()

    // El bug: el foco volvía a «Ver ficha», detrás del overlay de pago.
    expect(verFicha).not.toHaveFocus()
    const pago = screen.getByRole('dialog', { name: 'Registrar Pago' })
    expect(pago).toContainElement(document.activeElement as HTMLElement)
    // Y el pago abrió con el saldo del resumen.
    const saldo = within(pago).getByText('Saldo pendiente:').parentElement as HTMLElement
    expect(saldo).toHaveTextContent('1.500')
  })

  it('con el resumen al instante (la ficha se cierra enseguida): el foco también queda en el pago', async () => {
    const user = userEvent.setup()
    montar()
    const { verFicha, ficha } = await abrirFicha(user)

    await registrarPagoDesdeLaFicha(user, ficha)

    expect(verFicha).not.toHaveFocus()
    expect(screen.getByRole('dialog', { name: 'Registrar Pago' }))
      .toContainElement(document.activeElement as HTMLElement)
  })

  it('después de cerrarse la ficha, Tab no sale del modal de pago hacia «Ver ficha»', async () => {
    const user = userEvent.setup()
    montar()
    const { verFicha, ficha } = await abrirFicha(user)

    await registrarPagoDesdeLaFicha(user, ficha)

    expect(verFicha).not.toHaveFocus()
    const pago = screen.getByRole('dialog', { name: 'Registrar Pago' })
    for (let i = 0; i < 25; i++) {
      await user.tab()
      expect(verFicha).not.toHaveFocus()
      expect(pago).toContainElement(document.activeElement as HTMLElement)
    }
  })
})
