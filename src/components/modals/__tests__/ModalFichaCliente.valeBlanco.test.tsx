/**
 * Ficha del cliente: historial de pedidos con items.
 *
 * En un vale blanco el precio de la línea es el costo del producto. El
 * preventista (rol sin acceso a costos) abre la ficha de sus clientes, así que
 * ahí también se le oculta el precio por línea de un VB y ve sólo el total.
 * Admin y encargado ven todo. Un ZZ/FC se ve igual para todos.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactElement, ReactNode } from 'react'

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn(), auth: { getUser: vi.fn(), getSession: vi.fn(), onAuthStateChange: vi.fn() } },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(),
}))

const estado = vi.hoisted(() => ({ pedidos: [] as unknown[] }))

vi.mock('../../../hooks/supabase', () => ({
  useFichaCliente: () => ({
    pedidosCliente: estado.pedidos,
    estadisticas: null,
    loading: false,
    refetch: vi.fn(),
  }),
  usePagos: () => ({
    pagos: [],
    loading: false,
    fetchPagosCliente: vi.fn(),
    obtenerResumenCuenta: vi.fn(() => Promise.resolve(null)),
    eliminarPago: vi.fn(),
  }),
}))

import ModalFichaCliente from '../ModalFichaCliente'
import { AuthDataProvider } from '../../../contexts/AuthDataContext'
import { NotificationProvider } from '../../../contexts/NotificationContext'
import type { RolUsuario } from '../../../types'
import { PEDIDOS_FIXTURE } from '../../../../dev/gallery/fixtures/pedidos'
import { CLIENTES_FIXTURE } from '../../../../dev/gallery/fixtures/catalogo'
import { authDataDeRol } from '../../../../dev/gallery/fixtures/auth'

function pedidoFixture(id: string): unknown {
  const ejemplo = PEDIDOS_FIXTURE.find(e => e.pedido.id === id)
  if (!ejemplo) throw new Error(`No hay fixture #${id}`)
  return { ...ejemplo.pedido }
}

async function abrirPedido(pedido: unknown, rol: RolUsuario): Promise<void> {
  estado.pedidos = [pedido]
  const auth = authDataDeRol(rol)
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  function Wrapper({ children }: { children: ReactNode }): ReactElement {
    return (
      <QueryClientProvider client={qc}>
        <NotificationProvider>
          <AuthDataProvider value={auth}>{children}</AuthDataProvider>
        </NotificationProvider>
      </QueryClientProvider>
    )
  }
  render(
    <ModalFichaCliente cliente={CLIENTES_FIXTURE.consumoInterno} onClose={vi.fn()} />,
    { wrapper: Wrapper },
  )
  const user = userEvent.setup()
  await user.click(screen.getByRole('button', { name: /Pedidos/ }))
  await user.click(await screen.findByText(/^#?\d{5}$/))
}

const VB = '18460'
const PENDIENTE = '18420'

describe('ModalFichaCliente — precios por línea de un vale blanco', () => {
  it.each(['admin', 'encargado'] as const)('%s ve precio y subtotal de cada línea de un VB', async (rol) => {
    await abrirPedido(pedidoFixture(VB), rol)
    expect(screen.getByRole('columnheader', { name: 'Precio' })).toBeInTheDocument()
    expect(screen.getByRole('columnheader', { name: 'Subtotal' })).toBeInTheDocument()
    expect(screen.getAllByText(/2\.220/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/26\.640/).length).toBeGreaterThan(0)
  })

  it('el preventista ve las cantidades y el total de un VB, pero no precio ni subtotal por línea', async () => {
    await abrirPedido(pedidoFixture(VB), 'preventista')
    expect(screen.getByRole('columnheader', { name: 'Cant.' })).toBeInTheDocument()
    expect(screen.queryByRole('columnheader', { name: 'Precio' })).not.toBeInTheDocument()
    expect(screen.queryByRole('columnheader', { name: 'Subtotal' })).not.toBeInTheDocument()
    expect(screen.queryByText(/2\.220/)).not.toBeInTheDocument()
    expect(screen.queryByText(/26\.640/)).not.toBeInTheDocument()
    expect(screen.queryByText(/12\.000/)).not.toBeInTheDocument()
    expect(screen.getAllByText(/38\.640/).length).toBeGreaterThan(0)
  })

  it('un ZZ lo ve el preventista con precio y subtotal: la regla es sólo de VB', async () => {
    await abrirPedido(pedidoFixture(PENDIENTE), 'preventista')
    expect(screen.getByRole('columnheader', { name: 'Precio' })).toBeInTheDocument()
    expect(screen.getByRole('columnheader', { name: 'Subtotal' })).toBeInTheDocument()
  })
})
