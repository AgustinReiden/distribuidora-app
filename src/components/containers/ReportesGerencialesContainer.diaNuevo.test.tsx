/**
 * «Este mes» del gerencial no queda fijo en el día en que se montó (#1597, 1597-b3).
 *
 * `periodos` salía de un `useMemo(..., [])`: con la pantalla abierta de un día para el otro, el
 * período por defecto seguía terminando ayer y el día nuevo (o el mes nuevo) no entraba al reporte.
 * Ahora se rearma cuando cambia el día argentino.
 *
 * La vista se mockea: acá se prueba qué rango le pide el container al reporte.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import { MemoryRouter } from 'react-router-dom'

const mockReporte = vi.fn()

vi.mock('../../hooks/queries', () => ({
  useReporteGerencialQuery: (...args: unknown[]) => {
    mockReporte(...args)
    return { data: undefined, isLoading: false, error: null }
  },
  useReporteCombosQuery: () => ({ data: undefined }),
  useReporteCombosRotacionQuery: () => ({ data: undefined }),
  useAnalisisMensualQuery: () => ({ data: undefined }),
  useMetasGerencialQuery: () => ({ data: undefined }),
  useGuardarMetaMutation: () => ({ mutate: vi.fn(), isPending: false }),
  useCalcularComisionesQuery: () => ({ data: undefined }),
  useSucursalesActivasQuery: () => ({ data: [] }),
}))

vi.mock('../../hooks/useAlertasCombos', () => ({
  useAlertasCombos: () => [],
}))

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    sucursales: [{ id: 1, nombre: 'Sucursal Uno' }],
    hasMultipleSucursales: false,
    loading: false,
    currentSucursalId: 1,
  }),
}))

vi.mock('../vistas/VistaReportesGerenciales', () => ({
  default: () => <div>vista gerencial</div>,
}))

import ReportesGerencialesContainer from './ReportesGerencialesContainer'

/** Último rango [desde, hasta] con el que se pidió el reporte YA habilitado (arg 5 = ready). */
function ultimoRango(): [string, string] {
  const pedidas = mockReporte.mock.calls.filter(c => c[5] === true)
  const c = pedidas[pedidas.length - 1]
  return [c[1] as string, c[2] as string]
}

describe('ReportesGerencialesContainer › «Este mes» al cruzar la medianoche (#1597)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    // 23:59:30 del 30/11 en Argentina = 02:59:30 UTC del 01/12. Sólo se simulan el reloj y el
    // intervalo: el resto (lazy, Suspense) sigue con temporizadores reales.
    vi.useFakeTimers({ toFake: ['Date', 'setInterval', 'clearInterval'], now: new Date('2026-12-01T02:59:30Z') })
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('al pasar la medianoche, el período por defecto pasa a incluir el día (y el mes) nuevo', async () => {
    render(
      <MemoryRouter initialEntries={['/reportes-gerenciales']}>
        <ReportesGerencialesContainer />
      </MemoryRouter>,
    )
    await screen.findByText('vista gerencial')
    expect(ultimoRango()).toEqual(['2026-11-01', '2026-11-30'])

    // Pasa un minuto: ya es 01/12 en Argentina.
    await act(async () => { vi.advanceTimersByTime(60_000) })

    expect(ultimoRango()).toEqual(['2026-12-01', '2026-12-01'])
  })

  it('mientras el día no cambia, el período no se mueve', async () => {
    render(
      <MemoryRouter initialEntries={['/reportes-gerenciales']}>
        <ReportesGerencialesContainer />
      </MemoryRouter>,
    )
    await screen.findByText('vista gerencial')
    const antes = mockReporte.mock.calls.length

    await act(async () => { vi.advanceTimersByTime(20_000) })

    expect(ultimoRango()).toEqual(['2026-11-01', '2026-11-30'])
    expect(mockReporte.mock.calls.length).toBe(antes)
  })
})
