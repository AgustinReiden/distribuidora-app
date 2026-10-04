/**
 * Paginacion de `VistaProductos`: la pagina guardada pasa del final (#876).
 *
 * La vista pagina en el cliente, sobre la lista ya filtrada, de a 20. Si la
 * lista se achica (se borro el ultimo producto de la ultima pagina) la pagina
 * guardada queda mas alla del final: sin el recorte la tabla se veia en blanco y
 * `Paginacion` se ocultaba, asi que no habia forma de volver. Es el mismo
 * recorte que WP-51 (#775) le puso a Proveedores, Promociones y Vencimientos:
 * `pagina = min(paginaActual, max(1, totalPaginas))`.
 *
 * `VistaProductos.porRol.test.tsx` fija lo que cada rol ve con una lista chica y
 * tiene que seguir verde.
 *
 * La lista se lee de la tabla de escritorio por rol ARIA (la columna Producto);
 * jsdom no evalua media queries, asi que las tarjetas del celular estan en el
 * DOM tambien, y un caso aparte mira que las dos pantallas muestren lo mismo.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { MemoryRouter } from 'react-router-dom'
import VistaProductos, { type VistaProductosProps } from '../VistaProductos'
import type { ProductoDB } from '../../../types'

// Radix (menus del toolbar del admin) los pide al montar.
class ObservadorStub {
  observe(): void { /* no-op */ }
  unobserve(): void { /* no-op */ }
  disconnect(): void { /* no-op */ }
  takeRecords(): [] { return [] }
}
globalThis.ResizeObserver ??= ObservadorStub as unknown as typeof ResizeObserver
globalThis.IntersectionObserver ??= ObservadorStub as unknown as typeof IntersectionObserver

const POR_PAGINA = 20
const pad = (n: number) => String(n).padStart(2, '0')
const nombre = (n: number) => `Producto ${pad(n)}`

/**
 * 45 productos "Producto 01" .. "Producto 45":
 *  - 45 -> 3 paginas (20 + 20 + 5)
 *  - 40 -> 2 paginas
 *  - 20 -> 1 pagina (sin pie)
 */
function productos(cantidad = 45): ProductoDB[] {
  return Array.from({ length: cantidad }, (_, i) => {
    const n = i + 1
    return {
      id: String(n),
      codigo: `P-${pad(n)}`,
      nombre: nombre(n),
      precio: 1000 + n,
      stock: 50,
      stock_minimo: 10,
      categoria: 'Varios',
    } as unknown as ProductoDB
  })
}

function props(lista: ProductoDB[]): VistaProductosProps {
  return {
    productos: lista,
    productosStockBajo: [],
    loading: false,
    isAdmin: true,
    onNuevoProducto: vi.fn(),
    onEditarProducto: vi.fn(),
    onEliminarProducto: vi.fn(),
  }
}

const vistaDe = (p: VistaProductosProps) => (
  <MemoryRouter>
    <VistaProductos {...p} />
  </MemoryRouter>
)

function renderVista(lista = productos()) {
  const p = props(lista)
  const vista = render(vistaDe(p))
  // `MemoryRouter` va adentro del rerender tambien: se monta igual y conserva el estado.
  const rerenderCon = (nueva: ProductoDB[]) => vista.rerender(vistaDe({ ...p, productos: nueva }))
  return { ...vista, props: p, rerenderCon }
}

/** Los nombres de la columna "Producto" de la tabla, en orden. */
const filas = () =>
  within(screen.getByRole('table'))
    .getAllByRole('row')
    .slice(1)
    .map(fila => within(fila).getAllByRole('cell')[1].textContent)

/** Los nombres de las tarjetas del celular, en orden. */
const tarjetas = () =>
  screen.getAllByRole('heading', { level: 3 }).map(h => h.textContent)

const rango = (desde: number, hasta: number) =>
  Array.from({ length: hasta - desde + 1 }, (_, i) => nombre(desde + i))
const siguiente = () => screen.getByRole('button', { name: 'Página siguiente' })
const anterior = () => screen.getByRole('button', { name: 'Página anterior' })

describe('VistaProductos — paginacion (control: lo que ya andaba)', () => {
  it('con 45 productos se ven los 20 de la pagina 1, con pie de 3 paginas', () => {
    renderVista()
    expect(filas()).toEqual(rango(1, POR_PAGINA))
    expect(screen.getByText('45 productos')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Página 3' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Página 4' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { current: 'page' })).toHaveAccessibleName('Página 1')
  })

  it('la ultima pagina tiene los 5 que quedan', async () => {
    renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página 3' }))
    expect(filas()).toEqual(rango(41, 45))
    expect(siguiente()).toBeDisabled()
  })
})

describe('VistaProductos — la pagina guardada pasa del final de la lista', () => {
  it('si se borra el ultimo de la ultima pagina, muestra la ultima que existe y no una en blanco', async () => {
    const { rerenderCon } = renderVista(productos(41))
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página 3' }))
    expect(filas()).toEqual(rango(41, 41))

    // Se borra el unico producto de la pagina 3: quedan 40 -> 2 paginas.
    rerenderCon(productos(40))
    expect(filas()).toEqual(rango(21, 40))
    expect(screen.getByRole('table')).toBeInTheDocument()
    expect(screen.getByRole('button', { current: 'page' })).toHaveAccessibleName('Página 2')
    expect(siguiente()).toBeDisabled()
    expect(anterior()).toBeEnabled()
  })

  it('si se borran los 5 de la ultima pagina, tambien: la tabla no queda en blanco', async () => {
    const { rerenderCon } = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página 3' }))
    expect(filas()).toEqual(rango(41, 45))

    rerenderCon(productos(40))
    expect(filas()).toEqual(rango(21, 40))
    expect(screen.getByText('40 productos')).toBeInTheDocument()
  })

  it('las tarjetas del celular tambien muestran la ultima pagina que existe', async () => {
    const { rerenderCon } = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página 3' }))

    rerenderCon(productos(40))
    expect(tarjetas()).toEqual(rango(21, 40))
  })

  it('si queda una sola pagina, muestra esa y no queda en blanco', async () => {
    const { rerenderCon } = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página 3' }))

    rerenderCon(productos(12))
    expect(filas()).toEqual(rango(1, 12))
    // Una sola pagina: sin pie, y ya no hace falta volver.
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })

  it('despues del recorte se puede volver con "Página anterior" a la pagina de al lado', async () => {
    const { rerenderCon } = renderVista()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Página 3' }))
    rerenderCon(productos(40))
    expect(filas()).toEqual(rango(21, 40))

    // La pagina que cuenta es la visible (2), no la guardada (3): anterior va a la 1.
    await user.click(anterior())
    expect(filas()).toEqual(rango(1, POR_PAGINA))
    expect(screen.getByRole('button', { current: 'page' })).toHaveAccessibleName('Página 1')
  })
})
