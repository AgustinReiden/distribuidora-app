/**
 * RutaActivaTransportista sube la pila de avisos mientras se ve el mapa (#765).
 *
 * LO QUE SE PROTEGE
 * -----------------
 * La rama del mapa tiene cosas fijas contra el borde de abajo: la barra de la
 * parada (SheetParada) y el FAB «centrar». Mientras se ve, la pantalla pisa
 * `--bottom-inset` en `<html>` con `calc(10rem + env(safe-area-inset-bottom))`,
 * que es lo que `noticeRoot` suma a su `padding-bottom`: sin eso «Sin conexión»
 * y los banners quedaban encima de «Entregar». Las ramas sin mapa (cargando, sin
 * ruta, ruta sin paradas, error de carga) no tienen nada abajo, y ahí la pila se
 * tiene que quedar en su lugar.
 *
 * `useBottomInset` tiene sus tests unitarios; lo que acá se fija es que la
 * pantalla LO LLAME, con qué valor, y sólo en la rama del mapa — incluido el
 * caso en que la ruta se queda sin paradas con la pantalla montada, que es
 * cuando el hook tiene que soltar la variable sin que nada se desmonte.
 *
 * Se monta la RutaActivaTransportista REAL. Se mockea lo que toca el mundo de
 * afuera: la sesión, el GPS, la voz, el wake lock, la guía giro-a-giro, la
 * query de la ruta del día, supabase y el mapa de Google (un lazy que acá es un
 * componente trivial). SheetParada, los modales y useEntregaParada son los
 * reales. Se asevera por comportamiento: el valor de la variable en `<html>` y
 * el texto visible que confirma en qué rama se está.
 */
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { PedidoConCliente } from './useEntregaParada'

// `vi.mock` se hoistea arriba de todo: el estado que cada test cambia y los
// stubs estables viven en `vi.hoisted`.
const { ruta, supabaseStub, voz, wakeLock, guia } = vi.hoisted(() => ({
  // Lo que devuelve `useRecorridoActivoQuery`. Cada test lo arma antes de
  // montar; `data` conserva la identidad entre renders mientras no se reasigne.
  ruta: {
    data: undefined as unknown,
    isLoading: false,
    isError: false,
    refetch: vi.fn(),
  },
  supabaseStub: {
    rpc: vi.fn(() => Promise.resolve({ data: null, error: null })),
    from: vi.fn(() => ({ select: vi.fn(() => ({ data: [], error: null })) })),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  voz: { prime: vi.fn(), decir: vi.fn(), callar: vi.fn(), soportada: true },
  wakeLock: { solicitar: vi.fn(), liberar: vi.fn(), soportado: true },
  guia: {
    pasoActual: null,
    pasoSiguiente: null,
    distManiobra: null,
    rutaTramo: [],
    cargando: false,
    error: null,
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

vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isOnline: true }),
}))

vi.mock('../../hooks/useWatchPosition', () => ({
  useWatchPosition: () => ({ posicion: null, error: null, soportado: true }),
}))
vi.mock('../../hooks/useNavegacionVoz', () => ({ useNavegacionVoz: () => voz }))
vi.mock('../../hooks/useWakeLock', () => ({ useWakeLock: () => wakeLock }))
vi.mock('../../hooks/useGuiaNavegacion', () => ({ useGuiaNavegacion: () => guia }))

// Se parte del barrel real y se pisan sólo los dos hooks que la pantalla usa:
// así un hook nuevo del barrel no rompe este test con "No export is defined on
// the mock", y los modales que importan otros hooks del barrel siguen cargando.
vi.mock('../../hooks/queries', async (importOriginal) => ({
  ...(await importOriginal<Record<string, unknown>>()),
  useDepositoCoords: () => ({ lat: -26.8241, lng: -65.2226 }),
  useRecorridoActivoQuery: () => ({
    data: ruta.data,
    isLoading: ruta.isLoading,
    isError: ruta.isError,
    refetch: ruta.refetch,
    desdeCache: false,
    datosDe: null,
  }),
}))

// El mapa de Google Maps JS no tiene nada que ver con la variable y en jsdom no
// carga: un componente trivial alcanza para saber que la rama del mapa montó.
vi.mock('./MapaRutaGoogle', () => ({
  default: () => <div>Mapa de prueba</div>,
}))

import RutaActivaTransportista from './RutaActivaTransportista'

const PROPIEDAD = '--bottom-inset'
const INSET_AVISOS_MAPA = 'calc(10rem + env(safe-area-inset-bottom))'

function insetEnHtml(): string {
  return document.documentElement.style.getPropertyValue(PROPIEDAD)
}

const parada = (over: Partial<PedidoConCliente> = {}): PedidoConCliente => ({
  id: '4625',
  total: 21600,
  monto_pagado: 0,
  estado: 'asignado',
  estado_pago: 'pendiente',
  orden_entrega: 1,
  cliente: {
    id: '1',
    nombre_fantasia: 'Kiosco Sur',
    direccion: 'San Martín 123',
    latitud: -26.83,
    longitud: -65.21,
  },
  items: [],
  ...over,
} as unknown as PedidoConCliente)

function rutaConParadas(paradas: PedidoConCliente[]): void {
  ruta.data = { id: '77', polylines: null, paradas, fecha: '2026-09-27', obtenidoEn: Date.now() }
  ruta.isLoading = false
  ruta.isError = false
}

function montar() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const onMarcarEntregado = vi.fn()
  // Un elemento nuevo en cada llamada: con el mismo objeto, `rerender` no
  // vuelve a renderizar la pantalla (React corta por identidad de props) y la
  // query mockeada nunca se relee.
  const pantalla = () => (
    <QueryClientProvider client={queryClient}>
      <RutaActivaTransportista onMarcarEntregado={onMarcarEntregado} userId="chofer-1" />
    </QueryClientProvider>
  )
  const utils = render(pantalla())
  return { ...utils, rerenderMismo: () => utils.rerender(pantalla()) }
}

describe('RutaActivaTransportista — --bottom-inset sólo en la rama del mapa', () => {
  beforeEach(() => {
    ruta.data = undefined
    ruta.isLoading = false
    ruta.isError = false
    document.documentElement.style.removeProperty(PROPIEDAD)
  })
  afterEach(() => {
    document.documentElement.style.removeProperty(PROPIEDAD)
  })

  it('con un recorrido activo con paradas, sube la pila por encima de la barra y del FAB', async () => {
    rutaConParadas([parada()])

    montar()

    // Confirma la rama: el mapa (lazy) y el progreso del día que va encima.
    expect(await screen.findByText('Mapa de prueba')).toBeInTheDocument()
    expect(screen.getByText(/0\/1 entregas/)).toBeInTheDocument()
    expect(insetEnHtml()).toBe(INSET_AVISOS_MAPA)
  })

  it.each([
    {
      caso: 'sin recorrido armado',
      preparar: () => { ruta.data = null },
      texto: 'Todavía no tenés ruta para hoy',
    },
    {
      caso: 'recorrido sin paradas',
      preparar: () => rutaConParadas([]),
      texto: 'Ruta sin paradas',
    },
    {
      caso: 'ruta cargando',
      preparar: () => { ruta.data = undefined; ruta.isLoading = true },
      texto: 'Cargando tu ruta…',
    },
  ])('$caso (rama sin mapa): no pone la variable', ({ preparar, texto }) => {
    preparar()

    montar()

    expect(screen.getByRole('heading', { name: texto })).toBeInTheDocument()
    expect(screen.queryByText('Mapa de prueba')).not.toBeInTheDocument()
    expect(insetEnHtml()).toBe('')
  })

  it('con error de carga (rama de error, sin mapa): no pone la variable', () => {
    ruta.data = undefined
    ruta.isError = true

    montar()

    expect(screen.getByRole('heading', { name: 'No pudimos cargar tu ruta' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeInTheDocument()
    expect(insetEnHtml()).toBe('')
  })

  it('al desmontar la pantalla del mapa, la variable vuelve a vacío', async () => {
    rutaConParadas([parada()])
    const { unmount } = montar()
    await screen.findByText('Mapa de prueba')
    expect(insetEnHtml()).toBe(INSET_AVISOS_MAPA)

    unmount()

    expect(insetEnHtml()).toBe('')
  })

  it('si la ruta se queda sin paradas con la pantalla montada, la variable vuelve a vacío', async () => {
    rutaConParadas([parada()])
    const { rerenderMismo } = montar()
    await screen.findByText('Mapa de prueba')
    expect(insetEnHtml()).toBe(INSET_AVISOS_MAPA)

    // La query refetchea y la ruta vuelve sin paradas (p. ej. el admin las
    // sacó): mismo componente, sin desmontar, ahora en la rama sin mapa.
    rutaConParadas([])
    rerenderMismo()

    expect(screen.getByRole('heading', { name: 'Ruta sin paradas' })).toBeInTheDocument()
    expect(screen.queryByText('Mapa de prueba')).not.toBeInTheDocument()
    expect(insetEnHtml()).toBe('')
  })
})
