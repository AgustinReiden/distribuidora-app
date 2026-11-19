/**
 * ModalEditarPedido y «Salir sin guardar» (decisión 4 del dueño, #1603): la X, Escape y el «atrás» del
 * teléfono preguntan si lo editado difiere de lo guardado (renglones, notas, fechas); una edición sin
 * tocar —o que volvió a lo guardado— cierra de una. Historial real de jsdom.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, waitFor, cleanup, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { reiniciarAtrasModales } from '../../utils/atrasModales'

vi.mock('../../hooks/queries/useCombosQuery', () => ({
  useCombosVigentesQuery: () => ({ data: [], isLoading: false }),
  useFotosCombosPedidoQuery: () => ({ data: [] }),
  useNombresCombosQuery: () => ({ data: new Map() }),
}))
vi.mock('../../lib/supabase', () => ({
  supabase: {
    from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
}))
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({ usePricingMapQuery: () => ({ data: new Map(), isLoading: false }) }))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoCuposQuery: () => ({ data: undefined }),
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false }),
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
  usePedidoSustitucionesQuery: () => ({ data: [], isLoading: false }),
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({ useMinimosVentaQuery: () => ({ data: new Map(), isLoading: false }) }))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({ usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: true } }) }))

import ModalEditarPedido from './ModalEditarPedido'

const productos = [{ id: '1', nombre: 'Producto de prueba', codigo: 'P001', precio: 250, stock: 20, categoria: 'Snacks' }] as never[]
const pedido = {
  id: 601, notas: 'Entregar por la mañana', estado: 'en_preparacion', total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco de prueba', direccion: 'Calle 1' },
  items: [{ producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto de prueba' } }],
} as never

const asentar = () => act(async () => { await new Promise(r => setTimeout(r, 150)) })
const atras = async () => { act(() => { window.history.back() }); await asentar() }
const cant = () => screen.getByLabelText('Cantidad') as HTMLInputElement

async function abrir() {
  const onClose = vi.fn()
  const user = userEvent.setup()
  render(
    <ModalEditarPedido productos={productos} pedido={pedido} isAdmin onSave={vi.fn()} onSaveItems={vi.fn()}
      onClose={onClose} guardando={false} />,
  )
  await waitFor(() => screen.getByText('Producto de prueba'))
  await asentar()
  return { onClose, user }
}

beforeEach(() => {
  reiniciarAtrasModales()
  window.history.replaceState(null, '', '/')
})
afterEach(async () => {
  cleanup()
  await asentar()
  reiniciarAtrasModales()
})

describe('ModalEditarPedido · salir sin guardar', () => {
  it('una edición sin tocar cierra de una con el «atrás», la X y Escape', async () => {
    const { onClose, user } = await abrir()
    await atras()
    expect(onClose).toHaveBeenCalledTimes(1)

    await user.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalledTimes(2)
    expect(screen.queryByRole('button', { name: 'Salir igual' })).not.toBeInTheDocument()
  })

  it.each([
    ['la cantidad de un renglón', async (user: ReturnType<typeof userEvent.setup>) => {
      await user.clear(cant()); await user.type(cant(), '12'); await user.tab()
    }],
    ['las notas', async (user: ReturnType<typeof userEvent.setup>) => {
      await user.type(screen.getByPlaceholderText(/Observaciones importantes/), ' y llamar antes')
    }],
  ])('con %s cambiadas, el «atrás» pregunta; «Seguir editando» las conserva y «Salir igual» cierra', async (_que, cambiar) => {
    const { onClose, user } = await abrir()
    await cambiar(user)
    await asentar()

    await atras()
    expect(await screen.findByRole('button', { name: 'Salir igual' })).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: 'Seguir editando' }))
    await asentar()
    expect(onClose).not.toHaveBeenCalled()

    await atras()
    await user.click(await screen.findByRole('button', { name: 'Salir igual' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('con la cantidad cambiada, la X y Escape preguntan lo mismo que el «atrás»', async () => {
    const { onClose, user } = await abrir()
    await user.clear(cant()); await user.type(cant(), '12'); await user.tab()
    await asentar()

    await user.keyboard('{Escape}')
    expect(await screen.findByRole('button', { name: 'Salir igual' })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Seguir editando' }))
    await asentar()
    await user.click(screen.getByRole('button', { name: /cerrar/i }))
    expect(await screen.findByRole('button', { name: 'Salir igual' })).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })

  it('si lo editado vuelve a lo guardado, ya no hay cambios y no pregunta', async () => {
    const { onClose, user } = await abrir()
    await user.clear(cant()); await user.type(cant(), '12'); await user.tab()
    await user.clear(cant()); await user.type(cant(), '10'); await user.tab()
    await asentar()

    await atras()
    expect(onClose).toHaveBeenCalledTimes(1)
    expect(screen.queryByRole('button', { name: 'Salir igual' })).not.toBeInTheDocument()
  })
})
