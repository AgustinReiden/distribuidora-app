/**
 * PedidoCard con vale blanco (VB: consumo interno, a costo, nace entregado y
 * saldado por naturaleza).
 *
 *  - El badge "VB · consumo interno" se ve siempre, para todos los roles.
 *  - El estado de pago es "Consumo interno": nunca "Pagado"/"Pendiente" ni
 *    "Pagado: X de Y", y el detalle no muestra forma de pago.
 *  - El badge del comprobante ya no es un flip binario: ofrece los destinos que
 *    N10 permite para el rol y el estado (`destinosTipoFactura`).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactElement, ReactNode } from 'react'

vi.mock('../../../lib/supabase', () => ({
  supabase: {
    rpc: vi.fn(),
    from: vi.fn(),
    auth: {
      getUser: vi.fn(() => Promise.resolve({ data: { user: null } })),
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(),
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1, currentSucursalNombre: 'Test' }),
}))

vi.mock('../../../lib/pdfExport', () => ({
  generarReciboPedido: vi.fn(),
}))

import PedidoCard from '../PedidoCard'
import { AuthDataProvider } from '../../../contexts/AuthDataContext'
import { NotificationProvider } from '../../../contexts/NotificationContext'
import { supabase } from '../../../lib/supabase'
import type { PedidoDB, RolUsuario } from '../../../types'
import { PEDIDOS_FIXTURE } from '../../../../dev/gallery/fixtures/pedidos'
import { CLIENTES_FIXTURE } from '../../../../dev/gallery/fixtures/catalogo'
import { authDataDeRol, ROLES_GALERIA } from '../../../../dev/gallery/fixtures/auth'

class ObservadorStub {
  observe(): void { /* no-op */ }
  unobserve(): void { /* no-op */ }
  disconnect(): void { /* no-op */ }
  takeRecords(): [] { return [] }
}
globalThis.IntersectionObserver = ObservadorStub as unknown as typeof IntersectionObserver
if (!Element.prototype.hasPointerCapture) Element.prototype.hasPointerCapture = (): boolean => false
if (!Element.prototype.setPointerCapture) Element.prototype.setPointerCapture = (): void => undefined
if (!Element.prototype.releasePointerCapture) Element.prototype.releasePointerCapture = (): void => undefined
if (!Element.prototype.scrollIntoView) Element.prototype.scrollIntoView = (): void => undefined

const VB = '18460'
const PENDIENTE = '18420'

function fixture(id: string): PedidoDB {
  const ejemplo = PEDIDOS_FIXTURE.find(e => e.pedido.id === id)
  if (!ejemplo) throw new Error(`No hay fixture #${id}`)
  return { ...ejemplo.pedido }
}

/** Un ZZ pendiente de un cliente habilitado para vale blanco. */
function zzDeClienteVB(over: Partial<PedidoDB> = {}): PedidoDB {
  return {
    ...fixture(PENDIENTE),
    cliente_id: CLIENTES_FIXTURE.consumoInterno.id,
    cliente: CLIENTES_FIXTURE.consumoInterno,
    ...over,
  }
}

function renderCard(pedido: PedidoDB, rol: RolUsuario): { qc: QueryClient } {
  const auth = authDataDeRol(rol)
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
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
    <PedidoCard
      pedido={pedido}
      isAdmin={auth.isAdmin}
      isPreventista={auth.isPreventista}
      isTransportista={auth.isTransportista}
      isEncargado={auth.isEncargado}
      onVerHistorial={vi.fn()}
      onEditarPedido={vi.fn()}
      onEditarNotas={vi.fn()}
      onCancelarPedido={vi.fn()}
      onRegistrarPago={vi.fn()}
      onDesmarcarEntregado={vi.fn()}
    />,
    { wrapper: Wrapper },
  )
  return { qc }
}

beforeEach(() => {
  vi.mocked(supabase.rpc).mockReset()
})

describe('PedidoCard — vale blanco: lo que se ve', () => {
  it.each(ROLES_GALERIA)('%s: "Consumo interno" y el badge VB; nunca "Pagado"', (rol) => {
    renderCard(fixture(VB), rol)
    expect(screen.getAllByText('Consumo interno').length).toBeGreaterThan(0)
    expect(screen.getAllByText('VB · consumo interno').length).toBeGreaterThan(0)
    expect(screen.queryByText('Pagado')).not.toBeInTheDocument()
    expect(screen.queryByText(/Pago Pendiente/)).not.toBeInTheDocument()
  })

  it('el detalle dice el comprobante, no una forma de pago', async () => {
    renderCard(fixture(VB), 'admin')
    await userEvent.setup().click(screen.getByRole('button', { name: 'Ver detalle del pedido' }))
    expect(screen.getByText('Comprobante')).toBeInTheDocument()
    expect(screen.getByText('Vale blanco — consumo interno')).toBeInTheDocument()
    expect(screen.queryByText('Forma de pago')).not.toBeInTheDocument()
  })

  it('sin acción principal "Registrar Pago" y sin pagos/revertir en el menú', async () => {
    renderCard(fixture(VB), 'admin')
    expect(screen.queryByRole('button', { name: 'Registrar Pago' })).not.toBeInTheDocument()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Mas acciones' }))
    const menu = await screen.findByRole('menu')
    const opciones = within(menu).queryAllByRole('menuitem').map(i => (i.textContent ?? '').trim())
    expect(opciones).toContain('Cancelar Pedido')
    expect(opciones).not.toContain('Ver/Editar Pagos')
    expect(opciones).not.toContain('Revertir Entrega')
    expect(opciones).not.toContain('Editar')
  })
})

describe('PedidoCard — menú de conversión de comprobante (N10)', () => {
  it('admin sobre un VB: el badge abre los destinos ZZ y FC; elegir FC arma la confirmación y el segundo clic llama a la RPC', async () => {
    vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: true }, error: null } as never)
    renderCard(fixture(VB), 'admin')
    const user = userEvent.setup()

    await user.click(screen.getByRole('button', { name: 'VB · consumo interno' }))
    expect(screen.getByRole('button', { name: '→ ZZ' })).toBeEnabled()
    await user.click(screen.getByRole('button', { name: '→ FC' }))
    expect(supabase.rpc).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: '→ FC?' }))
    await waitFor(() => {
      expect(supabase.rpc).toHaveBeenCalledWith(
        'cambiar_tipo_factura_pedido',
        expect.objectContaining({ p_pedido_id: VB, p_tipo: 'FC' }),
      )
    })
    // El aviso dice que queda pendiente de cobro y fuera de toda rendición.
    expect(await screen.findByText(/pendiente de cobro/)).toBeInTheDocument()
  })

  it.each(['encargado', 'preventista', 'transportista', 'deposito'] as const)(
    '%s sobre un VB: badge de sólo lectura',
    (rol) => {
      renderCard(fixture(VB), rol)
      expect(screen.queryByRole('button', { name: 'VB · consumo interno' })).not.toBeInTheDocument()
      expect(screen.getByText('VB · consumo interno')).toBeInTheDocument()
    },
  )

  it('admin sobre un ZZ de cliente habilitado: el badge abre FC y VB, y pasar a VB llama a la RPC con VB', async () => {
    vi.mocked(supabase.rpc).mockResolvedValue({ data: { success: true }, error: null } as never)
    renderCard(zzDeClienteVB(), 'admin')
    const user = userEvent.setup()

    await user.click(screen.getByRole('button', { name: 'ZZ' }))
    expect(screen.getByRole('button', { name: '→ FC' })).toBeEnabled()
    await user.click(screen.getByRole('button', { name: '→ VB' }))
    await user.click(screen.getByRole('button', { name: '→ VB?' }))
    await waitFor(() => {
      expect(supabase.rpc).toHaveBeenCalledWith(
        'cambiar_tipo_factura_pedido',
        expect.objectContaining({ p_tipo: 'VB' }),
      )
    })
  })

  it('un ZZ con pagos de cliente habilitado: VB aparece deshabilitado con el motivo', async () => {
    renderCard(zzDeClienteVB({ monto_pagado: 500, estado_pago: 'parcial' }), 'admin')
    await userEvent.setup().click(screen.getByRole('button', { name: 'ZZ' }))
    const vb = screen.getByRole('button', { name: '→ VB' })
    expect(vb).toBeDisabled()
    expect(vb).toHaveAttribute('title', expect.stringMatching(/pagos/))
  })

  it('un ZZ de cliente NO habilitado sigue con el flip de un clic de siempre', async () => {
    renderCard(fixture(PENDIENTE), 'admin')
    await userEvent.setup().click(screen.getByRole('button', { name: 'ZZ' }))
    expect(screen.getByRole('button', { name: '→ FC?' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '→ VB' })).not.toBeInTheDocument()
  })

  it('si la RPC rechaza la conversión, avisa el motivo', async () => {
    vi.mocked(supabase.rpc).mockResolvedValue({
      data: { success: false, error: 'Tiene una nota de crédito vigente' },
      error: null,
    } as never)
    renderCard(zzDeClienteVB(), 'admin')
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'ZZ' }))
    await user.click(screen.getByRole('button', { name: '→ VB' }))
    await user.click(screen.getByRole('button', { name: '→ VB?' }))
    expect(
      await screen.findByText('No se pudo cambiar el tipo de factura: Tiene una nota de crédito vigente'),
    ).toBeInTheDocument()
  })
})
