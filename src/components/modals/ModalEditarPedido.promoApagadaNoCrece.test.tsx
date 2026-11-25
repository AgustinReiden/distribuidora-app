/**
 * promos-B6 (tanda 6 de #1603), decisión del dueño del 24/11: al editar, el regalo de una
 * promo que el admin apagó se CONSERVA pero NO CRECE. V×10 + R×2 («10 dan 2»), la promo
 * apagada: subir la venta a V×20 deja el regalo en 2 (no 4), como lo mide el server
 * (`regalo_fuera_de_promo`). El admin no tiene ese tope.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor, fireEvent, within } from '@testing-library/react'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'

const { promoApagada, filaPromo } = vi.hoisted(() => {
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
  const fila = {
    id: '13', nombre: 'Promo 10 + 2', tipo: 'bonificacion', activo: false,
    fecha_inicio: '2026-01-01', fecha_fin: null, producto_regalo_id: '81', regalo_mueve_stock: true,
    ajuste_producto_id: null, unidades_por_bloque: null, productos: [], reglas: [],
  }
  return { promoApagada: promo, filaPromo: fila }
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
  usePromoMapQuery: (_fecha?: string, promosDelPedido?: readonly string[]) => ({
    data: promosDelPedido?.includes('13') ? new Map([['1', [promoApagada]]]) as PromoMap : new Map(),
    isLoading: false,
  }),
  usePromocionesListQuery: () => ({ data: [filaPromo], isLoading: false }),
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

const pedido = {
  id: 602, notas: '', estado: 'en_preparacion', total: 2500, fecha: '2026-11-20',
  cliente: { id: '9', nombre_fantasia: 'Kiosco Norte', direccion: 'Calle 2' },
  items: [
    {
      producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista',
      producto: { nombre: 'Producto 1' },
    },
    {
      id: '78', precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
      producto_id: '81', cantidad: 2, producto: { nombre: 'Manaos 3L' },
    },
  ],
} as any

const renderModal = (isAdmin: boolean) => render(
  <ModalEditarPedido
    productos={productos}
    isAdmin={isAdmin}
    canEditItems
    onSave={vi.fn().mockResolvedValue(undefined)}
    onSaveItems={vi.fn().mockResolvedValue(undefined)}
    onClose={vi.fn()}
    guardando={false}
    pedido={pedido}
  />,
)

const cambiarVentaA = (n: number): void => {
  const fila = screen.getByText('Producto 1').closest('.p-3') as HTMLElement
  const input = within(fila).getByLabelText('Cantidad')
  fireEvent.change(input, { target: { value: String(n) } })
  fireEvent.blur(input)
}

describe('ModalEditarPedido — el regalo de una promo apagada no crece (promos-B6)', () => {
  it('subir la venta deja el regalo como estaba', async () => {
    renderModal(false)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    expect(screen.getByText(/^REGALO x2/)).toBeInTheDocument()
    cambiarVentaA(20)
    await waitFor(() => expect(screen.getByText(/^REGALO x2/)).toBeInTheDocument())
    expect(screen.queryByText(/^REGALO x4/)).not.toBeInTheDocument()
  })

  it('bajar la venta lo recorta como siempre', async () => {
    renderModal(false)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    cambiarVentaA(5)
    await waitFor(() => expect(screen.queryByText(/^REGALO x/)).not.toBeInTheDocument())
  })

  it('el admin no tiene ese tope', async () => {
    renderModal(true)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    cambiarVentaA(20)
    await waitFor(() => expect(screen.getByText(/^REGALO x4/)).toBeInTheDocument())
  })
})
