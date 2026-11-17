/**
 * STK-13 (#1542): editar la compra y sincronizar sus lotes son dos llamadas. Si
 * la segunda falla, el container no puede dejarlo en un toast que se cierra: muestra
 * un aviso que queda, con «Reintentar», que repite sólo la sincronización de los
 * lotes con la misma foto.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const actualizar = vi.fn()
const reintentar = vi.fn()
const notifySuccess = vi.fn()
const notifyWarning = vi.fn()

const COMPRA = { id: 77, items: [{ id: 5 }] }
const PENDIENTE = { compraId: '77', lotes: [{ producto_id: 7, fecha_vencimiento: '2027-03-01', cantidad: 8 }] }

vi.mock('../../hooks/queries', () => ({
  useComprasQuery: () => ({ data: [COMPRA], isLoading: false }),
  useComprasTransferenciasQuery: () => ({ data: null }),
  useCompraQuery: () => ({ data: undefined }),
  useTraerCompraFresca: () => vi.fn().mockResolvedValue(COMPRA),
  useProveedoresQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useNotasCreditoByCompraQuery: () => ({ data: [] }),
  useNotasCreditoResumenQuery: () => ({ data: [] }),
  useRegistrarCompraMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarCompraMutation: () => ({ mutateAsync: actualizar, isPending: false }),
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

vi.mock('../../hooks/queries/useComprasQuery', () => ({
  reintentarSincronizarLotes: (...args: unknown[]) => reintentar(...args),
}))

vi.mock('../../hooks/queries/useLotesQuery', () => ({
  useLotesCompraQuery: () => ({ data: [] }),
}))

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdmin: true, isEncargado: false, user: { id: 'u1' } }),
}))

vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: notifySuccess, warning: notifyWarning }),
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1 }),
}))

vi.mock('../../hooks/useResetOnSucursalChange', () => ({
  useResetOnSucursalChange: () => undefined,
}))

vi.mock('../vistas/VistaCompras', () => ({
  default: ({ onEditarCompra }: { onEditarCompra?: (c: unknown) => void }) => (
    <button type="button" onClick={() => onEditarCompra?.(COMPRA)}>Editar</button>
  ),
}))

// El modal de edición guarda con un solo botón, para disparar el handler del container.
vi.mock('../modals/ModalCompra', () => ({
  default: ({ onGuardarEdicion }: { onGuardarEdicion?: (i: unknown) => Promise<void> }) => (
    <button type="button" onClick={() => void onGuardarEdicion?.({ compraId: '77' })}>Guardar edición</button>
  ),
}))

import ComprasContainer from './ComprasContainer'

async function editarYGuardar() {
  const user = userEvent.setup()
  const qc = new QueryClient()
  render(
    <QueryClientProvider client={qc}>
      <ComprasContainer />
    </QueryClientProvider>,
  )
  await user.click(await screen.findByText('Editar'))
  await user.click(await screen.findByText('Guardar edición'))
  return user
}

const RESULTADO_OK = {
  compraId: '77', warningCostoPromedio: [], warningCostoCompra: [], warningIiDeclarado: null,
  warningConceptos: null, warningMedidas: null,
}

describe('ComprasContainer · lotes sin sincronizar tras editar (STK-13)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it('con los lotes al día no aparece ningún aviso', async () => {
    actualizar.mockResolvedValue({ ...RESULTADO_OK, warningLotes: null, lotesPendientes: null })
    await editarYGuardar()
    await waitFor(() => expect(notifySuccess).toHaveBeenCalledWith('Compra actualizada'))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('si no se sincronizaron, queda el aviso con «Reintentar» y al lograrlo se va', async () => {
    actualizar.mockResolvedValue({ ...RESULTADO_OK, warningLotes: 'La compra se editó, pero los vencimientos…', lotesPendientes: PENDIENTE })
    reintentar.mockResolvedValue(null)
    const user = await editarYGuardar()

    const aviso = await screen.findByRole('alert')
    expect(aviso).toHaveTextContent('quedaron sin sincronizar')
    expect(aviso).toHaveTextContent('#77')

    await user.click(screen.getByRole('button', { name: 'Reintentar' }))
    await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument())
    expect(reintentar).toHaveBeenCalledTimes(1)
    expect(reintentar.mock.calls[0][2]).toEqual(PENDIENTE)
    expect(notifySuccess).toHaveBeenCalledWith('Vencimientos sincronizados con la compra')
  })

  it('si el reintento falla, el aviso sigue y dice el motivo', async () => {
    actualizar.mockResolvedValue({ ...RESULTADO_OK, warningLotes: 'x', lotesPendientes: PENDIENTE })
    reintentar.mockRejectedValue(new Error('Sin conexión: no se pudo confirmar el guardado de los vencimientos.'))
    const user = await editarYGuardar()

    await user.click(await screen.findByRole('button', { name: 'Reintentar' }))
    expect(await screen.findByText(/Último intento: Sin conexión/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeEnabled()
  })
})
