/**
 * UsuariosContainer — nadie edita su propio usuario (C4b v3, D1 y N7 de su revisión).
 *
 * El server lo rechaza (`guardar_usuario`: «No podés editar tu propio usuario»), así que la pantalla
 * no abre el formulario sobre la propia fila: avisa el motivo antes de que se tipee nada. A otro
 * usuario se lo sigue editando.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import UsuariosContainer from './UsuariosContainer'
import type { PerfilDB } from '../../types'

const mocks = vi.hoisted(() => ({
  warning: vi.fn(),
  error: vi.fn(),
  success: vi.fn(),
}))

const usuarios = [
  { id: 'yo', nombre: 'Admin Propio', email: 'yo@example.com', rol: 'admin', activo: true, zona: '' },
  { id: 'otro', nombre: 'Otra Persona', email: 'otro@example.com', rol: 'preventista', activo: true, zona: '' },
] as unknown as PerfilDB[]

vi.mock('../../hooks/queries', () => ({
  useUsuariosQuery: () => ({ data: usuarios, isLoading: false, error: null }),
  useActualizarUsuarioMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  usePerfilRolesQuery: () => ({ data: [] }),
}))
// Los emails van en su propia consulta (C6, 1601-b5); acá no importan.
vi.mock('../../hooks/queries/emailsDeUsuarios', () => ({
  useEmailsDeUsuariosQuery: () => ({ data: undefined, isError: false, refetch: vi.fn() }),
}))
vi.mock('../../hooks/supabase/useAuth', () => ({
  useAuth: () => ({ user: { id: 'yo' } }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ warning: mocks.warning, error: mocks.error, success: mocks.success }),
}))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: () => undefined,
}))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalNombre: 'Sucursal de prueba' }),
}))

// La lista y el formulario son lazy: el import en frío, con la máquina cargada, pasa los 5 s de
// setup.js. La cota sólo cuenta cuando el elemento NO aparece (si aparece, findBy vuelve en el acto).
const ESPERA_LAZY = { timeout: 20000 }

beforeEach(() => {
  vi.clearAllMocks()
})

describe('UsuariosContainer — la propia fila', () => {
  it('no abre el formulario sobre uno mismo y dice por qué', async () => {
    render(<UsuariosContainer />)
    fireEvent.click(await screen.findByRole('button', { name: /editar usuario admin propio/i }, ESPERA_LAZY))

    expect(mocks.warning).toHaveBeenCalledWith(expect.stringMatching(/tu propio usuario.*otro administrador/i))
    expect(screen.queryByText('Editar Usuario')).not.toBeInTheDocument()
  })

  it('a otro usuario lo abre', async () => {
    render(<UsuariosContainer />)
    fireEvent.click(await screen.findByRole('button', { name: /editar usuario otra persona/i }, ESPERA_LAZY))

    expect(await screen.findByText('Editar Usuario', {}, ESPERA_LAZY)).toBeInTheDocument()
    expect(mocks.warning).not.toHaveBeenCalled()
  })
})
