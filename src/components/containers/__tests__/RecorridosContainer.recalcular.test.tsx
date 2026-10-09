/**
 * «Recalcular» un recorrido normaliza el error de supabase (#1011).
 *
 * `handleRecalcular` mostraba `error?.message`: con el objeto plano de
 * supabase-js, un fallo de red salía como "TypeError: Failed to fetch" y nada
 * decía que el recálculo NO se confirmó. Con `errorDeSupabase` la red se
 * traduce y el mensaje del servidor pasa intacto. El caso "respondió sin error
 * pero `success` no es true" conserva su literal.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const { rpc, notifyError, notifySuccess } = vi.hoisted(() => ({
  rpc: vi.fn(),
  notifyError: vi.fn(),
  notifySuccess: vi.fn(),
}))

vi.mock('../../../lib/supabase', () => ({
  supabase: { rpc },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(() => null),
}))

vi.mock('../../../hooks/supabase', () => ({
  useRecorridos: () => ({
    recorridos: [],
    loading: false,
    fetchRecorridosHoy: vi.fn().mockResolvedValue(undefined),
    fetchRecorridosPorFecha: vi.fn().mockResolvedValue(undefined),
    getEstadisticasRecorridos: vi.fn().mockResolvedValue(null),
  }),
}))

vi.mock('../../../contexts/AuthDataContext', () => ({ useAuthData: () => ({ isAdmin: true }) }))
vi.mock('../../../contexts/NotificationContext', () => {
  const notify = { error: notifyError, success: notifySuccess, warning: vi.fn(), info: vi.fn() }
  return { useNotification: () => notify }
})

vi.mock('../../vistas/VistaRecorridos', () => ({
  default: ({ onRecalcular }: { onRecalcular?: (id: string) => Promise<void> }) => (
    <button type="button" onClick={() => void onRecalcular?.('15')}>Recalcular</button>
  ),
}))

import RecorridosContainer from '../RecorridosContainer'

// Las dos formas reales de supabase-js (ver errorDeSupabase.test.ts).
const ERROR_DE_RED = { message: 'TypeError: Failed to fetch', details: '', hint: '', code: '' }
const ERROR_DE_SERVIDOR = { message: 'Acceso denegado: se requiere rol admin', details: '', hint: '', code: '42501' }

async function recalcular(respuesta: unknown) {
  rpc.mockResolvedValue(respuesta)
  const user = userEvent.setup()
  render(<RecorridosContainer />)
  await user.click(await screen.findByRole('button', { name: 'Recalcular' }))
  await waitFor(() => expect(rpc).toHaveBeenCalledWith('recalcular_recorrido', { p_recorrido_id: 15 }))
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe('RecorridosContainer — recalcular (#1011)', () => {
  it('un fallo de red avisa que no se confirmó, sin "Failed to fetch"', async () => {
    await recalcular({ data: null, error: ERROR_DE_RED })

    await waitFor(() => expect(notifyError).toHaveBeenCalled())
    const [msg] = notifyError.mock.calls[0]
    expect(msg).toMatch(/^Sin conexión: no se pudo confirmar/)
    expect(msg).not.toMatch(/failed to fetch/i)
  })

  it('un error del servidor conserva su mensaje', async () => {
    await recalcular({ data: null, error: ERROR_DE_SERVIDOR })

    await waitFor(() => expect(notifyError).toHaveBeenCalledWith('Acceso denegado: se requiere rol admin'))
  })

  // `errorDeSupabase` nunca devuelve vacío: con un mensaje en blanco diría
  // "Error del servidor", que es menos de lo que el literal decía antes.
  it('un error del servidor sin mensaje conserva el literal de siempre', async () => {
    await recalcular({ data: null, error: { message: '', details: '', hint: '', code: 'P0001' } })

    await waitFor(() => expect(notifyError).toHaveBeenCalledWith('No se pudo recalcular el recorrido'))
  })

  it('sin error pero sin success, conserva el literal de siempre', async () => {
    await recalcular({ data: { success: false }, error: null })

    await waitFor(() => expect(notifyError).toHaveBeenCalledWith('No se pudo recalcular el recorrido'))
  })

  it('con success avisa que se recalculó', async () => {
    await recalcular({ data: { success: true }, error: null })

    await waitFor(() => expect(notifySuccess).toHaveBeenCalledWith('Totales del recorrido recalculados'))
    expect(notifyError).not.toHaveBeenCalled()
  })
})
