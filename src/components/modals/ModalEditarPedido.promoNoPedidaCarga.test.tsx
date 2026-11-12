/**
 * PRM-2 mientras carga la consulta de las promos no pedidas (#1538, B3).
 *
 * `promosNoPedidas` sale de `usePromoMapQuery(fechaReferenciaPromo, promosDelPedido)`, que el
 * modal pide aparte. Mientras esa consulta no contesta, la lista está vacía y la promo no queda
 * excluida. Si `usePromocionPedido` ya tiene la suya y recalculó el regalo, `bonifDifierenDeDB`
 * prendía el guardado solo: guardar una nota le agregaba al pedido el regalo que no tenía.
 *
 * El mock distingue las dos llamadas por la pila: la de `usePromocionPedido` contesta con la
 * promo y la del modal no, hasta que el test la "deja contestar".
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'

const { promo13, usePromocionPedidoSpy, consultaDelModal } = vi.hoisted(() => {
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
  return { promo13: promo, usePromocionPedidoSpy: vi.fn(), consultaDelModal: { contesto: false } }
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
  usePromoMapQuery: () => {
    const mapa = new Map([['1', [promo13]]]) as PromoMap
    const desdeUsePromocionPedido = (new Error().stack ?? '').includes('usePromocionPedido')
    if (desdeUsePromocionPedido || consultaDelModal.contesto) return { data: mapa, isLoading: false }
    return { data: undefined, isLoading: true }
  },
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

// 10 unidades dispararían la promo 13 (10 + 2), pero el pedido no tiene su regalo.
const pedido = {
  id: 601, notas: '', estado: 'en_preparacion', total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [{ producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' } }],
} as any

const onSave = vi.fn().mockResolvedValue(undefined)
const onSaveItems = vi.fn().mockResolvedValue(undefined)
const props = { productos, isAdmin: true, onSave, onSaveItems, onClose: vi.fn(), guardando: false }

beforeEach(() => {
  consultaDelModal.contesto = false
  onSave.mockClear()
  onSaveItems.mockClear()
  usePromocionPedidoSpy.mockClear()
})

describe('ModalEditarPedido — la consulta de las promos no pedidas todavía no contestó (#1538, B3)', () => {
  it('con la consulta del modal pendiente no se prende el guardado, y guardar una nota no toca los ítems', async () => {
    const user = userEvent.setup()
    render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    // usePromocionPedido ya tiene la promo y, sin excluidas todavía, recalcula el regalo.
    const excluidas = usePromocionPedidoSpy.mock.lastCall?.[3] as ReadonlySet<string> | undefined
    expect([...(excluidas ?? [])]).toEqual([])
    expect(screen.queryByText('Modificado')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Guardar Todo' })).not.toBeInTheDocument()

    await user.type(screen.getByPlaceholderText(/Observaciones importantes/), 'Dejar con el encargado')
    await user.click(screen.getByRole('button', { name: 'Guardar' }))

    await waitFor(() => expect(onSave).toHaveBeenCalledTimes(1))
    expect(onSaveItems).not.toHaveBeenCalled()
  })

  it('cuando la consulta contesta, la promo queda excluida y el guardado sigue apagado', async () => {
    const { rerender } = render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    consultaDelModal.contesto = true
    // Una copia: con las mismas props el modal (memo) no se vuelve a dibujar.
    rerender(<ModalEditarPedido {...props} pedido={{ ...pedido }} />)

    await waitFor(() => {
      const excluidas = usePromocionPedidoSpy.mock.lastCall?.[3] as ReadonlySet<string> | undefined
      expect([...(excluidas ?? [])]).toEqual(['13'])
    })
    expect(screen.getByText(/no se agrega solo/)).toBeInTheDocument()
    expect(screen.queryByText(/^REGALO x/)).not.toBeInTheDocument()
    expect(screen.queryByText('Modificado')).not.toBeInTheDocument()
  })
})
