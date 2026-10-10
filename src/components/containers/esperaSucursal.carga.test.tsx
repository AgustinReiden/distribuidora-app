/**
 * #1061: el Dashboard, Comisiones y Metas esperan a la sucursal activa antes de
 * consultar (`enabled: ... && currentSucursalId != null`). Con la query apagada,
 * TanStack v5 da `isLoading: false` y `data: undefined`, así que si el container
 * le pasa sólo `isLoading` a la vista, durante el arranque se ve un instante la
 * pantalla vacía ("sin datos", ceros) en vez del esqueleto de carga. Mientras la
 * sucursal no está resuelta, la vista tiene que recibir `loading`.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'

const sucursal = { currentSucursalId: null as number | null }

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => sucursal,
}))

// Lo que da TanStack con la query apagada: ni cargando ni con datos.
const apagada = { data: undefined, isLoading: false, error: null, refetch: vi.fn() }

vi.mock('../../hooks/queries', () => ({
  useMetricasQuery: () => apagada,
  useClientesQuery: () => ({ data: [] }),
  useAvanceMetasQuery: () => ({ data: undefined }),
  useProductosQuery: () => ({ data: [] }),
  periodoMensual: () => '2026-10',
  useCalcularComisionesQuery: () => apagada,
  useVendedoresComisionablesQuery: () => ({ data: [] }),
  useRendimientoPreventistasQuery: () => apagada,
  useDesactivarMetaPreventistaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
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

vi.mock('../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: () => {},
}))

// Las vistas no son lo que se prueba: sólo muestran el `loading` que reciben.
const vista = ({ loading }: { loading: boolean }) => <p>{loading ? 'cargando' : 'listo'}</p>
vi.mock('../vistas/VistaDashboard', () => ({ default: vista }))
vi.mock('../vistas/VistaComisiones', () => ({ default: vista }))
vi.mock('../vistas/VistaMetasPreventistas', () => ({ default: vista }))

import DashboardContainer from './DashboardContainer'
import ComisionesContainer from './ComisionesContainer'
import MetasContainer from './MetasContainer'

const CONTAINERS = [
  ['DashboardContainer', DashboardContainer],
  ['ComisionesContainer', ComisionesContainer],
  ['MetasContainer', MetasContainer],
] as const

describe('containers que esperan a la sucursal activa (#1061)', () => {
  beforeEach(() => {
    sucursal.currentSucursalId = null
  })

  it.each(CONTAINERS)('%s: con la sucursal sin resolver la vista está cargando, no vacía', async (_n, Container) => {
    render(<Container />)
    expect(await screen.findByText('cargando')).toBeInTheDocument()
  })

  it.each(CONTAINERS)('%s: con la sucursal resuelta y la query quieta, la vista no está cargando', async (_n, Container) => {
    sucursal.currentSucursalId = 1
    render(<Container />)
    expect(await screen.findByText('listo')).toBeInTheDocument()
  })
})
