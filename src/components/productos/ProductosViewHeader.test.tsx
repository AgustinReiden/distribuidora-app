/**
 * Caracterización de ProductosViewHeader: fija el comportamiento ACTUAL del
 * crumb, el título dinámico (vía labelCategoriaProductos) y el conteo antes
 * de reemplazarlo por un PageHeader común.
 *
 * La fecha del sistema queda fija en martes 21 de abril de 2026 (10:00 hora
 * local) para que el crumb de fecha sea determinista.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import ProductosViewHeader from './ProductosViewHeader'

const AHORA = '2026-04-21T10:00:00'

beforeEach(() => {
  vi.useFakeTimers()
  vi.setSystemTime(new Date(AHORA))
})

afterEach(() => {
  vi.useRealTimers()
})

describe('ProductosViewHeader', () => {
  it('muestra el crumb de sección, la fecha larga y el título sin sufijo cuando no hay filtros', () => {
    render(
      <ProductosViewHeader
        busqueda=""
        categoriaSeleccionada="todas"
        mostrarSoloStockBajo={false}
        totalCount={0}
        loading={false}
      />
    )

    expect(screen.getByText('Catálogo')).toBeInTheDocument()
    expect(screen.getByText('MARTES 21 DE ABRIL')).toBeInTheDocument()
    expect(screen.getByRole('heading', { level: 1, name: 'Productos' })).toBeInTheDocument()
  })

  it('mostrarSoloStockBajo=true tiene prioridad y da "Productos con stock bajo"', () => {
    render(
      <ProductosViewHeader
        busqueda="agua"
        categoriaSeleccionada="BEBIDAS"
        mostrarSoloStockBajo
        totalCount={4}
        loading={false}
      />
    )
    expect(
      screen.getByRole('heading', { level: 1, name: 'Productos con stock bajo' })
    ).toBeInTheDocument()
  })

  it('categoría SCREAMING_CASE se normaliza a Title Case en el título', () => {
    render(
      <ProductosViewHeader
        busqueda=""
        categoriaSeleccionada="BEBIDAS"
        mostrarSoloStockBajo={false}
        totalCount={20}
        loading={false}
      />
    )
    expect(
      screen.getByRole('heading', { level: 1, name: 'Productos de Bebidas' })
    ).toBeInTheDocument()
  })

  it('solo búsqueda da "Productos que coinciden con \\"agua\\""', () => {
    render(
      <ProductosViewHeader
        busqueda="agua"
        categoriaSeleccionada="todas"
        mostrarSoloStockBajo={false}
        totalCount={3}
        loading={false}
      />
    )
    expect(
      screen.getByRole('heading', { level: 1, name: 'Productos que coinciden con "agua"' })
    ).toBeInTheDocument()
  })

  it('conteo en singular: "1 PRODUCTO"', () => {
    render(
      <ProductosViewHeader
        busqueda=""
        categoriaSeleccionada="todas"
        mostrarSoloStockBajo={false}
        totalCount={1}
        loading={false}
      />
    )
    expect(screen.getByText('1 PRODUCTO')).toBeInTheDocument()
  })

  it('conteo en plural con separador de miles: "1.500 PRODUCTOS"', () => {
    render(
      <ProductosViewHeader
        busqueda=""
        categoriaSeleccionada="todas"
        mostrarSoloStockBajo={false}
        totalCount={1500}
        loading={false}
      />
    )
    expect(screen.getByText('1.500 PRODUCTOS')).toBeInTheDocument()
  })

  it('estado loading muestra "ACTUALIZANDO…" en vez del conteo', () => {
    render(
      <ProductosViewHeader
        busqueda=""
        categoriaSeleccionada="todas"
        mostrarSoloStockBajo={false}
        totalCount={90}
        loading
      />
    )
    expect(screen.getByText('ACTUALIZANDO…')).toBeInTheDocument()
    expect(screen.queryByText('90 PRODUCTOS')).not.toBeInTheDocument()
  })

  it('renderiza el slot de actions cuando se provee', () => {
    render(
      <ProductosViewHeader
        busqueda=""
        categoriaSeleccionada="todas"
        mostrarSoloStockBajo={false}
        totalCount={0}
        loading={false}
        actions={<button>Nuevo producto</button>}
      />
    )
    expect(screen.getByRole('button', { name: 'Nuevo producto' })).toBeInTheDocument()
  })
})
