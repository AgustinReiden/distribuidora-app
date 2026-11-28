/**
 * `ConfiguracionContainer` con la consulta de políticas caída (#1561, 1561-b14).
 *
 * Si `usePoliticasComercialesQuery` fallaba sin datos, el hook devolvía los
 * valores por defecto ("sin política") como si fueran los de la sucursal, y
 * guardar una sección los escribía encima de los reales. Ahora la pantalla
 * muestra el error con "Reintentar" y no ofrece ningún formulario.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  usePoliticasComercialesQuery: vi.fn(),
}))

vi.mock('../../../hooks/queries/usePoliticasComercialesQuery', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    usePoliticasComercialesQuery: () => mocks.usePoliticasComercialesQuery(),
    useActualizarPoliticaMinimoMutation: mutacion,
    useActualizarComisionesDefaultMutation: mutacion,
    useActualizarAlertasVencimientoMutation: mutacion,
    useActualizarMostrarSinStockMutation: mutacion,
    useActualizarVentanaPrecioAnteriorMutation: mutacion,
    useActualizarAlertasCombosMutation: mutacion,
    useActualizarDiasAtrasFechaPedidoMutation: mutacion,
    useActualizarMultiploRedondeoPrecioMutation: mutacion,
    useActualizarComisionPctSimulacionMutation: mutacion,
    useImpactoMinimoQuery: () => ({ data: undefined, isFetching: false }),
  }
})

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))
vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1, currentSucursalNombre: 'Sucursal de prueba' }),
}))
vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true }),
}))
vi.mock('../../vistas/configuracion/PanelImpuestosInternos', () => ({
  default: () => <div>panel ii</div>,
}))

import ConfiguracionContainer from '../ConfiguracionContainer'

const ESPERA_VISTA = { timeout: 5000 }
const refetch = vi.fn()

const POR_DEFECTO = {
  montoMinimoPedido: 0,
  modoMinimoPedido: 'bloqueo',
  montoEnvioGratis: 0,
  cargoEnvioPedido: 0,
  comisionPctPreventista: 0,
  comisionPctOtros: 0,
  diasAlertaVencimiento: 60,
  diasCriticoVencimiento: 15,
  mostrarSinStock: true,
  ventanaPrecioAnteriorHoras: 24,
  comboMargenMinimoPct: 0,
  comboDescuentoMaximoPct: 0,
  diasAtrasFechaPedido: 7,
  multiploRedondeoPrecio: 1,
}

beforeEach(() => {
  refetch.mockReset()
  mocks.usePoliticasComercialesQuery.mockReset()
})

describe('ConfiguracionContainer — la consulta de políticas falló', () => {
  it('sin datos del servidor muestra el error y no los valores por defecto', async () => {
    mocks.usePoliticasComercialesQuery.mockReturnValue({
      politicas: POR_DEFECTO, data: undefined, isLoading: false, isError: true, refetch,
    })
    render(<ConfiguracionContainer />)

    expect(await screen.findByRole('alert')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeInTheDocument()
    // Ninguna sección editable: no hay nada que guardar encima de lo real.
    expect(screen.queryByRole('button', { name: 'Guardar' })).not.toBeInTheDocument()
    expect(screen.queryByText('Fecha del pedido hacia atrás')).not.toBeInTheDocument()
  })

  it('"Reintentar" vuelve a pedir la consulta', async () => {
    mocks.usePoliticasComercialesQuery.mockReturnValue({
      politicas: POR_DEFECTO, data: undefined, isLoading: false, isError: true, refetch,
    })
    render(<ConfiguracionContainer />)

    await userEvent.setup().click(await screen.findByRole('button', { name: 'Reintentar' }))
    expect(refetch).toHaveBeenCalledTimes(1)
  })

  it('con datos del servidor y un refetch fallido sigue mostrando la pantalla', async () => {
    mocks.usePoliticasComercialesQuery.mockReturnValue({
      politicas: { ...POR_DEFECTO, diasAtrasFechaPedido: 3 },
      data: { ...POR_DEFECTO, diasAtrasFechaPedido: 3 },
      isLoading: false, isError: true, refetch,
    })
    render(<ConfiguracionContainer />)

    expect(await screen.findByText('Fecha del pedido hacia atrás', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Reintentar' })).not.toBeInTheDocument()
  })
})
