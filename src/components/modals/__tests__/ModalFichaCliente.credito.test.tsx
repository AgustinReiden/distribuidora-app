/**
 * Ficha del cliente: días de crédito (#1172).
 *
 * `dias_credito || 30` mostraba "30 días" para un cliente de contado (0).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactElement, ReactNode } from 'react'

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn(), auth: { getUser: vi.fn(), getSession: vi.fn(), onAuthStateChange: vi.fn() } },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(),
}))

vi.mock('../../../hooks/supabase', () => ({
  useFichaCliente: () => ({ pedidosCliente: [], estadisticas: null, loading: false, refetch: vi.fn() }),
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
import type { ClienteDB } from '../../../types'
import { CLIENTES_FIXTURE } from '../../../../dev/gallery/fixtures/catalogo'
import { authDataDeRol } from '../../../../dev/gallery/fixtures/auth'

function abrir(diasCredito: number | null): void {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  function Wrapper({ children }: { children: ReactNode }): ReactElement {
    return (
      <QueryClientProvider client={qc}>
        <NotificationProvider>
          <AuthDataProvider value={authDataDeRol('admin')}>{children}</AuthDataProvider>
        </NotificationProvider>
      </QueryClientProvider>
    )
  }
  const cliente = { ...CLIENTES_FIXTURE.consumoInterno, dias_credito: diasCredito } as unknown as ClienteDB
  render(<ModalFichaCliente cliente={cliente} onClose={vi.fn()} />, { wrapper: Wrapper })
}

describe('ModalFichaCliente — días de crédito (#1172)', () => {
  it('un cliente de contado muestra 0 días, no 30', () => {
    abrir(0)
    expect(screen.getByText('0 días')).toBeInTheDocument()
    expect(screen.queryByText('30 días')).toBeNull()
  })

  it('un cliente con 15 días muestra 15', () => {
    abrir(15)
    expect(screen.getByText('15 días')).toBeInTheDocument()
  })

  it('un null muestra el default 30', () => {
    abrir(null)
    expect(screen.getByText('30 días')).toBeInTheDocument()
  })
})
