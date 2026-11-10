/**
 * FRT-3 (#1517): si la query de métricas falla, el dashboard mostraba ceros como si
 * fueran datos. `metricas={metricas || { ventasPeriodo: 0, ... }}` convertía un
 * `data: undefined` por error en "$0 de ventas, 0 pedidos".
 *
 * Con la query en error y sin nada en caché va un estado de error con "Reintentar";
 * con datos en caché y un refetch fallido siguen los datos.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const m = vi.hoisted(() => ({
  query: {} as Record<string, unknown>,
  refetch: vi.fn(),
  capturarProps: vi.fn(),
}))

vi.mock('../../hooks/queries', () => ({
  useMetricasQuery: () => m.query,
  useClientesQuery: () => ({ data: [] }),
  useClientesOperativosQuery: () => ({ data: [] }),
  useAvanceMetasQuery: () => ({ data: undefined }),
  useProductosQuery: () => ({ data: [] }),
  periodoMensual: () => '2026-09',
}))

// La sucursal activa ya resuelta: el container muestra cargando mientras no lo está (#1061).
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({
    user: { id: 'u1' },
    isAdmin: true,
    isPreventista: false,
    isEncargado: false,
    authReady: true,
  }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn() }),
}))

vi.mock('../../hooks/supabase', () => ({
  useBackup: () => ({ exportando: false, descargarJSON: vi.fn() }),
}))

vi.mock('../vistas/VistaDashboard', () => ({
  default: (props: unknown) => {
    m.capturarProps(props)
    return <div data-testid="vista-dashboard" />
  },
}))

import DashboardContainer from './DashboardContainer'

const METRICAS_REALES = {
  ventasPeriodo: 125000,
  ventasEnCurso: 0,
  pedidosPeriodo: 9,
  pedidosEntregados: 9,
  pedidosEnCurso: 0,
  productosMasVendidos: [],
  clientesMasActivos: [],
  pedidosPorEstado: { pendiente: 0, asignado: 0, entregado: 9 },
  pedidosRechazados: 0,
  ventasPorDia: [],
}

/** Deja correr los lazy/Suspense pendientes: sirve para afirmar que algo NO apareció. */
async function dejarAsentar(): Promise<void> {
  await act(async () => { await new Promise(r => setTimeout(r, 0)) })
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('DashboardContainer › la query de métricas falla (FRT-3)', () => {
  it('sin datos en caché muestra el error con "Reintentar" y NO la vista con ceros', async () => {
    m.query = { data: undefined, isError: true, isLoading: false, refetch: m.refetch }
    render(<DashboardContainer />)

    const alerta = screen.getByRole('alert')
    expect(alerta.textContent).toContain('No se pudo cargar')
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeTruthy()

    await dejarAsentar()
    expect(screen.queryByTestId('vista-dashboard')).toBeNull()
    expect(m.capturarProps).not.toHaveBeenCalled()
  })

  it('"Reintentar" vuelve a pedir las métricas (refetch)', async () => {
    m.query = { data: undefined, isError: true, isLoading: false, refetch: m.refetch }
    const user = userEvent.setup()
    render(<DashboardContainer />)

    await user.click(screen.getByRole('button', { name: 'Reintentar' }))

    expect(m.refetch).toHaveBeenCalledTimes(1)
  })

  it('con datos en caché y un refetch que falla siguen los datos, sin error', async () => {
    m.query = { data: METRICAS_REALES, isError: true, isLoading: false, refetch: m.refetch }
    render(<DashboardContainer />)

    expect(await screen.findByTestId('vista-dashboard')).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
    const props = m.capturarProps.mock.calls[m.capturarProps.mock.calls.length - 1][0] as { metricas: typeof METRICAS_REALES }
    expect(props.metricas.ventasPeriodo).toBe(125000)
  })

  it('mientras carga sigue el esqueleto de la vista, no el error', async () => {
    m.query = { data: undefined, isError: false, isLoading: true, refetch: m.refetch }
    render(<DashboardContainer />)

    expect(await screen.findByTestId('vista-dashboard')).toBeTruthy()
    expect(screen.queryByRole('alert')).toBeNull()
    const props = m.capturarProps.mock.calls[m.capturarProps.mock.calls.length - 1][0] as { loading: boolean }
    expect(props.loading).toBe(true)
  })
})
