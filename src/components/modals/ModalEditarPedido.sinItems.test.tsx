/**
 * Un pedido no puede quedar sin productos (#1078): sin ningún renglón que no sea
 * regalo, el pedido se cancela, no se guarda vacío. El modal ya lo bloquea con el
 * botón Guardar deshabilitado y el aviso "No hay productos en el pedido"; este
 * test fija ese comportamiento (caracterización).
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

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
    data: [{ id: 13, nombre: 'Promo Manaos 6 + 2 3L', regalo_mueve_stock: false, ajuste_producto_id: null, unidades_por_bloque: 6 }],
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

const itemNormal = { id: '10', producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Producto 1' } }
const itemRegalo = {
  id: '11', producto_id: '314', cantidad: 5, precio_unitario: 0, es_bonificacion: true, promocion_id: '13',
  descripcion_regalo: null, producto: { id: '314', nombre: 'Manaos Limon 3L' },
}

const pedidoCon = (items: any[]) => ({
  id: 601,
  notas: '',
  estado: 'pendiente',
  total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items,
}) as any

const botonesMenos = () => Array.from(document.body.querySelectorAll('button.rounded-l-lg'))
// El botón de eliminar del ítem no tiene aria-label: se lo busca por su ícono (Trash2).
const botonesEliminar = () =>
  Array.from(document.body.querySelectorAll('button')).filter(b => b.querySelector('svg.lucide-trash-2, svg.lucide-trash2'))
const botonGuardar = () => screen.getByRole('button', { name: /^guardar/i })

const montar = (items: any[]) => {
  const onSave = vi.fn().mockResolvedValue(undefined)
  const onSaveItems = vi.fn().mockResolvedValue(undefined)
  render(
    <ModalEditarPedido
      productos={productos}
      pedido={pedidoCon(items)}
      isAdmin
      onSave={onSave}
      onSaveItems={onSaveItems}
      onClose={vi.fn()}
      guardando={false}
    />,
  )
  return { onSave, onSaveItems }
}

// Elimina el renglón de "Producto 1" con el botón de eliminar del ítem.
const sacarProducto = async (user: ReturnType<typeof userEvent.setup>) => {
  await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
  const eliminar = botonesEliminar()
  expect(eliminar.length).toBeGreaterThan(0)
  await user.click(eliminar[0])
  await waitFor(() => expect(screen.queryByText('Producto 1')).not.toBeInTheDocument())
}

beforeEach(() => vi.clearAllMocks())

describe('ModalEditarPedido — el pedido no queda sin productos', () => {
  it('control: con el producto presente, Guardar está habilitado tras un cambio', async () => {
    const user = userEvent.setup()
    montar([itemNormal])
    await waitFor(() => expect(screen.getByText('Producto 1')).toBeInTheDocument())
    await user.click(botonesMenos()[0])
    await waitFor(() => expect(botonGuardar()).toBeEnabled())
    expect(screen.queryByText('No hay productos en el pedido')).not.toBeInTheDocument()
  })

  it('al sacar el único producto: aviso, Guardar deshabilitado y no se llama a onSaveItems ni onSave', async () => {
    const user = userEvent.setup()
    const { onSave, onSaveItems } = montar([itemNormal])
    await sacarProducto(user)

    expect(screen.getByText('No hay productos en el pedido')).toBeInTheDocument()
    const guardar = botonGuardar()
    expect(guardar).toBeDisabled()

    await user.click(guardar)
    expect(onSaveItems).not.toHaveBeenCalled()
    expect(onSave).not.toHaveBeenCalled()
  })

  it('si queda sólo el regalo (sin renglón no-regalo), Guardar también está deshabilitado', async () => {
    const user = userEvent.setup()
    const { onSave, onSaveItems } = montar([itemNormal, itemRegalo])
    await sacarProducto(user)

    expect(screen.getByText('No hay productos en el pedido')).toBeInTheDocument()
    const guardar = botonGuardar()
    expect(guardar).toBeDisabled()
    await user.click(guardar)
    expect(onSaveItems).not.toHaveBeenCalled()
    expect(onSave).not.toHaveBeenCalled()
  })
})
