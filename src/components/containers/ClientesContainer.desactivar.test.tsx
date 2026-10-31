/**
 * Desactivar un cliente es un botón propio, no un desvío de "Eliminar".
 *
 * Hasta acá la baja lógica sólo se alcanzaba por el tacho, y sólo si el cliente
 * tenía historial: a uno sin pedidos no había forma de desactivarlo (el admin
 * lo borraba, el encargado chocaba con "solo un administrador puede eliminar").
 * Ahora admin y encargado tienen "Desactivar" en la tarjeta, con confirmación,
 * para cualquier cliente activo; el tacho queda para el admin.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ClienteDB } from '../../types'

const { CLIENTE, SESION, actualizar, contarReferencias } = vi.hoisted(() => ({
  CLIENTE: {
    id: '4118',
    nombre_fantasia: 'Almacén Don Ramón',
    razon_social: 'Ramón Ernesto Ledesma',
    activo: true,
    saldo_cuenta: 0,
  } as unknown as ClienteDB,
  SESION: {
    user: { id: 'u1' },
    perfil: { rol: 'encargado' },
    isAdmin: false,
    isPreventista: false,
    isEncargado: true,
  },
  actualizar: vi.fn(),
  contarReferencias: vi.fn(),
}))

vi.mock('../../hooks/queries', () => ({
  useClientesOperativosQuery: () => ({ data: [CLIENTE], isLoading: false, isError: false, refetch: vi.fn() }),
  useClienteQuery: () => ({ data: undefined }),
  useCrearClienteMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarClienteMutation: () => ({ mutateAsync: actualizar, isPending: false }),
  useEliminarClienteMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearPedidoCambioEnRutaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  contarReferenciasDeCliente: contarReferencias,
  verificarDuplicadoCliente: vi.fn(),
  useZonasEstandarizadasQuery: () => ({ data: [] }),
  useUsuariosQuery: () => ({ data: [] }),
  useProductosQuery: () => ({ data: [] }),
  useClienteAdmiteAdelantoQuery: () => ({ data: undefined }),
}))
vi.mock('../../hooks/supabase', () => ({
  usePagos: () => ({
    obtenerResumenCuenta: vi.fn(),
    registrarPago: vi.fn(),
    registrarPagoFIFO: vi.fn(),
    registrarPagoCombinadoFIFO: vi.fn(),
  }),
}))
vi.mock('../../hooks/supabase/useFichaCliente', () => ({
  useFichaCliente: () => ({ pedidosCliente: [], estadisticas: null, loading: false }),
}))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => SESION }))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1, currentSucursalNombre: 'Tucumán' }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))

// La confirmación, reducida a su título y a «Confirmar» / «Cancelar».
vi.mock('../modals/ModalConfirmacion', () => ({
  default: (props: { config: { titulo: string; onConfirm: () => void }; onClose: () => void }) => (
    <div role="dialog" aria-label={props.config.titulo}>
      <button type="button" onClick={() => props.config.onConfirm()}>Confirmar</button>
      <button type="button" onClick={() => props.onClose()}>Cancelar</button>
    </div>
  ),
}))

import ClientesContainer from './ClientesContainer'

function montar() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <ClientesContainer />
    </QueryClientProvider>,
  )
}

function comoRol(rol: 'admin' | 'encargado' | 'preventista') {
  SESION.perfil = { rol }
  SESION.isAdmin = rol === 'admin'
  SESION.isEncargado = rol === 'encargado'
  SESION.isPreventista = rol === 'preventista'
}

const DESACTIVAR = /desactivar cliente almacén don ramón/i
const ELIMINAR = /eliminar cliente almacén don ramón/i

describe('ClientesContainer — desactivar cliente', () => {
  beforeEach(() => {
    actualizar.mockReset().mockResolvedValue(undefined)
    contarReferencias.mockReset()
  })

  it('el encargado desactiva con confirmación, sin pasar por el conteo de eliminar', async () => {
    comoRol('encargado')
    const user = userEvent.setup()
    montar()

    await user.click(await screen.findByRole('button', { name: DESACTIVAR }))
    expect(screen.queryByRole('button', { name: ELIMINAR })).not.toBeInTheDocument()

    expect(await screen.findByRole('dialog', { name: 'Desactivar cliente' })).toBeInTheDocument()
    expect(actualizar).not.toHaveBeenCalled()

    await user.click(screen.getByRole('button', { name: 'Confirmar' }))

    expect(actualizar).toHaveBeenCalledWith({ id: '4118', data: { activo: false } })
    expect(contarReferencias).not.toHaveBeenCalled()
  })

  it('cancelar la confirmación no toca al cliente', async () => {
    comoRol('encargado')
    const user = userEvent.setup()
    montar()

    await user.click(await screen.findByRole('button', { name: DESACTIVAR }))
    await user.click(await screen.findByRole('button', { name: 'Cancelar' }))

    expect(actualizar).not.toHaveBeenCalled()
  })

  it('el admin tiene los dos botones: desactivar y eliminar', async () => {
    comoRol('admin')
    montar()

    expect(await screen.findByRole('button', { name: DESACTIVAR })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: ELIMINAR })).toBeInTheDocument()
  })

  it('el preventista no ve ninguno de los dos', async () => {
    comoRol('preventista')
    montar()

    // La vista es lazy: esperar a que la tarjeta esté antes de mirar que no hay botón.
    expect(await screen.findByRole('button', { name: /editar cliente almacén don ramón/i })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: DESACTIVAR })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: ELIMINAR })).not.toBeInTheDocument()
  })
})
