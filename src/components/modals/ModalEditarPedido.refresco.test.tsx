/**
 * FRV-1 (#1598): un refresco de datos no pisa lo que se está editando.
 *
 * El efecto que arma las líneas desde `pedido.items` corría con cada identidad
 * nueva de `pedido` o de `productos`. Las dos cambian sin que cambie el pedido
 * guardado: reasignar el preventista desde el mismo modal copia el pedido, y la
 * lista de productos se vuelve a pedir al reconectar o al vaciarse la cola
 * offline. Un pedido de 10 bajado a 8 volvía a 10 y desaparecían «Anterior» y
 * «Guardar Todo».
 *
 * Y 1559-b17: el desglose fiscal de lo que se guarda buscaba el producto con
 * `p.id === '97'`, con `p.id` number en runtime: no lo encontraba y todo salía
 * al 21 %, también lo exento.
 *
 * Los ids van como number, como llegan de PostgREST. El andamiaje es el de
 * `ModalEditarPedido.precioAdmin.test.tsx`.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

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
  usePromoCuposQuery: () => ({ data: undefined }),
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
  { id: 97, nombre: 'PLACER MANZANA 500 cc', codigo: 'P97', precio: 1000, stock: 165, categoria: 'Jugos' },
] as any[]

const pedido = {
  id: 11503,
  notas: '',
  estado: 'pendiente',
  total: 10000,
  usuario_id: 'prev-1',
  cliente: { id: 9, nombre_fantasia: 'Escuela', direccion: 'Peru 577' },
  items: [{ id: 501, producto_id: 97, cantidad: 10, precio_unitario: 1000, origen_precio: 'lista', producto: { nombre: 'PLACER MANZANA 500 cc' } }],
} as any

function props(over: Record<string, unknown> = {}) {
  return {
    productos,
    pedido,
    isAdmin: true,
    onSave: vi.fn().mockResolvedValue(undefined),
    onSaveItems: vi.fn().mockResolvedValue(undefined),
    onClose: vi.fn(),
    guardando: false,
    ...over,
  } as any
}

/** Baja la cantidad de 10 a 8 y confirma el campo (blur). */
async function bajarA8(user: ReturnType<typeof userEvent.setup>) {
  const cantidad = await screen.findByLabelText('Cantidad')
  expect(cantidad).toHaveValue('10')
  await user.clear(cantidad)
  await user.type(cantidad, '8')
  await user.tab()
  await waitFor(() => expect(screen.getByLabelText('Cantidad')).toHaveValue('8'))
  await waitFor(() => expect(screen.getByRole('button', { name: 'Guardar Todo' })).toBeInTheDocument())
}

beforeEach(() => vi.clearAllMocks())

describe('FRV-1 — un refresco no pisa la edición', () => {
  it('llega un `productos` nuevo: el campo sigue en 8 y siguen «Anterior» y «Guardar Todo»', async () => {
    const user = userEvent.setup()
    const p = props()
    const { rerender } = render(<ModalEditarPedido {...p} />)
    await bajarA8(user)

    // El refetch de productos al reconectar: otra identidad, el mismo contenido.
    rerender(<ModalEditarPedido {...p} productos={productos.map(x => ({ ...x }))} />)

    await waitFor(() => expect(screen.getByLabelText('Cantidad')).toHaveValue('8'))
    expect(screen.getByRole('button', { name: 'Guardar Todo' })).toBeInTheDocument()
    expect(screen.getByText(/Anterior:/)).toBeInTheDocument()
  })

  it('reasignar el preventista copia el pedido: la edición sigue en 8', async () => {
    const user = userEvent.setup()
    const p = props()
    const { rerender } = render(<ModalEditarPedido {...p} />)
    await bajarA8(user)

    // Lo que hace el container tras `actualizar_preventista_pedido`.
    rerender(<ModalEditarPedido {...p} pedido={{ ...pedido, usuario_id: 'prev-2' }} />)

    await waitFor(() => expect(screen.getByLabelText('Cantidad')).toHaveValue('8'))
    expect(screen.getByRole('button', { name: 'Guardar Todo' })).toBeInTheDocument()
  })

  it('lo que se guarda después del refresco es lo editado (8), no lo guardado (10)', async () => {
    const user = userEvent.setup()
    const p = props()
    const { rerender } = render(<ModalEditarPedido {...p} />)
    await bajarA8(user)
    rerender(<ModalEditarPedido {...p} productos={productos.map(x => ({ ...x }))} />)

    await user.click(screen.getByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(p.onSaveItems).toHaveBeenCalled())
    expect(p.onSaveItems.mock.calls[0][0]).toEqual([expect.objectContaining({ productoId: '97', cantidad: 8 })])
  })

  it('con otras líneas guardadas (la versión nueva) sí arranca de lo guardado', async () => {
    const user = userEvent.setup()
    const p = props()
    const { rerender } = render(<ModalEditarPedido {...p} />)
    await bajarA8(user)

    const nuevaVersion = { ...pedido, items: [{ ...pedido.items[0], id: 777, cantidad: 12 }] }
    rerender(<ModalEditarPedido {...p} pedido={nuevaVersion} />)

    await waitFor(() => expect(screen.getByLabelText('Cantidad')).toHaveValue('12'))
  })

  it('sin nada editado, los productos que llegan tarde sí se usan (el precio manual se marca)', async () => {
    // Un precio distinto de lista sin origen (anterior a la mig 148) congela el
    // precio: para saberlo hace falta el producto.
    const sinOrigen = { ...pedido, items: [{ ...pedido.items[0], precio_unitario: 900, origen_precio: null }] }
    const p = props({ pedido: sinOrigen, productos: [] })
    const { rerender } = render(<ModalEditarPedido {...p} />)
    await screen.findByLabelText('Cantidad')
    expect(screen.queryByText('Manual')).not.toBeInTheDocument()

    rerender(<ModalEditarPedido {...p} productos={productos} />)

    await waitFor(() => expect(screen.getByText('Manual')).toBeInTheDocument())
  })
})

describe('1559-b17 — el desglose fiscal de lo que se guarda usa el producto', () => {
  it('un producto exento se guarda con IVA 0, no al 21 %', async () => {
    const user = userEvent.setup()
    const exento = [{ ...productos[0], condicion_iva: 'exento', porcentaje_iva: 0 }]
    const p = props({ productos: exento, pedido: { ...pedido, tipo_factura: 'FC' } })
    render(<ModalEditarPedido {...p} />)
    await bajarA8(user)

    await user.click(screen.getByRole('button', { name: 'Guardar Todo' }))
    await waitFor(() => expect(p.onSaveItems).toHaveBeenCalled())
    const [items] = p.onSaveItems.mock.calls[0]
    expect(items).toEqual([expect.objectContaining({ productoId: '97', porcentaje_iva: 0, iva_unitario: 0, neto_unitario: 1000 })])
  })
})
