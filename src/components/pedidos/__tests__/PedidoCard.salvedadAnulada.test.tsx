/**
 * PedidoCard con salvedades anuladas (#1180). Una anulada deshace todo: las
 * unidades vuelven al pedido y el total las incluye, así que la tarjeta no
 * puede decir "Resuelta", ni restar el monto, ni marcar el ítem, ni mostrar
 * "Con Salvedad" si no queda ninguna vigente.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
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
import type { PedidoDB } from '../../../types'
import { PEDIDOS_FIXTURE } from '../../../../dev/gallery/fixtures/pedidos'
import { PRODUCTOS_FIXTURE } from '../../../../dev/gallery/fixtures/catalogo'
import { authDataDeRol } from '../../../../dev/gallery/fixtures/auth'

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

type Salvedad = NonNullable<PedidoDB['salvedades']>[number]

function fixtureCon(salvedades: Salvedad[]): PedidoDB {
  const ejemplo = PEDIDOS_FIXTURE.find(e => e.pedido.id === '18371')
  if (!ejemplo) throw new Error('No hay fixture #18371')
  return { ...ejemplo.pedido, salvedades }
}

const SODA = (estado: string): Salvedad => ({
  id: 'sv-soda',
  motivo: 'producto_danado',
  cantidad_afectada: 2,
  monto_afectado: 1_960,
  estado_resolucion: estado,
  producto_id: PRODUCTOS_FIXTURE.sodaSifon.id,
} as Salvedad)

const AGUA = (estado: string): Salvedad => ({
  id: 'sv-agua',
  motivo: 'producto_danado',
  cantidad_afectada: 2,
  monto_afectado: 2_240,
  estado_resolucion: estado,
  producto_id: PRODUCTOS_FIXTURE.aguaMineral.id,
} as Salvedad)

function renderCard(pedido: PedidoDB): void {
  const auth = authDataDeRol('admin')
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
}

async function abrirDetalle(): Promise<void> {
  await userEvent.setup().click(screen.getByRole('button', { name: 'Ver detalle del pedido' }))
}

describe('PedidoCard — salvedad anulada (#1180)', () => {
  it('sólo una anulada: dice "Anulada", no resta el monto ni marca el ítem', async () => {
    renderCard(fixtureCon([SODA('anulada')]))
    await abrirDetalle()
    expect(screen.getAllByText('Anulada').length).toBeGreaterThan(0)
    expect(screen.queryAllByText('Resuelta')).toHaveLength(0)
    expect(screen.queryAllByText('Pendiente de resolver')).toHaveLength(0)
    expect(screen.queryAllByText(/-\$\s?1\.960,00/)).toHaveLength(0)
    expect(screen.queryAllByText(/Total afectado:/)).toHaveLength(0)
    expect(screen.queryAllByText(/Pedido: 12/)).toHaveLength(0)
  })

  it('sólo una anulada, tarjeta cerrada: no es "Con Salvedad", es "Entregado"', () => {
    renderCard(fixtureCon([SODA('anulada')]))
    expect(screen.queryAllByText('Con Salvedad')).toHaveLength(0)
    expect(screen.getAllByText('Entregado').length).toBeGreaterThan(0)
  })

  it('anulada más pendiente: el total afectado suma sólo la vigente', async () => {
    renderCard(fixtureCon([AGUA('anulada'), SODA('pendiente')]))
    expect(screen.getAllByText('Con Salvedad').length).toBeGreaterThan(0)
    await abrirDetalle()
    expect(screen.getByText('Salvedades (2)')).toBeInTheDocument()
    expect(screen.getAllByText('Anulada').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Pendiente de resolver').length).toBeGreaterThan(0)
    expect(screen.getAllByText(/Total afectado:/).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/-\$\s?1\.960,00/).length).toBeGreaterThan(0)
    expect(screen.queryAllByText(/-\$\s?2\.240,00/)).toHaveLength(0)
    expect(screen.queryAllByText(/-\$\s?4\.200,00/)).toHaveLength(0)
  })

  it('una vigente resuelta sigue diciendo "Resuelta" con su monto', async () => {
    renderCard(fixtureCon([SODA('nota_credito')]))
    await abrirDetalle()
    expect(screen.getAllByText('Resuelta').length).toBeGreaterThan(0)
    expect(screen.getAllByText(/-\$\s?1\.960,00/).length).toBeGreaterThan(0)
  })
})
