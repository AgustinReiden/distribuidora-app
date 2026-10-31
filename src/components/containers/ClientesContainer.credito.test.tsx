/**
 * El crédito del cliente (descuento, límite y días) viaja sólo si guarda un
 * admin (#1156).
 *
 * Desde la migración de #1156 el trigger trg_clientes_saldo_y_credito_solo_admin
 * rechaza con 42501 que alguien que no es admin CAMBIE descuento_porcentaje,
 * limite_credito o dias_credito, y que los fije distintos de los defaults en el
 * alta. Un PATCH que reenvía el valor vigente pasa, pero el cliente que edita el
 * encargado sale del caché (staleTime de 5 minutos, sin refetch al volver a la
 * ventana): si el admin acaba de cambiar el límite, el encargado reenviaba el
 * viejo y el guardado de una dirección daba 42501 (o, sin el trigger, pisaba en
 * silencio lo del admin). Por eso las tres claves van adentro del bloque
 * `isAdmin`, igual que `descuentos_categoria` y `reservado_admin`: para quien no
 * es admin no viajan, y en el alta `createCliente` completa 0 / 30 / 0.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ClienteDB } from '../../types'

const { CLIENTE, SESION, actualizar, crear } = vi.hoisted(() => ({
  CLIENTE: {
    id: '4118',
    nombre_fantasia: 'Almacén Don Ramón',
    razon_social: 'Ramón Ernesto Ledesma',
    activo: true,
    limite_credito: 0,
    dias_credito: 30,
    descuento_porcentaje: 0,
  } as unknown as ClienteDB,
  SESION: {
    user: { id: 'u1' },
    perfil: { rol: 'admin' },
    isAdmin: true,
    isPreventista: false,
    isEncargado: false,
  },
  actualizar: vi.fn(),
  crear: vi.fn(),
}))

vi.mock('../../hooks/queries', () => ({
  useClientesOperativosQuery: () => ({ data: [CLIENTE], isLoading: false, isError: false, refetch: vi.fn() }),
  useClienteQuery: () => ({ data: undefined }),
  useCrearClienteMutation: () => ({ mutateAsync: crear, isPending: false }),
  useActualizarClienteMutation: () => ({ mutateAsync: actualizar, isPending: false }),
  useEliminarClienteMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCrearPedidoCambioEnRutaMutation: () => ({ mutateAsync: vi.fn(), isPending: false }),
  contarReferenciasDeCliente: vi.fn(),
  verificarDuplicadoCliente: vi.fn(),
  useZonasEstandarizadasQuery: () => ({ data: [] }),
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
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))
vi.mock('../../hooks/useResetOnSucursalChange', () => ({ useResetOnSucursalChange: () => undefined }))

// La vista, reducida a «Nuevo» y «Editar».
vi.mock('../vistas/VistaClientes', () => ({
  default: (props: { onNuevoCliente: () => void; onEditarCliente: (c: ClienteDB) => void }) => (
    <>
      <button type="button" onClick={() => props.onNuevoCliente()}>Nuevo</button>
      <button type="button" onClick={() => props.onEditarCliente(CLIENTE)}>Editar</button>
    </>
  ),
}))

// El modal, reducido a «Guardar» con lo que el formulario manda: el crédito
// que muestra (el del cliente cacheado) y una dirección nueva.
vi.mock('../modals/ModalCliente', () => ({
  default: (props: { onSave: (data: unknown) => Promise<void> }) => (
    <button
      type="button"
      onClick={() => {
        props.onSave({
          tipo_documento: 'CUIT',
          numero_documento: '',
          cuit: '',
          razonSocial: 'Ramón Ernesto Ledesma',
          nombreFantasia: 'Almacén Don Ramón',
          direccion: 'San Martín 1200',
          aclaracionDireccion: '',
          latitud: null,
          longitud: null,
          place_id: null,
          telefono: '',
          contacto: '',
          zona: '',
          zona_id: '',
          horarios_atencion: '',
          dias_atencion: null,
          horario_entrega: '',
          sin_horario_fijo: false,
          rubro: '',
          notas: '',
          limiteCredito: 1000,
          diasCredito: 15,
          descuentoPorcentaje: 10,
          tipoFacturaDefault: 'ZZ',
          descuentosPorCategoria: [],
          preventista_id: '',
          preventista_ids: [],
          reservado_admin: false,
        }).catch(() => undefined)
      }}
    >
      Guardar
    </button>
  ),
}))

import ClientesContainer from './ClientesContainer'

const CLAVES_CREDITO = ['limite_credito', 'dias_credito', 'descuento_porcentaje']

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

async function guardar(boton: 'Nuevo' | 'Editar') {
  const user = userEvent.setup()
  montar()
  await user.click(await screen.findByRole('button', { name: boton }))
  await user.click(await screen.findByRole('button', { name: 'Guardar' }))
}

describe('ClientesContainer: el crédito del cliente viaja sólo si guarda un admin (#1156)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    actualizar.mockResolvedValue(CLIENTE)
    crear.mockResolvedValue(CLIENTE)
  })

  it('el encargado edita un cliente: el PATCH no lleva descuento, límite ni días', async () => {
    comoRol('encargado')
    await guardar('Editar')
    await vi.waitFor(() => expect(actualizar).toHaveBeenCalledTimes(1))
    const { id, data } = actualizar.mock.calls[0][0] as { id: string; data: Record<string, unknown> }
    expect(id).toBe('4118')
    expect(data.direccion).toBe('San Martín 1200')
    for (const clave of CLAVES_CREDITO) expect(data, clave).not.toHaveProperty(clave)
  })

  it('el admin edita un cliente: el PATCH lleva las tres', async () => {
    comoRol('admin')
    await guardar('Editar')
    await vi.waitFor(() => expect(actualizar).toHaveBeenCalledTimes(1))
    const { data } = actualizar.mock.calls[0][0] as { data: Record<string, unknown> }
    expect(data).toMatchObject({ limite_credito: 1000, dias_credito: 15, descuento_porcentaje: 10 })
  })

  it('el preventista da de alta un cliente: el alta no lleva ninguna (createCliente completa los defaults)', async () => {
    comoRol('preventista')
    await guardar('Nuevo')
    await vi.waitFor(() => expect(crear).toHaveBeenCalledTimes(1))
    const data = crear.mock.calls[0][0] as Record<string, unknown>
    expect(data.direccion).toBe('San Martín 1200')
    for (const clave of CLAVES_CREDITO) expect(data, clave).not.toHaveProperty(clave)
  })
})
