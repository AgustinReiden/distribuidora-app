/**
 * ModalUsuario y las capacidades extra (perfil_roles) al guardar (#1561, 1561-b12; C4b v2).
 *
 *  - El perfil y sus capacidades viajan en UN guardado (`guardar_usuario`): el modal le pasa los
 *    roles extra a `onSave`, no los escribe aparte. Antes se guardaba el perfil y después los roles,
 *    y si fallaba lo segundo el perfil ya había quedado.
 *  - Si la consulta de los roles guardados no volvió, los roles no viajan: el estado local arranca
 *    en «sin capacidades» y guardar así las borraba.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import ModalUsuario from './ModalUsuario'
import type { PerfilDB } from '../../types'

const mocks = vi.hoisted(() => ({
  rolesGuardados: undefined as string[] | undefined,
}))

vi.mock('../../hooks/queries', () => ({
  usePerfilRolesQuery: () => ({ data: mocks.rolesGuardados }),
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalNombre: 'Sucursal de prueba' }),
}))

const usuario = {
  id: 'u1', nombre: 'Persona Prueba', email: 'prueba@example.com', rol: 'deposito', activo: true, zona: '',
} as unknown as PerfilDB

function guardar(onSave = vi.fn(), u: PerfilDB = usuario) {
  render(<ModalUsuario usuario={u} onSave={onSave} onClose={vi.fn()} guardando={false} />)
  fireEvent.click(screen.getByRole('button', { name: /guardar/i }))
  return onSave
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.rolesGuardados = undefined
})

describe('ModalUsuario — capacidades extra en el mismo guardado (C4b v2)', () => {
  it('sin los roles guardados cargados, los roles no viajan (no se borran las capacidades)', async () => {
    mocks.rolesGuardados = undefined
    const onSave = guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(onSave.mock.calls[0][0]).not.toHaveProperty('rolesExtra')
  })

  it('con los roles cargados viajan con el perfil', async () => {
    mocks.rolesGuardados = ['transportista']
    const onSave = guardar()

    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(onSave.mock.calls[0][0]).toMatchObject({ id: 'u1', nombre: 'Persona Prueba', rolesExtra: ['transportista'] })
  })

  it('a quien ya lleva la ruta por su rol se le limpian', async () => {
    mocks.rolesGuardados = ['transportista']
    const onSave = guardar(vi.fn(), { ...usuario, rol: 'transportista' } as unknown as PerfilDB)

    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(onSave.mock.calls[0][0].rolesExtra).toEqual([])
  })

  it('con los roles cargados se puede tildar, y el tilde viaja en el guardado (H6 de la revisión)', async () => {
    mocks.rolesGuardados = []
    const onSave = vi.fn()
    render(<ModalUsuario usuario={usuario} onSave={onSave} onClose={vi.fn()} guardando={false} />)
    const casilla = screen.getByRole('checkbox', { name: /puede llevar la ruta/i })

    expect(casilla).toBeEnabled()
    fireEvent.click(casilla)
    fireEvent.click(screen.getByRole('button', { name: /guardar/i }))

    await waitFor(() => expect(onSave).toHaveBeenCalled())
    expect(onSave.mock.calls[0][0].rolesExtra).toEqual(['transportista'])
  })

  it('el checkbox de la ruta queda deshabilitado mientras no cargan los roles', () => {
    mocks.rolesGuardados = undefined
    render(<ModalUsuario usuario={usuario} onSave={vi.fn()} onClose={vi.fn()} guardando={false} />)

    expect(screen.getByRole('checkbox', { name: /puede llevar la ruta/i })).toBeDisabled()
  })
})

// H2 de la revisión de C6 (1601-b5): el email llega por otro pedido (emails_de_usuarios) que
// puede fallar. El campo es de sólo lectura y no se guarda: sin él, Guardar tiene que guardar.
describe('ModalUsuario — sin el email', () => {
  it('un usuario sin email (no se pudo cargar) se guarda igual', async () => {
    mocks.rolesGuardados = []
    const onSave = vi.fn()
    const sinEmail = { ...usuario, email: undefined } as unknown as PerfilDB
    render(<ModalUsuario usuario={sinEmail} onSave={onSave} onClose={vi.fn()} guardando={false} />)
    fireEvent.click(screen.getByRole('button', { name: /guardar/i }))

    await waitFor(() => expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ id: 'u1', nombre: 'Persona Prueba' })))
    expect(screen.getByLabelText('Email')).toHaveValue('')
  })
})
