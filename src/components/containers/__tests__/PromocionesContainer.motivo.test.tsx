/**
 * `PromocionesContainer` y el motivo del server (#1599, 1599-b1).
 *
 * Activar o desactivar una promo, desactivarla o borrarla dejaba un genérico
 * («Error al cambiar estado») aunque el server hubiera dicho por qué. Se monta
 * el container real con la vista reemplazada por botones que disparan los handlers.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  toggle: vi.fn(),
  actualizar: vi.fn(),
  notifyError: vi.fn(),
}))

const PROMO = { id: '1', nombre: 'Promo', tipo: 'bonificacion', activo: true, productos: [], reglas: [], usos_pendientes: 0 }

vi.mock('../../../hooks/queries', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    usePromocionesListQuery: () => ({ data: [PROMO], isLoading: false, isError: false, refetch: vi.fn() }),
    useProductosQuery: () => ({ data: [] }),
    useCrearPromocionMutation: mutacion,
    useActualizarPromocionMutation: () => ({ mutateAsync: mocks.actualizar, isPending: false }),
    useEliminarPromocionMutation: mutacion,
    useTogglePromocionActivaMutation: () => ({ mutateAsync: mocks.toggle, isPending: false }),
    usePromoUnidadesEntregadasQuery: () => ({ data: undefined }),
    usePromoAcumuladoresMapQuery: () => ({ data: undefined }),
    usePromoCuposQuery: () => ({ data: undefined }),
    contarReferenciasDePromocion: vi.fn(),
  }
})
vi.mock('../../../hooks/queries/useCombosQuery', () => ({
  useCombosAdminQuery: () => ({ data: [], isLoading: false, isError: false, refetch: vi.fn() }),
  useGuardarComboMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock('../../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { comboMargenMinimoPct: 10, comboDescuentoMaximoPct: 30 } }),
}))
vi.mock('../../../hooks/queries/useCategoriasQuery', () => ({
  useCategoriasQuery: () => ({ data: [] }),
  useSubcategoriasQuery: () => ({ data: [] }),
}))
vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ perfil: { rol: 'admin' } }),
}))
vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: mocks.notifyError, warning: vi.fn() }),
}))
vi.mock('../../vistas/VistaPromociones', () => ({
  default: (p: { promociones: unknown[]; onToggleActivo: (x: unknown) => void }) => (
    <button onClick={() => p.onToggleActivo(p.promociones[0])}>toggle</button>
  ),
}))

import PromocionesContainer from '../PromocionesContainer'

beforeEach(() => vi.clearAllMocks())

describe('PromocionesContainer — el motivo del server llega al usuario', () => {
  it('activar o desactivar muestra el motivo del server, no «Error al cambiar estado»', async () => {
    mocks.toggle.mockRejectedValue(new Error('Acceso denegado: se requiere rol admin'))
    render(<PromocionesContainer />)

    await userEvent.setup().click(await screen.findByRole('button', { name: 'toggle' }, { timeout: 5000 }))

    expect(mocks.notifyError).toHaveBeenCalledWith('Acceso denegado: se requiere rol admin')
  })

  it('algo que no es un Error cae al genérico', async () => {
    mocks.toggle.mockRejectedValue('boom')
    render(<PromocionesContainer />)

    await userEvent.setup().click(await screen.findByRole('button', { name: 'toggle' }, { timeout: 5000 }))

    expect(mocks.notifyError).toHaveBeenCalledWith('Error al cambiar estado')
  })
})
