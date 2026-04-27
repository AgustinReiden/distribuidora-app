/**
 * Tests para VincularTelegramButton.
 *
 * Cubrimos los 3 casos mínimos requeridos:
 *  1) Renderiza el botón "Vincular Telegram".
 *  2) Al click, llama a la mutation y muestra el código retornado.
 *  3) "Generar otro código" re-dispara la mutation y actualiza el modal.
 *
 * Mockeamos `supabase.rpc` con `vi.fn()` (siguiendo el patrón de
 * ModalEditarPedido.test.jsx) para evitar networking en tests.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactElement, ReactNode } from 'react'

// Mock supabase ANTES de importar el componente — la cadena de imports tira
// "supabaseUrl is required" si no se mockea (mismo patrón que en otros tests).
// Usamos `vi.hoisted` porque `vi.mock` se hoistea por encima de los `const`
// del archivo, así que necesitamos que `rpcMock` también esté hoisteado.
const { rpcMock } = vi.hoisted(() => ({ rpcMock: vi.fn() }))

vi.mock('../../../lib/supabase', () => ({
  supabase: {
    rpc: rpcMock,
    from: vi.fn(),
    auth: {
      getSession: vi.fn(() => Promise.resolve({ data: { session: null } })),
      onAuthStateChange: vi.fn(() => ({ data: { subscription: { unsubscribe: vi.fn() } } })),
    },
  },
  setSucursalHeader: vi.fn(),
  getSucursalHeader: vi.fn(),
}))

import VincularTelegramButton from '../VincularTelegramButton'

function makeWrapper(qc: QueryClient) {
  return function Wrapper({ children }: { children: ReactNode }): ReactElement {
    return <QueryClientProvider client={qc}>{children}</QueryClientProvider>
  }
}

function renderButton(): { user: ReturnType<typeof userEvent.setup> } {
  // Disable retries para que los errores no se reintenten en tests.
  const qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  const user = userEvent.setup()
  render(<VincularTelegramButton />, { wrapper: makeWrapper(qc) })
  return { user }
}

describe('VincularTelegramButton', () => {
  beforeEach(() => {
    rpcMock.mockReset()
  })

  it('renderiza el botón "Vincular Telegram"', () => {
    renderButton()
    const btn = screen.getByRole('button', { name: /vincular telegram/i })
    expect(btn).toBeInTheDocument()
  })

  it('al click, llama la mutation y muestra el código retornado', async () => {
    rpcMock.mockResolvedValueOnce({ data: 'abc123', error: null })
    const { user } = renderButton()

    await user.click(screen.getByRole('button', { name: /vincular telegram/i }))

    // El código aparece uppercase en el modal.
    await waitFor(() => {
      expect(screen.getByText('ABC123')).toBeInTheDocument()
    })
    expect(rpcMock).toHaveBeenCalledWith('generar_codigo_vinculacion_bot')
    expect(rpcMock).toHaveBeenCalledTimes(1)

    // Las instrucciones también aparecen.
    expect(screen.getByText(/Cómo vincular tu cuenta/i)).toBeInTheDocument()
  })

  it('"Generar otro código" re-dispara la mutation y actualiza el modal', async () => {
    rpcMock
      .mockResolvedValueOnce({ data: 'abc123', error: null })
      .mockResolvedValueOnce({ data: 'xyz789', error: null })

    const { user } = renderButton()

    await user.click(screen.getByRole('button', { name: /vincular telegram/i }))
    await waitFor(() => expect(screen.getByText('ABC123')).toBeInTheDocument())

    // Click en "Generar otro código".
    await user.click(screen.getByRole('button', { name: /generar otro código/i }))

    await waitFor(() => {
      expect(screen.getByText('XYZ789')).toBeInTheDocument()
    })
    expect(rpcMock).toHaveBeenCalledTimes(2)
    // El código previo ya no está visible.
    expect(screen.queryByText('ABC123')).not.toBeInTheDocument()
  })

  it('si la RPC falla, muestra modal de error con "Reintentar" que re-dispara la mutation', async () => {
    // Primer intento falla; segundo intento (al hacer click en Reintentar)
    // resuelve OK para que la UI complete el flujo limpio.
    rpcMock
      .mockResolvedValueOnce({ data: null, error: new Error('boom') })
      .mockResolvedValueOnce({ data: 'ok1234', error: null })

    const { user } = renderButton()

    await user.click(screen.getByRole('button', { name: /vincular telegram/i }))

    // Aparece el modal de error con el botón "Reintentar".
    const reintentarBtn = await screen.findByRole('button', { name: /reintentar/i })
    expect(reintentarBtn).toBeInTheDocument()
    expect(screen.getByRole('alert')).toHaveTextContent(/boom/i)

    // Click en "Reintentar" → segundo call a la RPC.
    await user.click(reintentarBtn)

    await waitFor(() => {
      expect(rpcMock).toHaveBeenCalledTimes(2)
    })
  })
})
