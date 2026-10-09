/**
 * ModalCtaCtePendiente no disfraza un fallo de "no hay pendientes" (#1011).
 *
 * Si la RPC fallaba, el modal ponía la lista en vacío y mostraba "No hay
 * pedidos entregados pendientes de cobro en este período": indistinguible de
 * que de verdad no haya deuda. Ahora muestra el motivo, normalizado con
 * `errorDeSupabase` (la red se traduce; el mensaje del servidor pasa intacto).
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'

const { rpc } = vi.hoisted(() => ({ rpc: vi.fn() }))

vi.mock('../../hooks/supabase/base', () => ({
  supabase: { rpc },
  setErrorNotifier: vi.fn(),
  notifyError: vi.fn(),
  handleSupabaseError: vi.fn(),
}))

import ModalCtaCtePendiente from './ModalCtaCtePendiente'

const ERROR_DE_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
const ERROR_DE_SERVIDOR = { message: 'permission denied for function obtener_pedidos_ctacte_pendientes', details: '', hint: '', code: '42501' }
const VACIO = /No hay pedidos entregados pendientes de cobro/

function montar() {
  render(<ModalCtaCtePendiente fechaDesde="2026-10-01" fechaHasta="2026-10-07" onClose={vi.fn()} />)
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('ModalCtaCtePendiente — error de carga (#1011)', () => {
  it('un fallo de red lo dice (sin "Failed to fetch") en vez de mostrar la lista vacía', async () => {
    rpc.mockResolvedValue({ data: null, error: ERROR_DE_RED })
    montar()

    const alerta = await screen.findByRole('alert')
    expect(alerta).toHaveTextContent(/No se pudo cargar la cuenta corriente pendiente: Sin conexión/)
    expect(alerta).not.toHaveTextContent(/failed to fetch/i)
    expect(screen.queryByText(VACIO)).not.toBeInTheDocument()
  })

  it('un error del servidor muestra su mensaje en vez de la lista vacía', async () => {
    rpc.mockResolvedValue({ data: null, error: ERROR_DE_SERVIDOR })
    montar()

    const alerta = await screen.findByRole('alert')
    expect(alerta).toHaveTextContent('permission denied for function obtener_pedidos_ctacte_pendientes')
    expect(screen.queryByText(VACIO)).not.toBeInTheDocument()
  })

  it('sin error y sin filas sigue diciendo que no hay pendientes, y sin alerta', async () => {
    rpc.mockResolvedValue({ data: [], error: null })
    montar()

    expect(await screen.findByText(VACIO)).toBeInTheDocument()
    await waitFor(() => expect(rpc).toHaveBeenCalled())
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })
})
