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
  { id: '7', nombre: 'Alfajores', activo: true, stock: 10 },
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
// Combos vigentes (#1596, 1596-b11): el 5 es la única opción de un lugar del «Combo X»;
// el 6 es una de dos opciones del «Combo Y».
const COMBOS = [
  { id: '1', nombre: 'Combo X', activo: true, fechaFin: null, productoAMoverId: null, componentes: [{ cantidad: 1, sueltos: ['5'], categorias: [] }] },
  { id: '2', nombre: 'Combo Y', activo: true, fechaFin: null, productoAMoverId: null, componentes: [{ cantidad: 1, sueltos: ['6', '7'], categorias: [] }] },
  { id: '3', nombre: 'Combo apagado', activo: false, fechaFin: null, productoAMoverId: null, componentes: [{ cantidad: 1, sueltos: ['5'], categorias: [] }] },
]
const combos = vi.hoisted(() => ({ fetch: vi.fn() }))
vi.mock('../../hooks/queries/useCombosQuery', () => ({
  fetchCombosAdmin: () => combos.fetch(),
}))
vi.mock('../../hooks/queries/useControlStockQuery', () => ({ useAplicarControlStockMutation: () => ({ mutateAsync: vi.fn() }) }))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({ isAdmin: true, perfil: { rol: 'admin' } }) }))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => ({ error: vi.fn(), success: vi.fn() }) }))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => {} }))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalNombre: 'Tucuman' }) }))
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
  beforeEach(() => {
    vi.clearAllMocks()
    combos.fetch.mockResolvedValue(COMBOS)
  })

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

  it('avisa de los combos: el que se rompe y el que sigue con otra opción, sin contar los apagados', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Desactivar Gaseosa regalo' }, { timeout: 15000 }))
    const dialogo = await screen.findByRole('dialog', {}, { timeout: 15000 })
    expect(dialogo.textContent).toContain('Es parte del combo «Combo X» y no tiene otro producto que lo reemplace: ese combo deja de poder armarse.')
    expect(dialogo.textContent).not.toContain('Combo apagado')
  })

  it('un producto que es una de varias opciones de un combo lo avisa en suave', async () => {
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Desactivar Galletitas' }, { timeout: 15000 }))
    const dialogo = await screen.findByRole('dialog', {}, { timeout: 15000 })
    expect(dialogo.textContent).toContain('También es una de las opciones del combo «Combo Y»: sigue armándose con los otros productos de ese lugar.')
    expect(dialogo.textContent).not.toContain('deja de poder armarse')
  })

  it('si no se pueden leer los combos, el aviso lo dice en vez de callar', async () => {
    combos.fetch.mockRejectedValue(new Error('red'))
    const user = userEvent.setup()
    montar()
    await user.click(await screen.findByRole('button', { name: 'Desactivar Galletitas' }, { timeout: 15000 }))
    const dialogo = await screen.findByRole('dialog', {}, { timeout: 15000 })
    expect(dialogo.textContent).toContain('No se pudo verificar si es parte de algún combo')
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
