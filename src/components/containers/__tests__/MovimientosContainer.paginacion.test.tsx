/**
 * `MovimientosContainer` lleva la pagina (WP-51, #775).
 *
 * El hook ya pagina en el servidor, pero el container nunca le pasaba `pagina`:
 * la pantalla traia siempre las primeras 50 y no habia como ver el resto. Ahora
 * el container guarda la pagina, se la pide al hook y arma el control con el
 * total que devuelve el hook.
 *
 * Se monta el container REAL con la vista real y el hook simulado: un "servidor"
 * que contesta `total` y las filas del rango pedido. Lo que se fija:
 *  - pasar de pagina le pide al hook `pagina + 1` con el mismo estado;
 *  - el numero de paginas es `ceil(total / MOVIMIENTOS_PAGE_SIZE)`;
 *  - cambiar de pestaña (el filtro de esta pantalla) y de sucursal vuelve a la
 *    pagina 1;
 *  - si la pagina guardada pasa del final porque se resolvio el ultimo
 *    movimiento (el total baja), el container retrocede a la ultima que existe
 *    — pero no con los datos viejos que se muestran mientras llega la pagina.
 */
import '@testing-library/jest-dom/vitest'
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const PAGE_SIZE = 50

interface Servidor {
  /** Total de movimientos por pestaña. */
  totales: Record<string, number>
  /** El hook devuelve los datos de la pagina anterior mientras llega la nueva. */
  placeholder: boolean
}

let servidor: Servidor
let sucursalId = 1
const mockUseMovimientosQuery = vi.fn()

function fila(id: number) {
  return {
    id,
    sucursal_origen_id: 2,
    sucursal_destino_id: 1,
    estado: 'aceptada',
    total_costo: 100,
    total_unidades: 1,
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

vi.mock('../../../hooks/queries', () => {
  const mutacion = () => ({ mutateAsync: vi.fn(), isPending: false })
  return {
    MOVIMIENTOS_PAGE_SIZE: 50,
    useMovimientosQuery: (filtros: { estado?: string; pagina?: number }) => mockUseMovimientosQuery(filtros),
    useMovimientoItemsQuery: () => ({ data: [], isLoading: false }),
    useSucursalesQuery: () => ({ data: [] }),
    useProductosQuery: () => ({ data: [] }),
    useCrearMovimientoMutation: mutacion,
    useAceptarMovimientoMutation: mutacion,
    useDenegarMovimientoMutation: mutacion,
    useCancelarMovimientoMutation: mutacion,
    useEditarMovimientoMutation: mutacion,
  }
})

vi.mock('../../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ isAdminOrEncargado: true }),
}))

vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: sucursalId, currentSucursalRol: 'admin' }),
}))

vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn(), warning: vi.fn() }),
}))

import MovimientosContainer from '../MovimientosContainer'

beforeEach(() => {
  sucursalId = 1
  servidor = { totales: { pendiente: 120, aceptada: 120, todos: 120 }, placeholder: false }
  mockUseMovimientosQuery.mockReset()
  mockUseMovimientosQuery.mockImplementation((filtros: { estado?: string; pagina?: number }) => {
    const total = servidor.totales[filtros.estado ?? 'todos'] ?? 0
    const pagina = filtros.pagina ?? 1
    const desde = (pagina - 1) * PAGE_SIZE
    const cuantas = Math.max(0, Math.min(PAGE_SIZE, total - desde))
    return {
      data: Array.from({ length: cuantas }, (_, i) => fila(desde + i + 1)),
      total,
      isLoading: false,
      isSuccess: true,
      isPlaceholderData: servidor.placeholder,
    }
  })
})

// La vista es lazy (`VistaMovimientos`): la primera vez que se monta en la
// corrida, el import en frío se come casi todo el segundo por defecto de
// `findBy*`, y con la máquina cargada el primer caso del archivo se pasaba (#821).
const ESPERA_VISTA = { timeout: 5000 }

async function montar() {
  const vista = render(<MovimientosContainer />)
  await screen.findByRole('heading', { name: 'Movimientos entre sucursales' }, ESPERA_VISTA)
  return vista
}

const filas = () => screen.queryAllByRole('button', { name: 'Ver detalle' })
const siguiente = () => screen.getByRole('button', { name: 'Página siguiente' })
const anterior = () => screen.getByRole('button', { name: 'Página anterior' })
const ultimaLlamada = () => {
  const llamadas = mockUseMovimientosQuery.mock.calls
  return llamadas[llamadas.length - 1]?.[0]
}

describe('MovimientosContainer — la pagina llega al hook', () => {
  it('arranca en la pestaña Pendientes, pagina 1, y muestra las primeras 50', async () => {
    await montar()
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 1 })
    expect(filas()).toHaveLength(50)
    expect(screen.getByText('120 movimientos')).toBeInTheDocument()
    expect(anterior()).toBeDisabled()
  })

  it('"Página siguiente" le pide al hook la pagina 2 con el mismo estado', async () => {
    await montar()
    const user = userEvent.setup()
    await user.click(siguiente())
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 2 })
    expect(filas()).toHaveLength(50)

    await user.click(siguiente())
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 3 })
    // La ultima pagina trae las 20 que quedan.
    expect(filas()).toHaveLength(20)
    expect(siguiente()).toBeDisabled()
  })

  it('ir a una pagina por su numero y volver con "Página anterior"', async () => {
    await montar()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: '3' }))
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 3 })
    await user.click(anterior())
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 2 })
  })
})

describe('MovimientosContainer — cuantas paginas hay', () => {
  it('100 movimientos son 2 paginas (ceil(100 / 50))', async () => {
    servidor.totales.pendiente = 100
    await montar()
    expect(screen.getByRole('button', { name: '2' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '3' })).not.toBeInTheDocument()
    expect(screen.getByText('100 movimientos')).toBeInTheDocument()
  })

  it('101 movimientos son 3 paginas', async () => {
    servidor.totales.pendiente = 101
    await montar()
    expect(screen.getByRole('button', { name: '3' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: '4' })).not.toBeInTheDocument()
  })

  it('50 movimientos o menos no muestran el control', async () => {
    servidor.totales.pendiente = 50
    await montar()
    expect(filas()).toHaveLength(50)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
  })

  it('el total es el del conteo del hook, no las filas que llegaron', async () => {
    servidor.totales.pendiente = 73
    await montar()
    expect(filas()).toHaveLength(50)
    expect(screen.getByText('73 movimientos')).toBeInTheDocument()
  })
})

describe('MovimientosContainer — volver a la pagina 1', () => {
  it('cambiar de pestaña desde la pagina 3 vuelve a la 1 de la pestaña nueva', async () => {
    await montar()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: '3' }))
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 3 })

    await user.click(screen.getByRole('button', { name: 'Aceptadas' }))
    expect(ultimaLlamada()).toEqual({ estado: 'aceptada', pagina: 1 })
    expect(anterior()).toBeDisabled()
    // Nunca se pidio la pestaña nueva en una pagina vieja.
    expect(mockUseMovimientosQuery.mock.calls.some(([f]) => f.estado === 'aceptada' && f.pagina !== 1)).toBe(false)
  })

  it('"Todas" tambien vuelve a la pagina 1', async () => {
    await montar()
    const user = userEvent.setup()
    await user.click(siguiente())
    await user.click(screen.getByRole('button', { name: 'Todas' }))
    expect(ultimaLlamada()).toEqual({ estado: 'todos', pagina: 1 })
  })

  it('cambiar de sucursal vuelve a Pendientes, pagina 1', async () => {
    const { rerender } = await montar()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Aceptadas' }))
    await user.click(siguiente())
    expect(ultimaLlamada()).toEqual({ estado: 'aceptada', pagina: 2 })

    sucursalId = 2
    rerender(<MovimientosContainer />)
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 1 })
  })
})

describe('MovimientosContainer — la pagina guardada pasa del final', () => {
  it('si el total baja y la pagina ya no existe, retrocede a la ultima que existe', async () => {
    const { rerender } = await montar()
    await userEvent.setup().click(screen.getByRole('button', { name: '3' }))
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 3 })

    // Se resolvieron los 20 de la pagina 3: quedan 100 -> 2 paginas.
    servidor.totales.pendiente = 100
    rerender(<MovimientosContainer />)
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 2 })
    expect(filas()).toHaveLength(50)
  })

  it('si no queda ninguno, vuelve a la pagina 1', async () => {
    const { rerender } = await montar()
    await userEvent.setup().click(screen.getByRole('button', { name: '2' }))

    servidor.totales.pendiente = 0
    rerender(<MovimientosContainer />)
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 1 })
    expect(screen.getByText('No hay movimientos para mostrar')).toBeInTheDocument()
  })

  it('con datos de la pagina anterior (placeholder) NO retrocede: ese total no es el de esta lista', async () => {
    const { rerender } = await montar()
    await userEvent.setup().click(screen.getByRole('button', { name: '3' }))

    servidor.totales.pendiente = 10
    servidor.placeholder = true
    rerender(<MovimientosContainer />)
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 3 })

    // Cuando llegan los datos de verdad, si.
    servidor.placeholder = false
    rerender(<MovimientosContainer />)
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 1 })
  })

  it('mientras carga la lista (sin exito todavia) no retrocede', async () => {
    const { rerender } = await montar()
    await userEvent.setup().click(screen.getByRole('button', { name: '3' }))

    mockUseMovimientosQuery.mockImplementation(() => ({
      data: undefined, total: 0, isLoading: true, isSuccess: false, isPlaceholderData: false,
    }))
    rerender(<MovimientosContainer />)
    expect(ultimaLlamada()).toEqual({ estado: 'pendiente', pagina: 3 })
  })
})
