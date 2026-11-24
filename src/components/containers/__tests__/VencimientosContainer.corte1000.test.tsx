/**
 * gestion-B1 (tanda 6, #1603): `reporte_vencimientos` devuelve todos los lotes dentro del horizonte y
 * PostgREST corta en 1.000 sin avisar: con más lotes la lista y sus contadores salían cortos y se
 * mostraban como completos. Con 1.000 filas justas el panel dice que puede haber más.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'

const mocks = vi.hoisted(() => ({ useVencimientosQuery: vi.fn() }))

vi.mock('../../../hooks/queries/useLotesQuery', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    useVencimientosQuery: () => mocks.useVencimientosQuery(),
    useDarDeBajaLoteMutation: mutacion,
    useRegistrarNotaCreditoLoteMutation: mutacion,
  }
})
vi.mock('../../../hooks/queries/useNotasCreditoQuery', () => ({
  useRestanteDevolucionCompraQuery: () => ({ data: null }),
}))
vi.mock('../../../hooks/queries/usePoliticasComercialesQuery', () => ({
  useParametrosVencimientoQuery: () => ({ diasAlertaVencimiento: 30, diasCriticoVencimiento: 15 }),
}))
vi.mock('../../../hooks/supabase/useAuth', () => ({ useAuth: () => ({ isAdminOrEncargado: true }) }))
vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))
vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalNombre: 'Tucumán' }),
}))
vi.mock('../../vistas/VistaVencimientos', () => ({ default: () => <div>vista de vencimientos</div> }))

import VencimientosContainer from '../VencimientosContainer'

const lotes = (n: number) => Array.from({ length: n }, (_, i) => ({ lote_id: i + 1, producto_id: i + 1 }))
const consulta = (data: unknown[]) => ({
  data, isLoading: false, isFetching: false, isError: false, refetch: vi.fn(),
})
const AVISO = /La lista se corta en 1\.000 lotes/

describe('VencimientosContainer · el corte de 1.000 filas', () => {
  beforeEach(() => mocks.useVencimientosQuery.mockReset())

  it('con 1.000 lotes avisa que puede haber más', async () => {
    mocks.useVencimientosQuery.mockReturnValue(consulta(lotes(1000)))
    render(<VencimientosContainer />)
    expect(await screen.findByText(AVISO)).toBeInTheDocument()
  })

  it('con menos de 1.000 no avisa', async () => {
    mocks.useVencimientosQuery.mockReturnValue(consulta(lotes(999)))
    render(<VencimientosContainer />)
    await screen.findByText('vista de vencimientos')
    expect(screen.queryByText(AVISO)).not.toBeInTheDocument()
  })
})
