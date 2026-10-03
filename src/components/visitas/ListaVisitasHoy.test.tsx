/**
 * `ListaVisitasHoy` (WP-48, #773): los cuatro estados, por rol y por texto.
 *
 * La lista la comparten el modal "Visitas del día" y la pantalla "Hoy". El
 * modal tiene su caracterización aparte (`ModalVisitasHoy.caracterizacion`);
 * acá se prueba el componente solo, con las props que le pasan los dos.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import ListaVisitasHoy from './ListaVisitasHoy'
import type { VisitaHoy } from '../../hooks/queries/useVisitasQuery'

function visita(parcial: Partial<VisitaHoy> & Pick<VisitaHoy, 'visita_id'>): VisitaHoy {
  return {
    cliente_id: parcial.visita_id * 10,
    cliente_nombre: `Cliente ${parcial.visita_id}`,
    cliente_direccion: null,
    cliente_lat: null,
    cliente_lng: null,
    gps_lat: null,
    gps_lng: null,
    gps_status: 'ok',
    gps_capturado_at: null,
    created_at: '2026-10-02T12:00:00Z',
    distancia_m: 100,
    ...parcial,
  }
}

const VACIO = 'Todavía no marcaste ninguna visita hoy.'

const DOS: VisitaHoy[] = [
  visita({ visita_id: 7, cliente_nombre: 'Kiosco La Esquina', cliente_direccion: 'San Martín 450', distancia_m: 300 }),
  visita({ visita_id: 3, cliente_nombre: 'Almacén Lucía', gps_status: 'timeout', distancia_m: null }),
]

describe('ListaVisitasHoy — estados', () => {
  it('cargando: "Cargando…", sin lista ni vacío, aunque no haya visitas', () => {
    render(<ListaVisitasHoy visitas={[]} cargando error={null} />)
    expect(screen.getByText('Cargando…')).toBeInTheDocument()
    expect(screen.queryByRole('list')).toBeNull()
    expect(screen.queryByText(VACIO)).toBeNull()
  })

  it('la carga manda sobre un error', () => {
    render(<ListaVisitasHoy visitas={[]} cargando error={new Error('x')} />)
    expect(screen.getByText('Cargando…')).toBeInTheDocument()
    expect(screen.queryByText('Error: x')).toBeNull()
  })

  it('error: "Error: <mensaje>", sin lista ni vacío', () => {
    render(<ListaVisitasHoy visitas={[]} cargando={false} error={new Error('sin conexión')} />)
    expect(screen.getByText('Error: sin conexión')).toBeInTheDocument()
    expect(screen.queryByRole('list')).toBeNull()
    expect(screen.queryByText(VACIO)).toBeNull()
  })

  it('el error manda sobre las visitas que hubiera de antes', () => {
    render(<ListaVisitasHoy visitas={DOS} cargando={false} error={new Error('sin conexión')} />)
    expect(screen.getByText('Error: sin conexión')).toBeInTheDocument()
    expect(screen.queryByRole('list')).toBeNull()
  })

  it('vacío: el aviso de que todavía no marcó ninguna, y sin lista', () => {
    render(<ListaVisitasHoy visitas={[]} cargando={false} error={null} />)
    expect(screen.getByText(VACIO)).toBeInTheDocument()
    expect(screen.queryByRole('list')).toBeNull()
    expect(screen.queryByText(/visitas? marcadas? hoy/)).toBeNull()
  })

  it('lista: resumen, una fila por visita en el orden recibido, sin el aviso de vacío', () => {
    render(<ListaVisitasHoy visitas={DOS} cargando={false} error={null} />)
    expect(screen.getByText('2 visitas marcadas hoy. Ordenadas por hora.')).toBeInTheDocument()
    expect(screen.queryByText(VACIO)).toBeNull()

    const filas = within(screen.getByRole('list')).getAllByRole('listitem')
    expect(filas).toHaveLength(2)
    expect(filas[0].textContent?.startsWith('1Kiosco La Esquina')).toBe(true)
    expect(filas[1].textContent?.startsWith('2Almacén Lucía')).toBe(true)
    expect(within(filas[0]).getByText('San Martín 450')).toBeInTheDocument()
  })

  it('lista: distancia con semáforo si el GPS es ok, "Sin GPS" si no', () => {
    render(<ListaVisitasHoy visitas={DOS} cargando={false} error={null} />)
    const filas = within(screen.getByRole('list')).getAllByRole('listitem')
    expect(within(filas[0]).getByText('300 m')).toHaveAttribute('title', 'En el cliente')
    expect(within(filas[0]).queryByText('Sin GPS')).toBeNull()
    expect(within(filas[1]).getByText('Sin GPS')).toBeInTheDocument()
  })

  it('una visita sin nombre de cliente se lee "Cliente sin nombre"', () => {
    render(<ListaVisitasHoy visitas={[visita({ visita_id: 1, cliente_nombre: null })]} cargando={false} error={null} />)
    expect(screen.getByText('Cliente sin nombre')).toBeInTheDocument()
    expect(screen.getByText('1 visita marcada hoy. Ordenadas por hora.')).toBeInTheDocument()
  })
})

describe('ListaVisitasHoy — scroll propio', () => {
  it('por defecto (el modal) la lista tiene tope de alto y scroll propio', () => {
    render(<ListaVisitasHoy visitas={DOS} cargando={false} error={null} />)
    expect(screen.getByRole('list')).toHaveClass('max-h-[60vh]', 'overflow-y-auto')
  })

  it('con scrollPropio={false} (la pantalla) scrollea la página', () => {
    render(<ListaVisitasHoy visitas={DOS} cargando={false} error={null} scrollPropio={false} />)
    expect(screen.getByRole('list')).not.toHaveClass('max-h-[60vh]')
    expect(screen.getByRole('list')).not.toHaveClass('overflow-y-auto')
  })
})
