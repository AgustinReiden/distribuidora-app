/**
 * H-4 de la lente de H (tanda 6 bis de #1603): la ficha de un preventista pide la carga con su id,
 * para que el «Total comprado» cuente sólo lo que él le vendió al cliente (como su Dashboard). Admin y
 * encargado, sin vendedor.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render } from '@testing-library/react'

const m = vi.hoisted(() => ({
  perfil: { id: 'u1', rol: 'admin' } as Record<string, unknown>,
  useFichaCliente: vi.fn(),
}))

vi.mock('../../hooks/supabase', () => ({
  useFichaCliente: (...args: unknown[]) => m.useFichaCliente(...args),
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
vi.mock('../../contexts/AuthDataContext', () => ({
  useAuthData: () => ({ perfil: m.perfil }),
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

const CLIENTE = { id: '303', nombre_fantasia: 'CLIENTE DE PRUEBA', limite_credito: 0 } as unknown as ClienteDB

beforeEach(() => {
  vi.clearAllMocks()
  m.useFichaCliente.mockReturnValue({ pedidosCliente: [], estadisticas: null, loading: true, error: false, pedidosTotales: 0, refetch: vi.fn() })
})

describe('ModalFichaCliente — el vendedor de la ficha (H-4)', () => {
  it('un preventista carga la ficha con su id', () => {
    m.perfil = { id: 'pre-1', rol: 'preventista' }
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
    expect(m.useFichaCliente).toHaveBeenCalledWith('303', 'pre-1')
  })

  it.each(['admin', 'encargado'])('%s la carga sin vendedor', (rol) => {
    m.perfil = { id: 'u1', rol }
    render(<ModalFichaCliente cliente={CLIENTE} onClose={vi.fn()} />)
    expect(m.useFichaCliente).toHaveBeenCalledWith('303', null)
  })
})
