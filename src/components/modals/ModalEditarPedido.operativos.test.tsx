/**
 * Qué productos ofrece el buscador de "Agregar" al editar un pedido.
 *
 * Reglas (src/utils/productosOperativos.ts + política `mostrarSinStock`):
 *   - un producto desactivado nunca se ofrece;
 *   - el agotado se ofrece, deshabilitado, sólo si la política lo muestra;
 *   - los ítems YA cargados siguen resolviendo nombre y precio aunque su
 *     producto se haya desactivado: sólo se filtra la lista para AGREGAR.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const politica = vi.hoisted(() => ({ mostrarSinStock: true }))

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
  usePoliticasComercialesQuery: () => ({ politicas: { mostrarSinStock: politica.mostrarSinStock } }),
}))
vi.mock('../../utils/formatters', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../utils/formatters')>()
  return { ...actual, formatPrecio: (v: number) => `$${Number(v).toFixed(2)}` }
})

import ModalEditarPedido from './ModalEditarPedido'

const productos = [
  // El del pedido, desactivado después de cargarse.
  { id: '1', nombre: 'Cargado Retirado', codigo: 'A001', precio: 250, stock: 100, categoria: 'X', activo: false },
  { id: '2', nombre: 'Zeta Con Stock', codigo: 'Z002', precio: 100, stock: 7, categoria: 'X', activo: true },
  { id: '3', nombre: 'Zeta Agotado', codigo: 'Z003', precio: 100, stock: 0, categoria: 'X', activo: true },
  { id: '4', nombre: 'Zeta Desactivado', codigo: 'Z004', precio: 100, stock: 50, categoria: 'X', activo: false },
] as any[]

const pedido = {
  id: 701,
  notas: '',
  estado: 'pendiente',
  total: 2500,
  cliente: { id: '9', nombre_fantasia: 'Kiosco Sur', direccion: 'Calle 1' },
  items: [{ producto_id: '1', cantidad: 10, precio_unitario: 250, origen_precio: 'lista', producto: { nombre: 'Cargado Retirado' } }],
} as any

async function abrirBuscador(termino: string) {
  const user = userEvent.setup()
  render(
    <ModalEditarPedido
      productos={productos}
      pedido={pedido}
      isAdmin
      onSave={vi.fn()}
      onSaveItems={vi.fn()}
      onClose={vi.fn()}
      guardando={false}
    />,
  )
  await waitFor(() => expect(screen.getByText('Cargado Retirado')).toBeInTheDocument())
  await user.click(screen.getByText('Agregar'))
  await user.type(screen.getByPlaceholderText(/buscar producto/i), termino)
  return user
}

beforeEach(() => {
  politica.mostrarSinStock = true
})

describe('ModalEditarPedido — productos para agregar', () => {
  it('con la política prendida: el agotado se ve deshabilitado y el desactivado no aparece', async () => {
    await abrirBuscador('Zeta')
    expect(screen.getByText('Zeta Con Stock')).toBeInTheDocument()
    const agotado = screen.getByText('Zeta Agotado').closest('button')!
    expect(agotado).toHaveAttribute('aria-disabled', 'true')
    expect(screen.queryByText('Zeta Desactivado')).not.toBeInTheDocument()
  })

  it('agregar el agotado no hace nada; el que tiene stock se agrega', async () => {
    const user = await abrirBuscador('Zeta')
    await user.click(screen.getByText('Zeta Agotado'))
    // El buscador sigue abierto y el agotado no entró al pedido.
    expect(screen.getByPlaceholderText(/buscar producto/i)).toBeInTheDocument()
    await user.click(screen.getByText('Zeta Con Stock'))
    await waitFor(() => expect(screen.queryByPlaceholderText(/buscar producto/i)).not.toBeInTheDocument())
    expect(screen.getByText('Zeta Con Stock')).toBeInTheDocument()
  })

  it('con la política apagada: el agotado deja de ofrecerse', async () => {
    politica.mostrarSinStock = false
    await abrirBuscador('Zeta')
    expect(screen.getByText('Zeta Con Stock')).toBeInTheDocument()
    expect(screen.queryByText('Zeta Agotado')).not.toBeInTheDocument()
    expect(screen.queryByText('Zeta Desactivado')).not.toBeInTheDocument()
  })

  it('el ítem ya cargado conserva nombre y precio aunque su producto esté desactivado', async () => {
    await abrirBuscador('Zeta')
    expect(screen.getByText('Cargado Retirado')).toBeInTheDocument()
    expect(screen.getAllByText(/\$250\.00/).length).toBeGreaterThan(0)
  })
})
