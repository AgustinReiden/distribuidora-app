/**
 * `ProveedoresContainer` con la query caída (#1517, FRT-3).
 *
 * Si `useProveedoresQuery` fallaba tras agotar los reintentos, la pantalla caía
 * al vacío: "No hay proveedores registrados" y hasta el botón "Agregar primer
 * proveedor", como si la sucursal no tuviera ninguno. Ahora el listado lo
 * reemplaza `QueryErrorState` (role="alert" + "Reintentar"), igual que
 * Clientes, Compras y Productos.
 *
 * Se monta el container REAL con la vista real y los hooks simulados. Lo que se
 * fija:
 *  - query en error y sin proveedores: se ve el error, NO el vacío;
 *  - "Reintentar" llama al `refetch` de la query;
 *  - query en error pero CON proveedores en caché (un refetch que falló): se ve
 *    la lista, no el error;
 *  - sin error y sin proveedores sigue diciendo que no hay (no se rompe el vacío
 *    de verdad).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  useProveedoresQuery: vi.fn(),
}))

vi.mock('../../../hooks/queries', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    useProveedoresQuery: () => mocks.useProveedoresQuery(),
    useComprasQuery: () => ({ data: [] }),
    useCrearProveedorMutation: mutacion,
    useActualizarProveedorMutation: mutacion,
    useToggleProveedorActivoMutation: mutacion,
    useEliminarProveedorMutation: mutacion,
  }
})

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

import ProveedoresContainer from '../ProveedoresContainer'

// La vista es lazy: la primera vez que se monta en la corrida el import en frío
// se come casi todo el segundo por defecto de `findBy*`.
const ESPERA_VISTA = { timeout: 5000 }

const refetch = vi.fn()

const proveedor = {
  id: '1',
  nombre: 'Norte 01',
  cuit: '30-01',
  contacto: null,
  activo: true,
}

beforeEach(() => {
  refetch.mockReset()
  mocks.useProveedoresQuery.mockReset()
})

describe('ProveedoresContainer — la query falló', () => {
  it('sin proveedores muestra el error y no "No hay proveedores registrados"', async () => {
    mocks.useProveedoresQuery.mockReturnValue({ data: undefined, isLoading: false, isError: true, refetch })
    render(<ProveedoresContainer />)

    expect(await screen.findByRole('alert', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeInTheDocument()
    expect(screen.queryByText('No hay proveedores registrados')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Agregar primer proveedor' })).not.toBeInTheDocument()
  })

  it('"Reintentar" vuelve a pedir la query', async () => {
    mocks.useProveedoresQuery.mockReturnValue({ data: undefined, isLoading: false, isError: true, refetch })
    render(<ProveedoresContainer />)

    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Reintentar' }, ESPERA_VISTA))
    expect(refetch).toHaveBeenCalledTimes(1)
  })

  it('con la lista en caché y el refetch fallido, se ve la lista y no el error', async () => {
    mocks.useProveedoresQuery.mockReturnValue({ data: [proveedor], isLoading: false, isError: true, refetch })
    render(<ProveedoresContainer />)

    expect(await screen.findByText('Norte 01', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})

describe('ProveedoresContainer — sin error', () => {
  it('sin proveedores sigue diciendo que no hay', async () => {
    mocks.useProveedoresQuery.mockReturnValue({ data: [], isLoading: false, isError: false, refetch })
    render(<ProveedoresContainer />)

    expect(await screen.findByText('No hay proveedores registrados', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
