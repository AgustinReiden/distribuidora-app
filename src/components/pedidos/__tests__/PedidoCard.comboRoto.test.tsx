/**
 * PedidoCard con una salvedad que rompió un combo (#1192). Rechazar parte de
 * un combo descuenta lo rechazado (monto_afectado) y suma un recargo aparte:
 * lo que se quedó volvió a su precio sin combo. La tarjeta muestra los dos, y
 * el recargo de una anulada no cuenta (anular deshace salvedad y recargo).
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

function fixtureCon(salvedades: Salvedad[], conLineaRota = false): PedidoDB {
  const ejemplo = PEDIDOS_FIXTURE.find(e => e.pedido.id === '18371')
  if (!ejemplo) throw new Error('No hay fixture #18371')
  const items = conLineaRota
    ? (ejemplo.pedido.items ?? []).map((it, i) => (i === 0 ? { ...it, combo_roto_id: '7' } : it))
    : ejemplo.pedido.items
  return { ...ejemplo.pedido, items, salvedades }
}

const RECHAZO = (estado: string, recargo: number | null): Salvedad => ({
  id: 'sv-soda',
  motivo: 'cliente_rechaza',
  cantidad_afectada: 1,
  monto_afectado: 1_960,
  estado_resolucion: estado,
  producto_id: PRODUCTOS_FIXTURE.sodaSifon.id,
  recargo_combo: recargo,
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

describe('PedidoCard — combo roto (#1192)', () => {
  it('muestra lo rechazado y, aparte, el recargo por combo roto', async () => {
    renderCard(fixtureCon([RECHAZO('pendiente', 2160)]))
    await abrirDetalle()
    expect(screen.getAllByText(/-\$\s?1\.960,00/).length).toBeGreaterThan(0)
    expect(screen.getByText(/\+\$\s?2\.160,00 combo roto/)).toBeInTheDocument()
    expect(screen.getByTestId('recargo-combos-pedido')).toHaveTextContent(/Recargo por combo roto:\s*\+\$\s?2\.160,00/)
  })

  it('el recargo de una salvedad anulada no cuenta', async () => {
    renderCard(fixtureCon([RECHAZO('anulada', 2160)]))
    await abrirDetalle()
    expect(screen.queryByText(/combo roto/)).not.toBeInTheDocument()
    expect(screen.queryByTestId('recargo-combos-pedido')).not.toBeInTheDocument()
  })

  it('una salvedad sin combo no muestra recargo', async () => {
    renderCard(fixtureCon([RECHAZO('pendiente', null)]))
    await abrirDetalle()
    expect(screen.queryByText(/combo roto/)).not.toBeInTheDocument()
    expect(screen.queryByTestId('recargo-combos-pedido')).not.toBeInTheDocument()
  })

  it('la línea que salió de un combo roto dice "Fuera de combo"', async () => {
    renderCard(fixtureCon([RECHAZO('pendiente', 2160)], true))
    await abrirDetalle()
    expect(screen.getAllByText(/^Fuera de combo/).length).toBeGreaterThan(0)
  })
})
