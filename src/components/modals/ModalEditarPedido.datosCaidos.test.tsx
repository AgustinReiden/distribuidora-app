/**
 * FRV-2 (#1559): la edición de ítems no esperaba la foto de combos del pedido ni los errores de
 * los combos vigentes, del mapa de precios o de los mínimos. `actualizar_pedido_items` borra y
 * reinserta las líneas: un combo vencido cuya foto no cargó desaparece y sus líneas viajan a
 * precio suelto. Mismo molde que VTA-2 (`ModalEditarPedido.promosCaidas.test.tsx`).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

type Q = { data?: unknown; isLoading?: boolean; isError?: boolean; isPaused?: boolean; refetch: () => unknown }

const { estado, refetch } = vi.hoisted(() => {
  const refetchFn = vi.fn()
  const ok = (data: unknown): Q => ({ data, isLoading: false, isError: false, isPaused: false, refetch: refetchFn })
  return {
    refetch: refetchFn,
    estado: { ok, pricing: ok(new Map()), minimos: ok(new Map()), combos: ok([]), fotos: ok([]) },
  }
})

vi.mock('../../hooks/queries/useCombosQuery', () => ({
  useCombosVigentesQuery: () => estado.combos,
  useFotosCombosPedidoQuery: () => estado.fotos,
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
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({ usePricingMapQuery: () => estado.pricing }))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false, isError: false, refetch: vi.fn() }),
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
  usePedidoSustitucionesQuery: () => ({ data: [], isLoading: false, isFetching: false }),
  usePromoCuposQuery: () => ({ data: undefined }),
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({ useMinimosVentaQuery: () => estado.minimos }))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: true } }),
}))

import ModalEditarPedido from './ModalEditarPedido'

const productos = [{ id: '1', nombre: 'Producto 1', codigo: 'P001', precio: 250, stock: 100, categoria: 'Snacks' }] as any[]
const pedido = {
  id: 601, notas: '', estado: 'en_preparacion', total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [{ id: '10', producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' } }],
} as any

const onSave = vi.fn().mockResolvedValue(undefined)
const onSaveItems = vi.fn().mockResolvedValue(undefined)
const props = { productos, isAdmin: true, onSave, onSaveItems, onClose: vi.fn(), guardando: false }
const botonesMas = () => Array.from(document.body.querySelectorAll('button.rounded-r-lg')) as HTMLButtonElement[]
const sinDatos = (extra: Partial<Q> = {}): Q => ({ data: undefined, isLoading: false, isError: false, isPaused: false, refetch, ...extra })

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
  estado.pricing = estado.ok(new Map())
  estado.minimos = estado.ok(new Map())
  estado.combos = estado.ok([])
  estado.fotos = estado.ok([])
})

describe('ModalEditarPedido — foto de combos, combos vigentes, escalas y mínimos (FRV-2, #1559)', () => {
  it.each([
    ['la foto de combos del pedido', 'fotos', 'los combos del pedido'],
    ['los combos vigentes', 'combos', 'los combos'],
    ['el mapa de precios', 'pricing', 'las escalas mayoristas'],
    ['los mínimos de venta', 'minimos', 'los mínimos de venta'],
  ] as const)('con %s en error, Guardar Todo queda deshabilitado, dice por qué y no manda nada', async (_titulo, consulta, nombre) => {
    estado[consulta] = sinDatos({ isError: true })
    const user = await tocarCantidad()

    const boton = await screen.findByRole('button', { name: 'Guardar Todo' })
    expect(boton).toBeDisabled()
    expect(screen.getByRole('alert')).toHaveTextContent(`No se pudieron cargar ${nombre}`)
    await user.click(boton)
    expect(onSaveItems).not.toHaveBeenCalled()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('"Reintentar" vuelve a pedir la foto de combos', async () => {
    estado.fotos = sinDatos({ isError: true })
    const user = await tocarCantidad()

    await user.click(await screen.findByRole('button', { name: 'Reintentar' }))
    expect(refetch).toHaveBeenCalled()
  })

  it('con la foto de combos todavía cargando tampoco se mandan los ítems, ni se ofrece Reintentar', async () => {
    estado.fotos = sinDatos({ isLoading: true })
    const user = await tocarCantidad()

    const boton = await screen.findByRole('button', { name: 'Guardar Todo' })
    expect(boton).toBeDisabled()
    expect(screen.getByRole('alert')).toHaveTextContent('Todavía se están cargando los combos del pedido')
    expect(screen.queryByRole('button', { name: 'Reintentar' })).not.toBeInTheDocument()
    await user.click(boton)
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('con la consulta caída, guardar sólo una nota sigue funcionando (no toca los ítems)', async () => {
    estado.fotos = sinDatos({ isError: true })
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

  it('con todo cargado se guarda', async () => {
    const user = await tocarCantidad()
    const boton = await screen.findByRole('button', { name: 'Guardar Todo' })
    await waitFor(() => expect(boton).toBeEnabled())
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    await user.click(boton)
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
  })
})
