/**
 * `VencimientosContainer` con la query caída (#1517, FRT-3).
 *
 * Si `useVencimientosQuery` fallaba tras agotar los reintentos, el panel decía
 * "No hay vencimientos cargados" como si ningún producto tuviera lotes con fecha:
 * justo la pantalla que existe para no perder una mercadería por vencer. Ahora
 * el listado lo reemplaza `QueryErrorState` (role="alert" + "Reintentar").
 *
 * Se monta el container REAL con la vista real y los hooks simulados. Lo que se
 * fija:
 *  - query en error y sin lotes: se ve el error, NO el vacío;
 *  - "Reintentar" llama al `refetch` de la query;
 *  - query en error pero CON lotes en caché (un refetch que falló): se ven los
 *    lotes, no el error;
 *  - sin error y sin lotes sigue diciendo que no hay.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  useVencimientosQuery: vi.fn(),
}))

vi.mock('../../../hooks/queries/useLotesQuery', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    useVencimientosQuery: () => mocks.useVencimientosQuery(),
    useDarDeBajaLoteMutation: mutacion,
    useRegistrarNotaCreditoLoteMutation: mutacion,
  }
})

vi.mock('../../../hooks/queries/usePoliticasComercialesQuery', () => ({
  useParametrosVencimientoQuery: () => ({ diasAlertaVencimiento: 30, diasCriticoVencimiento: 15 }),
}))

vi.mock('../../../hooks/supabase/useAuth', () => ({
  useAuth: () => ({ isAdminOrEncargado: true }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalNombre: 'Tucumán' }),
}))

import VencimientosContainer from '../VencimientosContainer'

// La vista es lazy: la primera vez que se monta en la corrida el import en frío
// se come casi todo el segundo por defecto de `findBy*`.
const ESPERA_VISTA = { timeout: 5000 }

const refetch = vi.fn()

const lote = {
  lote_id: 1,
  producto_id: 101,
  producto_nombre: 'Producto en caché',
  producto_codigo: null,
  fecha_vencimiento: '2030-12-31',
  cantidad: 10,
  cantidad_restante: 8,
  dias_restantes: 0,
  origen: 'manual',
  compra_id: null,
  stock_producto: 40,
  bolsa_producto: 0,
}

const consulta = (extra: Record<string, unknown>) => ({
  data: undefined, isLoading: false, isFetching: false, isError: false, refetch, ...extra,
})

beforeEach(() => {
  refetch.mockReset()
  mocks.useVencimientosQuery.mockReset()
})

describe('VencimientosContainer — la query falló', () => {
  it('sin lotes muestra el error y no "No hay vencimientos cargados"', async () => {
    mocks.useVencimientosQuery.mockReturnValue(consulta({ isError: true }))
    render(<VencimientosContainer />)

    expect(await screen.findByRole('alert', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeInTheDocument()
    expect(screen.queryByText('No hay vencimientos cargados.')).not.toBeInTheDocument()
  })

  it('"Reintentar" vuelve a pedir la query', async () => {
    mocks.useVencimientosQuery.mockReturnValue(consulta({ isError: true }))
    render(<VencimientosContainer />)

    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Reintentar' }, ESPERA_VISTA))
    expect(refetch).toHaveBeenCalledTimes(1)
  })

  it('con lotes en caché y el refetch fallido, se ven los lotes y no el error', async () => {
    mocks.useVencimientosQuery.mockReturnValue(consulta({ data: [lote], isError: true }))
    render(<VencimientosContainer />)

    expect(await screen.findByText('Producto en caché', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})

describe('VencimientosContainer — sin error', () => {
  it('sin lotes sigue diciendo que no hay', async () => {
    mocks.useVencimientosQuery.mockReturnValue(consulta({ data: [] }))
    render(<VencimientosContainer />)

    expect(await screen.findByText('No hay vencimientos cargados.', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
