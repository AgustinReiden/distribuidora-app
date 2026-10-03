/**
 * Caracterizacion de `VistaMovimientos` (WP-51, #775), ANTES de darle paginacion.
 *
 * Fija, por rol ARIA y por texto (nunca por clase), lo que el usuario ve hoy:
 * una tarjeta por movimiento, entrante o saliente segun la sucursal activa, sus
 * acciones segun el rol y el estado, las pestañas, la lista vacia y la carga.
 *
 * La vista dibuja TODO lo que le llega: la paginacion es del servidor y vive en
 * el container, asi que este archivo no la toca. Lo nuevo (el control de pagina)
 * lo cubre `VistaMovimientos.paginacion.test.tsx`. Este archivo tiene que seguir
 * verde, sin tocarse, despues de agregarla.
 *
 * El reloj se fija (solo `Date`): "Sin resolver hace N h" depende de ahora.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import VistaMovimientos, { type VistaMovimientosProps } from '../VistaMovimientos'
import type { EstadoMovimiento, MovimientoSucursalDB } from '../../../hooks/queries'

const AHORA = new Date('2026-10-03T15:00:00Z')
const SUCURSAL_ACTIVA = 1

beforeEach(() => {
  vi.useFakeTimers({ toFake: ['Date'] })
  vi.setSystemTime(AHORA)
})

afterEach(() => {
  vi.useRealTimers()
})

interface MovOpts {
  /** true = llega a la sucursal activa; false = sale de ella. */
  entrante?: boolean
  estado?: EstadoMovimiento
  horasAtras?: number
  stockDescontado?: boolean
  contraparte?: string
}

function mov(id: number, opts: MovOpts = {}): MovimientoSucursalDB {
  const { entrante = true, estado = 'pendiente', horasAtras = 2, stockDescontado = false, contraparte = 'Sucursal Sur' } = opts
  const otra = 2
  return {
    id,
    sucursal_origen_id: entrante ? otra : SUCURSAL_ACTIVA,
    sucursal_destino_id: entrante ? SUCURSAL_ACTIVA : otra,
    estado,
    total_costo: 1000 * id,
    total_unidades: 10,
    stock_descontado: stockDescontado,
    notas: null,
    motivo_rechazo: null,
    creado_por: 'u1',
    resuelto_por: null,
    editado_por: null,
    created_at: new Date(AHORA.getTime() - horasAtras * 3_600_000).toISOString(),
    resuelto_at: null,
    editado_at: null,
    origen: { id: entrante ? otra : SUCURSAL_ACTIVA, nombre: entrante ? contraparte : 'Casa Central' },
    destino: { id: entrante ? SUCURSAL_ACTIVA : otra, nombre: entrante ? 'Casa Central' : contraparte },
    creador: { id: 'u1', nombre: 'Ana' },
  }
}

function renderVista(overrides: Partial<VistaMovimientosProps> = {}) {
  const props: VistaMovimientosProps = {
    movimientos: [],
    loading: false,
    currentSucursalId: SUCURSAL_ACTIVA,
    canResolver: true,
    canEditar: true,
    estado: 'pendiente',
    onEstadoChange: vi.fn(),
    onNuevaSalida: vi.fn(),
    onAceptar: vi.fn(),
    onDenegar: vi.fn(),
    onVerDetalle: vi.fn(),
    onEditar: vi.fn(),
    onCancelar: vi.fn(),
    ...overrides,
  }
  render(<VistaMovimientos {...props} />)
  return props
}

/** Una tarjeta por movimiento: tiene su unico boton "Ver detalle". */
const tarjetas = () => screen.getAllByRole('button', { name: 'Ver detalle' })

describe('VistaMovimientos — lista', () => {
  it('con 5 movimientos dibuja 5 tarjetas con su numero', () => {
    renderVista({ movimientos: [mov(5), mov(4), mov(3), mov(2), mov(1)] })
    expect(tarjetas()).toHaveLength(5)
    for (const id of [5, 4, 3, 2, 1]) expect(screen.getByText(`#${id}`)).toBeInTheDocument()
  })

  it('dice si es entrante de o saliente a, con el nombre de la otra sucursal', () => {
    renderVista({
      movimientos: [mov(2, { entrante: true, contraparte: 'Sucursal Sur' }), mov(1, { entrante: false, contraparte: 'Taco Pozo' })],
    })
    expect(screen.getByText('Entrante de Sucursal Sur')).toBeInTheDocument()
    expect(screen.getByText('Saliente a Taco Pozo')).toBeInTheDocument()
  })

  it('muestra el estado y el costo total de cada movimiento', () => {
    renderVista({ movimientos: [mov(1, { estado: 'aceptada' }), mov(2, { estado: 'denegada' })] })
    expect(screen.getByText('aceptada')).toBeInTheDocument()
    expect(screen.getByText('denegada')).toBeInTheDocument()
    expect(screen.getAllByText('costo total')).toHaveLength(2)
  })

  it('"Ver detalle" llama a onVerDetalle con ese movimiento', async () => {
    const m = [mov(2), mov(1)]
    const props = renderVista({ movimientos: m })
    await userEvent.setup().click(tarjetas()[1])
    expect(props.onVerDetalle).toHaveBeenCalledWith(m[1])
  })

  it('un envio pendiente de mas de 24 h se marca como demorado', () => {
    renderVista({ movimientos: [mov(2, { horasAtras: 30 }), mov(1, { horasAtras: 2 })] })
    expect(screen.getAllByText(/^Sin resolver hace/)).toHaveLength(1)
    expect(screen.getByText('Sin resolver hace 30 h')).toBeInTheDocument()
  })

  it('un saliente con el stock ya descontado avisa que esta en transito', () => {
    renderVista({ movimientos: [mov(1, { entrante: false, stockDescontado: true })] })
    expect(screen.getByText('Stock ya descontado · 10 u. en tránsito')).toBeInTheDocument()
  })
})

describe('VistaMovimientos — acciones segun rol y estado', () => {
  it('un entrante pendiente se puede aceptar o denegar si el rol resuelve', async () => {
    const m = mov(1)
    const props = renderVista({ movimientos: [m] })
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Aceptar' }))
    expect(props.onAceptar).toHaveBeenCalledWith(m)
    await user.click(screen.getByRole('button', { name: 'Denegar' }))
    expect(props.onDenegar).toHaveBeenCalledWith(m)
  })

  it('sin permiso para resolver no hay Aceptar ni Denegar', () => {
    renderVista({ movimientos: [mov(1)], canResolver: false })
    expect(screen.queryByRole('button', { name: 'Aceptar' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Denegar' })).not.toBeInTheDocument()
  })

  it('un entrante ya resuelto no ofrece Aceptar ni Denegar', () => {
    renderVista({ movimientos: [mov(1, { estado: 'aceptada' })] })
    expect(screen.queryByRole('button', { name: 'Aceptar' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Denegar' })).not.toBeInTheDocument()
  })

  it('un saliente pendiente espera la aprobacion y el admin puede editarlo o cancelarlo', async () => {
    const m = mov(1, { entrante: false, contraparte: 'Taco Pozo' })
    const props = renderVista({ movimientos: [m] })
    expect(screen.getByText('Esperando aprobación de Taco Pozo.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Aceptar' })).not.toBeInTheDocument()
    const user = userEvent.setup()
    await user.click(screen.getByRole('button', { name: 'Editar' }))
    expect(props.onEditar).toHaveBeenCalledWith(m)
    await user.click(screen.getByRole('button', { name: 'Cancelar' }))
    expect(props.onCancelar).toHaveBeenCalledWith(m)
  })

  it('sin ser admin de la sucursal no hay Editar ni Cancelar', () => {
    renderVista({ movimientos: [mov(1, { entrante: false })], canEditar: false })
    expect(screen.queryByRole('button', { name: 'Editar' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Cancelar' })).not.toBeInTheDocument()
  })
})

describe('VistaMovimientos — pestañas y encabezado', () => {
  it('ofrece las cinco pestañas y avisa cual se elige', async () => {
    const props = renderVista()
    const user = userEvent.setup()
    for (const nombre of ['Pendientes', 'Aceptadas', 'Denegadas', 'Canceladas', 'Todas']) {
      expect(screen.getByRole('button', { name: nombre })).toBeInTheDocument()
    }
    await user.click(screen.getByRole('button', { name: 'Aceptadas' }))
    expect(props.onEstadoChange).toHaveBeenLastCalledWith('aceptada')
    await user.click(screen.getByRole('button', { name: 'Todas' }))
    expect(props.onEstadoChange).toHaveBeenLastCalledWith('todos')
  })

  it('"Nueva salida" llama a onNuevaSalida', async () => {
    const props = renderVista()
    await userEvent.setup().click(screen.getByRole('button', { name: /Nueva salida/ }))
    expect(props.onNuevaSalida).toHaveBeenCalledTimes(1)
  })

  it('se titula "Movimientos entre sucursales"', () => {
    renderVista()
    expect(screen.getByRole('heading', { name: 'Movimientos entre sucursales' })).toBeInTheDocument()
  })
})

describe('VistaMovimientos — lista vacia y carga', () => {
  it('sin movimientos dice "No hay movimientos para mostrar"', () => {
    renderVista({ movimientos: [] })
    expect(screen.getByText('No hay movimientos para mostrar')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Ver detalle' })).not.toBeInTheDocument()
  })

  it('cargando dice "Cargando..." y no dibuja las tarjetas ni el vacio', () => {
    renderVista({ movimientos: [mov(1)], loading: true })
    expect(screen.getByText('Cargando...')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Ver detalle' })).not.toBeInTheDocument()
    expect(screen.queryByText('No hay movimientos para mostrar')).not.toBeInTheDocument()
  })

  it('las pestañas siguen a la vista mientras carga', () => {
    renderVista({ loading: true })
    expect(within(document.body).getByRole('button', { name: 'Pendientes' })).toBeInTheDocument()
  })

  it('no hay control de paginacion con una lista chica', () => {
    renderVista({ movimientos: [mov(3), mov(2), mov(1)] })
    expect(tarjetas()).toHaveLength(3)
    expect(screen.queryByRole('button', { name: 'Página siguiente' })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Página anterior' })).not.toBeInTheDocument()
  })
})
