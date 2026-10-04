/**
 * Paginacion de `VistaVencimientos` (WP-51, #775).
 *
 * La query trae TODOS los lotes del horizonte y la vista los pagina en el
 * cliente, sobre la lista ya filtrada por estado, de a 20 (el patron de
 * `VistaProductos`, que tambien es una tabla).
 *
 * Lo que fijan estos tests, por rol y por texto:
 *  - con mas lotes que una pagina se ven solo los de la pagina 1;
 *  - pasar de pagina muestra los siguientes;
 *  - cambiar el filtro de estado, `diasAlerta` o `diasCritico` vuelve a la
 *    pagina 1. Los casos estan armados para que, despues del cambio, la lista
 *    siga teniendo mas de una pagina: si no, el recorte de la pagina al final de
 *    la lista (el `Math.min` de la vista) taparia un reset que falta;
 *  - el total del pie coincide con el filtro elegido, mientras que los conteos
 *    de los botones de filtro siguen siendo los de la lista completa;
 *  - si la lista se achica (se dio de baja el ultimo lote) y la pagina guardada
 *    pasa del final, se muestra la ultima que existe y no una tabla en blanco.
 *
 * `VistaVencimientos.caracterizacion.test.tsx` fija lo que NO cambia (lista
 * chica) y tiene que seguir verde.
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
  vi.setSystemTime(new Date(2026, 9, 3, 12, 0, 0))
})

afterEach(() => {
  vi.useRealTimers()
})

const POR_PAGINA = 20
const pad = (n: number) => String(n).padStart(2, '0')
const nombre = (n: number) => `Producto ${pad(n)}`

// Con diasCritico = 15, diasAlerta = 30 y hoy = 2026-10-03:
const VENCIDO = '2026-09-20' // hace 13 dias
const CRITICO = '2026-10-10' // en 7 dias
const OK = '2026-12-31' // en 89 dias

/**
 * 45 lotes: del 1 al 25 criticos, del 26 al 35 vencidos y del 36 al 45 ok.
 *  - Todos: 45 -> 3 paginas (20 + 20 + 5)
 *  - Urgentes: 25 -> 2 paginas (20 + 5)
 *  - Vencidos: 10 -> 1 pagina
 */
function lotes(cantidad = 45): LoteReporte[] {
  return Array.from({ length: cantidad }, (_, i) => {
    const n = i + 1
    return {
      lote_id: n,
      producto_id: 100 + n,
      producto_nombre: nombre(n),
      producto_codigo: null,
      fecha_vencimiento: n <= 25 ? CRITICO : n <= 35 ? VENCIDO : OK,
      cantidad: 10,
      cantidad_restante: 8,
      dias_restantes: 0,
      origen: 'manual',
      compra_id: null,
      stock_producto: 40,
      bolsa_producto: 0,
    }
  })
}

function propsBase(lista: LoteReporte[]): VistaVencimientosProps {
  return {
    lotes: lista,
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
    nombreSucursal: null,
  }
}

function renderVista(lista = lotes()) {
  const props = propsBase(lista)
  const vista = render(<VistaVencimientos {...props} />)
  return { ...vista, props }
}

/** Los productos de las filas de datos, en orden (sin el encabezado). */
const productos = () =>
  screen.queryAllByRole('row').slice(1).map(fila => within(fila).getByText(/^Producto \d+$/).textContent)
const rango = (desde: number, hasta: number) =>
  Array.from({ length: hasta - desde + 1 }, (_, i) => nombre(desde + i))
const siguiente = () => screen.getByRole('button', { name: 'Página siguiente' })
const anterior = () => screen.getByRole('button', { name: 'Página anterior' })
const filtro = (nombreBoton: string) => screen.getByRole('button', { name: new RegExp(`^${nombreBoton}`) })

describe('VistaVencimientos — paginacion', () => {
  it('con 45 lotes se ven solo los 20 de la pagina 1', () => {
    renderVista()
    expect(productos()).toEqual(rango(1, POR_PAGINA))
    expect(screen.queryByText(nombre(21))).not.toBeInTheDocument()
  })

  it('el pie dice el total de la lista (45), tiene 3 paginas y estamos en la primera', () => {
    renderVista()
    expect(screen.getByText('45 lotes')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: '3' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '4' })).not.toBeInTheDocument()
    expect(anterior()).toBeDisabled()
  })

  it('"Página siguiente" muestra del 21 al 40 y despues los 5 que quedan', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(siguiente())
    expect(productos()).toEqual(rango(21, 40))

    await user.click(siguiente())
    expect(productos()).toEqual(rango(41, 45))
    expect(siguiente()).toBeDisabled()
  })

  it('una lista de exactamente una pagina (20) no muestra el pie', () => {
    renderVista(lotes(20))
    expect(productos()).toHaveLength(20)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })

  it('los botones de filtro cuentan la lista completa, no la pagina', async () => {
    renderVista()
    await userEvent.setup().click(siguiente())
    expect(filtro('Todos')).toHaveTextContent('Todos (45)')
    expect(filtro('Urgentes')).toHaveTextContent('Urgentes (25)')
    expect(filtro('Vencidos')).toHaveTextContent('Vencidos (10)')
  })
})

describe('VistaVencimientos — el filtro de estado vuelve a la pagina 1', () => {
  it('"Urgentes" desde la pagina 2 muestra la 1 (25 urgentes: siguen siendo 2 paginas)', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(siguiente())
    expect(productos()[0]).toBe(nombre(21))

    await user.click(filtro('Urgentes'))
    expect(productos()).toEqual(rango(1, 20))
    expect(anterior()).toBeDisabled()
    // El total del pie es el del filtro: 25, no 45.
    expect(screen.getByText('25 lotes')).toBeInTheDocument()
  })

  it('"Todos" desde la pagina 2 de "Urgentes" vuelve a la 1 (45: 3 paginas)', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(filtro('Urgentes'))
    await user.click(siguiente())
    expect(productos()).toEqual(rango(21, 25))

    await user.click(filtro('Todos'))
    expect(productos()).toEqual(rango(1, 20))
    expect(anterior()).toBeDisabled()
    expect(screen.getByText('45 lotes')).toBeInTheDocument()
  })

  it('"Vencidos" desde la pagina 3 muestra los 10 en una sola pagina, sin pie', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: '3' }))

    await user.click(filtro('Vencidos'))
    expect(productos()).toEqual(rango(26, 35))
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })

  it('despues de filtrar se puede seguir paginando sobre el resultado', async () => {
    renderVista()
    const user = userEvent.setup()
    await user.click(filtro('Urgentes'))
    await user.click(siguiente())
    expect(productos()).toEqual(rango(21, 25))
    expect(siguiente()).toBeDisabled()
  })
})

describe('VistaVencimientos — los umbrales vuelven a la pagina 1', () => {
  it('cambiar diasCritico desde la pagina 2 vuelve a la 1', async () => {
    const { rerender, props } = renderVista()
    await userEvent.setup().click(siguiente())
    expect(productos()[0]).toBe(nombre(21))

    // Con 5 dias de umbral rojo los criticos (a 7 dias) pasan a "por vencer":
    // el total de lotes no cambia, asi que el recorte al final no lo disimula.
    rerender(<VistaVencimientos {...props} diasCritico={5} />)
    expect(productos()).toEqual(rango(1, 20))
    expect(anterior()).toBeDisabled()
    expect(filtro('Urgentes')).toHaveTextContent('Urgentes (0)')
  })

  it('cambiar diasAlerta desde la pagina 2 vuelve a la 1', async () => {
    const { rerender, props } = renderVista()
    await userEvent.setup().click(siguiente())
    expect(productos()[0]).toBe(nombre(21))

    rerender(<VistaVencimientos {...props} diasAlerta={60} />)
    expect(productos()).toEqual(rango(1, 20))
    expect(anterior()).toBeDisabled()
  })

  it('re-renderizar con los mismos umbrales NO vuelve a la pagina 1', async () => {
    const { rerender, props } = renderVista()
    await userEvent.setup().click(siguiente())

    rerender(<VistaVencimientos {...props} refrescando />)
    expect(productos()[0]).toBe(nombre(21))
  })

  it('refrescar la lista (otro array, mismos lotes) deja la pagina donde estaba', async () => {
    const { rerender, props } = renderVista()
    await userEvent.setup().click(siguiente())

    rerender(<VistaVencimientos {...props} lotes={lotes()} />)
    expect(productos()[0]).toBe(nombre(21))
  })
})

describe('VistaVencimientos — la pagina guardada pasa del final de la lista', () => {
  it('si se da de baja el ultimo lote de la ultima pagina, muestra la ultima que existe', async () => {
    const { rerender, props } = renderVista(lotes(41))
    await userEvent.setup().click(screen.getByRole('button', { name: '3' }))
    expect(productos()).toEqual(rango(41, 41))

    // El lote 41 se dio de baja: quedan 40 -> 2 paginas.
    rerender(<VistaVencimientos {...props} lotes={lotes(40)} />)
    expect(productos()).toEqual(rango(21, 40))
    expect(siguiente()).toBeDisabled()
    expect(anterior()).toBeEnabled()
  })

  it('si queda una sola pagina, muestra esa y no una tabla en blanco', async () => {
    const { rerender, props } = renderVista()
    await userEvent.setup().click(siguiente())

    rerender(<VistaVencimientos {...props} lotes={lotes(12)} />)
    expect(productos()).toEqual(rango(1, 12))
  })
})
