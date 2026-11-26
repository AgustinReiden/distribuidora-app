/**
 * Fr-B1 de #1554 (T14 de #1690): «por cobrar» del encabezado sumaba el `total` de cada parada
 * no pagada, incluida la parte que el cliente ya había pagado de un parcial. Tiene que sumar lo
 * que falta (total menos lo pagado), como el resto de la app.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
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

const cliente = (n: number) => ({ id: String(n), nombre_fantasia: `Cliente ${n}`, direccion: `Calle ${n}`, latitud: -26.83, longitud: -65.21 })
const PARADAS = [
  // Parcial: 1.000 con 400 cobrados → faltan 600.
  { id: '1', total: 1000, monto_pagado: 400, estado: 'asignado', estado_pago: 'parcial', orden_entrega: 1, cliente: cliente(1), items: [] },
  // Sin cobrar: faltan los 2.000 enteros.
  { id: '2', total: 2000, monto_pagado: 0, estado: 'asignado', estado_pago: 'pendiente', orden_entrega: 2, cliente: cliente(2), items: [] },
  // Pagada: no suma.
  { id: '3', total: 5000, monto_pagado: 5000, estado: 'asignado', estado_pago: 'pagado', orden_entrega: 3, cliente: cliente(3), items: [] },
] as unknown as PedidoConCliente[]

vi.mock('../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  useDepositoCoords: () => ({ lat: -26.8241, lng: -65.2226 }),
  useRecorridoActivoQuery: () => ({
    data: { id: '77', polylines: null, paradas: PARADAS, fecha: '2026-09-27', obtenidoEn: 1 },
    isLoading: false, isError: false, refetch: vi.fn(), desdeCache: false, datosDe: null,
  }),
}))
vi.mock('./MapaRutaGoogle', () => ({ default: () => <div>Mapa de prueba</div> }))

import RutaActivaTransportista from './RutaActivaTransportista'

describe('RutaActivaTransportista — «por cobrar» es lo que falta (Fr-B1)', () => {
  it('suma el saldo de cada parada, no su total', async () => {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={queryClient}>
        <RutaActivaTransportista onMarcarEntregado={vi.fn()} userId="chofer-1" />
      </QueryClientProvider>,
    )
    await screen.findByText('Mapa de prueba')

    // 600 + 2.000 = 2.600 (con el total sería 3.000).
    expect(screen.getByText(/por cobrar/)).toHaveTextContent(/\$\s*2\.600,00 por cobrar/)
  })
})
