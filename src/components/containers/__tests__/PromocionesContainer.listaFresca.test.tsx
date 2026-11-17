/**
 * Editar una promo, y editar o activar un combo, parten de la base y no de la lista
 * en caché (#1599, 1599-b8).
 *
 * `guardar_combo` y `cambiar_regalo_promocion` reescriben la entidad entera con lo
 * que manda el formulario. La lista tiene hasta 2 minutos de caché: si otro admin
 * cambió el nombre o los productos en el medio, guardar desde la lista vieja lo
 * pisaba. Ahora, antes de abrir el editor o de reactivar, se relee.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const mocks = vi.hoisted(() => ({
  refetchPromos: vi.fn(),
  refetchCombos: vi.fn(),
  guardarCombo: vi.fn(),
  notifyError: vi.fn(),
  notifyWarning: vi.fn(),
}))

const PROMO_VIEJA = { id: '1', nombre: 'Promo vieja', tipo: 'bonificacion', activo: true, productos: [], reglas: [], usos_pendientes: 0 }
const PROMO_FRESCA = { ...PROMO_VIEJA, nombre: 'Promo fresca' }
const comboBase = {
  id: '500', activo: false, fechaInicio: '2026-01-01', fechaFin: null, precio: 11000,
  combinaEscalas: false, prioridad: 0, topeCombos: null, productoAMoverId: null,
  componentes: [{ cantidad: 1, sueltos: ['10'], categorias: [] }],
}
const COMBO_VIEJO = { ...comboBase, nombre: 'Combo viejo' }
const COMBO_FRESCO = { ...comboBase, nombre: 'Combo fresco' }

vi.mock('../../../hooks/queries', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    usePromocionesListQuery: () => ({ data: [PROMO_VIEJA], isLoading: false, isError: false, refetch: mocks.refetchPromos }),
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
  useCombosAdminQuery: () => ({ data: [COMBO_VIEJO], isLoading: false, isError: false, refetch: mocks.refetchCombos }),
  useGuardarComboMutation: () => ({ mutateAsync: mocks.guardarCombo, isPending: false }),
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
  useNotification: () => ({ success: vi.fn(), error: mocks.notifyError, warning: mocks.notifyWarning }),
}))

vi.mock('../../vistas/VistaPromociones', () => ({
  default: (p: { promociones: unknown[]; onEditarPromocion: (x: unknown) => void }) => (
    <button onClick={() => p.onEditarPromocion(p.promociones[0])}>editar promo</button>
  ),
}))
vi.mock('../../modals/ModalPromocion', () => ({
  default: (p: { promocion: { nombre: string } | null }) => <div>editando: {p.promocion?.nombre}</div>,
}))
vi.mock('../../vistas/VistaCombos', () => ({
  default: (p: { combos: unknown[]; onEditarCombo: (x: unknown) => void; onToggleActivo: (x: unknown) => void }) => (
    <div>
      <button onClick={() => p.onEditarCombo(p.combos[0])}>editar combo</button>
      <button onClick={() => p.onToggleActivo(p.combos[0])}>activar combo</button>
    </div>
  ),
}))
vi.mock('../../modals/ModalCombo', () => ({
  default: (p: { combo: { nombre: string } | null }) => <div>editando combo: {p.combo?.nombre}</div>,
}))

import PromocionesContainer from '../PromocionesContainer'

const ESPERA = { timeout: 5000 }

beforeEach(() => {
  vi.clearAllMocks()
  mocks.refetchPromos.mockResolvedValue({ data: [PROMO_FRESCA] })
  mocks.refetchCombos.mockResolvedValue({ data: [COMBO_FRESCO] })
  mocks.guardarCombo.mockResolvedValue('500')
})

async function irACombos() {
  const user = userEvent.setup()
  render(<PromocionesContainer />)
  await user.click(await screen.findByRole('tab', { name: 'Combos' }, ESPERA))
  return user
}

describe('PromocionesContainer — parte de la base, no de la lista en caché', () => {
  it('editar una promo abre el editor con la versión fresca', async () => {
    const user = userEvent.setup()
    render(<PromocionesContainer />)
    await user.click(await screen.findByRole('button', { name: 'editar promo' }, ESPERA))

    expect(await screen.findByText('editando: Promo fresca', {}, ESPERA)).toBeInTheDocument()
    expect(mocks.refetchPromos).toHaveBeenCalledWith({ throwOnError: true })
  })

  it('si no se puede traer la promo fresca, no abre el editor y lo dice', async () => {
    mocks.refetchPromos.mockRejectedValue(new Error('red'))
    const user = userEvent.setup()
    render(<PromocionesContainer />)
    await user.click(await screen.findByRole('button', { name: 'editar promo' }, ESPERA))

    expect(mocks.notifyError).toHaveBeenCalledWith(expect.stringMatching(/versión actual de la promoción/))
    expect(screen.queryByText(/editando:/)).not.toBeInTheDocument()
  })

  it('editar un combo abre el editor con la versión fresca', async () => {
    const user = await irACombos()
    await user.click(await screen.findByRole('button', { name: 'editar combo' }, ESPERA))

    expect(await screen.findByText('editando combo: Combo fresco', {}, ESPERA)).toBeInTheDocument()
  })

  it('activar un combo manda el combo fresco, no el de la lista vieja', async () => {
    const user = await irACombos()
    await user.click(await screen.findByRole('button', { name: 'activar combo' }, ESPERA))

    await vi.waitFor(() => expect(mocks.guardarCombo).toHaveBeenCalledTimes(1))
    const input = mocks.guardarCombo.mock.calls[0][0]
    expect(input.nombre).toBe('Combo fresco')
    expect(input.activo).toBe(true)
    expect(input.id).toBe('500')
  })

  it('si el combo ya estaba activo (otro lo activó), avisa y no escribe', async () => {
    mocks.refetchCombos.mockResolvedValue({ data: [{ ...COMBO_FRESCO, activo: true }] })
    const user = await irACombos()
    await user.click(await screen.findByRole('button', { name: 'activar combo' }, ESPERA))

    await vi.waitFor(() => expect(mocks.notifyWarning).toHaveBeenCalledWith(expect.stringMatching(/ya estaba activo/)))
    expect(mocks.guardarCombo).not.toHaveBeenCalled()
  })

  it('si no se puede releer, no reactiva con lo viejo', async () => {
    mocks.refetchCombos.mockRejectedValue(new Error('red'))
    const user = await irACombos()
    await user.click(await screen.findByRole('button', { name: 'activar combo' }, ESPERA))

    await vi.waitFor(() => expect(mocks.notifyError).toHaveBeenCalledWith(expect.stringMatching(/versión actual del combo/)))
    expect(mocks.guardarCombo).not.toHaveBeenCalled()
  })

  it('mientras relee la lista muestra «Verificando…» y un segundo toque no repite la lectura', async () => {
    let soltar: (v: unknown) => void = () => {}
    mocks.refetchCombos.mockReturnValue(new Promise(r => { soltar = r }))
    const user = await irACombos()
    const boton = await screen.findByRole('button', { name: 'editar combo' }, ESPERA)

    await user.click(boton)
    expect(await screen.findByRole('status')).toHaveTextContent('Verificando')
    await user.click(boton)
    expect(mocks.refetchCombos).toHaveBeenCalledTimes(1)

    soltar({ data: [COMBO_FRESCO] })
    expect(await screen.findByText('editando combo: Combo fresco', {}, ESPERA)).toBeInTheDocument()
    expect(screen.queryByRole('status')).not.toBeInTheDocument()
  })
})
