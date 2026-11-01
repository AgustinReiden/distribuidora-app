/**
 * #1273: el panel de pendientes mostraba un vale blanco encolado como $0.
 *
 * `OfflineIndicator` ya sabía pintar "Vale blanco (a costo al sincronizar)"
 * cuando recibe `tipoFactura: 'VB'` (lo cubre su propio test), pero
 * `PendingSyncRuntime` arma las props campo por campo y nunca pasaba
 * `tipoFactura`: en la app real la condición no se cumplía jamás. Por eso este
 * test no le da las props al panel directo: pasa por `PendingSyncRuntime` con
 * un `PedidoOffline` como lo arma `useOfflineSync`.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ReactNode } from 'react'

// App.tsx importa a mano toda la app. Sólo se prueba el mapeo del panel: lo de
// afuera se corta acá para no cargar los contenedores ni el cliente de Supabase.
vi.mock('./hooks/supabase', () => ({
  AuthProvider: ({ children }: { children: ReactNode }) => children,
  setErrorNotifier: vi.fn(),
  useAuth: vi.fn(),
  useProductos: () => ({ productos: [], refetch: vi.fn() }),
}))
vi.mock('./hooks/queries', () => ({ useInvalidateMetricas: () => vi.fn() }))
vi.mock('./hooks/queries/usePedidosQuery', () => ({
  useCrearPedidoMutation: () => ({ mutateAsync: vi.fn() }),
  useInvalidatePedidos: () => vi.fn(),
}))
vi.mock('./hooks/useSyncManager', () => ({
  useSyncManager: () => ({ handleSincronizar: vi.fn() }),
}))
vi.mock('./hooks/useOfflineSync', () => ({ useOfflineSync: vi.fn() }))
vi.mock('./hooks/useRealtimeInvalidation', () => ({ useRealtimeInvalidation: vi.fn() }))
vi.mock('./contexts/NotificationContext', () => ({
  NotificationProvider: ({ children }: { children: ReactNode }) => children,
  useNotification: () => ({ error: vi.fn(), warning: vi.fn(), success: vi.fn(), info: vi.fn() }),
}))
vi.mock('./contexts/SucursalContext', () => ({
  SucursalProvider: ({ children }: { children: ReactNode }) => children,
  useSucursal: vi.fn(),
}))
vi.mock('./contexts/AuthDataContext', () => ({ AuthDataProvider: ({ children }: { children: ReactNode }) => children }))
vi.mock('./contexts/ThemeContext', () => ({ ThemeProvider: ({ children }: { children: ReactNode }) => children }))
vi.mock('./utils/authPerformance', () => ({ trackFirstAuthenticatedRender: vi.fn() }))
vi.mock('./components/auth/LoginScreen', () => ({ default: () => null }))
vi.mock('./components/SinSucursalScreen', () => ({ default: () => null }))
vi.mock('./components/ErrorBoundary', () => ({ default: ({ children }: { children: ReactNode }) => children }))
vi.mock('./components/layout/TopNavigation', () => ({ default: () => null }))
vi.mock('./components/SyncStatusBanner', () => ({ default: () => null }))
vi.mock('./components/BannerActualizacion', () => ({ default: () => null }))
vi.mock('./components/a11y/SkipLinks', () => ({ default: () => null }))
vi.mock('./components/containers/ClientesContainer', () => ({ default: () => null }))
vi.mock('./components/containers/ComprasContainer', () => ({ default: () => null }))
vi.mock('./components/containers/VencimientosContainer', () => ({ default: () => null }))
vi.mock('./components/containers/DashboardContainer', () => ({ default: () => null }))
vi.mock('./components/containers/PedidosContainer', () => ({ default: () => null }))
vi.mock('./components/containers/ProductosContainer', () => ({ default: () => null }))
vi.mock('./components/containers/ProveedoresContainer', () => ({ default: () => null }))
vi.mock('./components/containers/RevisionHorariosContainer', () => ({ default: () => null }))
vi.mock('./components/containers/UsuariosContainer', () => ({ default: () => null }))
vi.mock('./components/containers/ConfiguracionContainer', () => ({ default: () => null }))

import { PendingSyncRuntime } from './App'
import type { PedidoOffline } from './hooks/useOfflineSync'

function pedido(parcial: Partial<PedidoOffline>): PedidoOffline {
  return {
    offlineId: 'op_1',
    clienteId: 5,
    clienteNombre: 'Almacén Don José',
    items: [{ productoId: '1', cantidad: 3, precioUnitario: 0 }],
    total: 0,
    creadoOffline: new Date().toISOString(),
    sincronizado: false,
    ...parcial,
  }
}

function renderRuntime(pedidosPendientes: PedidoOffline[]) {
  return render(
    <PendingSyncRuntime
      isOnline={false}
      pedidosPendientes={pedidosPendientes}
      sincronizando={false}
      sincronizarPedidos={vi.fn()}
    />,
  )
}

describe('PendingSyncRuntime', () => {
  it('un vale blanco encolado se ve como vale blanco y no como $0', async () => {
    renderRuntime([
      pedido({ offlineId: 'op_vb', clienteNombre: 'Empresa propia', total: 0, tipoFactura: 'VB' }),
      pedido({ offlineId: 'op_zz', clienteNombre: 'Kiosco', total: 1500, tipoFactura: 'ZZ' }),
    ])

    await userEvent.click(screen.getByRole('button', { name: /sin conexion/i }))

    expect(await screen.findByText('Vale blanco (a costo al sincronizar)')).toBeInTheDocument()
    expect(screen.getAllByText('Vale blanco (a costo al sincronizar)')).toHaveLength(1)
    // El único monto del panel es el del ZZ: el VB no pinta "$ 0".
    expect(screen.queryAllByText(/\$\s*0(,00)?$/)).toHaveLength(0)
  })

  it('un pedido común sigue mostrando su total', async () => {
    renderRuntime([pedido({ total: 2500, tipoFactura: 'FC' })])

    await userEvent.click(screen.getByRole('button', { name: /sin conexion/i }))

    expect(await screen.findByText('Almacén Don José')).toBeInTheDocument()
    expect(screen.queryByText('Vale blanco (a costo al sincronizar)')).not.toBeInTheDocument()
    expect(screen.getByText(/2\.500/)).toBeInTheDocument()
  })
})
