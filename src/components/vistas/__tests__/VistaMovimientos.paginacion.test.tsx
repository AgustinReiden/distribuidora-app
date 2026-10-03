/**
 * Paginacion de `VistaMovimientos` (WP-51, #775).
 *
 * La paginacion de esta pantalla es del SERVIDOR (`useMovimientosQuery` pide una
 * pagina de 50 con `.range()` y trae el conteo exacto): la vista dibuja todo lo
 * que le llega y solo suma el control de pagina. Estos tests fijan ese control,
 * por rol y por texto:
 *  - el pie dice el total de la lista (el conteo del servidor, no las filas que
 *    llegaron) y avisa a `onPageChange` a que pagina se quiere ir;
 *  - la pagina que se dibuja es la que llega: la vista no recorta;
 *  - sin `paginacion`, o con una sola pagina, no hay control.
 *
 * Que el container pida la pagina siguiente, que vuelva a la 1 al cambiar de
 * pestaña y de donde sale el total lo cubren `MovimientosContainer.paginacion`
 * y `useMovimientosQuery.paginacion`.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaMovimientos, { type VistaMovimientosProps } from '../VistaMovimientos'
import type { MovimientoSucursalDB } from '../../../hooks/queries'

function mov(id: number): MovimientoSucursalDB {
  return {
    id,
    sucursal_origen_id: 2,
    sucursal_destino_id: 1,
    estado: 'aceptada',
    total_costo: 1000,
    total_unidades: 10,
    stock_descontado: false,
    notas: null,
    motivo_rechazo: null,
    creado_por: 'u1',
    resuelto_por: null,
    editado_por: null,
    created_at: '2026-10-01T12:00:00Z',
    resuelto_at: null,
    editado_at: null,
    origen: { id: 2, nombre: 'Sucursal Sur' },
    destino: { id: 1, nombre: 'Casa Central' },
    creador: { id: 'u1', nombre: 'Ana' },
  }
}

/** Una pagina de `cantidad` movimientos con ids decrecientes desde `desde`. */
const pagina = (desde: number, cantidad: number) =>
  Array.from({ length: cantidad }, (_, i) => mov(desde - i))

function renderVista(overrides: Partial<VistaMovimientosProps> = {}) {
  const props: VistaMovimientosProps = {
    movimientos: pagina(120, 50),
    loading: false,
    currentSucursalId: 1,
    canResolver: true,
    canEditar: true,
    estado: 'todos',
    onEstadoChange: vi.fn(),
    onNuevaSalida: vi.fn(),
    onAceptar: vi.fn(),
    onDenegar: vi.fn(),
    onVerDetalle: vi.fn(),
    onEditar: vi.fn(),
    onCancelar: vi.fn(),
    paginacion: { paginaActual: 1, totalPaginas: 3, totalItems: 120, onPageChange: vi.fn() },
    ...overrides,
  }
  render(<VistaMovimientos {...props} />)
  return props
}

const filas = () => screen.queryAllByRole('button', { name: 'Ver detalle' })

describe('VistaMovimientos — control de pagina', () => {
  it('dibuja las 50 filas que llegan, sin recortar, y el pie dice el total del servidor (120)', () => {
    renderVista()
    expect(filas()).toHaveLength(50)
    expect(screen.getByText('120 movimientos')).toBeInTheDocument()
  })

  it('con 3 paginas ofrece 1, 2 y 3, y en la primera no se puede ir hacia atras', () => {
    renderVista()
    for (const n of ['1', '2', '3']) expect(screen.getByRole('button', { name: n })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '4' })).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Página anterior' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Página siguiente' })).toBeEnabled()
  })

  it('"Página siguiente" pide la pagina 2', async () => {
    const props = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Página siguiente' }))
    expect(props.paginacion!.onPageChange).toHaveBeenCalledWith(2)
  })

  it('"Página anterior" pide la pagina previa y el numero pide esa pagina', async () => {
    const props = renderVista({
      paginacion: { paginaActual: 2, totalPaginas: 3, totalItems: 120, onPageChange: vi.fn() },
    })
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Página anterior' }))
    expect(props.paginacion!.onPageChange).toHaveBeenLastCalledWith(1)
    await user.click(screen.getByRole('button', { name: '3' }))
    expect(props.paginacion!.onPageChange).toHaveBeenLastCalledWith(3)
  })

  it('en la ultima pagina no se puede ir hacia adelante y se ven las filas que llegaron (20)', () => {
    renderVista({
      movimientos: pagina(20, 20),
      paginacion: { paginaActual: 3, totalPaginas: 3, totalItems: 120, onPageChange: vi.fn() },
    })
    expect(filas()).toHaveLength(20)
    expect(screen.getByRole('button', { name: 'Página siguiente' })).toBeDisabled()
    // El pie sigue diciendo el total de la lista, no los 20 de esta pagina.
    expect(screen.getByText('120 movimientos')).toBeInTheDocument()
  })

  it('con una sola pagina no hay control', () => {
    renderVista({
      movimientos: pagina(30, 30),
      paginacion: { paginaActual: 1, totalPaginas: 1, totalItems: 30, onPageChange: vi.fn() },
    })
    expect(filas()).toHaveLength(30)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })

  it('sin la prop `paginacion` no hay control', () => {
    renderVista({ paginacion: undefined })
    expect(filas()).toHaveLength(50)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })

  it('cargando una lista nueva no hay filas pero el pie no se rompe', () => {
    renderVista({
      movimientos: [],
      loading: true,
      paginacion: { paginaActual: 1, totalPaginas: 0, totalItems: 0, onPageChange: vi.fn() },
    })
    expect(screen.getByText('Cargando...')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })
})
