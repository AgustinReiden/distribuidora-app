/**
 * `GastosContainer` con la query caída (#1561, 1561-b15).
 *
 * Si `useGastosDelMesQuery` fallaba, el container no leía `isError`: la lista quedaba en `[]`
 * y la vista decía «No hay gastos en {mes}», como si el mes estuviera vacío. Ahora, con la
 * carga fallida y sin gastos, va el error con «Reintentar» (el `refetch` de la query).
 *
 * Se monta el container REAL con la vista real y los hooks simulados.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  gastos: vi.fn(),
}))

vi.mock('../../../hooks/queries', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    useGastosDelMesQuery: () => mocks.gastos(),
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

vi.mock('../../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: () => undefined,
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true, user: { id: 'u1' } }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))

import GastosContainer from '../GastosContainer'

// La vista es lazy: la primera vez que se monta en la corrida el import en frío
// se come casi todo el segundo por defecto de `findBy*`.
const ESPERA_VISTA = { timeout: 5000 }

const refetch = vi.fn()

// El container abre en el mes de hoy: el gasto cae en ese mes, sea cual sea la fecha de la corrida.
const hoy = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Tucuman' })
const gasto = {
  id: 1,
  fecha: hoy,
  mes_imputado: `${hoy.slice(0, 7)}-01`,
  repartir_meses: 1,
  costo: 1500,
  rubro_id: 1,
  rubro: { id: 1, nombre: 'Combustible', grupo: 'logistica' },
  comprobante: 'ticket',
  origen_pago: 'oficina',
  compartido: false,
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('GastosContainer — la carga de los gastos falló (#1561)', () => {
  it('con la query en error y sin gastos, muestra el error y NO «No hay gastos»', async () => {
    mocks.gastos.mockReturnValue({ data: undefined, isLoading: false, isError: true, refetch })
    render(<GastosContainer />)

    expect(await screen.findByRole('alert', undefined, ESPERA_VISTA)).toHaveTextContent('No se pudo cargar')
    expect(screen.queryByText(/No hay gastos/)).not.toBeInTheDocument()
  })

  it('«Reintentar» llama al refetch de la query', async () => {
    mocks.gastos.mockReturnValue({ data: undefined, isLoading: false, isError: true, refetch })
    render(<GastosContainer />)

    await userEvent.setup().click(await screen.findByRole('button', { name: 'Reintentar' }, ESPERA_VISTA))
    expect(refetch).toHaveBeenCalledTimes(1)
  })

  it('con la carga caída el encabezado y las tarjetas no dicen «0 GASTOS» ni «$0», y Exportar no baja un mes vacío (H7)', async () => {
    mocks.gastos.mockReturnValue({ data: undefined, isLoading: false, isError: true, refetch })
    render(<GastosContainer />)

    await screen.findByRole('alert', undefined, ESPERA_VISTA)
    expect(document.body.textContent).not.toMatch(/(^|\s)0 GASTOS/)
    expect(screen.getByTestId('total-todos')).toHaveTextContent('—')
    expect(screen.getByTestId('total-todos')).not.toHaveTextContent('$')
    expect(screen.getByTestId('total-vehiculos')).not.toHaveTextContent('$')
    expect(screen.getByRole('button', { name: /Exportar/ })).toBeDisabled()
  })

  it('con gastos en caché y un refetch que falló, manda la lista, no el error', async () => {
    mocks.gastos.mockReturnValue({ data: [gasto], isLoading: false, isError: true, refetch })
    render(<GastosContainer />)

    expect(await screen.findByTestId('gasto-1', undefined, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('sin error y sin gastos sigue diciendo que no hay (el vacío de verdad no se rompe)', async () => {
    mocks.gastos.mockReturnValue({ data: [], isLoading: false, isError: false, refetch })
    render(<GastosContainer />)

    expect(await screen.findByText(/No hay gastos en/, undefined, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
