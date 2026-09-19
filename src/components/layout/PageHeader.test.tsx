/**
 * PageHeader: el contrato que tienen que seguir cumpliendo los cuatro headers
 * de vista cuando WP-19 los migre acá. Los casos son los mismos que aseveran
 * sus tests de caracterización — nombre accesible del h1, crumb de loading,
 * slot de acciones — pero contra el primitivo.
 */
import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import '@testing-library/jest-dom/vitest'
import PageHeader from './PageHeader'

const CRUMBS = ['Operaciones', 'MARTES 21 DE ABRIL', '649 RESULTADOS']

describe('PageHeader', () => {
  it('renderiza todos los crumbs recibidos', () => {
    render(<PageHeader titulo="Pedidos" crumbs={CRUMBS} />)

    expect(screen.getByText('Operaciones')).toBeInTheDocument()
    expect(screen.getByText('MARTES 21 DE ABRIL')).toBeInTheDocument()
    expect(screen.getByText('649 RESULTADOS')).toBeInTheDocument()
  })

  it('pone un separador ENTRE crumbs: uno menos que crumbs', () => {
    const { container } = render(<PageHeader titulo="Pedidos" crumbs={CRUMBS} />)

    expect(
      container.querySelectorAll('header > div > p > span[aria-hidden="true"]')
    ).toHaveLength(CRUMBS.length - 1)
  })

  it('el nombre accesible del h1 es "titulo periodo"', () => {
    render(<PageHeader titulo="Pedidos" periodo="del día" crumbs={CRUMBS} />)

    expect(screen.getByRole('heading', { level: 1, name: 'Pedidos del día' })).toBeInTheDocument()
  })

  it('sin período el h1 es sólo el título y no hay <em>', () => {
    const { container } = render(<PageHeader titulo="Pedidos" crumbs={CRUMBS} />)

    expect(screen.getByRole('heading', { level: 1, name: 'Pedidos' })).toBeInTheDocument()
    expect(container.querySelector('h1 em')).toBeNull()
  })

  it('período null se trata igual que sin período', () => {
    const { container } = render(<PageHeader titulo="Clientes" periodo={null} crumbs={['Cartera']} />)

    expect(screen.getByRole('heading', { level: 1, name: 'Clientes' })).toBeInTheDocument()
    expect(container.querySelector('h1 em')).toBeNull()
  })

  it('el período va en un <em> con key = período, que es lo que dispara la animación', () => {
    const { container, rerender } = render(
      <PageHeader titulo="Pedidos" periodo="del día" crumbs={CRUMBS} />
    )
    const primero = container.querySelector('h1 em')
    expect(primero).toHaveTextContent('del día')
    expect(primero).toHaveClass('animate-[fadeSlideIn_300ms_ease-out]')

    rerender(<PageHeader titulo="Pedidos" periodo="del mes" crumbs={CRUMBS} />)

    // key distinta ⇒ nodo nuevo, no el mismo con otro texto.
    expect(container.querySelector('h1 em')).not.toBe(primero)
    expect(screen.getByRole('heading', { level: 1, name: 'Pedidos del mes' })).toBeInTheDocument()
  })

  it('loading reemplaza SÓLO el último crumb por "ACTUALIZANDO…" y lo hace latir', () => {
    render(<PageHeader titulo="Pedidos" crumbs={CRUMBS} loading />)

    expect(screen.getByText('Operaciones')).toBeInTheDocument()
    expect(screen.getByText('MARTES 21 DE ABRIL')).toBeInTheDocument()
    expect(screen.queryByText('649 RESULTADOS')).not.toBeInTheDocument()
    expect(screen.getByText('ACTUALIZANDO…')).toHaveClass('animate-pulse')
  })

  it('sin loading ningún crumb late', () => {
    const { container } = render(<PageHeader titulo="Pedidos" crumbs={CRUMBS} />)

    expect(screen.queryByText('ACTUALIZANDO…')).not.toBeInTheDocument()
    expect(container.querySelector('.animate-pulse')).toBeNull()
  })

  it('loading no toca el título ni el período', () => {
    render(<PageHeader titulo="Pedidos" periodo="del día" crumbs={CRUMBS} loading />)

    expect(screen.getByRole('heading', { level: 1, name: 'Pedidos del día' })).toBeInTheDocument()
  })

  it('renderiza el slot de acciones cuando se provee', () => {
    render(
      <PageHeader titulo="Pedidos" crumbs={CRUMBS} acciones={<button>Nuevo pedido</button>} />
    )

    expect(screen.getByRole('button', { name: 'Nuevo pedido' })).toBeInTheDocument()
  })

  it('sin acciones no se renderiza el contenedor del slot', () => {
    const { container } = render(<PageHeader titulo="Pedidos" crumbs={CRUMBS} />)

    expect(container.querySelectorAll('header > div')).toHaveLength(1)
  })

  it('acepta crumbs que no son texto plano', () => {
    render(<PageHeader titulo="Pedidos" crumbs={[<span key="a">Operaciones</span>, 'HOY']} />)

    expect(screen.getByText('Operaciones')).toBeInTheDocument()
    expect(screen.getByText('HOY')).toBeInTheDocument()
  })

  it('className extra se aplica al <header>', () => {
    const { container } = render(<PageHeader titulo="Pedidos" crumbs={CRUMBS} className="mb-6" />)

    expect(container.querySelector('header')).toHaveClass('mb-6')
  })

  it('el acento decorativo no entra en el árbol accesible', () => {
    const { container } = render(<PageHeader titulo="Pedidos" crumbs={CRUMBS} />)

    expect(container.querySelector('header > div > div[aria-hidden="true"]')).toBeInTheDocument()
  })
})
