/**
 * FRT-3 y FRT-7 (#1517): la ficha del cliente no inventa ceros ni calla un recorte.
 *
 * - Si la carga de la ficha falla, el modal mostraba "0 compras · $0 comprado" y
 *   "Este cliente no tiene pedidos" (estadísticas null + lista vacía). Ahora muestra
 *   el error con "Reintentar".
 * - Mientras el resumen de cuenta carga, el saldo decía "$0 · Sin deuda". Ahora "—".
 * - La pestaña Pedidos trae los últimos 50: si hay más, lo avisa.
 *
 * Los mocks viejos del hook (sin `error` ni `pedidosTotales`) siguen funcionando: lo
 * cubren `ModalFichaCliente.credito.test` y `.valeBlanco.test`.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const m = vi.hoisted(() => ({
  ficha: {} as Record<string, unknown>,
  refetch: vi.fn(),
  obtenerResumenCuenta: vi.fn(),
}))

vi.mock('../../hooks/supabase', () => ({
  useFichaCliente: () => m.ficha,
  usePagos: () => ({
    pagos: [], loading: false,
    fetchPagosCliente: vi.fn().mockResolvedValue([]),
    obtenerResumenCuenta: m.obtenerResumenCuenta,
    eliminarPago: vi.fn(),
  }),
}))
// Los sub-paneles de la ficha importan el cliente de Supabase; acá no se usa.
vi.mock('../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn(), auth: { getSession: vi.fn(), onAuthStateChange: vi.fn() } },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ perfil: { id: 'u1', rol: 'admin' } }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))
vi.mock('@tanstack/react-query', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@tanstack/react-query')>()),
  useQueryClient: () => ({ invalidateQueries: vi.fn() }),
}))

import ModalFichaCliente from './ModalFichaCliente'
import type { ClienteDB } from '../../types'

const CLIENTE = {
  id: '303', nombre_fantasia: 'MARCOS CHOFER', limite_credito: 50000,
} as unknown as ClienteDB

const RESUMEN = {
  saldo_actual: 1200, limite_credito: 50000, credito_disponible: 48800, total_pedidos: 3,
  total_compras: 5000, total_pagos: 3800, pedidos_pendientes_pago: 1, ultimo_pedido: null, ultimo_pago: null,
}

const ESTADISTICAS = {
  totalPedidos: 3, totalCompras: 5000, pedidosPagados: 2, montoPagado: 3800,
  pedidosPendientes: 0, montoPendiente: 0, ticketPromedio: 1667, frecuenciaCompra: 1,
  diasDesdeUltimoPedido: 4, productosFavoritos: [],
}

const pedido = (n: number) => ({
  id: String(n), cliente_id: '303', created_at: '2026-10-01T15:00:00Z', estado: 'entregado',
  estado_pago: 'pagado', total: 1000, tipo_factura: 'ZZ', items: [],
})

beforeEach(() => {
  vi.clearAllMocks()
  m.obtenerResumenCuenta.mockResolvedValue(RESUMEN)
  m.ficha = { pedidosCliente: [], estadisticas: null, loading: false, error: false, pedidosTotales: 0, refetch: m.refetch }
})

describe('ModalFichaCliente — la carga de la ficha falla (FRT-3)', () => {
  it('muestra el error con "Reintentar" y no "0 compras · $0 comprado"', async () => {
    m.ficha = { ...m.ficha, error: true }
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    expect(screen.getByRole('alert')).toHaveTextContent('No se pudo cargar')
    expect(screen.getByRole('button', { name: 'Reintentar' })).toBeInTheDocument()
    expect(screen.queryByText('Compras entregadas')).toBeNull()
    expect(screen.queryByText('Total comprado')).toBeNull()
    expect(screen.queryByText('Pagado')).toBeNull()
  })

  it('"Reintentar" vuelve a pedir la ficha', async () => {
    m.ficha = { ...m.ficha, error: true }
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: 'Reintentar' }))

    expect(m.refetch).toHaveBeenCalledTimes(1)
  })

  it('la pestaña Pedidos tampoco dice "Este cliente no tiene pedidos" si la carga falló', async () => {
    m.ficha = { ...m.ficha, error: true }
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: /Pedidos/ }))

    expect(screen.getByRole('alert')).toBeInTheDocument()
    expect(screen.queryByText('Este cliente no tiene pedidos')).toBeNull()
  })

  it('Pagos no depende de la ficha: sigue andando aunque la ficha haya fallado', async () => {
    m.ficha = { ...m.ficha, error: true }
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: /Pagos/ }))

    expect(screen.getByText('Historial de Pagos')).toBeInTheDocument()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('si ya había estadísticas y el refetch falla, siguen las estadísticas (sin error)', async () => {
    m.ficha = { ...m.ficha, estadisticas: ESTADISTICAS, error: true }
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    expect(screen.getByText('Compras entregadas')).toBeInTheDocument()
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('mientras la ficha carga no hay estadísticas en cero ni error', async () => {
    m.ficha = { ...m.ficha, loading: true }
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    expect(screen.queryByText('Compras entregadas')).toBeNull()
    expect(screen.queryByText('Total comprado')).toBeNull()
    expect(screen.queryByRole('alert')).toBeNull()
  })
})

describe('ModalFichaCliente — el resumen de cuenta todavía carga (FRT-3)', () => {
  it('el saldo es "—" y no "$0 · Sin deuda" hasta que llega el resumen', async () => {
    let resolver: (r: typeof RESUMEN) => void = () => {}
    m.obtenerResumenCuenta.mockReturnValue(new Promise<typeof RESUMEN>(res => { resolver = res }))
    m.ficha = { ...m.ficha, estadisticas: ESTADISTICAS }
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    expect(screen.getByRole('status', { name: 'Cargando saldo' })).toHaveTextContent('—')
    expect(screen.queryByText('Sin deuda')).toBeNull()
    expect(screen.queryByText('Debe')).toBeNull()
    expect(screen.queryByText(/Disponible:/)).toBeNull()
    expect(screen.queryByText(/del crédito utilizado/)).toBeNull()

    resolver(RESUMEN)
    expect(await screen.findByText('Debe')).toBeInTheDocument()
    expect(screen.queryByRole('status', { name: 'Cargando saldo' })).toBeNull()
    expect(screen.getByText(/Disponible:/)).toBeInTheDocument()
  })

  it('con la ficha cargando y el resumen sin llegar, tampoco hay "Sin deuda"', async () => {
    m.obtenerResumenCuenta.mockReturnValue(new Promise(() => {}))
    m.ficha = { ...m.ficha, loading: true }
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    expect(screen.queryByText('Sin deuda')).toBeNull()
    expect(screen.getByRole('status', { name: 'Cargando saldo' })).toBeInTheDocument()
  })

  it('un cliente realmente sin deuda sigue diciendo "Sin deuda" cuando el resumen llega', async () => {
    m.obtenerResumenCuenta.mockResolvedValue({ ...RESUMEN, saldo_actual: 0, credito_disponible: 50000 })
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    expect(await screen.findByText('Sin deuda')).toBeInTheDocument()
  })
})

describe('ModalFichaCliente — la lista de pedidos viene cortada (FRT-7)', () => {
  it('con 83 pedidos y 50 a la vista avisa "Se muestran los últimos 50 de 83 pedidos."', async () => {
    m.ficha = {
      ...m.ficha,
      estadisticas: ESTADISTICAS,
      pedidosCliente: Array.from({ length: 50 }, (_, i) => pedido(83 - i)),
      pedidosTotales: 83,
    }
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: /Pedidos/ }))

    const aviso = screen.getByText('Se muestran los últimos 50 de 83 pedidos.')
    expect(aviso).toHaveAttribute('role', 'status')
  })

  it('si se ven todos, no hay aviso', async () => {
    m.ficha = {
      ...m.ficha,
      estadisticas: ESTADISTICAS,
      pedidosCliente: [pedido(2), pedido(1)],
      pedidosTotales: 2,
    }
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: /Pedidos/ }))

    expect(screen.getByText('#2')).toBeInTheDocument()
    expect(screen.queryByText(/Se muestran los últimos/)).toBeNull()
  })

  it('un hook sin `pedidosTotales` (mock viejo) no inventa el aviso', async () => {
    m.ficha = { pedidosCliente: [pedido(1)], estadisticas: ESTADISTICAS, loading: false, refetch: m.refetch }
    const user = userEvent.setup()
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)

    await user.click(screen.getByRole('button', { name: /Pedidos/ }))

    expect(screen.queryByText(/Se muestran los últimos/)).toBeNull()
  })
})
