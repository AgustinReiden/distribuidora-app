/**
 * La ficha de producto ofrece SÓLO las categorías que son fila de `categorias`
 * (#763). Antes unía la tabla con los textos sueltos de `productos.categoria`:
 * así seguía ofreciendo "FRAU" o "NACHOS", que no tenían fila, y elegir uno para
 * un producto nuevo lo dejaba también sin `categoria_id` -- invisible para
 * comisiones, metas y asignaciones masivas.
 */
import React from 'react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

const PRODUCTOS = [
  { id: '1', nombre: 'Papa clásica', activo: true, stock: 10, categoria: 'SNACKS' },
  { id: '2', nombre: 'Franela', activo: true, stock: 10, categoria: 'FRAU' },
]
const CATEGORIAS = [
  { id: 'c1', nombre: 'SNACKS', activa: true },
  { id: 'c2', nombre: 'AZUCAR', activa: true },
  // Dos filas con el mismo nombre (pasa en prod): una sola opción.
  { id: 'c3', nombre: 'PAPEL HIGIENICO', activa: true },
  { id: 'c4', nombre: 'PAPEL HIGIENICO', activa: true },
  { id: 'c5', nombre: 'VIEJA', activa: false },
]

const categoriasRecibidas = vi.fn()

vi.mock('../../hooks/queries', () => {
  const mut = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    useProductosQuery: () => ({ data: PRODUCTOS, isLoading: false, isError: false, refetch: vi.fn() }),
    // Sólo la usa depósito (#999), que este test no monta.
    useCatalogoDepositoQuery: () => ({ data: [], isLoading: false, isError: false, refetch: vi.fn() }),
    useCrearProductoMutation: mut,
    useActualizarProductoMutation: mut,
    useEliminarProductoMutation: mut,
    useRegistrarMermaMutation: mut,
    useRegistrarCambioProductoMutation: mut,
    useCrearGrupoPrecioMutation: mut,
    useProveedoresActivosQuery: () => ({ data: [] }),
    useClientesQuery: () => ({ data: [] }),
    useCategoriasQuery: () => ({ data: CATEGORIAS }),
    useSubcategoriasQuery: () => ({ data: [] }),
    useGruposPrecioQuery: () => ({ data: [] }),
    useAsegurarCatalogo: () => ({ asegurar: vi.fn(), creando: false }),
    usePromocionesListQuery: () => ({ data: [] }),
  }
})
vi.mock('../../hooks/queries/useControlStockQuery', () => ({ useAplicarControlStockMutation: () => ({ mutateAsync: vi.fn() }) }))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({ isAdmin: true, perfil: { rol: 'admin' } }) }))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => ({ error: vi.fn(), success: vi.fn() }) }))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => {} }))
vi.mock('../vistas/VistaProductos', () => ({
  default: (props: { onNuevoProducto: () => void }) => (
    <button onClick={() => props.onNuevoProducto()}>Nuevo producto</button>
  ),
}))
vi.mock('../modals/ModalProducto', () => ({
  default: (props: { categorias: string[] }) => {
    categoriasRecibidas(props.categorias)
    return <div>ficha abierta</div>
  },
}))

import ProductosContainer from './ProductosContainer'

describe('ProductosContainer: categorías que ofrece la ficha (#763)', () => {
  beforeEach(() => vi.clearAllMocks())

  it('ofrece sólo las filas activas de categorias, sin repetir y ordenadas', async () => {
    const user = userEvent.setup()
    render(<MemoryRouter><ProductosContainer /></MemoryRouter>)
    await user.click(await screen.findByRole('button', { name: 'Nuevo producto' }))
    await screen.findByText('ficha abierta')

    const llamadas = categoriasRecibidas.mock.calls
    const ofrecidas = llamadas[llamadas.length - 1]?.[0]
    expect(ofrecidas).toEqual(['AZUCAR', 'PAPEL HIGIENICO', 'SNACKS'])
    expect(ofrecidas).not.toContain('FRAU')
  })
})
