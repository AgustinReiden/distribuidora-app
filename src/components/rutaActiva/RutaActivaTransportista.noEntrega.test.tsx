/**
 * «No se pudo entregar» normaliza el error de supabase (#1011).
 *
 * `onMarcarNoEntregado` hacía `throw new Error(error.message)`: con el objeto
 * plano de supabase-js eso perdía el `code` y, sin servidor, dejaba pasar
 * "TypeError: Failed to fetch" tal cual al modal del chofer (`setErrorNoEntrega`
 * en useEntregaParada), que no distinguía un rechazo del servidor de una señal
 * caída. Tiene que lanzar `errorDeSupabase`: la red se traduce a un aviso de que
 * NO se confirmó, y el mensaje del servidor pasa intacto.
 *
 * Se monta la pantalla real y se envuelve `useEntregaParada` sólo para agarrar
 * el callback que la pantalla le entrega; lo demás (SheetParada, modales) es real.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { PedidoConCliente } from './useEntregaParada'

const { supabaseStub, capturado } = vi.hoisted(() => ({
  supabaseStub: {
    rpc: vi.fn(),
    from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  capturado: { onMarcarNoEntregado: undefined as undefined | ((id: string, motivo: string, nota: string) => Promise<void>) },
}))

vi.mock('../../lib/supabase', () => ({
  supabase: supabaseStub,
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
vi.mock('../../hooks/supabase/base', () => ({
  supabase: supabaseStub,
  setErrorNotifier: vi.fn(),
  notifyError: vi.fn(),
  handleSupabaseError: vi.fn(),
}))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({ isOnline: true }) }))
vi.mock('../../hooks/useWatchPosition', () => ({
  useWatchPosition: () => ({ posicion: null, error: null, soportado: true }),
}))
vi.mock('../../hooks/useNavegacionVoz', () => ({
  useNavegacionVoz: () => ({ prime: vi.fn(), decir: vi.fn(), callar: vi.fn(), soportada: true }),
}))
vi.mock('../../hooks/useWakeLock', () => ({
  useWakeLock: () => ({ solicitar: vi.fn(), liberar: vi.fn(), soportado: true }),
}))
vi.mock('../../hooks/useGuiaNavegacion', () => ({
  useGuiaNavegacion: () => ({
    pasoActual: null, pasoSiguiente: null, distManiobra: null, rutaTramo: [], cargando: false, error: null,
  }),
}))

const PARADAS = [{
  id: '4625', total: 21600, monto_pagado: 0, estado: 'asignado', estado_pago: 'pendiente', orden_entrega: 1,
  cliente: { id: '1', nombre_fantasia: 'Kiosco Sur', direccion: 'San Martín 123', latitud: -26.83, longitud: -65.21 },
  items: [],
}] as unknown as PedidoConCliente[]

vi.mock('../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  useDepositoCoords: () => ({ lat: -26.8241, lng: -65.2226 }),
  useRecorridoActivoQuery: () => ({
    data: { id: '77', polylines: null, paradas: PARADAS, fecha: '2026-09-27', obtenidoEn: 1 },
    isLoading: false, isError: false, refetch: vi.fn(), desdeCache: false, datosDe: null,
  }),
}))
vi.mock('./MapaRutaGoogle', () => ({ default: () => <div>Mapa de prueba</div> }))
vi.mock('./useEntregaParada', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./useEntregaParada')>()
  return {
    ...actual,
    useEntregaParada: (args: Parameters<typeof actual.useEntregaParada>[0]) => {
      capturado.onMarcarNoEntregado = args.onMarcarNoEntregado as typeof capturado.onMarcarNoEntregado
      return actual.useEntregaParada(args)
    },
  }
})

import RutaActivaTransportista from './RutaActivaTransportista'

// Las dos formas reales de supabase-js (ver errorDeSupabase.test.ts).
const ERROR_DE_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
const ERROR_DE_SERVIDOR = { message: 'El pedido ya no está asignado a vos', details: '', hint: '', code: 'P0001' }

async function montarYAgarrar() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={queryClient}>
      <RutaActivaTransportista onMarcarEntregado={vi.fn()} userId="chofer-1" />
    </QueryClientProvider>,
  )
  await screen.findByText('Mapa de prueba')
  return capturado.onMarcarNoEntregado!
}

describe('RutaActivaTransportista — marcar no entregado (#1011)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    capturado.onMarcarNoEntregado = undefined
  })

  it('un fallo de red lanza el aviso de sin conexión, sin "Failed to fetch"', async () => {
    supabaseStub.rpc.mockResolvedValue({ data: null, error: ERROR_DE_RED })
    const marcar = await montarYAgarrar()

    const e = await marcar('4625', 'cliente_ausente', '').catch((x: Error) => x)

    expect(e).toBeInstanceOf(Error)
    expect((e as Error).message).toMatch(/^Sin conexión: no se pudo confirmar/)
    expect((e as Error).message).not.toMatch(/failed to fetch/i)
  })

  it('un error del servidor conserva su mensaje y su code', async () => {
    supabaseStub.rpc.mockResolvedValue({ data: null, error: ERROR_DE_SERVIDOR })
    const marcar = await montarYAgarrar()

    const e = await marcar('4625', 'cliente_ausente', '').catch((x: Error) => x)

    expect((e as Error).message).toBe('El pedido ya no está asignado a vos')
    expect((e as Error & { code?: string }).code).toBe('P0001')
  })
})
