/**
 * Editar un pedido no le agrega un regalo que no tenía (PRM-2, #1515).
 *
 * Quitar una promo al cargar el pedido no deja rastro: el pedido queda sin su regalo. Al abrirlo
 * para editar, la promo volvía a disparar, aparecía el regalo y `bonifDifierenDeDB` prendía el
 * guardado solo, aunque se tocara sólo una nota. Ahora las promos que dispararían con las líneas
 * guardadas pero de las que el pedido no tiene regalo arrancan excluidas; el botón "Agregar" las
 * suma de vuelta.
 *
 * Se usa el `usePromocionPedido` de verdad, envuelto en un spy para ver el set de excluidas
 * (4º argumento) que le llega.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'

const { promo13, usePromocionPedidoSpy } = vi.hoisted(() => {
  const promo: PromocionActiva = {
    id: '13',
    nombre: 'Promo 10 + 2',
    tipo: 'bonificacion',
    productoIds: ['1'],
    reglas: { cantidad_compra: 10, cantidad_bonificacion: 2 },
    productoRegaloId: '81',
    prioridad: 0,
    regaloMueveStock: true,
    modoExclusion: 'acumulable',
  }
  return { promo13: promo, usePromocionPedidoSpy: vi.fn() }
})

vi.mock('../../hooks/usePromocionPedido', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../hooks/usePromocionPedido')>()
  usePromocionPedidoSpy.mockImplementation((...args: Parameters<typeof actual.usePromocionPedido>) =>
    actual.usePromocionPedido(...args))
  return { ...actual, usePromocionPedido: usePromocionPedidoSpy }
})
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
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  // La promo 13 está vigente para el producto 1, la pida el modal por id o no.
  usePromoMapQuery: () => ({ data: new Map([['1', [promo13]]]) as PromoMap, isLoading: false }),
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
  usePedidoSustitucionesQuery: () => ({ data: [], isLoading: false, isFetching: false }),
  usePromoCuposQuery: () => ({ data: undefined }),
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: true } }),
}))

import ModalEditarPedido from './ModalEditarPedido'

const productos = [
  { id: '1', nombre: 'Producto 1', codigo: 'P001', precio: 250, stock: 100, categoria: 'Snacks' },
  { id: '81', nombre: 'Manaos 3L', codigo: 'P081', precio: 1000, stock: 500, categoria: 'Bebidas' },
] as any[]

const ventaDe = (cantidad: number) => ({
  producto_id: '1', cantidad, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' },
})
const regalo = {
  id: '77', precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
  producto_id: '81', cantidad: 2, producto: { nombre: 'Manaos 3L' },
}

const pedidoCon = (items: unknown[], estado = 'en_preparacion') => ({
  id: 601, notas: '', estado, total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items,
}) as any

const onSave = vi.fn().mockResolvedValue(undefined)
const onSaveItems = vi.fn().mockResolvedValue(undefined)
const props = { productos, isAdmin: true, onSave, onSaveItems, onClose: vi.fn(), guardando: false }

const excluidasDelHook = (): string[] => {
  const set = usePromocionPedidoSpy.mock.lastCall?.[3] as ReadonlySet<string> | undefined
  return [...(set ?? [])]
}

const avisoNoPedida = () => screen.queryByText(/no se agrega solo/)
// El "Agregar" de la fila de la promo (hay otro, el de agregar un producto, en la misma pantalla).
const botonAgregarPromo = () =>
  within(screen.getByText(/El pedido no tiene el regalo de/).parentElement as HTMLElement)
    .getByRole('button', { name: 'Agregar' })

beforeEach(() => {
  onSave.mockClear()
  onSaveItems.mockClear()
  usePromocionPedidoSpy.mockClear()
})

describe('ModalEditarPedido — promo que el pedido no tenía (PRM-2, #1515)', () => {
  it('al abrir arranca excluida, avisa que no se agrega sola y guardar una nota no toca los ítems', async () => {
    const user = userEvent.setup()
    // 10 unidades dispararían la promo 13 (10 + 2), pero el pedido no tiene su regalo.
    render(<ModalEditarPedido {...props} pedido={pedidoCon([ventaDe(10)])} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    expect(excluidasDelHook()).toEqual(['13'])
    expect(avisoNoPedida()).toBeInTheDocument()
    expect(screen.getByText(/El pedido no tiene el regalo de/)).toHaveTextContent('Promo 10 + 2')
    expect(screen.queryByText(/^REGALO x/)).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeInTheDocument()

    await user.type(screen.getByPlaceholderText(/Observaciones importantes/), 'Dejar con el encargado')
    await user.click(screen.getByRole('button', { name: 'Guardar' }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSave.mock.calls[0][0]).toMatchObject({ notas: 'Dejar con el encargado' })
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('"Agregar" saca la promo de las excluidas: vuelve el regalo y el guardado pasa a ser de ítems', async () => {
    const user = userEvent.setup()
    render(<ModalEditarPedido {...props} pedido={pedidoCon([ventaDe(10)])} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    expect(excluidasDelHook()).toEqual(['13'])

    await user.click(botonAgregarPromo())

    await waitFor(() => expect(excluidasDelHook()).toEqual([]))
    expect(avisoNoPedida()).not.toBeInTheDocument()
    expect(await screen.findByText(/^REGALO x2/)).toBeInTheDocument()

    const guardar = await screen.findByRole('button', { name: 'Guardar Todo' })
    await user.click(guardar)
    await waitFor(() => expect(onSaveItems).toHaveBeenCalledTimes(1))
    const items = onSaveItems.mock.calls[0][0] as Array<Record<string, unknown>>
    expect(items.filter(i => i.es_bonificacion || i.esBonificacion)).toHaveLength(1)
  })

  it('una promo de la que el pedido sí tiene regalo no aparece como "no pedida" ni se excluye', async () => {
    render(<ModalEditarPedido {...props} pedido={pedidoCon([ventaDe(10), regalo])} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    expect(excluidasDelHook()).toEqual([])
    expect(avisoNoPedida()).not.toBeInTheDocument()
    expect(screen.getByText(/^REGALO x2/)).toBeInTheDocument()
    expect(screen.queryByText('Modificado')).not.toBeInTheDocument()
  })

  it('una promo que no llega a disparar con las líneas guardadas no se muestra ni se excluye', async () => {
    render(<ModalEditarPedido {...props} pedido={pedidoCon([ventaDe(9)])} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    expect(excluidasDelHook()).toEqual([])
    expect(avisoNoPedida()).not.toBeInTheDocument()
  })

  it('en un pedido entregado no hay promos "no pedidas" (no se le ofrece un regalo nuevo)', async () => {
    render(<ModalEditarPedido {...props} pedido={pedidoCon([ventaDe(10)], 'entregado')} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    expect(avisoNoPedida()).not.toBeInTheDocument()
  })
})
