/**
 * Var-B1 (T8 de la ola 3), la clave sobrevive al modal: el preventista toca el cliente, la
 * respuesta se pierde (el server sí guardó la visita), el toast dice «Revisá las visitas de hoy
 * antes de reintentar», cierra «Marcar visita» y lo vuelve a abrir. El modal se desmonta al
 * cerrarse (PedidosContainer y HoyContainer lo montan condicionado), así que la clave no puede
 * vivir en el estado del componente: el segundo toque tiene que mandar la MISMA clave, y el
 * server devuelve la visita del primero en vez de crear otra.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import type { ReactNode } from 'react'
import type { ClienteDB } from '../../types'

const rpcCalls: Array<{ fn: string; args: Record<string, unknown> }> = []
let respuestas: Array<{ data: unknown; error: { message: string; code?: string } | null }> = []

const { capturar, notify } = vi.hoisted(() => ({
  capturar: vi.fn(),
  notify: { success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() },
}))

vi.mock('../../lib/supabase', () => ({
  setSucursalHeader: () => {},
  getSucursalHeader: () => null,
  supabase: {
    rpc: (fn: string, args: Record<string, unknown>) => {
      rpcCalls.push({ fn, args })
      return Promise.resolve(respuestas.shift() ?? { data: { success: true, visita_id: 1 }, error: null })
    },
  },
}))
vi.mock('../../contexts/SucursalContext', () => ({ useSucursal: () => ({ currentSucursalId: 1 }) }))
vi.mock('../GeolocationGate', () => ({ default: ({ children }: { children: ReactNode }) => <>{children}</> }))
vi.mock('../../hooks/useGeolocationCapture', () => ({ useGeolocationCapture: () => capturar }))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => notify }))

import ModalMarcarVisita from './ModalMarcarVisita'
import { fijarUsuarioRequestIds, olvidarRequestIdsDe } from '../../utils/requestIdPersistente'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
const cliente = { id: '41', nombre_fantasia: 'Almacén Norte', activo: true, preventista_ids: [] } as unknown as ClienteDB
const gpsOk = { status: 'ok', lat: -26.8, lng: -65.2, accuracy: 9, capturadoAt: '2026-11-25T12:00:00.000Z' }

const claves = () => rpcCalls.map(c => c.args.p_clave as string)

let qc: QueryClient

function Montaje({ abierto }: { abierto: boolean }) {
  return (
    <QueryClientProvider client={qc}>
      {abierto && (
        <ModalMarcarVisita clientes={[cliente]} userId="u1" isAdmin={false} isPreventista onClose={() => {}} />
      )}
    </QueryClientProvider>
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  qc = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
  rpcCalls.length = 0
  respuestas = []
  localStorage.clear()
  sessionStorage.clear()
  fijarUsuarioRequestIds('u1')
  olvidarRequestIdsDe('u1')
  capturar.mockResolvedValue(gpsOk)
})

describe('ModalMarcarVisita › la clave al cerrar y reabrir (Var-B1)', () => {
  it('la respuesta se pierde, se cierra el modal y se vuelve a abrir: el segundo toque manda la MISMA clave', async () => {
    const user = userEvent.setup()
    respuestas = [{ data: null, error: { message: 'Failed to fetch' } }]
    const vista = render(<Montaje abierto />)
    await user.click(screen.getByRole('button', { name: /Almacén Norte/ }))
    await waitFor(() => expect(notify.error).toHaveBeenCalledTimes(1))
    expect(rpcCalls).toHaveLength(1)

    // El modal se desmonta (cierra) y se vuelve a montar (reabre): otra instancia del hook.
    vista.rerender(<Montaje abierto={false} />)
    expect(screen.queryByRole('button', { name: /Almacén Norte/ })).toBeNull()
    vista.rerender(<Montaje abierto />)
    await user.click(screen.getByRole('button', { name: /Almacén Norte/ }))
    await waitFor(() => expect(rpcCalls).toHaveLength(2))

    expect(claves()[0]).toMatch(UUID)
    expect(claves()[1]).toBe(claves()[0])
  })

  it('después de una visita que salió bien, cerrar y reabrir da una clave nueva para el mismo cliente', async () => {
    const user = userEvent.setup()
    const vista = render(<Montaje abierto />)
    await user.click(screen.getByRole('button', { name: /Almacén Norte/ }))
    await waitFor(() => expect(rpcCalls).toHaveLength(1))
    vista.rerender(<Montaje abierto={false} />)
    vista.rerender(<Montaje abierto />)
    await user.click(screen.getByRole('button', { name: /Almacén Norte/ }))
    await waitFor(() => expect(rpcCalls).toHaveLength(2))
    expect(claves()[1]).not.toBe(claves()[0])
  })
})
