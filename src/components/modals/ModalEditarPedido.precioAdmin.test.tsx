/**
 * El precio que el admin tipea en la edicion se guarda como 'manual'.
 *
 * EL HUECO
 * --------
 * Desde #1191 las lineas que se guardan salen de `resultadoCombos.lineas`, con
 * el id del producto como string, y la fila del estado se buscaba con
 * `i.productoId === pid`. En runtime los ids son `bigint` y llegan como number
 * (97 !== '97'): la fila no aparecia, se perdia `precioOverride` y el precio
 * tipeado se registraba como 'lista'. Al reabrir, una linea 'lista' se
 * re-cotiza a la lista de hoy: el modal mostraba 7.400 y guardar devolvia el
 * pedido a 7.400 (pedidos 11502/11503/11508/11509, 2026-10-20).
 *
 * Los ids van como number, como llegan de PostgREST: con strings el bug no se ve.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

// #1191: los combos tienen su propia query (y su sucursal): acá no hay combos.
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
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false }),
  usePromocionesListQuery: () => ({ data: [], isLoading: false }),
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
  { id: 97, nombre: 'PLACER MANZANA 500 cc', codigo: 'P97', precio: 7400, stock: 165, categoria: 'Jugos' },
] as any[]

const pedido = {
  id: 11503,
  notas: '',
  estado: 'pendiente',
  total: 14800,
  cliente: { id: 9, nombre_fantasia: 'Escuela', direccion: 'Peru 577' },
  items: [{ producto_id: 97, cantidad: 2, precio_unitario: 7400, origen_precio: 'lista', producto: { nombre: 'PLACER MANZANA 500 cc' } }],
} as any

beforeEach(() => vi.clearAllMocks())

describe('ModalEditarPedido — precio puesto por el admin', () => {
  it('guarda el precio tipeado con origen "manual", no "lista"', async () => {
    const user = userEvent.setup()
    const onSaveItems = vi.fn().mockResolvedValue(undefined)
    render(
      <ModalEditarPedido
        productos={productos}
        pedido={pedido}
        isAdmin
        onSave={vi.fn().mockResolvedValue(undefined)}
        onSaveItems={onSaveItems}
        onClose={vi.fn()}
        guardando={false}
      />,
    )

    await waitFor(() => expect(screen.getByText('PLACER MANZANA 500 cc')).toBeInTheDocument())
    await user.click(screen.getByText('$7400.00 c/u'))
    const input = screen.getByLabelText('Editar precio unitario')
    await user.clear(input)
    await user.type(input, '7500')
    await user.click(screen.getByLabelText('Confirmar precio'))

    await waitFor(() => expect(screen.getByRole('button', { name: 'Guardar Todo' })).toBeEnabled())
    await user.click(screen.getByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(onSaveItems).toHaveBeenCalled())

    const [items, origenes] = onSaveItems.mock.calls[0]
    expect(items).toEqual([expect.objectContaining({ productoId: '97', cantidad: 2, precioUnitario: 7500, precioOverride: true })])
    expect(origenes).toEqual([expect.objectContaining({ producto_id: '97', es_bonificacion: false, origen_precio: 'manual' })])
  })

  it('al reabrir, la linea "manual" muestra el precio guardado y no el de lista', async () => {
    const guardado = {
      ...pedido,
      total: 15000,
      items: [{ ...pedido.items[0], precio_unitario: 7500, origen_precio: 'manual' }],
    }
    render(
      <ModalEditarPedido
        productos={productos}
        pedido={guardado}
        isAdmin
        onSave={vi.fn()}
        onSaveItems={vi.fn()}
        onClose={vi.fn()}
        guardando={false}
      />,
    )

    await waitFor(() => expect(screen.getByText('PLACER MANZANA 500 cc')).toBeInTheDocument())
    expect(screen.getByText('$7500.00 c/u')).toBeInTheDocument()
    expect(screen.queryByText('$7400.00 c/u')).not.toBeInTheDocument()
    expect(screen.getByText('Manual')).toBeInTheDocument()
  })
})
