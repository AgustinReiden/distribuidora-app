/**
 * `PromocionesContainer` con las queries caídas (#1517, FRT-3).
 *
 * Si `usePromocionesListQuery` fallaba tras agotar los reintentos, la pestaña
 * Regalos decía "Sin promociones" con su botón "Crear primera promocion", como si
 * no hubiera ninguna. Lo mismo la pestaña Combos con `useCombosAdminQuery`
 * ("Sin combos"). Ahora el listado lo reemplaza `QueryErrorState`
 * (role="alert" + "Reintentar").
 *
 * Se monta el container REAL con las vistas reales y los hooks simulados. Lo que
 * se fija, en cada pestaña:
 *  - query en error y sin datos: se ve el error, NO el vacío;
 *  - "Reintentar" llama al `refetch` de ESA query (no al de la otra);
 *  - query en error pero CON datos en caché: se ve la lista, no el error;
 * y que el error de una pestaña no se cuela en la otra.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  usePromocionesListQuery: vi.fn(),
  useCombosAdminQuery: vi.fn(),
}))

vi.mock('../../../hooks/queries', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    usePromocionesListQuery: () => mocks.usePromocionesListQuery(),
    useProductosQuery: () => ({ data: [] }),
    useCrearPromocionMutation: mutacion,
    useActualizarPromocionMutation: mutacion,
    useEliminarPromocionMutation: mutacion,
    useTogglePromocionActivaMutation: mutacion,
    usePromoUnidadesEntregadasQuery: () => ({ data: undefined }),
    usePromoAcumuladoresMapQuery: () => ({ data: undefined }),
    usePromoCuposQuery: () => ({ data: undefined }),
    contarReferenciasDePromocion: vi.fn(),
  }
})

vi.mock('../../../hooks/queries/useCombosQuery', () => ({
  useCombosAdminQuery: () => mocks.useCombosAdminQuery(),
  useGuardarComboMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))

vi.mock('../../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({
    politicas: { comboMargenMinimoPct: 10, comboDescuentoMaximoPct: 30 },
  }),
}))

vi.mock('../../../hooks/queries/useCategoriasQuery', () => ({
  useCategoriasQuery: () => ({ data: [] }),
  useSubcategoriasQuery: () => ({ data: [] }),
}))

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ perfil: { rol: 'admin' } }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))

import PromocionesContainer from '../PromocionesContainer'

// Las vistas son lazy: la primera vez que se montan en la corrida el import en
// frío se come casi todo el segundo por defecto de `findBy*`.
const ESPERA_VISTA = { timeout: 5000 }

const refetchPromos = vi.fn()
const refetchCombos = vi.fn()

const promo = {
  id: '1',
  nombre: 'Promo en caché',
  tipo: 'bonificacion',
  activo: true,
  fecha_inicio: '2026-09-01',
  fecha_fin: null,
  created_at: '2026-09-01T00:00:00Z',
  updated_at: '2026-09-01T00:00:00Z',
  productos: [],
  reglas: [],
  usos_pendientes: 0,
}

const combo = {
  id: '500',
  nombre: 'Combo en caché',
  activo: true,
  fechaInicio: '2026-01-01',
  fechaFin: null,
  precio: 11000,
  combinaEscalas: false,
  prioridad: 0,
  topeCombos: null,
  productoAMoverId: null,
  componentes: [{ cantidad: 1, sueltos: ['10'], categorias: [] }],
}

const consulta = (extra: Record<string, unknown>) => ({
  data: undefined, isLoading: false, isError: false, ...extra,
})

beforeEach(() => {
  refetchPromos.mockReset()
  refetchCombos.mockReset()
  mocks.usePromocionesListQuery.mockReset()
  mocks.useCombosAdminQuery.mockReset()
  // Por defecto las dos andan: cada caso rompe la que quiere probar.
  mocks.usePromocionesListQuery.mockReturnValue(consulta({ data: [], refetch: refetchPromos }))
  mocks.useCombosAdminQuery.mockReturnValue(consulta({ data: [], refetch: refetchCombos }))
})

describe('PromocionesContainer — pestaña Regalos con la query caída', () => {
  it('sin promociones muestra el error y no "Sin promociones"', async () => {
    mocks.usePromocionesListQuery.mockReturnValue(consulta({ isError: true, refetch: refetchPromos }))
    render(<PromocionesContainer />)

    expect(await screen.findByRole('alert', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeInTheDocument()
    expect(screen.queryByText('Sin promociones')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Crear primera promocion' })).not.toBeInTheDocument()
  })

  it('"Reintentar" vuelve a pedir la query de promociones, no la de combos', async () => {
    mocks.usePromocionesListQuery.mockReturnValue(consulta({ isError: true, refetch: refetchPromos }))
    render(<PromocionesContainer />)

    const user = userEvent.setup()
    await user.click(await screen.findByRole('button', { name: 'Reintentar' }, ESPERA_VISTA))
    expect(refetchPromos).toHaveBeenCalledTimes(1)
    expect(refetchCombos).not.toHaveBeenCalled()
  })

  it('con promociones en caché y el refetch fallido, se ven y no hay error', async () => {
    mocks.usePromocionesListQuery.mockReturnValue(consulta({ data: [promo], isError: true, refetch: refetchPromos }))
    render(<PromocionesContainer />)

    expect(await screen.findByRole('heading', { name: 'Promo en caché' }, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('sin error y sin promociones sigue diciendo "Sin promociones"; el error de combos no se cuela', async () => {
    mocks.useCombosAdminQuery.mockReturnValue(consulta({ isError: true, refetch: refetchCombos }))
    render(<PromocionesContainer />)

    expect(await screen.findByText('Sin promociones', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})

describe('PromocionesContainer — pestaña Combos con la query caída', () => {
  async function irACombos() {
    const user = userEvent.setup()
    render(<PromocionesContainer />)
    await user.click(await screen.findByRole('tab', { name: 'Combos' }))
    return user
  }

  it('sin combos muestra el error y no "Sin combos"', async () => {
    mocks.useCombosAdminQuery.mockReturnValue(consulta({ isError: true, refetch: refetchCombos }))
    await irACombos()

    expect(await screen.findByRole('alert', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeInTheDocument()
    expect(screen.queryByText('Sin combos')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Nuevo combo' })).toBeInTheDocument()
  })

  it('"Reintentar" vuelve a pedir la query de combos, no la de promociones', async () => {
    mocks.useCombosAdminQuery.mockReturnValue(consulta({ isError: true, refetch: refetchCombos }))
    const user = await irACombos()

    await user.click(await screen.findByRole('button', { name: 'Reintentar' }, ESPERA_VISTA))
    expect(refetchCombos).toHaveBeenCalledTimes(1)
    expect(refetchPromos).not.toHaveBeenCalled()
  })

  it('con combos en caché y el refetch fallido, se ven y no hay error', async () => {
    mocks.useCombosAdminQuery.mockReturnValue(consulta({ data: [combo], isError: true, refetch: refetchCombos }))
    await irACombos()

    expect(await screen.findByRole('heading', { name: 'Combo en caché' }, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('sin error y sin combos sigue diciendo "Sin combos"; el error de promociones no se cuela', async () => {
    mocks.usePromocionesListQuery.mockReturnValue(consulta({ isError: true, refetch: refetchPromos }))
    await irACombos()

    expect(await screen.findByText('Sin combos', {}, ESPERA_VISTA)).toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
