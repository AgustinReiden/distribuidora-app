/**
 * Fr-B11 (T8 de la ola 3): «Hoy» no queda fijo en el día en que se montó la pantalla.
 *
 * El rango salía de un `useState` inicializado al montar: con el panel abierto pasada la
 * medianoche, «Hoy» seguía pidiendo el día anterior (y con auto-refresco apagado, porque ya no
 * era hoy). Ahora el preset se recalcula contra el día argentino (`useDiaArgentino`), y un
 * rango elegido a mano no se toca.
 */
import '@testing-library/jest-dom/vitest'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { act, fireEvent, render, screen } from '@testing-library/react'

const { mockConsulta } = vi.hoisted(() => ({ mockConsulta: vi.fn() }))

vi.mock('../../../hooks/queries', () => ({
  useGeolocalizacionPreventistasQuery: (...args: unknown[]) => mockConsulta(...args),
}))

vi.mock('../../geolocalizacion/MapaPreventistas', () => ({
  default: () => <div data-testid="mapa" />,
}))

import VistaGeolocalizacion from '../VistaGeolocalizacion'

function ultimaConsulta() {
  const [desde, hasta, opciones] = mockConsulta.mock.lastCall as [string, string, { autoRefresh: boolean }]
  return { desde, hasta, autoRefresh: opciones.autoRefresh }
}

beforeEach(() => {
  // 23:59:30 del 30/11 en Argentina = 02:59:30 UTC del 01/12. Sólo el reloj y el intervalo.
  vi.useFakeTimers({ toFake: ['Date', 'setInterval', 'clearInterval'], now: new Date('2026-12-01T02:59:30Z') })
  mockConsulta.mockReset()
  mockConsulta.mockReturnValue({
    data: { fecha_desde: '', fecha_hasta: '', preventistas: [], pedidos: [], visitas: [] },
    isLoading: false,
    isFetching: false,
    error: null,
    refetch: vi.fn(),
  })
})

afterEach(() => {
  vi.useRealTimers()
})

describe('VistaGeolocalizacion › «Hoy» al cruzar la medianoche (Fr-B11)', () => {
  it('con «Hoy» abierto, pasada la medianoche pide el día nuevo y sigue auto-refrescando', () => {
    render(<VistaGeolocalizacion />)
    expect(ultimaConsulta()).toEqual({ desde: '2026-11-30', hasta: '2026-11-30', autoRefresh: true })

    act(() => { vi.advanceTimersByTime(60_000) })

    expect(ultimaConsulta()).toEqual({ desde: '2026-12-01', hasta: '2026-12-01', autoRefresh: true })
  })

  it('«Últimos 7 días» también corre su ventana con el día', () => {
    render(<VistaGeolocalizacion />)
    fireEvent.click(screen.getByRole('button', { name: 'Últimos 7 días' }))
    expect(ultimaConsulta()).toMatchObject({ desde: '2026-11-24', hasta: '2026-11-30' })

    act(() => { vi.advanceTimersByTime(60_000) })

    expect(ultimaConsulta()).toMatchObject({ desde: '2026-11-25', hasta: '2026-12-01' })
  })

  it('un rango elegido a mano no se mueve con el día', () => {
    render(<VistaGeolocalizacion />)
    fireEvent.change(screen.getByLabelText('Fecha desde'), { target: { value: '2026-11-20' } })
    expect(ultimaConsulta()).toMatchObject({ desde: '2026-11-20', hasta: '2026-11-30' })

    act(() => { vi.advanceTimersByTime(60_000) })

    expect(ultimaConsulta()).toEqual({ desde: '2026-11-20', hasta: '2026-11-30', autoRefresh: false })
  })
})
