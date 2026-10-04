/**
 * Paginacion de `VistaCompras`: la pagina guardada pasa del final (#876).
 *
 * La vista pagina en el cliente, sobre la lista ya filtrada, de a 15. Si la
 * lista se achica (se borro la ultima compra de la ultima pagina) la pagina
 * guardada queda mas alla del final: sin el recorte la tabla se veia en blanco y
 * `Paginacion` se ocultaba, asi que no habia forma de volver. Es el mismo
 * recorte que WP-51 (#775) le puso a Proveedores, Promociones y Vencimientos:
 * `pagina = min(paginaActual, max(1, totalPaginas))`.
 *
 * La lista se lee de la tabla de escritorio por rol ARIA (la columna
 * Proveedor); jsdom no evalua media queries, asi que las tarjetas del celular
 * estan en el DOM tambien, y un caso aparte mira que las dos pantallas muestren
 * lo mismo.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaCompras, { type VistaComprasProps } from '../VistaCompras'
import type { CompraDBExtended, ProveedorDBExtended } from '../../../types'

const POR_PAGINA = 15
const pad = (n: number) => String(n).padStart(2, '0')
const proveedor = (n: number) => `Proveedor ${pad(n)}`

/**
 * 37 compras de "Proveedor 01" .. "Proveedor 37":
 *  - 37 -> 3 paginas (15 + 15 + 7)
 *  - 30 -> 2 paginas
 *  - 16 -> 2 paginas (la segunda con una sola compra)
 *  - 15 -> 1 pagina (sin pie)
 */
function compras(cantidad = 37): CompraDBExtended[] {
  return Array.from({ length: cantidad }, (_, i) => {
    const n = i + 1
    return {
      id: String(n),
      proveedor_id: String(n),
      proveedor: { id: String(n), nombre: proveedor(n) },
      proveedor_nombre: proveedor(n),
      numero_factura: `A-${pad(n)}`,
      estado: 'recibida',
      total: 1000 * n,
      fecha_compra: '2026-09-20',
      created_at: '2026-09-20T10:00:00Z',
      items: [],
    } as unknown as CompraDBExtended
  })
}

function props(lista: CompraDBExtended[]): VistaComprasProps {
  return {
    compras: lista,
    proveedores: [] as ProveedorDBExtended[],
    loading: false,
    isAdmin: true,
    isEncargado: false,
    onNuevaCompra: vi.fn(),
    onVerDetalle: vi.fn(),
    onAnularCompra: vi.fn(),
  }
}

function renderVista(lista = compras()) {
  const p = props(lista)
  const vista = render(<VistaCompras {...p} />)
  const rerenderCon = (nueva: CompraDBExtended[]) => vista.rerender(<VistaCompras {...p} compras={nueva} />)
  return { ...vista, props: p, rerenderCon }
}

/** Los proveedores de la columna "Proveedor" de la tabla, en orden. */
const filas = () =>
  within(screen.getByRole('table'))
    .getAllByRole('row')
    .slice(1)
    .map(fila => within(fila).getAllByRole('cell')[1].textContent)

/** Los proveedores de las tarjetas del celular, en orden. */
const tarjetas = () =>
  screen.getAllByRole('heading', { level: 3 }).map(h => h.textContent)

const rango = (desde: number, hasta: number) =>
  Array.from({ length: hasta - desde + 1 }, (_, i) => proveedor(desde + i))
const siguiente = () => screen.getByRole('button', { name: 'Página siguiente' })
const anterior = () => screen.getByRole('button', { name: 'Página anterior' })

describe('VistaCompras — paginacion (control: lo que ya andaba)', () => {
  it('con 37 compras se ven las 15 de la pagina 1, con pie de 3 paginas', () => {
    renderVista()
    expect(filas()).toEqual(rango(1, POR_PAGINA))
    expect(screen.getByText('37 compras')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Página 3' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Página 4' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { current: 'page' })).toHaveAccessibleName('Página 1')
  })

  it('la ultima pagina tiene las 7 que quedan', async () => {
    renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página 3' }))
    expect(filas()).toEqual(rango(31, 37))
    expect(siguiente()).toBeDisabled()
  })
})

describe('VistaCompras — la pagina guardada pasa del final de la lista', () => {
  it('si se borra la ultima compra de la ultima pagina, muestra la ultima que existe y no una en blanco', async () => {
    const { rerenderCon } = renderVista(compras(31))
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página 3' }))
    expect(filas()).toEqual(rango(31, 31))

    // Se borra la unica compra de la pagina 3: quedan 30 -> 2 paginas.
    rerenderCon(compras(30))
    expect(filas()).toEqual(rango(16, 30))
    expect(screen.getByRole('table')).toBeInTheDocument()
    expect(screen.getByRole('button', { current: 'page' })).toHaveAccessibleName('Página 2')
    expect(siguiente()).toBeDisabled()
    expect(anterior()).toBeEnabled()
  })

  it('si se borran las 7 de la ultima pagina, tambien: la tabla no queda en blanco', async () => {
    const { rerenderCon } = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página 3' }))
    expect(filas()).toEqual(rango(31, 37))

    rerenderCon(compras(30))
    expect(filas()).toEqual(rango(16, 30))
    expect(screen.getByText('30 compras')).toBeInTheDocument()
  })

  it('las tarjetas del celular tambien muestran la ultima pagina que existe', async () => {
    const { rerenderCon } = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página 3' }))

    rerenderCon(compras(30))
    expect(tarjetas()).toEqual(rango(16, 30))
  })

  it('si queda una sola pagina, muestra esa y no queda en blanco', async () => {
    const { rerenderCon } = renderVista(compras(16))
    await userEvent.setup().click(siguiente())
    expect(filas()).toEqual(rango(16, 16))

    // Se borra la unica compra de la pagina 2: quedan 15 -> 1 pagina, sin pie.
    rerenderCon(compras(15))
    expect(filas()).toEqual(rango(1, 15))
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })

  it('despues del recorte se puede volver con "Página anterior" a la pagina de al lado', async () => {
    const { rerenderCon } = renderVista()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Página 3' }))
    rerenderCon(compras(30))
    expect(filas()).toEqual(rango(16, 30))

    // La pagina que cuenta es la visible (2), no la guardada (3): anterior va a la 1.
    await user.click(anterior())
    expect(filas()).toEqual(rango(1, POR_PAGINA))
    expect(screen.getByRole('button', { current: 'page' })).toHaveAccessibleName('Página 1')
  })
})
