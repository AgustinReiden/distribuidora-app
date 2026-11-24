/**
 * Tanda 6 (#1603), pedido de la coordinadora: `actualizar_compra_items` ahora devuelve
 * `warning_descuadre` (tarjeta A) y el hook lo sube como `warningDescuadre`. Para que el aviso se
 * vea al editar una compra, `handleGuardarEdicionCompra` lo pasa a `avisosDeLaBase` (antes iba `null`).
 * Se lee como opcional: compila contra `main`, donde el hook todavía no trae el campo.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const actualizar = vi.fn()
const notifyWarning = vi.fn()

const DE_LA_LISTA = { id: 77, items: [{ id: 1 }] }

vi.mock('../../hooks/queries', () => ({
  useComprasQuery: () => ({ data: [DE_LA_LISTA], isLoading: false }),
  useComprasTransferenciasQuery: () => ({ data: null }),
  useCompraQuery: () => ({ data: undefined }),
  useTraerCompraFresca: () => () => Promise.resolve(DE_LA_LISTA),
  useProveedoresQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useNotasCreditoByCompraQuery: () => ({ data: [] }),
  useNotasCreditoResumenQuery: () => ({ data: {} }),
  useRegistrarCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarCompraMutation: () => ({ mutateAsync: actualizar, isPending: false }),
  useAnularCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCambiarProveedorCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearProductoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearProveedorMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useRegistrarNotaCreditoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useAnularNotaCreditoCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarProductoMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCategoriasQuery: () => ({ data: [] }),
  useMarcasQuery: () => ({ data: [] }),
  useAsegurarCatalogo: () => ({ asegurar: vi.fn(), creando: false }),
}))
vi.mock('../../hooks/queries/useLotesQuery', () => ({ useLotesCompraQuery: () => ({ data: [] }) }))
vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true, user: { id: 'u1' } }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: notifyWarning }),
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))
vi.mock('../vistas/VistaCompras', () => ({
  default: ({ onEditarCompra }: { onEditarCompra?: (c: unknown) => void }) => (
    <button type="button" onClick={() => onEditarCompra?.(DE_LA_LISTA)}>Editar</button>
  ),
}))
vi.mock('../modals/ModalCompra', () => ({
  default: ({ onGuardarEdicion }: { onGuardarEdicion?: (i: unknown) => Promise<void> }) => (
    <button type="button" onClick={() => void onGuardarEdicion?.({ compraId: 77 })}>Guardar edición</button>
  ),
}))

import ComprasContainer from './ComprasContainer'

const RESPUESTA = {
  warningCostoPromedio: [],
  warningCostoReposicion: [],
}

async function editarYGuardar() {
  const user = userEvent.setup()
  render(<ComprasContainer />)
  await user.click(await screen.findByText('Editar'))
  await user.click(await screen.findByText('Guardar edición'))
}

describe('editar una compra muestra el aviso de descuadre de la base', () => {
  beforeEach(() => vi.clearAllMocks())

  it('si la RPC devuelve `warningDescuadre`, se avisa (persistente)', async () => {
    actualizar.mockResolvedValue({ ...RESPUESTA, warningDescuadre: 'El total no cuadra con la suma de las líneas.' })
    await editarYGuardar()
    expect(notifyWarning).toHaveBeenCalledWith('El total no cuadra con la suma de las líneas.', { persist: true })
  })

  it('sin ese campo (hook de antes) no avisa nada de descuadre', async () => {
    actualizar.mockResolvedValue({ ...RESPUESTA })
    await editarYGuardar()
    expect(notifyWarning).not.toHaveBeenCalled()
  })
})
