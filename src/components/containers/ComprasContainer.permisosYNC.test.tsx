/**
 * Dos cableados de ComprasContainer que mentían:
 *
 * · 1557-b9: «crear producto rápido» se ofrecía a todos, y el INSERT de
 *   `productos` es sólo de admin (`mt_productos_insert`): el encargado recibía
 *   un 42501 crudo. Ahora sólo se le pasa al modal si el usuario es admin.
 * · 1544-b4: si fallaba la consulta de notas de crédito, `ncResumen` quedaba en
 *   `[]` y aparecía «Editar» en una compra que sí tiene notas. Ahora, sin saber
 *   qué notas hay, no se ofrece editar (el server la rechaza igual).
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const estado = vi.hoisted(() => ({
  isAdmin: true,
  isEncargado: false,
  ncError: false,
}))

vi.mock('../../hooks/queries', () => ({
  useComprasQuery: () => ({ data: [{ id: 77, items: [] }], isLoading: false }),
  useComprasTransferenciasQuery: () => ({ data: null }),
  useCompraQuery: () => ({ data: undefined }),
  useTraerCompraFresca: () => vi.fn(),
  useProveedoresQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useNotasCreditoByCompraQuery: () => ({ data: [] }),
  useNotasCreditoResumenQuery: () => (
    estado.ncError ? { data: undefined, isError: true } : { data: [], isError: false }
  ),
  useRegistrarCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useAnularCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCambiarProveedorCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearProductoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearProveedorMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useRegistrarNotaCreditoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarProductoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCategoriasQuery: () => ({ data: [] }),
  useMarcasQuery: () => ({ data: [] }),
  useAsegurarCatalogo: () => ({ asegurar: vi.fn(), creando: false }),
}))

vi.mock('../../hooks/queries/useLotesQuery', () => ({
  useLotesCompraQuery: () => ({ data: [] }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: estado.isAdmin, isEncargado: estado.isEncargado, user: { id: 'u1' } }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn() }),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

vi.mock('../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: () => undefined,
}))

vi.mock('../vistas/VistaCompras', () => ({
  default: ({ onNuevaCompra, onEditarCompra }: { onNuevaCompra?: () => void; onEditarCompra?: (c: unknown) => void }) => (
    <div>
      <button type="button" onClick={onNuevaCompra}>Nueva compra</button>
      {onEditarCompra && <button type="button">Editar compra</button>}
    </div>
  ),
}))

vi.mock('../modals/ModalCompra', () => ({
  default: ({ onCrearProductoRapido }: { onCrearProductoRapido?: unknown }) => (
    <div>{onCrearProductoRapido ? 'ofrece crear producto' : 'no ofrece crear producto'}</div>
  ),
}))

import ComprasContainer from './ComprasContainer'

describe('ComprasContainer · crear producto rápido es sólo de admin (1557-b9)', () => {
  beforeEach(() => {
    estado.isAdmin = true
    estado.isEncargado = false
    estado.ncError = false
  })

  it('el admin lo tiene', async () => {
    const user = userEvent.setup()
    render(<ComprasContainer />)
    await user.click(await screen.findByText('Nueva compra'))
    expect(await screen.findByText('ofrece crear producto')).toBeInTheDocument()
  })

  it('el encargado carga la compra pero no ve el alta del producto', async () => {
    estado.isAdmin = false
    estado.isEncargado = true
    const user = userEvent.setup()
    render(<ComprasContainer />)
    await user.click(await screen.findByText('Nueva compra'))
    expect(await screen.findByText('no ofrece crear producto')).toBeInTheDocument()
  })
})

describe('ComprasContainer · sin saber las notas de crédito no se ofrece editar (1544-b4)', () => {
  beforeEach(() => {
    estado.isAdmin = true
    estado.isEncargado = false
    estado.ncError = false
  })

  it('con las notas cargadas, «Editar» está', async () => {
    render(<ComprasContainer />)
    expect(await screen.findByText('Editar compra')).toBeInTheDocument()
  })

  it('si la consulta de notas falló, «Editar» no se ofrece', async () => {
    estado.ncError = true
    render(<ComprasContainer />)
    await screen.findByText('Nueva compra')
    expect(screen.queryByText('Editar compra')).not.toBeInTheDocument()
  })
})
