/**
 * Editar el pedido que completó el cupo no le saca el regalo (#1300, PRM-N4), y
 * la edición avisa el cupo con las mismas cuentas que el rechazo (#1283).
 *
 * El mock de `usePromoMapQuery` hace lo que la query de verdad: la promo apagada
 * sólo resuelve si el modal la pide por id.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import type { PromoMap, PromocionActiva } from '../../utils/promociones'
import type { CupoPromo } from '../../utils/cupoPromo'

const { estado, promoApagada } = vi.hoisted(() => {
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
  return { estado: { cupos: undefined as Map<string, CupoPromo> | undefined }, promoApagada: promo }
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
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
  usePedidoSustitucionesQuery: () => ({ data: [], isLoading: false, isFetching: false }),
  usePromoCuposQuery: () => ({ data: estado.cupos }),
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
  id: 601, notas: '', estado: 'en_preparacion', total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [
    {
      producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista',
      producto: { nombre: 'Producto 1' },
    },
    {
      id: '77', precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
      producto_id: '81', cantidad: 2, producto: { nombre: 'Manaos 3L' },
    },
  ],
} as any

const props = {
  productos,
  isAdmin: true,
  onSave: vi.fn().mockResolvedValue(undefined),
  onSaveItems: vi.fn().mockResolvedValue(undefined),
  onClose: vi.fn(),
  guardando: false,
}

beforeEach(() => {
  estado.cupos = undefined
})

describe('ModalEditarPedido — promo apagada por el límite (#1300)', () => {
  it('conserva el regalo y el pedido no queda modificado', async () => {
    render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    expect(screen.getByText(/^REGALO x2/)).toBeInTheDocument()
    expect(screen.queryByText('Modificado')).not.toBeInTheDocument()
  })

  it('el pedido que completó el cupo no se avisa a sí mismo que no alcanza', async () => {
    estado.cupos = new Map([['13', { promocionId: '13', limite: 5, usos: 5, quedan: 2 }]])
    render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    expect(screen.getByText(/quedan 2 y este pedido lleva 2\./)).toBeInTheDocument()
    expect(screen.getByText(/El cupo cuenta el corte de la promo, en su unidad: sustituir el regalo no lo cambia\./))
      .toBeInTheDocument()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('si el regalo no entra en lo que queda, lo avisa antes de guardar', async () => {
    estado.cupos = new Map([['13', { promocionId: '13', limite: 5, usos: 5, quedan: 1 }]])
    render(<ModalEditarPedido {...props} pedido={pedido} />)
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())

    expect(screen.getByRole('alert')).toHaveTextContent(/quedan 1 y este pedido lleva 2\./)
  })
})
