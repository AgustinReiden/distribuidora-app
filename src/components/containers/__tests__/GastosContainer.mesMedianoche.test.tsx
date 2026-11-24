/**
 * gestion-B13 / infra-INF-9 (tanda 6, #1603): `GastosContainer` fijaba el mes al montar. Con la
 * pantalla abierta pasada la medianoche del último día del mes, seguía en el mes anterior hasta
 * recargar. Ahora el mes de hoy sigue al reloj; sólo queda fijo un mes que el usuario eligió a mano.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act, cleanup } from '@testing-library/react'

const mocks = vi.hoisted(() => ({
  mesesPedidos: [] as string[],
  cambiarMes: null as null | ((m: string) => void),
}))

vi.mock('../../../hooks/queries', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    useGastosDelMesQuery: (mes: string) => {
      mocks.mesesPedidos.push(mes)
      return { data: [], isLoading: false, isError: false, refetch: vi.fn() }
    },
    useGuardarGastoMutation: mutacion,
    useAnularGastoMutation: mutacion,
    useRubrosGastoQuery: () => ({ data: [] }),
    useGuardarRubroGastoMutation: mutacion,
    useVehiculosQuery: () => ({ data: [] }),
    useSucursalesActivasQuery: () => ({ data: [] }),
    useTransportistasQuery: () => ({ data: [] }),
    useRendicionesCerradasQuery: () => ({ data: undefined }),
    useEmpleadosParaElegirQuery: () => ({ data: [] }),
  }
})

vi.mock('../../../hooks/usePropsModalGasto', () => ({
  usePropsModalGasto: () => ({
    sucursalActual: { id: 1, nombre: 'Sucursal Uno' },
    tieneTodasLasSucursales: false,
  }),
}))
vi.mock('../../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))
vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true, user: { id: 'u1' } }),
}))
vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))
vi.mock('../../vistas/VistaGastos', () => ({
  default: ({ mes, onCambiarMes }: { mes: string; onCambiarMes: (m: string) => void }) => {
    mocks.cambiarMes = onCambiarMes
    return <div>mes mostrado {mes}</div>
  },
}))

import GastosContainer from '../GastosContainer'

describe('GastosContainer · el mes de hoy cruza la medianoche', () => {
  beforeEach(() => {
    vi.useFakeTimers({ toFake: ['Date', 'setInterval', 'clearInterval'] })
    mocks.mesesPedidos.length = 0
  })
  afterEach(() => {
    cleanup()
    vi.useRealTimers()
  })

  it('abierta el 30/11 de noche, pasada la medianoche pasa a diciembre', async () => {
    vi.setSystemTime(new Date('2026-11-30T23:58:00-03:00'))
    render(<GastosContainer />)
    expect(await screen.findByText('mes mostrado 2026-11-01')).toBeInTheDocument()

    await act(async () => { vi.setSystemTime(new Date('2026-12-01T00:01:00-03:00')); vi.advanceTimersByTime(61_000) })

    expect(await screen.findByText('mes mostrado 2026-12-01')).toBeInTheDocument()
    expect(mocks.mesesPedidos[mocks.mesesPedidos.length - 1]).toBe('2026-12-01')
  })

  it('un mes elegido a mano no se mueve solo', async () => {
    vi.setSystemTime(new Date('2026-11-30T23:58:00-03:00'))
    render(<GastosContainer />)
    await screen.findByText('mes mostrado 2026-11-01')

    await act(async () => { mocks.cambiarMes?.('2026-09-01') })
    expect(await screen.findByText('mes mostrado 2026-09-01')).toBeInTheDocument()

    await act(async () => { vi.setSystemTime(new Date('2026-12-01T00:01:00-03:00')); vi.advanceTimersByTime(61_000) })
    expect(screen.getByText('mes mostrado 2026-09-01')).toBeInTheDocument()
  })
})
