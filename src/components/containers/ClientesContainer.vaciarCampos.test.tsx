/**
 * FRT-4 (#1517): editar un cliente no dejaba vaciar el teléfono, el CUIT, el
 * contacto, los horarios, el rubro ni las notas.
 *
 * El container armaba `telefono: data.telefono || undefined`, y `undefined` no
 * viaja en el UPDATE: se veía "Cliente actualizado" y el valor viejo volvía con el
 * refetch. El alta ya coercía a `null`. Vaciar un campo tiene que mandar `null`.
 *
 * El modal real no es lo que se prueba: un botón lo reemplaza y guarda con los
 * campos de texto vacíos, como lo hace el formulario.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ClienteDB } from '../../types'

const { CLIENTE, SESION, actualizar } = vi.hoisted(() => ({
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

// El formulario guarda con los campos de texto opcionales vaciados.
vi.mock('../modals/ModalCliente', () => ({
  default: ({ onSave }: { onSave: (data: Record<string, unknown>) => Promise<void> }) => (
    <button
      type="button"
      onClick={() => void onSave({
        razonSocial: 'Ramón Ernesto Ledesma',
        nombreFantasia: 'Almacén Don Ramón',
        direccion: 'Mitre 100',
        telefono: '',
        cuit: '',
        contacto: '',
        horarios_atencion: '',
        horario_entrega: '',
        rubro: '',
        notas: '',
        zona_id: '',
        sin_horario_fijo: false,
        preventista_ids: [],
        descuentosPorCategoria: [],
      })}
    >
      Guardar con campos vacíos
    </button>
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

function comoRol(rol: 'admin' | 'preventista') {
  SESION.perfil = { rol }
  SESION.isAdmin = rol === 'admin'
  SESION.isPreventista = rol === 'preventista'
}

const CAMPOS_DE_TEXTO = ['telefono', 'contacto', 'horarios_atencion', 'horario_entrega', 'rubro', 'notas']

async function guardarVaciando() {
  const user = userEvent.setup()
  montar()
  await user.click(await screen.findByRole('button', { name: /editar cliente almacén don ramón/i }))
  await user.click(await screen.findByRole('button', { name: 'Guardar con campos vacíos' }))
  await waitFor(() => expect(actualizar).toHaveBeenCalledTimes(1))
  return actualizar.mock.calls[0][0] as { id: string; data: Record<string, unknown> }
}

describe('ClientesContainer — vaciar los campos opcionales al editar (FRT-4)', () => {
  beforeEach(() => {
    actualizar.mockReset().mockResolvedValue(undefined)
  })

  it('el admin: cada campo vaciado viaja como null (undefined no viaja en el UPDATE)', async () => {
    comoRol('admin')
    const { id, data } = await guardarVaciando()

    expect(id).toBe('4118')
    for (const campo of CAMPOS_DE_TEXTO) {
      expect(data, campo).toHaveProperty(campo, null)
    }
    expect(data).toHaveProperty('cuit', null)
  })

  it('el preventista (edición acotada): también manda null, y no toca el CUIT', async () => {
    comoRol('preventista')
    const { data } = await guardarVaciando()

    for (const campo of CAMPOS_DE_TEXTO) {
      expect(data, campo).toHaveProperty(campo, null)
    }
    // El patch acotado nunca lleva el CUIT: no se pisa desde esa UI.
    expect(data).not.toHaveProperty('cuit')
  })
})
