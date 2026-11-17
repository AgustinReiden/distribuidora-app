/**
 * «Este mes» del gerencial no queda fijo en el día en que se montó (#1597, 1597-b3).
 *
 * `periodos` salía de un `useMemo(..., [])`: con la pantalla abierta de un día para el otro, el
 * período por defecto seguía terminando ayer y el día nuevo (o el mes nuevo) no entraba al reporte.
 * Ahora se rearma cuando cambia el día argentino.
 *
 * La vista se mockea: acá se prueba qué rango le pide el container al reporte.
 */
import React, { useEffect } from 'react'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import { MemoryRouter, useLocation } from 'react-router-dom'

const mockReporte = vi.fn()
const vistaProps: { actual: Record<string, unknown> } = { actual: {} }
const ubicacion = { search: '' }

/** Anota la query string de la URL para poder afirmar qué se guarda ahí. */
function Sonda(): null {
  const { search } = useLocation()
  useEffect(() => { ubicacion.search = search }, [search])
  return null
}

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
  default: (props: Record<string, unknown>) => {
    vistaProps.actual = props
    return <div>vista gerencial</div>
  },
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

  it('con «Este mes» en la URL (sólo el preset), pasada la medianoche salta solo al mes nuevo y sigue siendo «Este mes» (H5)', async () => {
    render(
      <MemoryRouter initialEntries={['/reportes-gerenciales?pr=mes-actual']}>
        <ReportesGerencialesContainer />
      </MemoryRouter>,
    )
    await screen.findByText('vista gerencial')
    const antes = vistaProps.actual.periodoSel as { key: string; esMes: boolean; periodoMes: string | null }
    expect(antes.key).toBe('mes-actual')
    expect(ultimoRango()).toEqual(['2026-11-01', '2026-11-30'])

    await act(async () => { vi.advanceTimersByTime(60_000) })

    const despues = vistaProps.actual.periodoSel as { key: string; esMes: boolean; periodoMes: string | null }
    expect(despues.key).toBe('mes-actual')
    expect(ultimoRango()).toEqual(['2026-12-01', '2026-12-01'])
    // El análisis mensual sigue disponible, ahora el de diciembre.
    expect(despues.esMes).toBe(true)
    expect(despues.periodoMes).toBe('2026-12-01')
  })

  it('un link viejo con el rango de «Este mes» y el preset (pr) también sigue al día (H5)', async () => {
    render(
      <MemoryRouter initialEntries={['/reportes-gerenciales?desde=2026-11-01&hasta=2026-11-30&pr=mes-actual']}>
        <ReportesGerencialesContainer />
      </MemoryRouter>,
    )
    await screen.findByText('vista gerencial')
    expect((vistaProps.actual.periodoSel as { key: string }).key).toBe('mes-actual')
    expect(ultimoRango()).toEqual(['2026-11-01', '2026-11-30'])

    await act(async () => { vi.advanceTimersByTime(60_000) })

    expect((vistaProps.actual.periodoSel as { key: string }).key).toBe('mes-actual')
    expect(ultimoRango()).toEqual(['2026-12-01', '2026-12-01'])
  })

  it('elegir un preset a mano lo deja en la URL y sobrevive a la medianoche (H5)', async () => {
    render(
      <MemoryRouter initialEntries={['/reportes-gerenciales']}>
        <Sonda />
        <ReportesGerencialesContainer />
      </MemoryRouter>,
    )
    await screen.findByText('vista gerencial')
    const opciones = vistaProps.actual.opcionesPeriodo as Array<{ key: string }>
    const mesPasado = opciones.find(o => o.key === 'mes-pasado')!
    await act(async () => { (vistaProps.actual.onPeriodo as (p: unknown) => void)(mesPasado) })
    expect((vistaProps.actual.periodoSel as { key: string }).key).toBe('mes-pasado')
    expect(ubicacion.search).toBe('?pr=mes-pasado') // sólo el preset, sin fechas
    expect(ultimoRango()).toEqual(['2026-10-01', '2026-10-31'])

    await act(async () => { vi.advanceTimersByTime(60_000) })

    // El «mes pasado» ahora es noviembre completo: sigue siendo ese preset, no «Personalizado».
    expect((vistaProps.actual.periodoSel as { key: string }).key).toBe('mes-pasado')
    expect(ultimoRango()).toEqual(['2026-11-01', '2026-11-30'])
  })

  it('un rango tipeado a mano sin preset sigue siendo «Personalizado»', async () => {
    render(
      <MemoryRouter initialEntries={['/reportes-gerenciales?desde=2026-11-05&hasta=2026-11-20']}>
        <ReportesGerencialesContainer />
      </MemoryRouter>,
    )
    await screen.findByText('vista gerencial')
    expect((vistaProps.actual.periodoSel as { key: string }).key).toBe('custom')
    expect(ultimoRango()).toEqual(['2026-11-05', '2026-11-20'])
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
