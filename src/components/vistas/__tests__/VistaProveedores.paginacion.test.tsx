/**
 * Paginacion de `VistaProveedores` (WP-51, #775).
 *
 * La query trae TODOS los proveedores y la vista los pagina en el cliente, sobre
 * la lista ya filtrada, de a 15 (el patron de `VistaProductos` y `VistaCompras`).
 *
 * Lo que fijan estos tests, por rol y por texto:
 *  - con mas filas que una pagina se ven solo las de la pagina 1;
 *  - pasar de pagina muestra las siguientes;
 *  - cambiar CUALQUIER filtro (buscador, Activos, Inactivos, Total) vuelve a la
 *    pagina 1. Los casos estan armados para que, despues del filtro, la lista
 *    siga teniendo mas de una pagina: si no, un simple recorte de la pagina al
 *    final de la lista (el `Math.min` de la vista) taparia un reset que falta;
 *  - el total que cuenta el pie es el de la lista filtrada completa;
 *  - si la lista se achica y la pagina guardada pasa del final, se muestra la
 *    ultima que existe y no una pagina en blanco sin control para volver.
 *
 * `VistaProveedores.caracterizacion.test.tsx` fija lo que NO cambia (lista
 * chica) y tiene que seguir verde.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaProveedores, { type VistaProveedoresProps } from '../VistaProveedores'
import type { ProveedorDBExtended } from '../../../types'

const POR_PAGINA = 15
const pad = (n: number) => String(n).padStart(2, '0')

/**
 * 37 proveedores. Los que son multiplo de 3 estan inactivos (12) y el resto
 * activos (25). Del 1 al 30 se llaman "Norte NN" y del 31 al 37 "Sur NN":
 *  - Total: 37  -> 3 paginas (15 + 15 + 7)
 *  - Activos: 25 -> 2 paginas
 *  - Inactivos: 12 -> 1 pagina
 *  - buscar "norte": 30 -> 2 paginas
 */
function proveedores(cantidad = 37): ProveedorDBExtended[] {
  return Array.from({ length: cantidad }, (_, i) => {
    const n = i + 1
    return {
      id: String(n),
      nombre: `${n <= 30 ? 'Norte' : 'Sur'} ${pad(n)}`,
      cuit: `30-${pad(n)}`,
      contacto: null,
      activo: n % 3 !== 0,
    }
  })
}

function props(lista: ProveedorDBExtended[]): VistaProveedoresProps {
  return {
    proveedores: lista,
    compras: [],
    loading: false,
    isAdmin: true,
    onNuevoProveedor: vi.fn(),
    onEditarProveedor: vi.fn(),
    onEliminarProveedor: vi.fn(),
    onToggleActivo: vi.fn(),
  }
}

function renderVista(lista = proveedores()) {
  const p = props(lista)
  const vista = render(<VistaProveedores {...p} />)
  return { ...vista, props: p }
}

const nombres = () => screen.queryAllByRole('heading', { level: 3 }).map(h => h.textContent)
const rango = (desde: number, hasta: number, prefijo?: (n: number) => string) =>
  Array.from({ length: hasta - desde + 1 }, (_, i) => {
    const n = desde + i
    return prefijo ? prefijo(n) : `${n <= 30 ? 'Norte' : 'Sur'} ${pad(n)}`
  })
const siguiente = () => screen.getByRole('button', { name: 'Página siguiente' })
const anterior = () => screen.getByRole('button', { name: 'Página anterior' })

describe('VistaProveedores — paginacion', () => {
  it('con 37 proveedores se ven solo los 15 de la pagina 1', () => {
    renderVista()
    expect(nombres()).toEqual(rango(1, 15))
    expect(screen.queryByText('Norte 16')).not.toBeInTheDocument()
    expect(screen.queryByText('Sur 37')).not.toBeInTheDocument()
  })

  it('el pie dice el total de la lista (37), tiene 3 paginas y estamos en la primera', () => {
    renderVista()
    expect(screen.getByText('37 proveedores')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Página 1' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Página 3' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Página 4' })).not.toBeInTheDocument()
    expect(anterior()).toBeDisabled()
    expect(siguiente()).toBeEnabled()
  })

  it('"Página siguiente" muestra del 16 al 30 y despues los 7 que quedan', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(siguiente())
    expect(nombres()).toEqual(rango(16, 30))
    expect(anterior()).toBeEnabled()

    await user.click(siguiente())
    expect(nombres()).toEqual(rango(31, 37))
    expect(siguiente()).toBeDisabled()
  })

  it('se puede ir a una pagina por su numero y volver con "Página anterior"', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Página 3' }))
    expect(nombres()).toEqual(rango(31, 37))
    await user.click(anterior())
    expect(nombres()).toEqual(rango(16, 30))
  })

  it('una lista de exactamente una pagina (15) no muestra el pie', () => {
    renderVista(proveedores(15))
    expect(nombres()).toHaveLength(15)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })

  it('con 16 hay dos paginas y la segunda tiene un solo proveedor', async () => {
    renderVista(proveedores(16))
    await userEvent.setup().click(siguiente())
    expect(nombres()).toEqual(['Norte 16'])
  })
})

describe('VistaProveedores — los filtros vuelven a la pagina 1', () => {
  it('buscar desde la pagina 2 muestra los primeros resultados (30 coinciden: siguen siendo 2 paginas)', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(siguiente())
    expect(nombres()[0]).toBe('Norte 16')

    await user.type(screen.getByRole('textbox'), 'norte')
    expect(nombres()).toEqual(rango(1, 15))
    expect(anterior()).toBeDisabled()
    expect(screen.getByText('30 proveedores')).toBeInTheDocument()
  })

  it('"Activos" desde la pagina 2 vuelve a la 1 (25 activos: siguen siendo 2 paginas)', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(siguiente())

    await user.click(screen.getByText('Activos'))
    const activos = rango(1, 37).filter((_, i) => (i + 1) % 3 !== 0)
    expect(nombres()).toEqual(activos.slice(0, 15))
    expect(anterior()).toBeDisabled()
    expect(screen.getByText('25 proveedores')).toBeInTheDocument()
  })

  it('"Total proveedores" desde la pagina 2 de otro filtro vuelve a la 1', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(screen.getByText('Activos'))
    await user.click(siguiente())
    expect(nombres()).toHaveLength(10)

    await user.click(screen.getByText('Total proveedores'))
    expect(nombres()).toEqual(rango(1, 15))
    expect(anterior()).toBeDisabled()
    expect(screen.getByText('37 proveedores')).toBeInTheDocument()
  })

  it('"Inactivos" desde la pagina 3 muestra los 12 en una sola pagina, sin pie', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Página 3' }))

    await user.click(screen.getByText('Inactivos'))
    expect(nombres()).toHaveLength(12)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })

  it('despues de filtrar se puede seguir paginando sobre el resultado', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.type(screen.getByRole('textbox'), 'norte')
    await user.click(siguiente())
    expect(nombres()).toEqual(rango(16, 30))
    expect(siguiente()).toBeDisabled()
  })
})

describe('VistaProveedores — el total es el de la lista filtrada completa', () => {
  it('el pie cuenta los que pasan el filtro, no los de la pagina ni los 37', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.type(screen.getByRole('textbox'), 'sur')
    // 7 coinciden: una pagina, sin pie.
    expect(nombres()).toHaveLength(7)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()

    await user.clear(screen.getByRole('textbox'))
    await user.type(screen.getByRole('textbox'), 'norte')
    expect(screen.getByText('30 proveedores')).toBeInTheDocument()
  })

  it('las tarjetas de resumen siguen contando todo, sin importar la pagina', async () => {
    renderVista()
    await userEvent.setup().click(siguiente())
    expect(screen.getByText('25 activos de 37 proveedores')).toBeInTheDocument()
  })
})

describe('VistaProveedores — la pagina guardada pasa del final de la lista', () => {
  it('si la lista se achica, muestra la ultima pagina que existe y no una en blanco', async () => {
    const { rerender, props: p } = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página 3' }))
    expect(nombres()).toEqual(rango(31, 37))

    // Se borran los 7 de la pagina 3: quedan 30 -> 2 paginas.
    rerender(<VistaProveedores {...p} proveedores={proveedores(30)} />)
    expect(nombres()).toEqual(rango(16, 30))
    expect(siguiente()).toBeDisabled()
    expect(anterior()).toBeEnabled()
  })

  it('si queda una sola pagina, muestra esa y no queda en blanco', async () => {
    const { rerender, props: p } = renderVista()
    await userEvent.setup().click(siguiente())

    rerender(<VistaProveedores {...p} proveedores={proveedores(10)} />)
    expect(nombres()).toEqual(rango(1, 10))
  })
})
