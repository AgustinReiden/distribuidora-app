/**
 * `VistaHoy` (WP-48, #773), por rol y por texto: la fecha, las dos acciones de
 * un toque, los objetivos si hay metas y la lista de visitas (o su vacío).
 *
 * Los datos son los de la galería (`dev/gallery/fixtures/hoy.ts`).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaHoy, { type VistaHoyProps } from '../VistaHoy'
import { AVANCE_METAS_HOY, FECHA_HOY, SIN_METAS_HOY, VISITAS_HOY } from '../../../../dev/gallery/fixtures/hoy'

function renderVista(overrides: Partial<VistaHoyProps> = {}) {
  const props: VistaHoyProps = {
    fecha: FECHA_HOY,
    visitas: VISITAS_HOY,
    cargandoVisitas: false,
    errorVisitas: null,
    avanceMetas: AVANCE_METAS_HOY,
    onNuevoPedido: vi.fn(),
    onMarcarVisita: vi.fn(),
    ...overrides,
  }
  render(<VistaHoy {...props} />)
  return props
}

const seccionVisitas = () => screen.getByRole('region', { name: 'Visitas de hoy' })

describe('VistaHoy — encabezado', () => {
  it('se titula "Hoy" y dice la fecha del día, en Argentina', () => {
    renderVista()
    expect(screen.getByRole('heading', { level: 1, name: 'Hoy' })).toBeInTheDocument()
    expect(screen.getByText(/^lunes,? 21 de septiembre$/)).toBeInTheDocument()
  })

  it('la fecha es la de Argentina aunque en UTC ya sea mañana', () => {
    // 02:30 UTC del 22 = 23:30 del 21 en Tucumán.
    renderVista({ fecha: new Date('2026-09-22T02:30:00Z') })
    expect(screen.getByText(/^lunes,? 21 de septiembre$/)).toBeInTheDocument()
  })
})

describe('VistaHoy — acciones de un toque', () => {
  it('"Nuevo pedido" llama a onNuevoPedido y nada más', async () => {
    const props = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Nuevo pedido' }))
    expect(props.onNuevoPedido).toHaveBeenCalledTimes(1)
    expect(props.onMarcarVisita).not.toHaveBeenCalled()
  })

  it('"Marcar visita" llama a onMarcarVisita y nada más', async () => {
    const props = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Marcar visita' }))
    expect(props.onMarcarVisita).toHaveBeenCalledTimes(1)
    expect(props.onNuevoPedido).not.toHaveBeenCalled()
  })

  it('las dos acciones están aunque no haya visitas ni metas', () => {
    renderVista({ visitas: [], avanceMetas: undefined })
    expect(screen.getByRole('button', { name: 'Nuevo pedido' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Marcar visita' })).toBeInTheDocument()
  })
})

describe('VistaHoy — objetivos del mes', () => {
  it('con metas muestra el panel de objetivos del dashboard', () => {
    renderVista()
    expect(screen.getByRole('heading', { name: 'Mis objetivos de septiembre' })).toBeInTheDocument()
    expect(screen.getByText(/1 de 2 cumplidos/)).toBeInTheDocument()
  })

  it('sin metas cargadas no hay panel', () => {
    renderVista({ avanceMetas: SIN_METAS_HOY })
    expect(screen.queryByRole('heading', { name: /Mis objetivos/ })).toBeNull()
  })

  it('mientras no llegan los objetivos (undefined) tampoco', () => {
    renderVista({ avanceMetas: undefined })
    expect(screen.queryByRole('heading', { name: /Mis objetivos/ })).toBeNull()
  })
})

describe('VistaHoy — visitas de hoy', () => {
  it('lista las visitas en su sección, en el orden recibido', () => {
    renderVista()
    const filas = within(within(seccionVisitas()).getByRole('list')).getAllByRole('listitem')
    expect(filas).toHaveLength(4)
    expect(filas[0].textContent?.startsWith('1Kiosco La Esquina')).toBe(true)
    expect(filas[2]).toHaveTextContent('Sin GPS')
    expect(within(seccionVisitas()).getByText('4 visitas marcadas hoy. Ordenadas por hora.')).toBeInTheDocument()
  })

  it('en la pantalla la lista no tiene scroll propio: scrollea la página', () => {
    renderVista()
    expect(within(seccionVisitas()).getByRole('list')).not.toHaveClass('overflow-y-auto')
  })

  it('sin visitas, el aviso de vacío adentro de la sección', () => {
    renderVista({ visitas: [] })
    expect(within(seccionVisitas()).getByText('Todavía no marcaste ninguna visita hoy.')).toBeInTheDocument()
    expect(within(seccionVisitas()).queryByRole('list')).toBeNull()
  })

  it('cargando, "Cargando…" adentro de la sección', () => {
    renderVista({ visitas: [], cargandoVisitas: true })
    expect(within(seccionVisitas()).getByText('Cargando…')).toBeInTheDocument()
  })

  it('con error, el mensaje adentro de la sección y el resto de la pantalla sigue', () => {
    renderVista({ visitas: [], errorVisitas: new Error('sin conexión') })
    expect(within(seccionVisitas()).getByText('Error: sin conexión')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Nuevo pedido' })).toBeInTheDocument()
    expect(screen.getByRole('heading', { name: 'Mis objetivos de septiembre' })).toBeInTheDocument()
  })
})
