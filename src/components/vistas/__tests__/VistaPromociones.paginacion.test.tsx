/**
 * Paginacion de `VistaPromociones` (WP-51, #775).
 *
 * La query trae TODAS las promociones y la vista las pagina en el cliente, sobre
 * la lista ya filtrada por estado, de a 15 (el patron de `VistaCompras`).
 *
 * Lo que fijan estos tests, por rol y por texto:
 *  - con mas promociones que una pagina se ven solo las de la pagina 1;
 *  - pasar de pagina muestra las siguientes;
 *  - cambiar el filtro de estado vuelve a la pagina 1. Los casos estan armados
 *    para que, despues del filtro, la lista siga teniendo mas de una pagina: si
 *    no, el recorte de la pagina al final de la lista (el `Math.min` de la
 *    vista) taparia un reset que falta;
 *  - el total del pie coincide con el contador "x / y" y con la lista filtrada
 *    completa;
 *  - si la lista se achica y la pagina guardada pasa del final, se muestra la
 *    ultima que existe y no una pagina en blanco.
 *
 * `VistaPromociones.caracterizacion.test.tsx` fija lo que NO cambia (lista
 * chica) y tiene que seguir verde.
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
  vi.setSystemTime(new Date('2026-10-03T15:00:00Z'))
})

afterEach(() => {
  vi.useRealTimers()
})

const pad = (n: number) => String(n).padStart(2, '0')
const nombre = (n: number) => `Promo ${pad(n)}`

/**
 * 40 promociones: las primeras 33 vigentes y las ultimas 7 desactivadas.
 *  - Vigentes: 33 -> 3 paginas (15 + 15 + 3)
 *  - Todas: 40 -> 3 paginas (15 + 15 + 10)
 *  - Inactivas / vencidas: 7 -> 1 pagina
 */
function promociones(cantidad = 40, vigentes = 33): PromocionConDetalles[] {
  return Array.from({ length: cantidad }, (_, i) => {
    const n = i + 1
    return {
      id: String(n),
      nombre: nombre(n),
      tipo: 'bonificacion',
      activo: n <= vigentes,
      fecha_inicio: '2026-09-01',
      fecha_fin: null,
      created_at: '2026-09-01T00:00:00Z',
      updated_at: '2026-09-01T00:00:00Z',
      productos: [],
      reglas: [],
      usos_pendientes: 0,
    }
  })
}

function props(lista: PromocionConDetalles[]): VistaPromocionesProps {
  return {
    promociones: lista,
    loading: false,
    onNuevaPromocion: vi.fn(),
    onEditarPromocion: vi.fn(),
    onEliminarPromocion: vi.fn(),
    onToggleActivo: vi.fn(),
    productoNombres: new Map(),
  }
}

function renderVista(lista = promociones()) {
  const p = props(lista)
  const vista = render(<VistaPromociones {...p} />)
  return { ...vista, props: p }
}

const nombres = () => screen.queryAllByRole('heading', { level: 3 }).map(h => h.textContent)
const rango = (desde: number, hasta: number) =>
  Array.from({ length: hasta - desde + 1 }, (_, i) => nombre(desde + i))
const siguiente = () => screen.getByRole('button', { name: 'Página siguiente' })
const anterior = () => screen.getByRole('button', { name: 'Página anterior' })
const filtro = (nombreBoton: string) => screen.getByRole('button', { name: nombreBoton })

describe('VistaPromociones — paginacion', () => {
  it('con 33 vigentes se ven solo las 15 de la pagina 1', () => {
    renderVista()
    expect(nombres()).toEqual(rango(1, 15))
    expect(screen.queryByText(nombre(16))).not.toBeInTheDocument()
  })

  it('el pie dice el total del filtro (33), con 3 paginas y estamos en la primera', () => {
    renderVista()
    expect(screen.getByText('33 promociones')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: '3' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '4' })).not.toBeInTheDocument()
    expect(anterior()).toBeDisabled()
  })

  it('el total del pie coincide con el contador "x / y" de arriba', () => {
    renderVista()
    // 33 de 40, y el pie dice 33 promociones: la lista filtrada completa.
    expect(screen.getByText('33 / 40')).toBeInTheDocument()
    expect(screen.getByText('33 promociones')).toBeInTheDocument()
  })

  it('"Página siguiente" muestra de la 16 a la 30 y despues las 3 que quedan', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(siguiente())
    expect(nombres()).toEqual(rango(16, 30))

    await user.click(siguiente())
    expect(nombres()).toEqual(rango(31, 33))
    expect(siguiente()).toBeDisabled()
  })

  it('una lista de exactamente una pagina (15 vigentes) no muestra el pie', () => {
    renderVista(promociones(15, 15))
    expect(nombres()).toHaveLength(15)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })
})

describe('VistaPromociones — el filtro de estado vuelve a la pagina 1', () => {
  it('"Todas" desde la pagina 2 muestra la 1 (40 promos: siguen siendo 3 paginas)', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(siguiente())
    expect(nombres()[0]).toBe(nombre(16))

    await user.click(filtro('Todas'))
    expect(nombres()).toEqual(rango(1, 15))
    expect(anterior()).toBeDisabled()
    expect(screen.getByText('40 promociones')).toBeInTheDocument()
    expect(screen.getByText('40 / 40')).toBeInTheDocument()
  })

  it('"Vigentes" desde la pagina 3 de "Todas" vuelve a la 1 (33 vigentes: 3 paginas)', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(filtro('Todas'))
    await user.click(screen.getByRole('button', { name: '3' }))
    expect(nombres()).toEqual(rango(31, 40))

    await user.click(filtro('Vigentes'))
    expect(nombres()).toEqual(rango(1, 15))
    expect(anterior()).toBeDisabled()
  })

  it('"Inactivas / vencidas" desde la pagina 2 muestra las 7 en una sola pagina, sin pie', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(siguiente())

    await user.click(filtro('Inactivas / vencidas'))
    expect(nombres()).toEqual(rango(34, 40))
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
    expect(screen.getByText('7 / 40')).toBeInTheDocument()
  })

  it('elegir el mismo filtro que ya esta activo tambien vuelve a la pagina 1', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(siguiente())
    await user.click(filtro('Vigentes'))
    expect(nombres()).toEqual(rango(1, 15))
  })

  it('el boton "Ver histórico" no es un filtro: no mueve la pagina', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(siguiente())
    await user.click(screen.getByRole('button', { name: /Ver histórico/ }))
    expect(nombres()).toEqual(rango(16, 30))
  })
})

describe('VistaPromociones — la pagina guardada pasa del final de la lista', () => {
  it('si la lista se achica, muestra la ultima pagina que existe y no una en blanco', async () => {
    const { rerender, props: p } = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: '3' }))
    expect(nombres()).toEqual(rango(31, 33))

    // Se borran las 3 de la pagina 3: quedan 30 vigentes -> 2 paginas.
    rerender(<VistaPromociones {...p} promociones={promociones(37, 30)} />)
    expect(nombres()).toEqual(rango(16, 30))
    expect(siguiente()).toBeDisabled()
  })
})
