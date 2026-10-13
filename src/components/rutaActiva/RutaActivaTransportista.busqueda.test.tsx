/**
 * Buscar un cliente entre las entregas funciona sin señal.
 *
 * La ruta del chofer puede venir del caché del teléfono (`desdeCache`, sin red):
 * la búsqueda filtra en memoria sobre las paradas que ya tiene, y escribir en el
 * buscador no dispara ninguna consulta al servidor.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within, fireEvent } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { PedidoConCliente } from './useEntregaParada'

const { supabaseStub } = vi.hoisted(() => ({
  supabaseStub: {
    rpc: vi.fn(),
    from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
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
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({ isOnline: false }) }))
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

const PARADAS = [
  { id: '10', total: 1000, monto_pagado: 0, estado: 'asignado', estado_pago: 'pendiente', orden_entrega: 1, items: [],
    cliente: { id: '1', nombre_fantasia: 'Kiosco Sur', direccion: 'San Martín 123', latitud: -26.83, longitud: -65.21 } },
  { id: '11', total: 2000, monto_pagado: 0, estado: 'asignado', estado_pago: 'pendiente', orden_entrega: 2, items: [],
    cliente: { id: '2', nombre_fantasia: 'Almacén Ñandú', direccion: 'Avenida Perón 77', telefono: '381 444-5566', latitud: -26.84, longitud: -65.22 } },
  { id: '12', total: 3000, monto_pagado: 0, estado: 'asignado', estado_pago: 'pendiente', orden_entrega: 3, items: [],
    cliente: { id: '3', nombre_fantasia: 'Despensa Oeste', direccion: 'Mitre 9', latitud: -26.85, longitud: -65.23 } },
] as unknown as PedidoConCliente[]

vi.mock('../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  useDepositoCoords: () => ({ lat: -26.8241, lng: -65.2226 }),
  useRecorridoActivoQuery: () => ({
    data: { id: '77', polylines: null, paradas: PARADAS, fecha: '2026-10-13', obtenidoEn: 1 },
    isLoading: false, isError: true, refetch: vi.fn(), desdeCache: true, datosDe: '2026-10-13T08:00:00Z',
  }),
}))
vi.mock('./MapaRutaGoogle', () => ({ default: () => <div>Mapa de prueba</div> }))

import RutaActivaTransportista from './RutaActivaTransportista'

describe('RutaActivaTransportista — buscar cliente sin red (ruta desde el caché)', () => {
  beforeEach(() => { vi.clearAllMocks() })

  it('filtra las paradas en memoria y no consulta al servidor', async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={queryClient}>
        <RutaActivaTransportista onMarcarEntregado={vi.fn()} userId="chofer-1" />
      </QueryClientProvider>,
    )
    await screen.findByText('Mapa de prueba')
    expect(screen.getByRole('alert')).toHaveTextContent('Ruta guardada en el teléfono')

    fireEvent.click(screen.getByRole('button', { name: /abrir el detalle de la parada/i }))
    supabaseStub.rpc.mockClear()
    supabaseStub.from.mockClear()

    fireEvent.change(screen.getByRole('searchbox', { name: /buscar cliente/i }), { target: { value: 'peron' } })

    const filas = within(screen.getByRole('list', { name: /todas las paradas/i })).getAllByRole('listitem')
    expect(filas).toHaveLength(1)
    expect(filas[0]).toHaveTextContent('Almacén Ñandú')
    expect(within(filas[0]).getByTestId('numero-parada')).toHaveTextContent('2')
    expect(supabaseStub.rpc).not.toHaveBeenCalled()
    expect(supabaseStub.from).not.toHaveBeenCalled()

    // Y tocarla la vuelve parada activa, también sin red.
    fireEvent.click(within(filas[0]).getByRole('button'))
    fireEvent.click(screen.getByRole('button', { name: /abrir el detalle de la parada/i }))
    expect(screen.getByRole('button', { name: /abrir el detalle de la parada/i })).toHaveTextContent('Almacén Ñandú')
    expect(supabaseStub.rpc).not.toHaveBeenCalled()
    expect(supabaseStub.from).not.toHaveBeenCalled()
  })
})
