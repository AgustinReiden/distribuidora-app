/**
 * FRG-4 (#1557): dos ediciones de la misma compra se pisaban.
 *
 * `handleEditarCompra` abría el modal con la compra de la lista (caché de 5
 * minutos) y `actualizar_compra_items` no recibía versión: la segunda edición
 * reemplazaba todas las líneas con su copia vieja. Ahora la edición parte de
 * la compra recién leída, y guarda con sus renglones como versión (la RPC
 * rechaza si ya no son los de hoy; eso lo prueba el ensayo SQL).
 *
 * Se monta el container con la vista y el modal stubbeados: lo que se prueba es
 * el cableado, qué compra le llega al modal.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const traerCompraFresca = vi.fn()
const notifyError = vi.fn()

const DE_LA_LISTA = { id: 77, items: [{ id: 1 }, { id: 2 }] }
const RECIEN_LEIDA = { id: 77, items: [{ id: 5 }, { id: 6 }] }

vi.mock('../../hooks/queries', () => ({
  useComprasQuery: () => ({ data: [DE_LA_LISTA], isLoading: false }),
  useComprasTransferenciasQuery: () => ({ data: null }),
  useCompraQuery: () => ({ data: undefined }),
  useTraerCompraFresca: () => traerCompraFresca,
  useProveedoresQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useNotasCreditoByCompraQuery: () => ({ data: [] }),
  useNotasCreditoResumenQuery: () => ({ data: {} }),
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
  useAuthData: () => ({ isAdmin: true, user: { id: 'u1' } }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: notifyError, success: vi.fn(), warning: vi.fn() }),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

vi.mock('../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: () => undefined,
}))

vi.mock('../vistas/VistaCompras', () => ({
  default: ({ onEditarCompra }: { onEditarCompra?: (c: unknown) => void }) => (
    <button type="button" onClick={() => onEditarCompra?.(DE_LA_LISTA)}>Editar</button>
  ),
}))

vi.mock('../modals/ModalCompra', () => ({
  default: ({ modo, compra }: { modo: string; compra?: { items?: Array<{ id: number }> } }) => (
    <div>{`modal ${modo}: renglones ${(compra?.items ?? []).map(i => i.id).join(',')}`}</div>
  ),
}))

import ComprasContainer from './ComprasContainer'

describe('editar una compra parte de la compra recién leída (FRG-4, #1557)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('el modal recibe la compra que se leyó al abrir, no la de la lista', async () => {
    traerCompraFresca.mockResolvedValue(RECIEN_LEIDA)
    const user = userEvent.setup()
    render(<ComprasContainer />)
    await user.click(await screen.findByText('Editar'))

    expect(await screen.findByText('modal editar: renglones 5,6')).toBeInTheDocument()
    expect(traerCompraFresca).toHaveBeenCalledWith(77)
    expect(notifyError).not.toHaveBeenCalled()
  })

  it('si no se puede leer, avisa y no abre la edición con la copia vieja', async () => {
    traerCompraFresca.mockRejectedValue(new Error('Sin conexión: no se pudo cargar la compra. Revisá la señal e intentá de nuevo.'))
    const user = userEvent.setup()
    render(<ComprasContainer />)
    await user.click(await screen.findByText('Editar'))

    await waitFor(() => expect(notifyError).toHaveBeenCalledTimes(1))
    expect(notifyError.mock.calls[0][0]).toMatch(/no se pudo cargar la compra/)
    expect(screen.queryByText(/modal editar/)).not.toBeInTheDocument()
  })
})
