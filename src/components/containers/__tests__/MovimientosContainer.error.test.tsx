/**
 * `MovimientosContainer` con la query caída (#1517, FRT-3).
 *
 * Si `useMovimientosQuery` fallaba tras agotar los reintentos, la pantalla decía
 * "No hay movimientos para mostrar" como si no hubiera envíos entre sucursales.
 * Ahora el listado lo reemplaza `QueryErrorState` (role="alert" + "Reintentar").
 *
 * Se monta el container REAL con la vista real y el hook simulado. Lo que se
 * fija:
 *  - query en error y sin movimientos: se ve el error, NO el vacío, y las
 *    pestañas siguen ahí para cambiar de lista;
 *  - "Reintentar" llama al `refetch` de la query;
 *  - query en error pero CON movimientos en caché: se ve la lista, no el error;
 *  - sin error y sin movimientos sigue diciendo que no hay.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  useMovimientosQuery: vi.fn(),
}))

vi.mock('../../../hooks/queries', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    MOVIMIENTOS_PAGE_SIZE: 50,
    useMovimientosQuery: () => mocks.useMovimientosQuery(),
    useMovimientoItemsQuery: () => ({ data: [], isLoading: false }),
    useSucursalesQuery: () => ({ data: [] }),
    useProductosQuery: () => ({ data: [] }),
    useCrearMovimientoMutation: mutacion,
    useAceptarMovimientoMutation: mutacion,
    useDenegarMovimientoMutation: mutacion,
    useCancelarMovimientoMutation: mutacion,
    useEditarMovimientoMutation: mutacion,
  }
})

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdminOrEncargado: true }),
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1, currentSucursalRol: 'admin' }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))

import MovimientosContainer from '../MovimientosContainer'

// La vista es lazy: la primera vez que se monta en la corrida el import en frío
// se come casi todo el segundo por defecto de `findBy*`.
const ESPERA_VISTA = { timeout: 5000 }

const refetch = vi.fn()

const movimiento = {
  id: 7,
  sucursal_origen_id: 2,
  sucursal_destino_id: 1,
  estado: 'aceptada',
  total_costo: 100,
  total_unidades: 1,
  stock_descontado: false,
  notas: null,
  motivo_rechazo: null,
  creado_por: 'u1',
  resuelto_por: null,
  editado_por: null,
  created_at: '2026-10-01T12:00:00Z',
  resuelto_at: null,
  editado_at: null,
  origen: { id: 2, nombre: 'Sucursal Sur' },
  destino: { id: 1, nombre: 'Casa Central' },
  creador: { id: 'u1', nombre: 'Ana' },
}

const fallida = {
  data: undefined, total: 0, isLoading: false, isSuccess: false, isPlaceholderData: false, isError: true, refetch,
}

beforeEach(() => {
  refetch.mockReset()
  mocks.useMovimientosQuery.mockReset()
})

describe('MovimientosContainer — la query falló', () => {
  it('sin movimientos muestra el error y no "No hay movimientos para mostrar"', async () => {
    mocks.useMovimientosQuery.mockReturnValue(fallida)
    render(<MovimientosContainer />)

    expect(await screen.findByRole('alert', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeInTheDocument()
    expect(screen.queryByText('No hay movimientos para mostrar')).not.toBeInTheDocument()
    // Las pestañas no se van: se puede probar con otra lista.
    expect(screen.getByRole('button', { name: 'Aceptadas' })).toBeInTheDocument()
  })

  it('"Reintentar" vuelve a pedir la query', async () => {
    mocks.useMovimientosQuery.mockReturnValue(fallida)
    render(<MovimientosContainer />)

    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Reintentar' }, ESPERA_VISTA))
    expect(refetch).toHaveBeenCalledTimes(1)
  })

  it('con movimientos en caché y el refetch fallido, se ve la lista y no el error', async () => {
    mocks.useMovimientosQuery.mockReturnValue({
      ...fallida, data: [movimiento], total: 1, isSuccess: true,
    })
    render(<MovimientosContainer />)

    expect(await screen.findByRole('button', { name: 'Ver detalle' }, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})

describe('MovimientosContainer — sin error', () => {
  it('sin movimientos sigue diciendo que no hay', async () => {
    mocks.useMovimientosQuery.mockReturnValue({
      data: [], total: 0, isLoading: false, isSuccess: true, isPlaceholderData: false, isError: false, refetch,
    })
    render(<MovimientosContainer />)

    expect(await screen.findByText('No hay movimientos para mostrar', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
