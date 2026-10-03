/**
 * Caracterización de `ModalVisitasHoy` (WP-48, #773).
 *
 * Fija lo que el modal muestra HOY, antes de sacarle la lista a un componente
 * compartido con la pantalla "Hoy" del preventista. Se escribió y se corrió
 * contra el modal sin tocar: si después de la extracción algo de esto cambia,
 * la extracción cambió comportamiento.
 *
 * La query se mockea: lo que se fija es qué hace el modal con cada estado
 * (carga, error, vacío, lista), no el RPC.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { VisitaHoy } from '../../../hooks/queries/useVisitasQuery'

type EstadoQuery = { data?: VisitaHoy[]; isLoading: boolean; error: unknown }

const { useVisitasHoyQuery } = vi.hoisted(() => ({
  useVisitasHoyQuery: vi.fn((_userId: string | null, _opciones?: { enabled?: boolean }): EstadoQuery => ({
    data: [], isLoading: false, error: null,
  })),
}))

vi.mock('../../../hooks/queries', () => ({ useVisitasHoyQuery }))

import ModalVisitasHoy from '../ModalVisitasHoy'

function visita(parcial: Partial<VisitaHoy> & Pick<VisitaHoy, 'visita_id'>): VisitaHoy {
  return {
    cliente_id: parcial.visita_id * 10,
    cliente_nombre: `Cliente ${parcial.visita_id}`,
    cliente_direccion: null,
    cliente_lat: -26.8,
    cliente_lng: -65.2,
    gps_lat: -26.8,
    gps_lng: -65.2,
    gps_status: 'ok',
    gps_capturado_at: '2026-10-02T12:00:00Z',
    created_at: '2026-10-02T12:00:00Z',
    distancia_m: 100,
    ...parcial,
  }
}

/** Tal cual las devuelve el RPC: ya ordenadas por hora. */
const VISITAS: VisitaHoy[] = [
  visita({ visita_id: 1, cliente_nombre: 'Kiosco La Esquina', cliente_direccion: 'San Martín 450', created_at: '2026-10-02T12:05:00Z', distancia_m: 120 }),
  visita({ visita_id: 2, cliente_nombre: 'Autoservicio Don Pepe', created_at: '2026-10-02T13:40:00Z', distancia_m: 750 }),
  visita({ visita_id: 3, cliente_nombre: null, cliente_direccion: 'Av. Mate de Luna 2100', created_at: '2026-10-02T15:15:00Z', gps_status: 'denied', distancia_m: null }),
  visita({ visita_id: 4, cliente_nombre: 'Almacén Lucía', created_at: '2026-10-02T16:30:00Z', distancia_m: 1500 }),
  visita({ visita_id: 5, cliente_nombre: 'Despensa El Sol', created_at: '2026-10-02T17:00:00Z', gps_status: null, distancia_m: 80 }),
]

function renderModal(estado: EstadoQuery, userId: string | null = 'prev-1') {
  useVisitasHoyQuery.mockReturnValue(estado)
  const onClose = vi.fn()
  render(<ModalVisitasHoy userId={userId} onClose={onClose} />)
  return { onClose, dialogo: screen.getByRole('dialog', { name: 'Visitas del día' }) }
}

beforeEach(() => {
  useVisitasHoyQuery.mockClear()
})

describe('ModalVisitasHoy — caracterización', () => {
  it('es un diálogo "Visitas del día" y su X llama a onClose', async () => {
    const { onClose, dialogo } = renderModal({ data: [], isLoading: false, error: null })
    expect(within(dialogo).getByRole('heading', { name: 'Visitas del día' })).toBeInTheDocument()

    await userEvent.setup().click(within(dialogo).getByRole('button', { name: 'Cerrar' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('pide las visitas del usuario, habilitada sólo si hay usuario', () => {
    renderModal({ data: [], isLoading: false, error: null }, 'prev-1')
    expect(useVisitasHoyQuery).toHaveBeenLastCalledWith('prev-1', { enabled: true })
  })

  it('sin usuario la query va deshabilitada', () => {
    renderModal({ data: [], isLoading: false, error: null }, null)
    expect(useVisitasHoyQuery).toHaveBeenLastCalledWith(null, { enabled: false })
  })

  it('cargando: "Cargando…" y nada de lista ni de vacío', () => {
    const { dialogo } = renderModal({ data: undefined, isLoading: true, error: null })
    expect(within(dialogo).getByText('Cargando…')).toBeInTheDocument()
    expect(within(dialogo).queryByRole('list')).toBeNull()
    expect(within(dialogo).queryByText('Todavía no marcaste ninguna visita hoy.')).toBeNull()
  })

  it('error: muestra el mensaje del error, sin lista', () => {
    const { dialogo } = renderModal({ data: undefined, isLoading: false, error: new Error('permiso denegado') })
    expect(within(dialogo).getByText('Error: permiso denegado')).toBeInTheDocument()
    expect(within(dialogo).queryByRole('list')).toBeNull()
    expect(within(dialogo).queryByText('Cargando…')).toBeNull()
  })

  it('vacío: "Todavía no marcaste ninguna visita hoy." y sin lista', () => {
    const { dialogo } = renderModal({ data: [], isLoading: false, error: null })
    expect(within(dialogo).getByText('Todavía no marcaste ninguna visita hoy.')).toBeInTheDocument()
    expect(within(dialogo).queryByRole('list')).toBeNull()
  })

  it('sin data (undefined) y sin carga ni error, también es el vacío', () => {
    const { dialogo } = renderModal({ data: undefined, isLoading: false, error: null })
    expect(within(dialogo).getByText('Todavía no marcaste ninguna visita hoy.')).toBeInTheDocument()
  })

  it('lista: el resumen cuenta las visitas en plural', () => {
    const { dialogo } = renderModal({ data: VISITAS, isLoading: false, error: null })
    expect(within(dialogo).getByText('5 visitas marcadas hoy. Ordenadas por hora.')).toBeInTheDocument()
    expect(within(dialogo).queryByText('Todavía no marcaste ninguna visita hoy.')).toBeNull()
  })

  it('lista: con una sola visita el resumen va en singular', () => {
    const { dialogo } = renderModal({ data: [VISITAS[0]], isLoading: false, error: null })
    expect(within(dialogo).getByText('1 visita marcada hoy. Ordenadas por hora.')).toBeInTheDocument()
  })

  it('lista: una fila por visita, en el orden en que llegan, numeradas desde 1', () => {
    const { dialogo } = renderModal({ data: VISITAS, isLoading: false, error: null })
    const filas = within(within(dialogo).getByRole('list')).getAllByRole('listitem')
    expect(filas).toHaveLength(5)
    // El texto de la fila arranca con el número y sigue con el nombre.
    const esperados = [
      'Kiosco La Esquina', 'Autoservicio Don Pepe', 'Cliente sin nombre', 'Almacén Lucía', 'Despensa El Sol',
    ]
    filas.forEach((fila, i) => {
      expect(fila.textContent?.startsWith(`${i + 1}${esperados[i]}`), fila.textContent ?? '').toBe(true)
    })
  })

  // La hora es la de Argentina (UTC-3). Si va en 12 o 24 h y el sufijo "a. m."
  // dependen del ICU del entorno, por eso se fija sólo el comienzo (16:30Z = 13:30
  // o 01:30 p. m.).
  it('lista: cada fila lleva la hora en Argentina y la dirección si la hay', () => {
    const { dialogo } = renderModal({ data: VISITAS, isLoading: false, error: null })
    const filas = within(within(dialogo).getByRole('list')).getAllByRole('listitem')
    expect(within(filas[0]).getByText(/^09:05/)).toBeInTheDocument()
    expect(within(filas[0]).getByText('San Martín 450')).toBeInTheDocument()
    expect(within(filas[1]).getByText(/^10:40/)).toBeInTheDocument()
    expect(within(filas[2]).getByText('Av. Mate de Luna 2100')).toBeInTheDocument()
    expect(within(filas[3]).getByText(/^(13|01):30/)).toBeInTheDocument()
  })

  it('lista: con GPS ok va la distancia con el semáforo en el title; si no, "Sin GPS"', () => {
    const { dialogo } = renderModal({ data: VISITAS, isLoading: false, error: null })
    const filas = within(within(dialogo).getByRole('list')).getAllByRole('listitem')

    expect(within(filas[0]).getByText('120 m')).toHaveAttribute('title', 'En el cliente')
    expect(within(filas[1]).getByText('750 m')).toHaveAttribute('title', 'Cerca del cliente')
    expect(within(filas[3]).getByText('1.5 km')).toHaveAttribute('title', 'Lejos del cliente')
    for (const i of [0, 1, 3]) expect(within(filas[i]).queryByText('Sin GPS')).toBeNull()

    // 'denied' y null cuentan igual: todo lo que no es 'ok' es "Sin GPS",
    // aunque haya una distancia cargada (la fila 5 tiene 80 m y no se ve).
    expect(within(filas[2]).getByText('Sin GPS')).toBeInTheDocument()
    expect(within(filas[4]).getByText('Sin GPS')).toBeInTheDocument()
    expect(within(filas[4]).queryByText('80 m')).toBeNull()
  })
})
