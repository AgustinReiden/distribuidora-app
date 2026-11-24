/**
 * gestion-B13 / infra-INF-9 (tanda 6, #1603): Vehículos y Personal fijaban el mes y el día al
 * montar. Con la pantalla abierta pasada la medianoche del 1.º seguían en el mes anterior.
 * (Gastos tiene su propio test en `__tests__/GastosContainer.mesMedianoche.test.tsx`.)
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act, cleanup, fireEvent } from '@testing-library/react'

const mocks = vi.hoisted(() => ({
  mesesPedidos: [] as string[],
  hoyDelModal: [] as string[],
}))

vi.mock('../../hooks/queries', () => ({
  useGastosDelMesQuery: (mes: string) => {
    mocks.mesesPedidos.push(mes)
    return { data: [] }
  },
  useGuardarVehiculoMutation: () => ({ mutateAsync: vi.fn() }),
  useRegistrarKmMutation: () => ({ mutateAsync: vi.fn() }),
  useVehiculoFichaQuery: () => ({ data: { gastos: [], lecturas: [] }, isLoading: false }),
  useVehiculosQuery: () => ({ data: [], isLoading: false }),
  useEmpleadosParaElegirQuery: () => ({ data: [], isSuccess: true, isError: false }),
  usePersonalQuery: () => ({ data: [], isLoading: false, error: null, refetch: vi.fn() }),
  useGuardarEmpleadoMutation: () => ({ mutateAsync: vi.fn() }),
  useReactivarEmpleadoMutation: () => ({ mutateAsync: vi.fn() }),
  useDarDeBajaEmpleadoMutation: () => ({ mutateAsync: vi.fn() }),
  useUsuariosQuery: () => ({ data: [] }),
  useClientesQuery: () => ({ data: [] }),
  useSucursalesActivasQuery: () => ({ data: [] }),
}))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => ({ success: vi.fn(), error: vi.fn() }) }))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    currentSucursalId: 1,
    currentSucursalNombre: 'Tucumán',
    sucursales: [{ id: 1, nombre: 'Tucumán', rol: 'admin' }],
  }),
}))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({ user: { id: 'u-yo' } }) }))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))
vi.mock('../vistas/VistaVehiculos', () => ({ default: () => <div>vista de vehículos</div> }))
vi.mock('../modals/ModalVehiculo', () => ({ default: () => null }))
vi.mock('../modals/ModalFichaVehiculo', () => ({ default: () => null }))
vi.mock('../vistas/VistaPersonal', () => ({
  default: ({ onNuevo }: { onNuevo: () => void }) => <button type="button" onClick={onNuevo}>nuevo</button>,
}))
vi.mock('../modals/ModalEmpleado', () => ({
  default: ({ hoy }: { hoy: string }) => {
    mocks.hoyDelModal.push(hoy)
    return <div>hoy del modal {hoy}</div>
  },
}))
vi.mock('../modals/ModalCuentaEmpleado', () => ({ default: () => null }))
vi.mock('../modals/ModalBajaEmpleado', () => ({ default: () => null }))

import VehiculosContainer from './VehiculosContainer'
import PersonalContainer from './PersonalContainer'

describe('Vehículos y Personal · el día cruza la medianoche', () => {
  beforeEach(() => {
    mocks.mesesPedidos.length = 0
    mocks.hoyDelModal.length = 0
  })
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it('Vehículos: abierta el 30/11 de noche, pasada la medianoche pide los gastos de diciembre', async () => {
    vi.useFakeTimers({ toFake: ['Date', 'setInterval', 'clearInterval'] })
    vi.setSystemTime(new Date('2026-11-30T23:58:00-03:00'))
    render(<VehiculosContainer />)
    expect(await screen.findByText('vista de vehículos')).toBeInTheDocument()
    expect(mocks.mesesPedidos[mocks.mesesPedidos.length - 1]).toBe('2026-11-01')

    await act(async () => { vi.setSystemTime(new Date('2026-12-01T00:01:00-03:00')); vi.advanceTimersByTime(61_000) })

    expect(mocks.mesesPedidos[mocks.mesesPedidos.length - 1]).toBe('2026-12-01')
  })

  it('Personal: el día que recibe el modal sigue al reloj', async () => {
    vi.useFakeTimers({ toFake: ['Date', 'setInterval', 'clearInterval'] })
    vi.setSystemTime(new Date('2026-11-30T23:58:00-03:00'))
    render(<PersonalContainer />)
    fireEvent.click(await screen.findByRole('button', { name: 'nuevo' }))
    expect(await screen.findByText('hoy del modal 2026-11-30')).toBeInTheDocument()

    await act(async () => { vi.setSystemTime(new Date('2026-12-01T00:01:00-03:00')); vi.advanceTimersByTime(61_000) })

    expect(await screen.findByText('hoy del modal 2026-12-01')).toBeInTheDocument()
  })
})
