/**
 * H3 de la revisión de C2 (ola 2 de #1603): si la consulta de las sustituciones de regalo del
 * pedido falla, `data` queda vacía sin «cargando» y el Guardar se habilitaba: el regalo viajaba
 * con el producto final y la cantidad de la promo, el server lo leía como la línea de hoy
 * (1592-b1) y lo rechazaba por el tope, o lo guardaba sin su cadena. Ahora no se guardan los
 * ítems hasta que carguen, y se ofrece reintentar. Mismo molde que FRV-2
 * (`ModalEditarPedido.datosCaidos.test.tsx`).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

type Q = { data?: unknown; isLoading?: boolean; isFetching?: boolean; isError?: boolean; isPaused?: boolean; refetch: () => unknown }

const { estado, refetch } = vi.hoisted(() => {
  const refetchFn = vi.fn()
  const ok = (data: unknown): Q => ({ data, isLoading: false, isFetching: false, isError: false, isPaused: false, refetch: refetchFn })
  return { refetch: refetchFn, estado: { ok, sust: ok([]) } }
})

vi.mock('../../hooks/queries/useCombosQuery', () => ({
  useCombosVigentesQuery: () => ({ data: [], isLoading: false, isError: false }),
  useFotosCombosPedidoQuery: () => ({ data: [], isLoading: false, isError: false }),
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
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: new Map(), isLoading: false, isError: false }),
}))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false, isError: false, refetch: vi.fn() }),
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
  usePedidoSustitucionesQuery: () => estado.sust,
  usePromoCuposQuery: () => ({ data: undefined }),
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: new Map(), isLoading: false, isError: false }),
}))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: true } }),
}))

import ModalEditarPedido from './ModalEditarPedido'

const productos = [{ id: '1', nombre: 'Producto 1', codigo: 'P001', precio: 250, stock: 100, categoria: 'Snacks' }] as any[]
const pedido = {
  id: 602, notas: '', estado: 'en_preparacion', total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [{ id: '10', producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' } }],
} as any

const onSave = vi.fn().mockResolvedValue(undefined)
const onSaveItems = vi.fn().mockResolvedValue(undefined)
const props = { productos, isAdmin: true, onSave, onSaveItems, onClose: vi.fn(), guardando: false }
const botonesMas = () => Array.from(document.body.querySelectorAll('button.rounded-r-lg')) as HTMLButtonElement[]

async function tocarCantidad() {
  const user = userEvent.setup()
  render(<ModalEditarPedido {...props} pedido={pedido} />)
  await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
  await user.click(botonesMas()[0])
  return user
}

beforeEach(() => {
  refetch.mockClear()
  onSave.mockClear()
  onSaveItems.mockClear()
  estado.sust = estado.ok([])
})

describe('ModalEditarPedido — las sustituciones de regalo no cargaron (H3 de la revisión de C2)', () => {
  it('con la consulta en error, Guardar Todo queda deshabilitado, dice por qué y no manda nada', async () => {
    estado.sust = { data: undefined, isLoading: false, isFetching: false, isError: true, isPaused: false, refetch }
    const user = await tocarCantidad()

    const boton = await screen.findByRole('button', { name: 'Guardar Todo' })
    expect(boton).toBeDisabled()
    expect(screen.getByRole('alert')).toHaveTextContent('No se pudieron cargar los cambios de regalo del pedido')
    await user.click(boton)
    expect(onSaveItems).not.toHaveBeenCalled()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('"Reintentar" vuelve a pedir las sustituciones', async () => {
    estado.sust = { data: undefined, isLoading: false, isFetching: false, isError: true, isPaused: false, refetch }
    const user = await tocarCantidad()

    await user.click(await screen.findByRole('button', { name: 'Reintentar' }))
    expect(refetch).toHaveBeenCalled()
  })

  it('con la consulta caída, guardar sólo una nota sigue funcionando', async () => {
    estado.sust = { data: undefined, isLoading: false, isFetching: false, isError: true, isPaused: false, refetch }
    const user = userEvent.setup()
    render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    await user.type(screen.getByPlaceholderText(/Observaciones importantes/), 'Dejar con el encargado')
    const guardar = screen.getByRole('button', { name: 'Guardar' })
    expect(guardar).toBeEnabled()
    await user.click(guardar)

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('con las sustituciones cargadas se guarda', async () => {
    const user = await tocarCantidad()
    const boton = await screen.findByRole('button', { name: 'Guardar Todo' })
    await waitFor(() => expect(boton).toBeEnabled())
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    await user.click(boton)
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
  })
})
