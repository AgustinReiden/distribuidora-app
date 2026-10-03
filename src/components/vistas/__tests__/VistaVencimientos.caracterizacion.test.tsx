/**
 * Caracterizacion de `VistaVencimientos` (WP-51, #775), ANTES de paginarla.
 *
 * `VistaVencimientos.test.ts` solo cubre el schema Zod de la devolucion; este
 * archivo cubre la LISTA. Fija, por rol ARIA y por texto (nunca por clase), con
 * una lista CHICA —menos que una pagina—:
 *  - cuantas filas se ven con el filtro "Todos" (que incluye los lotes `ok`,
 *    que no tienen filtro propio);
 *  - los conteos por estado en los botones de filtro y que cada filtro deja
 *    solo las filas de su estado;
 *  - que los umbrales (diasAlerta / diasCritico) recalculan estados y conteos;
 *  - las acciones por fila, la lista vacia y la carga.
 *
 * La lista chica es a proposito: lo que cambia con la paginacion es lo que pasa
 * ARRIBA de una pagina, y eso lo cubre `VistaVencimientos.paginacion.test.tsx`.
 * Este archivo tiene que seguir verde, sin tocarse, despues de paginar.
 *
 * El reloj se fija en el 3/10/2026 (solo `Date`): el semaforo depende de hoy.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaVencimientos, { type VistaVencimientosProps } from '../VistaVencimientos'
import type { LoteReporte } from '../../../hooks/queries/useLotesQuery'

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] })
  // Mediodia del 3/10/2026, hora local: el "hoy" del navegador es el 2026-10-03.
  vi.setSystemTime(new Date(2026, 9, 3, 12, 0, 0))
})

afterEach(() => {
  vi.useRealTimers()
})

// Con diasCritico = 15 y diasAlerta = 30, y hoy = 2026-10-03:
const VENCIDO = '2026-09-20' // hace 13 dias
const CRITICO = '2026-10-10' // en 7 dias
const ALERTA = '2026-10-28' // en 25 dias
const OK = '2026-12-31' // en 89 dias

function lote(id: number, fecha: string, extra: Partial<LoteReporte> = {}): LoteReporte {
  return {
    lote_id: id,
    producto_id: 100 + id,
    producto_nombre: `Producto ${String(id).padStart(2, '0')}`,
    producto_codigo: null,
    fecha_vencimiento: fecha,
    cantidad: 10,
    cantidad_restante: 8,
    dias_restantes: 0,
    origen: 'manual',
    compra_id: null,
    stock_producto: 40,
    bolsa_producto: 0,
    ...extra,
  }
}

/** 2 vencidos, 3 criticos, 2 por vencer y 4 ok: 11 lotes. */
const LOTES: LoteReporte[] = [
  lote(1, VENCIDO), lote(2, VENCIDO),
  lote(3, CRITICO), lote(4, CRITICO), lote(5, CRITICO),
  lote(6, ALERTA), lote(7, ALERTA),
  lote(8, OK), lote(9, OK), lote(10, OK), lote(11, OK),
]

function propsBase(overrides: Partial<VistaVencimientosProps> = {}): VistaVencimientosProps {
  return {
    lotes: LOTES,
    cargando: false,
    refrescando: false,
    diasAlerta: 30,
    diasCritico: 15,
    puedeDarDeBaja: true,
    darDeBajaPendiente: false,
    devolucionPendiente: false,
    onRefrescar: vi.fn(),
    onDarDeBaja: vi.fn().mockResolvedValue(undefined),
    onDevolverAlProveedor: vi.fn().mockResolvedValue(undefined),
    nombreSucursal: 'Tucumán',
    ...overrides,
  }
}

function renderVista(overrides: Partial<VistaVencimientosProps> = {}) {
  const props = propsBase(overrides)
  const vista = render(<VistaVencimientos {...props} />)
  return { props, ...vista }
}

/** Las filas de datos de la tabla (sin el encabezado), por el nombre del producto. */
const productosEnFilas = () =>
  screen.getAllByRole('row').slice(1).map(fila => within(fila).getByText(/^Producto \d+$/).textContent)

const boton = (nombre: string) => screen.getByRole('button', { name: new RegExp(`^${nombre}`) })

describe('VistaVencimientos — filtro "Todos" y conteos por estado', () => {
  it('"Todos" es el filtro por defecto y dibuja los 11 lotes, ok incluidos', () => {
    renderVista()
    expect(productosEnFilas()).toHaveLength(11)
    expect(productosEnFilas()[0]).toBe('Producto 01')
    expect(productosEnFilas()[10]).toBe('Producto 11')
  })

  it('cada boton de filtro dice cuantos lotes tiene', () => {
    renderVista()
    expect(boton('Todos')).toHaveTextContent('Todos (11)')
    expect(boton('Vencidos')).toHaveTextContent('Vencidos (2)')
    expect(boton('Urgentes')).toHaveTextContent('Urgentes (3)')
    expect(boton('Por vencer')).toHaveTextContent('Por vencer (2)')
  })

  it('"Vencidos" deja solo los vencidos', async () => {
    renderVista()
    await userEvent.setup().click(boton('Vencidos'))
    expect(productosEnFilas()).toEqual(['Producto 01', 'Producto 02'])
  })

  it('"Urgentes" deja solo los criticos', async () => {
    renderVista()
    await userEvent.setup().click(boton('Urgentes'))
    expect(productosEnFilas()).toEqual(['Producto 03', 'Producto 04', 'Producto 05'])
  })

  it('"Por vencer" deja solo los de alerta', async () => {
    renderVista()
    await userEvent.setup().click(boton('Por vencer'))
    expect(productosEnFilas()).toEqual(['Producto 06', 'Producto 07'])
  })

  it('"Todos" vuelve a mostrar los 11 despues de filtrar', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(boton('Vencidos'))
    await user.click(boton('Todos'))
    expect(productosEnFilas()).toHaveLength(11)
  })

  it('los conteos no dependen del filtro elegido', async () => {
    renderVista()
    await userEvent.setup().click(boton('Urgentes'))
    expect(boton('Todos')).toHaveTextContent('Todos (11)')
    expect(boton('Vencidos')).toHaveTextContent('Vencidos (2)')
    expect(boton('Por vencer')).toHaveTextContent('Por vencer (2)')
  })

  it('cada fila lleva el texto de cuanto falta o cuanto hace que vencio', () => {
    renderVista()
    expect(screen.getAllByText('vencido hace 13 días')).toHaveLength(2)
    expect(screen.getAllByText('vence en 7 días')).toHaveLength(3)
    expect(screen.getAllByText('vence en 25 días')).toHaveLength(2)
    expect(screen.getAllByText('vence en 89 días')).toHaveLength(4)
  })
})

describe('VistaVencimientos — umbrales', () => {
  it('el encabezado dice los umbrales y la sucursal', () => {
    renderVista()
    expect(screen.getByRole('heading', { level: 1, name: 'Vencimientos' })).toBeInTheDocument()
    expect(screen.getByText(/Tucumán · Rojo a 15 días, amarillo a 30\./)).toBeInTheDocument()
  })

  it('al bajar diasCritico los lotes de 7 dias pasan de urgentes a por vencer', () => {
    const { props, rerender } = renderVista()
    expect(boton('Urgentes')).toHaveTextContent('Urgentes (3)')
    rerender(<VistaVencimientos {...props} diasCritico={5} />)
    expect(boton('Urgentes')).toHaveTextContent('Urgentes (0)')
    expect(boton('Por vencer')).toHaveTextContent('Por vencer (5)')
    // El total no cambia: son los mismos 11 lotes.
    expect(boton('Todos')).toHaveTextContent('Todos (11)')
  })

  it('al bajar diasAlerta los lotes de 25 dias pasan a ok y dejan de contar en "Por vencer"', () => {
    const { props, rerender } = renderVista()
    rerender(<VistaVencimientos {...props} diasAlerta={20} />)
    expect(boton('Por vencer')).toHaveTextContent('Por vencer (0)')
    expect(boton('Todos')).toHaveTextContent('Todos (11)')
  })
})

describe('VistaVencimientos — acciones por fila', () => {
  it('con permiso, cada fila ofrece "Dar de baja"', () => {
    renderVista()
    expect(screen.getAllByRole('button', { name: /Dar de baja/ })).toHaveLength(11)
  })

  it('"Devolver al proveedor" solo aparece en los lotes que vienen de una factura', () => {
    renderVista({ lotes: [lote(1, VENCIDO, { compra_id: 77, origen: 'compra' }), lote(2, VENCIDO)] })
    expect(screen.getAllByRole('button', { name: /Dar de baja/ })).toHaveLength(2)
    expect(screen.getAllByRole('button', { name: /Devolver al proveedor/ })).toHaveLength(1)
  })

  it('sin permiso no hay ninguna accion', () => {
    renderVista({ puedeDarDeBaja: false })
    expect(productosEnFilas()).toHaveLength(11)
    expect(screen.queryByRole('button', { name: /Dar de baja/ })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /Devolver al proveedor/ })).not.toBeInTheDocument()
  })

  it('"Dar de baja" abre el formulario y confirma con la cantidad restante', async () => {
    const { props } = renderVista({ lotes: [lote(1, VENCIDO)] })
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: /Dar de baja/ }))
    expect(screen.getByRole('spinbutton', { name: 'Unidades a dar de baja' })).toHaveValue(8)
    await user.click(screen.getByRole('button', { name: 'Confirmar la baja' }))
    expect(props.onDarDeBaja).toHaveBeenCalledWith(1, 8)
  })

  it('"Actualizar" llama a onRefrescar y se deshabilita mientras refresca', async () => {
    const { props, rerender } = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: 'Actualizar' }))
    expect(props.onRefrescar).toHaveBeenCalledTimes(1)
    rerender(<VistaVencimientos {...props} refrescando />)
    expect(screen.getByRole('button', { name: 'Actualizar' })).toBeDisabled()
  })

  it('con algun lote vencido aclara que no bloquean la venta', () => {
    renderVista()
    expect(screen.getByText(/Los lotes vencidos/)).toBeInTheDocument()
  })

  it('sin lotes vencidos no hay aclaracion', () => {
    renderVista({ lotes: [lote(1, CRITICO)] })
    expect(screen.queryByText(/Los lotes vencidos/)).not.toBeInTheDocument()
  })
})

describe('VistaVencimientos — lista vacia y carga', () => {
  it('sin lotes dice "No hay vencimientos cargados."', () => {
    renderVista({ lotes: [] })
    expect(screen.getByText('No hay vencimientos cargados.')).toBeInTheDocument()
    expect(screen.queryByRole('table')).not.toBeInTheDocument()
    expect(boton('Todos')).toHaveTextContent('Todos (0)')
  })

  it('un filtro sin lotes dice "Nada en esta categoría."', async () => {
    renderVista({ lotes: [lote(1, OK), lote(2, OK)] })
    await userEvent.setup().click(boton('Vencidos'))
    expect(screen.getByText('Nada en esta categoría.')).toBeInTheDocument()
    expect(screen.queryByText('No hay vencimientos cargados.')).not.toBeInTheDocument()
    expect(screen.queryByRole('table')).not.toBeInTheDocument()
  })

  it('cargando no dibuja la tabla ni el vacio', () => {
    renderVista({ cargando: true })
    expect(screen.queryByRole('table')).not.toBeInTheDocument()
    expect(screen.queryByText('No hay vencimientos cargados.')).not.toBeInTheDocument()
  })

  it('no hay control de paginacion con una lista chica', () => {
    renderVista()
    expect(productosEnFilas()).toHaveLength(11)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Página anterior' })).not.toBeInTheDocument()
  })
})
