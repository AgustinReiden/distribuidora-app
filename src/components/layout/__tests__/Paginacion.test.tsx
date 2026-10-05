/**
 * `Paginacion` (#876): la pagina actual la anuncia el lector de pantalla.
 *
 * Antes los botones numericos se distinguian solo por la clase CSS (el azul de
 * la pagina actual) y su nombre accesible era el numero pelado. Ahora el de la
 * pagina actual lleva `aria-current="page"` y cada numero se llama "Pagina N".
 *
 * Lo que se ve no cambia: el texto de cada boton sigue siendo el numero.
 *
 * Se mira por rol ARIA, nunca por clase: `getByRole('button', { current:
 * 'page' })` es exactamente lo que hace un lector de pantalla.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import Paginacion, { type PaginacionProps } from '../Paginacion'

function props(parcial: Partial<PaginacionProps> = {}): PaginacionProps {
  return {
    paginaActual: 1,
    totalPaginas: 3,
    totalItems: 37,
    itemsLabel: 'productos',
    onPageChange: vi.fn(),
    ...parcial,
  }
}

function renderPaginacion(parcial: Partial<PaginacionProps> = {}) {
  const p = props(parcial)
  const vista = render(<Paginacion {...p} />)
  return { ...vista, props: p }
}

const actual = () => screen.getByRole('button', { current: 'page' })
const pagina = (n: number) => screen.getByRole('button', { name: `Página ${n}` })

describe('Paginacion — la pagina actual para el lector de pantalla', () => {
  it('el boton de la pagina actual se encuentra por aria-current="page"', () => {
    renderPaginacion({ paginaActual: 2 })
    expect(actual()).toHaveAttribute('aria-current', 'page')
    expect(actual()).toHaveAccessibleName('Página 2')
    // Lo que se ve es el numero, como siempre.
    expect(actual()).toHaveTextContent('2')
  })

  it('es la unica: ninguna otra pagina, ni anterior ni siguiente, se marca como actual', () => {
    renderPaginacion({ paginaActual: 2 })
    expect(screen.getAllByRole('button', { current: 'page' })).toHaveLength(1)
    expect(pagina(1)).not.toHaveAttribute('aria-current')
    expect(pagina(3)).not.toHaveAttribute('aria-current')
    expect(screen.getByRole('button', { name: 'Página anterior' })).not.toHaveAttribute('aria-current')
    expect(screen.getByRole('button', { name: 'Página siguiente' })).not.toHaveAttribute('aria-current')
  })

  it('la marca sigue a la pagina: al cambiar paginaActual se mueve al otro boton', () => {
    const { rerender, props: p } = renderPaginacion({ paginaActual: 1 })
    expect(actual()).toHaveAccessibleName('Página 1')

    rerender(<Paginacion {...p} paginaActual={3} />)
    expect(screen.getAllByRole('button', { current: 'page' })).toHaveLength(1)
    expect(actual()).toHaveAccessibleName('Página 3')
    expect(pagina(1)).not.toHaveAttribute('aria-current')
  })
})

describe('Paginacion — cada numero se llama "Página N"', () => {
  it('con 5 paginas hay un boton "Página N" por cada una, y se lee el numero', () => {
    renderPaginacion({ paginaActual: 1, totalPaginas: 5 })
    for (const n of [1, 2, 3, 4, 5]) {
      expect(pagina(n)).toHaveTextContent(String(n))
    }
    expect(screen.queryByRole('button', { name: 'Página 6' })).not.toBeInTheDocument()
  })

  it('el nombre es "Página N" y no el numero pelado', () => {
    renderPaginacion({ paginaActual: 1, totalPaginas: 3 })
    expect(screen.queryByRole('button', { name: '1' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '2' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '3' })).not.toBeInTheDocument()
  })

  it('con muchas paginas muestra una ventana de 5 alrededor de la actual, cada una con su nombre', () => {
    renderPaginacion({ paginaActual: 9, totalPaginas: 9 })
    for (const n of [5, 6, 7, 8, 9]) expect(pagina(n)).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Página 4' })).not.toBeInTheDocument()
    expect(actual()).toHaveAccessibleName('Página 9')
  })

  it('anterior y siguiente conservan su nombre', () => {
    renderPaginacion({ paginaActual: 2 })
    expect(screen.getByRole('button', { name: 'Página anterior' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Página siguiente' })).toBeEnabled()
  })
})

describe('Paginacion — el comportamiento no cambia', () => {
  it('un clic en un numero llama a onPageChange con ese numero', async () => {
    const { props: p } = renderPaginacion({ paginaActual: 1 })
    await userEvent.setup().click(pagina(3))
    expect(p.onPageChange).toHaveBeenCalledTimes(1)
    expect(p.onPageChange).toHaveBeenCalledWith(3)
  })

  it('anterior y siguiente piden la pagina de al lado', async () => {
    const { props: p } = renderPaginacion({ paginaActual: 2 })
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Página anterior' }))
    expect(p.onPageChange).toHaveBeenLastCalledWith(1)
    await user.click(screen.getByRole('button', { name: 'Página siguiente' }))
    expect(p.onPageChange).toHaveBeenLastCalledWith(3)
  })

  it('anterior esta deshabilitado en la primera pagina y siguiente en la ultima', () => {
    const { rerender, props: p } = renderPaginacion({ paginaActual: 1 })
    expect(screen.getByRole('button', { name: 'Página anterior' })).toBeDisabled()
    rerender(<Paginacion {...p} paginaActual={3} />)
    expect(screen.getByRole('button', { name: 'Página siguiente' })).toBeDisabled()
  })

  it('el pie cuenta los items, en singular o plural', () => {
    const { rerender, props: p } = renderPaginacion({ totalItems: 37 })
    expect(screen.getByText('37 productos')).toBeInTheDocument()
    rerender(<Paginacion {...p} totalItems={1} totalPaginas={2} />)
    expect(screen.getByText('1 producto')).toBeInTheDocument()
  })

  it('con una sola pagina no dibuja nada', () => {
    const { container } = renderPaginacion({ totalPaginas: 1 })
    expect(container).toBeEmptyDOMElement()
    expect(screen.queryByRole('button')).not.toBeInTheDocument()
  })
})
