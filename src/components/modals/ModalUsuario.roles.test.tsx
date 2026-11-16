/**
 * ModalUsuario y las capacidades extra (perfil_roles) al guardar (#1561, 1561-b12).
 *
 *  - Si la consulta de los roles guardados no volvió, no se escriben roles: el estado local
 *    arranca en «sin capacidades» y guardar así las borraba.
 *  - Si guardar las capacidades falla (el perfil ya se guardó), se avisa: antes se tragaba.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import ModalUsuario from './ModalUsuario'
import type { PerfilDB } from '../../types'

const mocks = vi.hoisted(() => ({
  rolesGuardados: undefined as string[] | undefined,
  asignar: vi.fn(),
  notifyError: vi.fn(),
}))

vi.mock('../../hooks/queries', () => ({
  usePerfilRolesQuery: () => ({ data: mocks.rolesGuardados }),
  useAsignarPerfilRolesMutation: () => ({ mutateAsync: mocks.asignar, isPending: false }),
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalNombre: 'Sucursal de prueba' }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: mocks.notifyError, warning: vi.fn() }),
}))

const usuario = {
  id: 'u1', nombre: 'Persona Prueba', email: 'prueba@example.com', rol: 'deposito', activo: true, zona: '',
} as unknown as PerfilDB

function guardar(onSave = vi.fn()) {
  render(<ModalUsuario usuario={usuario} onSave={onSave} onClose={vi.fn()} guardando={false} />)
  fireEvent.click(screen.getByRole('button', { name: /guardar/i }))
  return onSave
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.rolesGuardados = undefined
  mocks.asignar.mockResolvedValue(undefined)
})

describe('ModalUsuario — capacidades extra', () => {
  it('sin los roles guardados cargados no escribe roles (no borra las capacidades)', async () => {
    mocks.rolesGuardados = undefined
    const onSave = guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(mocks.asignar).not.toHaveBeenCalled()
  })

  it('con los roles cargados los escribe', async () => {
    mocks.rolesGuardados = ['transportista']
    guardar()

    await waitFor(() => expect(mocks.asignar).toHaveBeenCalledWith({ usuarioId: 'u1', roles: ['transportista'] }))
  })

  it('si guardar las capacidades falla, lo avisa y dice que el usuario sí se guardó', async () => {
    mocks.rolesGuardados = []
    mocks.asignar.mockRejectedValue(new Error('Se quitaron los roles x, pero no se pudieron agregar y'))
    guardar()

    await waitFor(() => expect(mocks.notifyError).toHaveBeenCalled())
    const aviso = String(mocks.notifyError.mock.calls[0][0])
    expect(aviso).toMatch(/Se guardó el usuario, pero no se pudieron guardar sus capacidades extra/)
    expect(aviso).toContain('Se quitaron los roles x')
  })
})
