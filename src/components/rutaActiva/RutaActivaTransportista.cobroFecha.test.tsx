/**
 * cobros-B3 (tanda 6 de #1603): `ModalRegistrarPago` sólo deja elegir otra fecha a un admin. La
 * pantalla del chofer lo abre también, así que tiene que decirle si quien cobra es admin: sin
 * eso (isAdmin en false por defecto) un admin que cobra desde la ruta perdía la fecha.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { PedidoConCliente } from './useEntregaParada'

const { supabaseStub, auth, propsModal } = vi.hoisted(() => ({
  supabaseStub: {
    rpc: vi.fn(),
    from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  auth: { isAdmin: false },
  propsModal: { ultimas: undefined as undefined | Record<string, unknown> },
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
vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isOnline: true, isAdmin: auth.isAdmin }),
}))
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
// El cobro abierto sobre la parada: se fuerza `pedidoParaCobrar` y el modal sólo anota sus props.
vi.mock('./useEntregaParada', async (importOriginal) => {
  const actual = await importOriginal<typeof import('./useEntregaParada')>()
  return {
    ...actual,
    useEntregaParada: (args: Parameters<typeof actual.useEntregaParada>[0]) => ({
      ...actual.useEntregaParada(args),
      pedidoParaCobrar: PARADAS[0],
    }),
  }
})
vi.mock('../modals/ModalRegistrarPago', () => ({
  default: (props: Record<string, unknown>) => {
    propsModal.ultimas = props
    return <div>Modal de cobro</div>
  },
}))

import RutaActivaTransportista from './RutaActivaTransportista'

async function montar() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={queryClient}>
      <RutaActivaTransportista onMarcarEntregado={vi.fn()} userId="chofer-1" />
    </QueryClientProvider>,
  )
  await screen.findByText('Modal de cobro')
}

beforeEach(() => {
  propsModal.ultimas = undefined
})

describe('RutaActivaTransportista — la fecha del cobro según el rol (cobros-B3)', () => {
  it('un admin que cobra desde la ruta conserva la elección de fecha', async () => {
    auth.isAdmin = true
    await montar()
    expect(propsModal.ultimas?.isAdmin).toBe(true)
  })

  it('el chofer cobra con la fecha de hoy', async () => {
    auth.isAdmin = false
    await montar()
    expect(propsModal.ultimas?.isAdmin).toBe(false)
  })
})
