/**
 * VehiculosContainer (entrega 3 de gastos): lo que le pasa a la ficha del vehículo sobre quién
 * lo usa. La vista y el modal se mockean: importa qué recibe `usadoPor` según cómo viene la
 * lista de empleados (cargando o con error no es "nadie").
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const VEHICULO = { id: 7, sucursal_id: 1, patente: 'AC456EF', descripcion: 'Partner', activo: true }
const estado = vi.hoisted(() => ({
  empleados: { data: undefined as unknown, isSuccess: false, isError: false },
}))
const propsFicha = vi.hoisted(() => ({ actual: null as { usadoPor?: string[] } | null }))

vi.mock('../../hooks/queries', () => ({
  useGastosDelMesQuery: () => ({ data: [] }),
  useGuardarVehiculoMutation: () => ({ mutateAsync: vi.fn() }),
  useRegistrarKmMutation: () => ({ mutateAsync: vi.fn() }),
  useVehiculoFichaQuery: () => ({ data: { gastos: [], lecturas: [] }, isLoading: false }),
  useVehiculosQuery: () => ({ data: [VEHICULO], isLoading: false }),
  useEmpleadosParaElegirQuery: () => estado.empleados,
}))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => ({ success: vi.fn(), error: vi.fn() }) }))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1, currentSucursalNombre: 'Tucumán' }),
}))
vi.mock('../vistas/VistaVehiculos', () => ({
  default: ({ onVerFicha }: { onVerFicha: (v: typeof VEHICULO) => void }) => (
    <button type="button" onClick={() => onVerFicha(VEHICULO)}>ver ficha</button>
  ),
}))
vi.mock('../modals/ModalVehiculo', () => ({ default: () => null }))
vi.mock('../modals/ModalFichaVehiculo', () => ({
  default: (props: { usadoPor?: string[] }) => {
    propsFicha.actual = props
    return <div>ficha del vehículo</div>
  },
}))

import VehiculosContainer from './VehiculosContainer'

async function abrirFicha() {
  const user = userEvent.setup()
  render(<VehiculosContainer />)
  await user.click(await screen.findByRole('button', { name: 'ver ficha' }))
  await screen.findByText('ficha del vehículo', {}, { timeout: 4000 })
  return propsFicha.actual as { usadoPor?: string[] }
}

describe('VehiculosContainer — quién usa el vehículo', () => {
  beforeEach(() => { propsFicha.actual = null })

  it('mientras carga la lista de empleados, usadoPor es undefined (no "nadie")', async () => {
    estado.empleados = { data: undefined, isSuccess: false, isError: false }
    expect((await abrirFicha()).usadoPor).toBeUndefined()
  })

  it('si la lista de empleados falla, usadoPor es undefined', async () => {
    estado.empleados = { data: undefined, isSuccess: false, isError: true }
    expect((await abrirFicha()).usadoPor).toBeUndefined()
  })

  it('con la lista cargada, usadoPor son los activos que lo tienen como habitual', async () => {
    estado.empleados = {
      isSuccess: true,
      isError: false,
      data: [
        { id: 1, nombre: 'Martín Sosa', usuario_id: null, vehiculo_id: 7, activo: true },
        { id: 2, nombre: 'Rosa Vieja', usuario_id: null, vehiculo_id: 7, activo: false },
        { id: 3, nombre: 'Juan Paz', usuario_id: null, vehiculo_id: 8, activo: true },
      ],
    }
    expect((await abrirFicha()).usadoPor).toEqual(['Martín Sosa'])
  })

  it('con la lista cargada y vacía, usadoPor es [] (ahí sí es "nadie")', async () => {
    estado.empleados = { data: [], isSuccess: true, isError: false }
    expect((await abrirFicha()).usadoPor).toEqual([])
  })
})
