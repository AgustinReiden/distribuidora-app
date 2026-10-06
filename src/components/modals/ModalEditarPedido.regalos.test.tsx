/**
 * Lista "Regalos del pedido (sustituibles)" del ModalEditarPedido (#841).
 *
 * - Cada línea muestra el NOMBRE de su promo, no `descripcion_regalo`: ese
 *   texto es fijo de la promo ("2 Botellas ...") y en prod contradice la
 *   cantidad de la línea.
 * - En un pedido cancelado o anulado no se ofrece "Cambiar regalo": el stock
 *   ya se devolvió y sustituir lo devolvería otra vez (el server también lo
 *   rechaza).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'

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
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false }),
  usePromocionesListQuery: () => ({
    data: [
      { id: 13, nombre: 'Promo Manaos 6 + 2 3L', regalo_mueve_stock: false, ajuste_producto_id: null, unidades_por_bloque: 6 },
      { id: 15, nombre: 'Promo Placer 3 + 1 1,5LT', regalo_mueve_stock: true, ajuste_producto_id: null, unidades_por_bloque: null },
    ],
    isLoading: false,
  }),
  usePedidoSustitucionesQuery: () => ({ data: [], isLoading: false }),
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: true } }),
}))
vi.mock('../../utils/formatters', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../utils/formatters')>()
  return { ...actual, formatPrecio: (v: number) => `$${Number(v).toFixed(2)}` }
})

import ModalEditarPedido from './ModalEditarPedido'

const productos = [
  { id: '1', nombre: 'Producto 1', codigo: 'P001', precio: 250, stock: 100, categoria: 'Snacks' },
  { id: '314', nombre: 'Manaos Limon 3L', codigo: 'M314', precio: 0, stock: 100, categoria: 'Bebidas' },
] as any[]

const pedidoCon = (estado: string) => ({
  id: 601,
  notas: '',
  estado,
  total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [
    { id: '10', producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' } },
    {
      id: '11', producto_id: '314', cantidad: 5, precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
      descripcion_regalo: 'Regalo Manaos [Sustituido por: Manaos Limon 3L]',
      producto: { id: '314', nombre: 'Manaos Limon 3L' },
    },
    {
      id: '12', producto_id: '314', cantidad: 3, precio_unitario: 0, es_bonificacion: true, promocion_id: '15',
      descripcion_regalo: null,
      producto: { id: '314', nombre: 'Manaos Limon 3L' },
    },
  ],
}) as any

const baseProps = {
  productos,
  isAdmin: true,
  canSustituirRegalo: true,
  onSave: vi.fn().mockResolvedValue(undefined),
  onClose: vi.fn(),
  guardando: false,
}

beforeEach(() => vi.clearAllMocks())

describe('ModalEditarPedido — regalos sustituibles', () => {
  it('cada regalo dice de qué promo viene, por nombre, y no muestra descripcion_regalo', async () => {
    render(<ModalEditarPedido {...baseProps} pedido={pedidoCon('en_preparacion')} />)

    await waitFor(() => expect(screen.getByText('Regalos del pedido (sustituibles)')).toBeInTheDocument())
    expect(screen.getByText('REGALO x5 · Promo Manaos 6 + 2 3L')).toBeInTheDocument()
    expect(screen.getByText('REGALO x3 · Promo Placer 3 + 1 1,5LT')).toBeInTheDocument()
    expect(screen.queryByText(/Sustituido por/)).not.toBeInTheDocument()
    expect(screen.getAllByRole('button', { name: /cambiar regalo/i })).toHaveLength(2)
  })

  it.each(['cancelado', 'anulado'])('en un pedido %s no ofrece "Cambiar regalo"', async (estado) => {
    render(<ModalEditarPedido {...baseProps} pedido={pedidoCon(estado)} />)

    await waitFor(() => expect(screen.getByText('Total del Pedido')).toBeInTheDocument())
    expect(screen.queryByText('Regalos del pedido (sustituibles)')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /cambiar regalo/i })).not.toBeInTheDocument()
  })
})
