/**
 * Desactivar un producto que es el regalo (o contenedor) de una promo activa
 * tiene que avisarlo en el confirm: los pedidos que la activen van a fallar.
 */
import React from 'react'
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'

const PRODUCTOS = [
  { id: '5', nombre: 'Gaseosa regalo', activo: true, stock: 10 },
  { id: '6', nombre: 'Galletitas', activo: true, stock: 10 },
]
const PROMOS = [
  { id: '1', nombre: 'Combo A', activo: true, producto_regalo_id: '5', fecha_fin: null },
  { id: '2', nombre: 'Combo B', activo: true, producto_regalo_id: 5, fecha_fin: null },
  { id: '3', nombre: 'Combo C', activo: true, ajuste_producto_id: '5', fecha_fin: null },
  { id: '4', nombre: 'Apagada', activo: false, producto_regalo_id: '5', fecha_fin: null },
]

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
    useCategoriasQuery: () => ({ data: [] }),
    useSubcategoriasQuery: () => ({ data: [] }),
    useGruposPrecioQuery: () => ({ data: [] }),
    useAsegurarCatalogo: () => ({ asegurar: vi.fn(), creando: false }),
    usePromocionesListQuery: () => ({ data: PROMOS }),
  }
})
vi.mock('../../hooks/queries/useControlStockQuery', () => ({ useAplicarControlStockMutation: () => ({ mutateAsync: vi.fn() }) }))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({ isAdmin: true, perfil: { rol: 'admin' } }) }))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => ({ error: vi.fn(), success: vi.fn() }) }))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => {} }))
vi.mock('../vistas/VistaProductos', () => ({
  default: (props: { productos: { id: string; nombre: string }[]; onToggleActivoProducto?: (p: unknown) => void }) => (
    <div>
      {props.productos.map(p => (
        <button key={p.id} onClick={() => props.onToggleActivoProducto?.(p)}>{`Desactivar ${p.nombre}`}</button>
      ))}
    </div>
  ),
}))

import ProductosContainer from './ProductosContainer'

const montar = () => render(<MemoryRouter><ProductosContainer /></MemoryRouter>)

describe('ProductosContainer: aviso al desactivar', () => {
  beforeEach(() => vi.clearAllMocks())

  it('avisa que es regalo de promos activas y contenedor, sin contar las apagadas', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Desactivar Gaseosa regalo' }, { timeout: 15000 }))
    const dialogo = await screen.findByRole('dialog', {}, { timeout: 15000 })
    expect(dialogo.textContent).toContain(
      'Es el regalo de la promo «Combo A» y «Combo B». Mientras no cambies el regalo de esas promos, los pedidos que las activen van a fallar.',
    )
    expect(dialogo.textContent).toContain('También es el contenedor de ajuste de la promo «Combo C».')
    expect(dialogo.textContent).not.toContain('Apagada')
  })

  it('un producto sin promos mantiene el mensaje de siempre', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Desactivar Galletitas' }, { timeout: 15000 }))
    const dialogo = await screen.findByRole('dialog', {}, { timeout: 15000 })
    expect(dialogo.textContent).toContain('Deja de ofrecerse para vender')
    expect(dialogo.textContent).not.toContain('van a fallar')
  })
})
