/**
 * `ProveedoresContainer` y el motivo del server al guardar (#1599, 1599-b1).
 *
 * El container se comía el motivo: cualquier falla era «Error al guardar
 * proveedor», y el aviso de CUIT duplicado ("Ya existe un proveedor con CUIT…")
 * nunca llegaba a la pantalla. Se monta el container real con la vista y el
 * modal reemplazados por botones que disparan los handlers.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  crear: vi.fn(),
  actualizar: vi.fn(),
  toggle: vi.fn(),
  notifyError: vi.fn(),
  notifySuccess: vi.fn(),
  resultado: { success: true } as unknown,
}))

vi.mock('../../../hooks/queries', () => ({
  useProveedoresQuery: () => ({
    data: [{ id: '1', nombre: 'Norte 01', cuit: '', contacto: null, activo: true }],
    isLoading: false,
    isError: false,
    refetch: vi.fn(),
  }),
  useComprasQuery: () => ({ data: [] }),
  useCrearProveedorMutation: () => ({ mutateAsync: mocks.crear, isPending: false }),
  useActualizarProveedorMutation: () => ({ mutateAsync: mocks.actualizar, isPending: false }),
  useToggleProveedorActivoMutation: () => ({ mutateAsync: mocks.toggle, isPending: false }),
  useEliminarProveedorMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true }),
}))
vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: mocks.notifySuccess, error: mocks.notifyError, warning: vi.fn() }),
}))
vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

// Vista y modal mínimos: sólo exponen los handlers del container.
vi.mock('../../vistas/VistaProveedores', () => ({
  default: (p: { onNuevoProveedor: () => void; onToggleActivo: (x: unknown) => void; proveedores: unknown[] }) => (
    <div>
      <button onClick={p.onNuevoProveedor}>nuevo</button>
      <button onClick={() => p.onToggleActivo(p.proveedores[0])}>toggle</button>
    </div>
  ),
}))
vi.mock('../../modals/ModalProveedor', () => ({
  default: (p: { onSave: (d: unknown) => Promise<unknown> }) => (
    <button onClick={async () => { mocks.resultado = await p.onSave({ nombre: 'X' }) }}>guardar</button>
  ),
}))

import ProveedoresContainer from '../ProveedoresContainer'

const ESPERA = { timeout: 5000 }

beforeEach(() => {
  vi.clearAllMocks()
  mocks.resultado = undefined
})

describe('ProveedoresContainer — el motivo del server llega al usuario', () => {
  it('un CUIT duplicado se muestra tal cual, no «Error al guardar proveedor»', async () => {
    mocks.crear.mockRejectedValue(new Error('Ya existe un proveedor con CUIT "30-71234567-1": Norte 01'))
    render(<ProveedoresContainer />)
    const user = userEvent.setup()

    await user.click(await screen.findByRole('button', { name: 'nuevo' }, ESPERA))
    await user.click(await screen.findByRole('button', { name: 'guardar' }, ESPERA))

    expect(mocks.notifyError).toHaveBeenCalledWith('Ya existe un proveedor con CUIT "30-71234567-1": Norte 01')
    expect(mocks.resultado).toEqual({ success: false, error: 'Ya existe un proveedor con CUIT "30-71234567-1": Norte 01' })
  })

  it('sin mensaje (algo que no es un Error) cae al genérico', async () => {
    mocks.crear.mockRejectedValue('boom')
    render(<ProveedoresContainer />)
    const user = userEvent.setup()

    await user.click(await screen.findByRole('button', { name: 'nuevo' }, ESPERA))
    await user.click(await screen.findByRole('button', { name: 'guardar' }, ESPERA))

    expect(mocks.notifyError).toHaveBeenCalledWith('Error al guardar proveedor')
  })

  it('activar o desactivar muestra el motivo del server', async () => {
    mocks.toggle.mockRejectedValue(new Error('Acceso denegado: se requiere rol admin'))
    render(<ProveedoresContainer />)

    await userEvent.setup().click(await screen.findByRole('button', { name: 'toggle' }, ESPERA))

    expect(mocks.notifyError).toHaveBeenCalledWith('Acceso denegado: se requiere rol admin')
  })
})
