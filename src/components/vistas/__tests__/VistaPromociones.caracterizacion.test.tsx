/**
 * Caracterizacion de `VistaPromociones` (WP-51, #775), ANTES de paginarla.
 *
 * Fija, por rol ARIA y por texto (nunca por clase), lo que el usuario ve hoy con
 * una lista CHICA —menos que una pagina—: cuantas tarjetas hay en cada filtro de
 * estado (vigentes / todas / inactivas), el contador "x / y", la marca de cada
 * una, la lista vacia y la carga.
 *
 * La lista chica es a proposito: lo que cambia con la paginacion es lo que pasa
 * ARRIBA de una pagina, y eso lo cubre `VistaPromociones.paginacion.test.tsx`.
 * Este archivo tiene que seguir verde, sin tocarse, despues de paginar.
 *
 * El reloj se fija en el 3/10/2026 (solo `Date`): "vigente" depende de hoy.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaPromociones, { type VistaPromocionesProps } from '../VistaPromociones'
import type { PromocionConDetalles } from '../../../hooks/queries/usePromocionesQuery'

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] })
  // 12:00 en Tucumán del 3/10/2026.
  vi.setSystemTime(new Date('2026-10-03T15:00:00Z'))
})

afterEach(() => {
  vi.useRealTimers()
})

function promo(id: number, nombre: string, extra: Partial<PromocionConDetalles> = {}): PromocionConDetalles {
  return {
    id: String(id),
    nombre,
    tipo: 'bonificacion',
    activo: true,
    fecha_inicio: '2026-09-01',
    fecha_fin: null,
    created_at: '2026-09-01T00:00:00Z',
    updated_at: '2026-09-01T00:00:00Z',
    productos: [],
    reglas: [],
    usos_pendientes: 0,
    ...extra,
  }
}

/** 2 vigentes, 1 desactivada, 1 vencida y 1 que empieza en noviembre. */
const PROMOS: PromocionConDetalles[] = [
  promo(1, 'Vigente sin fin'),
  promo(2, 'Vigente con fin', { fecha_inicio: '2026-09-15', fecha_fin: '2026-12-31' }),
  promo(3, 'Desactivada', { activo: false }),
  promo(4, 'Vencida', { fecha_fin: '2026-09-30' }),
  promo(5, 'Futura', { fecha_inicio: '2026-11-01' }),
]

function renderVista(overrides: Partial<VistaPromocionesProps> = {}) {
  const props: VistaPromocionesProps = {
    promociones: PROMOS,
    loading: false,
    onNuevaPromocion: vi.fn(),
    onEditarPromocion: vi.fn(),
    onEliminarPromocion: vi.fn(),
    onToggleActivo: vi.fn(),
    productoNombres: new Map(),
    ...overrides,
  }
  render(<VistaPromociones {...props} />)
  return props
}

/** Una tarjeta por promocion: su nombre es el unico h3. */
const nombresDeTarjetas = () => screen.getAllByRole('heading', { level: 3 }).map(h => h.textContent)

describe('VistaPromociones — filtros de estado', () => {
  it('por defecto muestra solo las vigentes', () => {
    renderVista()
    expect(nombresDeTarjetas()).toEqual(['Vigente sin fin', 'Vigente con fin'])
    expect(screen.getByText('2 / 5')).toBeInTheDocument()
  })

  it('"Todas" muestra las cinco, en el orden recibido', async () => {
    renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Todas' }))
    expect(nombresDeTarjetas()).toEqual(['Vigente sin fin', 'Vigente con fin', 'Desactivada', 'Vencida', 'Futura'])
    expect(screen.getByText('5 / 5')).toBeInTheDocument()
  })

  it('"Inactivas / vencidas" muestra la desactivada, la vencida y la futura', async () => {
    renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Inactivas / vencidas' }))
    expect(nombresDeTarjetas()).toEqual(['Desactivada', 'Vencida', 'Futura'])
    expect(screen.getByText('3 / 5')).toBeInTheDocument()
  })

  it('se puede volver a "Vigentes" despues de mirar otro filtro', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Todas' }))
    await user.click(screen.getByRole('button', { name: 'Vigentes' }))
    expect(nombresDeTarjetas()).toEqual(['Vigente sin fin', 'Vigente con fin'])
  })
})

describe('VistaPromociones — la tarjeta', () => {
  it('cada tarjeta lleva su marca: Vigente, Inactiva o Fuera de rango', async () => {
    renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Todas' }))
    expect(screen.getAllByText('Vigente')).toHaveLength(2)
    expect(screen.getAllByText('Inactiva')).toHaveLength(1)
    // La vencida y la futura estan activas pero fuera de fechas.
    expect(screen.getAllByText('Fuera de rango')).toHaveLength(2)
  })

  it('dice las fechas, con "Sin fecha fin" cuando no hay', () => {
    renderVista()
    expect(screen.getByText(/Sin fecha fin/)).toBeInTheDocument()
  })

  it('las acciones llaman a sus callbacks con la promocion', async () => {
    const props = renderVista()
    const user = userEvent.setup()
    await user.click(screen.getAllByRole('button', { name: 'Editar' })[1])
    expect(props.onEditarPromocion).toHaveBeenCalledWith(PROMOS[1])
    await user.click(screen.getAllByRole('button', { name: 'Eliminar' })[0])
    expect(props.onEliminarPromocion).toHaveBeenCalledWith('1')
    await user.click(screen.getAllByRole('button', { name: 'Desactivar' })[0])
    expect(props.onToggleActivo).toHaveBeenCalledWith(PROMOS[0])
  })

  it('"Nueva Promoción" llama a onNuevaPromocion', async () => {
    const props = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: /Nueva Promoción/ }))
    expect(props.onNuevaPromocion).toHaveBeenCalledTimes(1)
  })

  it('"Ver histórico" agrega a cada tarjeta las unidades regaladas', async () => {
    renderVista({ unidadesEntregadas: new Map([['1', 12], ['2', 3]]) })
    expect(screen.queryByText(/unidades regaladas/)).not.toBeInTheDocument()
    await userEvent.setup().click(screen.getByRole('button', { name: /Ver histórico/ }))
    expect(screen.getByText('12 unidades regaladas')).toBeInTheDocument()
    expect(screen.getByText('3 unidades regaladas')).toBeInTheDocument()
  })
})

describe('VistaPromociones — lista vacia y carga', () => {
  it('sin promociones dice "Sin promociones" y ofrece crear la primera', async () => {
    const props = renderVista({ promociones: [] })
    expect(screen.getByRole('heading', { level: 3, name: 'Sin promociones' })).toBeInTheDocument()
    expect(screen.getByText('0 / 0')).toBeInTheDocument()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Crear primera promocion' }))
    expect(props.onNuevaPromocion).toHaveBeenCalledTimes(1)
  })

  it('si ninguna esta vigente, "Vigentes" muestra el vacio y el contador sigue contando todas', () => {
    renderVista({ promociones: [PROMOS[2], PROMOS[3]] })
    expect(screen.getByRole('heading', { level: 3, name: 'Sin promociones' })).toBeInTheDocument()
    expect(screen.getByText('0 / 2')).toBeInTheDocument()
  })

  it('cargando no dibuja el encabezado ni la lista', () => {
    renderVista({ loading: true })
    expect(screen.queryByRole('heading', { name: 'Promociones' })).not.toBeInTheDocument()
    expect(screen.queryAllByRole('heading', { level: 3 })).toHaveLength(0)
  })

  it('no hay control de paginacion con una lista chica', async () => {
    renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Todas' }))
    expect(nombresDeTarjetas()).toHaveLength(5)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Página anterior' })).not.toBeInTheDocument()
  })
})
