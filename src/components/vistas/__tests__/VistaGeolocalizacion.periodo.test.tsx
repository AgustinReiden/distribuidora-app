/**
 * El selector de período de `VistaGeolocalizacion` (WP-55, #779), por rol ARIA y
 * por texto: qué presets hay y en qué orden, cuál está activo, con qué rango
 * consulta cada uno, y qué pasa al tocar los inputs de fecha.
 *
 * Es CARACTERIZACIÓN: se escribió contra el markup a mano, antes de que la vista
 * pasara a usar `PeriodPicker`, y tiene que seguir verde sin tocarse. Fija lo que
 * esta pantalla hace HOY, que no es lo que haría un selector "ideal":
 *  - los presets son tres (hoy, ayer, últimos 7 días) y NO hay «personalizado»:
 *    editar una fecha deja a todos apagados;
 *  - los inputs de fecha están a la vista siempre;
 *  - la consulta se dispara SOLA al cambiar el rango (es el `queryKey` del hook),
 *    sin botón «Generar». Ese disparo es de esta pantalla (#727 decide si se
 *    unifica; este paquete no);
 *  - elegir un preset suelta al preventista seleccionado; editar una fecha no.
 *
 * El hook de datos y el mapa (Google Maps) se reemplazan: lo que se mira es el
 * rango con el que la vista pide los datos, no lo que vuelve.
 *
 * Cuál preset está activo: hoy la vista sólo lo marca con el fondo (`bg-blue-600`)
 * y no tiene `aria-pressed`. `estaActivo` lee `aria-pressed` si el botón lo trae
 * y, si no, ese fondo; así el test dice lo mismo antes y después de que la vista
 * pase a un primitivo que sí lo declara.
 */
import process from 'node:process'
import '@testing-library/jest-dom/vitest'
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, it, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const { mockConsulta } = vi.hoisted(() => ({ mockConsulta: vi.fn() }))

vi.mock('../../../hooks/queries', () => ({
  useGeolocalizacionPreventistasQuery: (...args: unknown[]) => mockConsulta(...args),
}))

vi.mock('../../geolocalizacion/MapaPreventistas', () => ({
  default: () => <div data-testid="mapa" />,
}))

import VistaGeolocalizacion from '../VistaGeolocalizacion'

// Lunes 21/09/2026 al mediodía, hora de Buenos Aires.
const HOY = new Date(2026, 8, 21, 12, 0, 0)

const TZ_ORIGINAL = process.env.TZ

beforeAll(() => {
  process.env.TZ = 'America/Argentina/Buenos_Aires'
  // Buenos Aires es UTC-3: 180 minutos. Si el runner no respeta el cambio de
  // zona en caliente, que falle acá y diga por qué, y no en una fecha corrida.
  if (new Date(2026, 8, 21).getTimezoneOffset() !== 180) {
    throw new Error('No se pudo fijar TZ=America/Argentina/Buenos_Aires en este runner')
  }
})

afterAll(() => {
  if (TZ_ORIGINAL === undefined) delete process.env.TZ
  else process.env.TZ = TZ_ORIGINAL
})

const DATOS_CON_UNA_PREVENTISTA = {
  fecha_desde: '2026-09-21',
  fecha_hasta: '2026-09-21',
  preventistas: [
    {
      preventista_id: 'prev-1',
      preventista_nombre: 'Ana Gómez',
      total_pedidos: 3,
      pedidos_con_gps: 3,
      pedidos_sin_gps: 0,
      pedidos_lejos: 0,
      total_visitas: 0,
      ultima_ubicacion: null,
    },
  ],
  pedidos: [],
  visitas: [],
}

beforeEach(() => {
  // Sólo `Date`: los timers reales dejan andar a userEvent y a Testing Library.
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(HOY)
  mockConsulta.mockReset()
  mockConsulta.mockReturnValue({
    data: DATOS_CON_UNA_PREVENTISTA,
    isLoading: false,
    isFetching: false,
    error: null,
    refetch: vi.fn(),
  })
})

afterEach(() => {
  vi.useRealTimers()
})

const PRESETS = ['Hoy', 'Ayer', 'Últimos 7 días']

const preset = (nombre: string) => screen.getByRole('button', { name: nombre })
const inputDesde = () => screen.getByLabelText('Fecha desde') as HTMLInputElement
const inputHasta = () => screen.getByLabelText('Fecha hasta') as HTMLInputElement

function estaActivo(boton: HTMLElement): boolean {
  const pressed = boton.getAttribute('aria-pressed')
  return pressed !== null ? pressed === 'true' : /(?:^|\s)bg-blue-600(?:\s|$)/.test(boton.className)
}

/** Los presets, en el orden en que están en pantalla. */
function presetsEnPantalla(): string[] {
  return screen
    .getAllByRole('button')
    .map((b) => b.textContent?.trim() ?? '')
    .filter((texto) => PRESETS.includes(texto))
}

function presetsActivos(): string[] {
  return PRESETS.filter((nombre) => estaActivo(preset(nombre)))
}

/** Con qué rango pidió los datos la vista en el último render. */
function ultimaConsulta() {
  const [desde, hasta, opciones] = mockConsulta.mock.lastCall as [
    string,
    string,
    { autoRefresh: boolean },
  ]
  return { desde, hasta, autoRefresh: opciones.autoRefresh }
}

function rangoEnPantalla() {
  return { desde: inputDesde().value, hasta: inputHasta().value }
}

describe('VistaGeolocalizacion · presets de período', () => {
  it('ofrece Hoy, Ayer y Últimos 7 días, en ese orden', () => {
    render(<VistaGeolocalizacion />)
    expect(presetsEnPantalla()).toEqual(PRESETS)
  })

  it('no hay un preset «personalizado»', () => {
    render(<VistaGeolocalizacion />)
    expect(screen.queryByRole('button', { name: /personalizad|custom/i })).toBeNull()
  })

  it('arranca en "Hoy": es el único activo y consulta hoy contra hoy, con auto-refresco', () => {
    render(<VistaGeolocalizacion />)

    expect(presetsActivos()).toEqual(['Hoy'])
    expect(ultimaConsulta()).toEqual({ desde: '2026-09-21', hasta: '2026-09-21', autoRefresh: true })
    expect(rangoEnPantalla()).toEqual({ desde: '2026-09-21', hasta: '2026-09-21' })
  })

  it('"Ayer" consulta ayer contra ayer y apaga el auto-refresco (el rango ya no incluye hoy)', async () => {
    render(<VistaGeolocalizacion />)
    await userEvent.setup().click(preset('Ayer'))

    expect(presetsActivos()).toEqual(['Ayer'])
    expect(ultimaConsulta()).toEqual({ desde: '2026-09-20', hasta: '2026-09-20', autoRefresh: false })
    expect(rangoEnPantalla()).toEqual({ desde: '2026-09-20', hasta: '2026-09-20' })
  })

  it('"Últimos 7 días" consulta hoy menos seis hasta hoy, con auto-refresco', async () => {
    render(<VistaGeolocalizacion />)
    await userEvent.setup().click(preset('Últimos 7 días'))

    expect(presetsActivos()).toEqual(['Últimos 7 días'])
    expect(ultimaConsulta()).toEqual({ desde: '2026-09-15', hasta: '2026-09-21', autoRefresh: true })
    expect(rangoEnPantalla()).toEqual({ desde: '2026-09-15', hasta: '2026-09-21' })
  })

  it('volver a "Hoy" después de otro preset recalcula el rango', async () => {
    const user = userEvent.setup()
    render(<VistaGeolocalizacion />)
    await user.click(preset('Últimos 7 días'))
    await user.click(preset('Hoy'))

    expect(presetsActivos()).toEqual(['Hoy'])
    expect(ultimaConsulta()).toEqual({ desde: '2026-09-21', hasta: '2026-09-21', autoRefresh: true })
  })
})

describe('VistaGeolocalizacion · inputs de fecha', () => {
  it('Fecha desde y Fecha hasta son campos de fecha y están a la vista con cualquier preset', async () => {
    const user = userEvent.setup()
    render(<VistaGeolocalizacion />)

    for (const nombre of PRESETS) {
      await user.click(preset(nombre))
      expect(inputDesde()).toHaveAttribute('type', 'date')
      expect(inputHasta()).toHaveAttribute('type', 'date')
      expect(inputDesde()).toBeVisible()
      expect(inputHasta()).toBeVisible()
    }
  })

  it('cada campo limita al otro: Desde no pasa de Hasta y Hasta no baja de Desde', async () => {
    render(<VistaGeolocalizacion />)
    await userEvent.setup().click(preset('Últimos 7 días'))

    expect(inputDesde()).toHaveAttribute('max', '2026-09-21')
    expect(inputHasta()).toHaveAttribute('min', '2026-09-15')
  })

  it('editar "Fecha desde" cambia la consulta y apaga todos los presets', () => {
    render(<VistaGeolocalizacion />)
    fireEvent.change(inputDesde(), { target: { value: '2026-09-10' } })

    expect(ultimaConsulta()).toEqual({ desde: '2026-09-10', hasta: '2026-09-21', autoRefresh: true })
    expect(rangoEnPantalla()).toEqual({ desde: '2026-09-10', hasta: '2026-09-21' })
    expect(presetsActivos()).toEqual([])
  })

  it('editar "Fecha hasta" cambia la consulta, apaga los presets y, sin hoy, el auto-refresco', () => {
    render(<VistaGeolocalizacion />)
    fireEvent.change(inputHasta(), { target: { value: '2026-09-18' } })

    expect(ultimaConsulta()).toEqual({ desde: '2026-09-21', hasta: '2026-09-18', autoRefresh: false })
    expect(rangoEnPantalla()).toEqual({ desde: '2026-09-21', hasta: '2026-09-18' })
    expect(presetsActivos()).toEqual([])
  })

  it('después de editar, elegir un preset vuelve a pisar las dos fechas y lo activa', async () => {
    render(<VistaGeolocalizacion />)
    fireEvent.change(inputDesde(), { target: { value: '2026-09-10' } })
    fireEvent.change(inputHasta(), { target: { value: '2026-09-18' } })
    await userEvent.setup().click(preset('Ayer'))

    expect(presetsActivos()).toEqual(['Ayer'])
    expect(ultimaConsulta()).toEqual({ desde: '2026-09-20', hasta: '2026-09-20', autoRefresh: false })
  })
})

describe('VistaGeolocalizacion · el preventista seleccionado', () => {
  const preventista = () => screen.getByRole('button', { name: /Ana Gómez/ })

  it('elegir un preset lo suelta', async () => {
    const user = userEvent.setup()
    render(<VistaGeolocalizacion />)
    await user.click(preventista())
    expect(preventista()).toHaveAttribute('aria-pressed', 'true')

    await user.click(preset('Ayer'))

    expect(preventista()).toHaveAttribute('aria-pressed', 'false')
  })

  it('editar una fecha NO lo suelta', async () => {
    const user = userEvent.setup()
    render(<VistaGeolocalizacion />)
    await user.click(preventista())

    fireEvent.change(inputDesde(), { target: { value: '2026-09-10' } })

    expect(preventista()).toHaveAttribute('aria-pressed', 'true')
  })
})
