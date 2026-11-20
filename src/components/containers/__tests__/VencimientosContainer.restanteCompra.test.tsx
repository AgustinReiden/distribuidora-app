/**
 * 1590-c (#1590): `VencimientosContainer` lee lo que le queda a la compra del lote
 * cuya devolución se abre, y la vista lo muestra («Le quedan $ X»). Container real,
 * vista real, hooks simulados: se fija que el hook recibe la compra del lote al
 * abrir y null al cerrar.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  restante: vi.fn(),
}))

vi.mock('../../../hooks/queries/useLotesQuery', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    useVencimientosQuery: () => ({
      data: [{
        lote_id: 7, producto_id: 107, producto_nombre: 'Agua del lote', producto_codigo: null,
        fecha_vencimiento: '2030-12-31', cantidad: 10, cantidad_restante: 10, dias_restantes: 0,
        origen: 'compra', compra_id: 55, stock_producto: 40, bolsa_producto: 0,
      }],
      isLoading: false, isFetching: false, isError: false, refetch: vi.fn(),
    }),
    useDarDeBajaLoteMutation: mutacion,
    useRegistrarNotaCreditoLoteMutation: mutacion,
  }
})

vi.mock('../../../hooks/queries/useNotasCreditoQuery', () => ({
  useRestanteDevolucionCompraQuery: (compraId: number | null) => mocks.restante(compraId),
}))

vi.mock('../../../hooks/queries/usePoliticasComercialesQuery', () => ({
  useParametrosVencimientoQuery: () => ({ diasAlertaVencimiento: 30, diasCriticoVencimiento: 15 }),
}))

vi.mock('../../../hooks/supabase/useAuth', () => ({
  useAuth: () => ({ isAdminOrEncargado: true }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalNombre: 'Tucumán' }),
}))

import VencimientosContainer from '../VencimientosContainer'

const ESPERA_VISTA = { timeout: 5000 }

beforeEach(() => {
  mocks.restante.mockReset()
  mocks.restante.mockImplementation((compraId: number | null) =>
    ({ data: compraId === 55 ? { compraId: 55, restante: 150 } : null }))
})

describe('VencimientosContainer — lo que le queda a la compra del lote', () => {
  it('al abrir la devolución lee la compra del lote y muestra lo que le queda; al cerrarla, la suelta', async () => {
    render(<VencimientosContainer />)
    const user = userEvent.setup()

    expect(mocks.restante).toHaveBeenLastCalledWith(null)
    await user.click(await screen.findByRole('button', { name: /Devolver al proveedor/ }, ESPERA_VISTA))

    expect(mocks.restante).toHaveBeenLastCalledWith(55)
    expect(screen.getByTestId('devolucion-restante-compra')).toHaveTextContent(/Le quedan \$\s?150,00 por acreditar/)

    await user.click(screen.getByRole('button', { name: 'Cancelar la devolución al proveedor' }))
    expect(mocks.restante).toHaveBeenLastCalledWith(null)
  })
})
