/**
 * Caracterización de DashboardViewHeader: fija el comportamiento ACTUAL del
 * crumb, el título dinámico (vía labelPeriodoDashboard) y el crumb de
 * período antes de reemplazarlo por un PageHeader común.
 *
 * OJO: el crumb de período (arriba) y el período del título (abajo, en el
 * h1) vienen de DOS fuentes independientes — `periodoLabel` es un string que
 * arma el caller, y el período del h1 lo deriva `labelPeriodoDashboard` a
 * partir de `filtroPeriodo`/`fechaDesde`/`fechaHasta`. Nada obliga a que
 * cuenten la misma historia; ver hallazgos.
 *
 * La fecha del sistema queda fija en martes 21 de abril de 2026 (10:00 hora
 * local) para que el crumb de fecha sea determinista.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import DashboardViewHeader from './DashboardViewHeader'

const AHORA = '2026-04-21T10:00:00'

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date(AHORA))
})

afterEach(() => {
  vi.useRealTimers()
})

describe('DashboardViewHeader', () => {
  it('muestra el crumb de sección y la fecha larga', () => {
    render(
      <DashboardViewHeader
        filtroPeriodo="hoy"
        periodoLabel="Hoy"
        loading={false}
      />
    )

    expect(screen.getByText('Dashboard')).toBeInTheDocument()
    expect(screen.getByText('MARTES 21 DE ABRIL')).toBeInTheDocument()
  })

  it('filtroPeriodo="hoy" da "Resumen del día"', () => {
    render(<DashboardViewHeader filtroPeriodo="hoy" periodoLabel="Hoy" loading={false} />)
    expect(screen.getByRole('heading', { level: 1, name: 'Resumen del día' })).toBeInTheDocument()
  })

  it('filtroPeriodo="mes" da "Resumen del mes"', () => {
    render(<DashboardViewHeader filtroPeriodo="mes" periodoLabel="Este mes" loading={false} />)
    expect(screen.getByRole('heading', { level: 1, name: 'Resumen del mes' })).toBeInTheDocument()
  })

  it('filtroPeriodo="personalizado" con rango en el mismo mes arma "del D al D de mes"', () => {
    render(
      <DashboardViewHeader
        filtroPeriodo="personalizado"
        fechaDesde="2026-04-01"
        fechaHasta="2026-04-05"
        periodoLabel="Personalizado"
        loading={false}
      />
    )
    expect(
      screen.getByRole('heading', { level: 1, name: 'Resumen del 1 al 5 de abril' })
    ).toBeInTheDocument()
  })

  it('verbo="Mis métricas" (preventista) reemplaza a "Resumen"', () => {
    render(
      <DashboardViewHeader
        filtroPeriodo="semana"
        periodoLabel="Esta semana"
        loading={false}
        verbo="Mis métricas"
      />
    )
    expect(
      screen.getByRole('heading', { level: 1, name: 'Mis métricas de la semana' })
    ).toBeInTheDocument()
  })

  it('el crumb de período usa periodoLabel en mayúsculas, independiente del período del h1', () => {
    render(<DashboardViewHeader filtroPeriodo="mes" periodoLabel="Este mes" loading={false} />)
    expect(screen.getByText('ESTE MES')).toBeInTheDocument()
  })

  it('estado loading muestra "ACTUALIZANDO…" en el crumb de período', () => {
    render(<DashboardViewHeader filtroPeriodo="mes" periodoLabel="Este mes" loading />)
    expect(screen.getByText('ACTUALIZANDO…')).toBeInTheDocument()
    expect(screen.queryByText('ESTE MES')).not.toBeInTheDocument()
  })

  it('renderiza el slot de actions cuando se provee', () => {
    render(
      <DashboardViewHeader
        filtroPeriodo="hoy"
        periodoLabel="Hoy"
        loading={false}
        actions={<button>Exportar</button>}
      />
    )
    expect(screen.getByRole('button', { name: 'Exportar' })).toBeInTheDocument()
  })
})
