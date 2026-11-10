/**
 * La ficha del cliente se bajaba dos veces (#1517, menor).
 *
 * `ClientesContainer` llamaba a `useFichaCliente(clienteFichaId)` y tiraba el
 * resultado: la ficha la carga `ModalFichaCliente` con su propio hook. Resultado:
 * al abrir una ficha se bajaban dos veces todos los pedidos y todos los pagos del
 * cliente. El container no tiene que cargar la ficha por su cuenta.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ClienteDB } from '../../types'

const { CLIENTE, SESION, actualizar, useFichaCliente } = vi.hoisted(() => ({
  CLIENTE: {
    id: '4118',
    nombre_fantasia: 'Almacén Don Ramón',
    razon_social: 'Ramón Ernesto Ledesma',
    activo: true,
    saldo_cuenta: 0,
    telefono: '381 555 0000',
    cuit: '20-11111111-1',
    contacto: 'Ramón',
    horarios_atencion: '8 a 12',
    horario_entrega: 'mañana',
    rubro: 'Almacén',
    notas: 'Entrega por el costado',
  } as unknown as ClienteDB,
  SESION: {
    user: { id: 'u1' },
    perfil: { rol: 'admin' },
    isAdmin: true,
    isPreventista: false,
    isEncargado: false,
  },
  actualizar: vi.fn(),
  useFichaCliente: vi.fn(() => ({ pedidosCliente: [], estadisticas: null, loading: false })),
}))

vi.mock('../../hooks/queries', () => ({
  useClientesOperativosQuery: () => ({ data: [CLIENTE], isLoading: false, isError: false, refetch: vi.fn() }),
  useClienteQuery: () => ({ data: undefined }),
  useCrearClienteMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useActualizarClienteMutation: () => ({ mutateAsync: actualizar, isPending: false }),
  useEliminarClienteMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearPedidoCambioEnRutaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  contarReferenciasDeCliente: vi.fn(),
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
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => SESION }))
vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1, currentSucursalNombre: 'Tucumán' }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))

vi.mock('../../hooks/supabase/useFichaCliente', () => ({ useFichaCliente }))
// El modal de la ficha, reducido a un marcador: lo que se mira es qué baja el container.
vi.mock('../modals/ModalFichaCliente', () => ({
  default: () => <div>Ficha abierta</div>,
}))

import ClientesContainer from './ClientesContainer'

describe('ClientesContainer — la ficha la baja el modal, no el container', () => {
  beforeEach(() => {
    useFichaCliente.mockClear()
  })

  it('abrir una ficha no llama a useFichaCliente desde el container', async () => {
    const user = userEvent.setup()
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={queryClient}>
        <ClientesContainer />
      </QueryClientProvider>,
    )

    await user.click(await screen.findByRole('button', { name: /ver ficha/i }))
    expect(await screen.findByText('Ficha abierta')).toBeInTheDocument()

    expect(useFichaCliente).not.toHaveBeenCalled()
  })
})
