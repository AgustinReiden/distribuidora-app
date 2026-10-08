/**
 * Depósito ve las hojas de ruta de su sucursal por la RPC sin plata (#782).
 *
 * Lo que se protege: que el container lea por `hojas_de_ruta_deposito` y nunca
 * por `.from('pedidos')` (que trae `total` con la fila), que arranque pidiendo
 * la próxima ruta (p_fecha null) y que al moverse pida la fecha nueva.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'

const { rpc, from, notifyError } = vi.hoisted(() => ({
  rpc: vi.fn(),
  from: vi.fn(),
  notifyError: vi.fn(),
}))

vi.mock('../../../hooks/supabase/base', () => ({ supabase: { rpc, from } }))
vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ({ currentSucursalId: 1, currentSucursalNombre: 'Tucumán' }),
}))
vi.mock('../../../contexts/NotificationContext', () => ({
  useNotification: () => ({ error: notifyError, success: vi.fn(), warning: vi.fn(), info: vi.fn() }),
}))

import PedidosDepositoContainer from '../PedidosDepositoContainer'

const respuesta = (fecha: string) => ({
  fecha,
  rutas: [{
    recorrido_id: 77, estado: 'en_curso', transportista: { id: 'u-1', nombre: 'Rober' },
    paradas: [{
      id: 7143, estado: 'asignado', canal: 'app', fecha: '2026-10-07', fecha_entrega_programada: null, created_at: null, notas: null, orden_entrega: 1,
      cliente: { id: 9, nombre_fantasia: 'Kiosco Lola', direccion: 'San Martín 100' },
      items: [{ id: 1, producto_id: 161, cantidad: 2, es_bonificacion: false, producto: { id: 161, nombre: 'PLACER ANANA 500 cc', categoria: 'PLACER' }, promocion: null }],
      cambio: null,
    }],
  }],
  sin_ruta: [],
  subrubros: {},
})

function montar() {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={qc}>
      <PedidosDepositoContainer />
    </QueryClientProvider>,
  )
}

describe('PedidosDepositoContainer', () => {
  beforeEach(() => {
    rpc.mockReset()
    from.mockReset()
    rpc.mockImplementation((_nombre: string, args: { p_fecha: string | null }) =>
      Promise.resolve({ data: respuesta(args.p_fecha ?? '2026-10-08'), error: null }))
  })

  it('arranca pidiendo la próxima ruta armada por la RPC, nunca leyendo pedidos', async () => {
    montar()
    expect(await screen.findByText(/Kiosco Lola/)).toBeInTheDocument()
    expect(rpc).toHaveBeenCalledWith('hojas_de_ruta_deposito', { p_fecha: null })
    expect(from).not.toHaveBeenCalled()
    expect(screen.getByLabelText(/fecha de la hoja de ruta/i)).toHaveValue('2026-10-08')
  })

  it('al pasar al día siguiente pide esa fecha', async () => {
    montar()
    await screen.findByText(/Kiosco Lola/)
    await userEvent.click(screen.getByRole('button', { name: /día siguiente/i }))
    await waitFor(() => expect(rpc).toHaveBeenLastCalledWith('hojas_de_ruta_deposito', { p_fecha: '2026-10-09' }))
  })

  it('si la RPC falla, muestra el error y deja reintentar', async () => {
    rpc.mockResolvedValue({ data: null, error: { message: 'No autorizado', code: '42501' } })
    montar()
    expect(await screen.findByRole('heading', { name: /no se pudieron cargar las hojas de ruta/i })).toBeInTheDocument()
    rpc.mockResolvedValue({ data: respuesta('2026-10-08'), error: null })
    await userEvent.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(await screen.findByText(/Kiosco Lola/)).toBeInTheDocument()
  })
})
