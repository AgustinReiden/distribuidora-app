/**
 * PersonalContainer (entrega 3 de gastos): conecta la vista con la query del personal y abre
 * lazy los modales. Se prueba el cableado: la vista y los modales se mockean, porque lo que
 * importa es qué recibe cada uno y qué hace el container con lo que le avisan.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { Empleado } from '../../types/personal'

const mockReactivar = vi.fn()
// Los props con que el container abrió el último ModalEmpleado.
const propsModalEmpleado = vi.hoisted(() => ({ actual: null as Record<string, unknown> | null }))
const mockNotify = { success: vi.fn(), error: vi.fn() }

const EMPLEADO = {
  id: 42, nombre: 'Luis Prios', puesto: 'preventista', sucursal_id: 1, de_las_dos: false, cuil: null,
  fecha_ingreso: null, telefono: null, activo: true, fecha_baja: null, usuario: null, cliente: null,
  vehiculo: null, arreglo: null, arranque: null, saldo: 0, es_propio: false,
} as Empleado
const INACTIVO = { ...EMPLEADO, id: 43, nombre: 'Rosa Vieja', activo: false } as Empleado
// Uno con vínculos: lo que ve ocupado quien carga o edita a otro.
const VINCULADO = {
  ...EMPLEADO, id: 44, nombre: 'Ana Vinculada',
  usuario: { id: 'u-9', nombre: 'Ana' }, cliente: { id: 77, nombre_fantasia: 'Kiosco Ana', activo: true },
} as Empleado

vi.mock('../../hooks/queries', () => ({
  usePersonalQuery: () => ({ data: [EMPLEADO, INACTIVO, VINCULADO], isLoading: false, error: null, refetch: vi.fn() }),
  useGuardarEmpleadoMutation: () => ({ mutateAsync: vi.fn() }),
  useReactivarEmpleadoMutation: () => ({ mutateAsync: mockReactivar }),
  useDarDeBajaEmpleadoMutation: () => ({ mutateAsync: vi.fn() }),
  // Los vínculos que el modal ofrece; el modal está mockeado, así que sólo importa que el
  // container los pida y los arme sin romper.
  useUsuariosQuery: () => ({ data: [{ id: 'u-9', nombre: 'Ana' }, { id: 'u-1', nombre: 'Pablo', activo: false }] }),
  useClientesQuery: () => ({ data: [{ id: '77', nombre_fantasia: 'Kiosco Ana' }, { id: '78', nombre_fantasia: 'Viejo', activo: false }] }),
  useVehiculosQuery: () => ({ data: [{ id: 7, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true }] }),
  useSucursalesActivasQuery: () => ({ data: [{ id: 1, nombre: 'Tucumán' }] }),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    currentSucursalId: 1,
    currentSucursalNombre: 'Tucumán',
    sucursales: [{ id: 1, nombre: 'Tucumán', rol: 'admin' }],
  }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ user: { id: 'u-yo' } }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => mockNotify,
}))

// La vista: un botón por acción, con el empleado que le toca.
vi.mock('../vistas/VistaPersonal', () => ({
  default: ({ onVerFicha, onReactivar, onNuevo, onEditar, onDarDeBaja }: {
    onVerFicha: (e: Empleado) => void; onReactivar: (e: Empleado) => void; onNuevo: () => void
    onEditar: (e: Empleado) => void; onDarDeBaja: (e: Empleado) => void
  }) => (
    <div>
      <button type="button" onClick={() => onVerFicha(EMPLEADO)}>ver ficha</button>
      <button type="button" onClick={() => onReactivar(INACTIVO)}>reactivar</button>
      <button type="button" onClick={onNuevo}>nuevo</button>
      <button type="button" onClick={() => onEditar(EMPLEADO)}>editar</button>
      <button type="button" onClick={() => onDarDeBaja(EMPLEADO)}>baja</button>
    </div>
  ),
}))

vi.mock('../modals/ModalCuentaEmpleado', () => ({
  default: ({ empleadoId }: { empleadoId: number }) => <div>cuenta del empleado {empleadoId}</div>,
}))
vi.mock('../modals/ModalEmpleado', () => ({
  default: (props: { empleado: Empleado | null }) => {
    propsModalEmpleado.actual = props as unknown as Record<string, unknown>
    return <div>{props.empleado ? `editando ${props.empleado.nombre}` : 'alta de empleado'}</div>
  },
}))
vi.mock('../modals/ModalBajaEmpleado', () => ({
  default: ({ empleado }: { empleado: Empleado }) => <div>baja de {empleado.nombre}</div>,
}))

import PersonalContainer from './PersonalContainer'

describe('PersonalContainer', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    propsModalEmpleado.actual = null
    mockReactivar.mockResolvedValue(undefined)
  })

  it('Ver ficha abre la cuenta con su id', async () => {
    const user = userEvent.setup()
    render(<PersonalContainer />)
    await user.click(await screen.findByRole('button', { name: 'ver ficha' }))
    expect(await screen.findByText('cuenta del empleado 42', {}, { timeout: 4000 })).toBeInTheDocument()
  })

  it('reactivar llama la mutation y avisa', async () => {
    const user = userEvent.setup()
    render(<PersonalContainer />)
    await user.click(await screen.findByRole('button', { name: 'reactivar' }))
    expect(mockReactivar).toHaveBeenCalledWith(43)
    expect(mockNotify.success).toHaveBeenCalledWith('Rosa Vieja reactivado')
  })

  it('si reactivar falla, avisa el error y no dice que salió bien', async () => {
    mockReactivar.mockRejectedValue(new Error('Ese empleado ya está activo'))
    const user = userEvent.setup()
    render(<PersonalContainer />)
    await user.click(await screen.findByRole('button', { name: 'reactivar' }))
    expect(mockNotify.error).toHaveBeenCalledWith('Ese empleado ya está activo')
    expect(mockNotify.success).not.toHaveBeenCalled()
  })

  it('nuevo abre el alta, editar abre la edición y baja abre la baja', async () => {
    const user = userEvent.setup()
    render(<PersonalContainer />)
    await user.click(await screen.findByRole('button', { name: 'nuevo' }))
    expect(await screen.findByText('alta de empleado', {}, { timeout: 4000 })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'editar' }))
    expect(await screen.findByText('editando Luis Prios', {}, { timeout: 4000 })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'baja' }))
    expect(await screen.findByText('baja de Luis Prios', {}, { timeout: 4000 })).toBeInTheDocument()
  })

  it('le pasa al modal quién es el usuario logueado, para no ofrecerlo en el alta', async () => {
    const user = userEvent.setup()
    render(<PersonalContainer />)
    await user.click(await screen.findByRole('button', { name: 'nuevo' }))
    await screen.findByText('alta de empleado', {}, { timeout: 4000 })
    expect((propsModalEmpleado.actual as { usuarioPropioId: unknown }).usuarioPropioId).toBe('u-yo')
  })

  it('arma los vínculos del modal: ids de cliente a number y ocupados sin el empleado que se edita', async () => {
    const user = userEvent.setup()
    render(<PersonalContainer />)

    // Alta: los vínculos de los demás están ocupados.
    await user.click(await screen.findByRole('button', { name: 'nuevo' }))
    await screen.findByText('alta de empleado', {}, { timeout: 4000 })
    const alta = propsModalEmpleado.actual as {
      usuarios: unknown; clientes: unknown; vehiculos: unknown; tieneTodasLasSucursales: boolean
      ocupados: { usuarios: Set<string>; clientes: Set<number> }
    }
    expect(alta.usuarios).toEqual([{ id: 'u-9', nombre: 'Ana' }])
    expect(alta.clientes).toEqual([
      { id: 77, nombre_fantasia: 'Kiosco Ana', activo: true },
      { id: 78, nombre_fantasia: 'Viejo', activo: false },
    ])
    expect(alta.vehiculos).toEqual([{ id: 7, patente: 'AC456EF', descripcion: 'Partner' }])
    expect(alta.tieneTodasLasSucursales).toBe(true)
    expect([...alta.ocupados.usuarios]).toEqual(['u-9'])
    expect([...alta.ocupados.clientes]).toEqual([77])
  })
})
