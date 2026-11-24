/**
 * frv-B3 (tanda 6 de #1603): en el Resumen de la ficha, «Pagado» es la plata cobrada y la nota de
 * crédito aplicada y el saldo a favor aplicado se muestran aparte, con su propio rótulo.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'

const m = vi.hoisted(() => ({ estadisticas: {} as Record<string, unknown> }))

vi.mock('../../hooks/supabase', () => ({
  useFichaCliente: () => ({ pedidosCliente: [], estadisticas: m.estadisticas, loading: false, error: false, refetch: vi.fn() }),
  usePagos: () => ({
    pagos: [], loading: false,
    fetchPagosCliente: vi.fn().mockResolvedValue([]),
    obtenerResumenCuenta: vi.fn().mockResolvedValue(null),
    eliminarPago: vi.fn(),
  }),
}))
vi.mock('../../lib/supabase', () => ({
  supabase: { rpc: vi.fn(), from: vi.fn(), auth: { getSession: vi.fn(), onAuthStateChange: vi.fn() } },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))
vi.mock('../../contexts/AuthDataContext', () => ({ useAuthData: () => ({ perfil: { id: 'u1', rol: 'admin' } }) }))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: vi.fn(), success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))
vi.mock('@tanstack/react-query', async (importOriginal) => ({
  ...(await importOriginal<typeof import('@tanstack/react-query')>()),
  useQueryClient: () => ({ invalidateQueries: vi.fn() }),
}))

import ModalFichaCliente from './ModalFichaCliente'
import type { ClienteDB } from '../../types'

const CLIENTE = { id: '303', nombre_fantasia: 'Kiosco Sur', limite_credito: 50000 } as unknown as ClienteDB

const BASE = {
  totalPedidos: 2, totalCompras: 12000, pedidosPagados: 1, pedidosPendientes: 0, montoPendiente: 0,
  ticketPromedio: 6000, frecuenciaCompra: 1, diasDesdeUltimoPedido: 3, productosFavoritos: [],
}

describe('ModalFichaCliente — «Pagado» (frv-B3)', () => {
  it('la nota de crédito aplicada va aparte, con su rótulo, y no como saldo a favor', async () => {
    m.estadisticas = { ...BASE, montoPagado: 10000, notaCreditoAplicada: 5000, saldoAFavorAplicado: 0 }
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
    expect(await screen.findByTestId('ficha-nc-aplicada')).toHaveTextContent('Nota de crédito aplicada: $')
    expect(screen.queryByTestId('ficha-saldo-aplicado')).toBeNull()
    expect(screen.queryByText(/Saldo a favor aplicado/)).toBeNull()
  })

  it('el saldo a favor aplicado va aparte con el suyo', async () => {
    m.estadisticas = { ...BASE, montoPagado: 10000, notaCreditoAplicada: 0, saldoAFavorAplicado: 200 }
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
    expect(await screen.findByTestId('ficha-saldo-aplicado')).toHaveTextContent('Saldo a favor aplicado: $')
    expect(screen.queryByTestId('ficha-nc-aplicada')).toBeNull()
  })

  it('sin ninguno de los dos no muestra líneas', async () => {
    m.estadisticas = { ...BASE, montoPagado: 10000 }
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
    await screen.findByText('Pagado')
    expect(screen.queryByTestId('ficha-nc-aplicada')).toBeNull()
    expect(screen.queryByTestId('ficha-saldo-aplicado')).toBeNull()
  })
})
