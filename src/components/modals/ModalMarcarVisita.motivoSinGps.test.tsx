/**
 * #1602: la visita de un preventista con la ubicación bloqueada (`denied`) pide
 * el motivo, como un timeout, y guarda el diagnóstico del equipo.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import type { ReactNode } from 'react'
import type { ClienteDB } from '../../types'

const { mutateAsync, capturar, notify } = vi.hoisted(() => ({
  mutateAsync: vi.fn(),
  capturar: vi.fn(),
  notify: { success: vi.fn(), error: vi.fn(), warning: vi.fn(), info: vi.fn() },
}))

vi.mock('../GeolocationGate', () => ({ default: ({ children }: { children: ReactNode }) => <>{children}</> }))
vi.mock('../../hooks/queries', () => ({
  useRegistrarVisitaMutation: () => ({ mutateAsync, isPending: false }),
}))
vi.mock('../../hooks/useGeolocationCapture', () => ({ useGeolocationCapture: () => capturar }))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => notify }))

import ModalMarcarVisita from './ModalMarcarVisita'

const diagnostico = { permiso: 'denied', error: 1, instalada: true, navegador: 'chrome 131', so: 'android 10' } as const
const cliente = { id: '41', nombre_fantasia: 'Almacén Norte', activo: true, preventista_ids: [] } as unknown as ClienteDB

beforeEach(() => {
  vi.clearAllMocks()
  mutateAsync.mockResolvedValue({ success: true, visita_id: 1 })
})

const montar = (isPreventista: boolean) =>
  render(
    <ModalMarcarVisita clientes={[cliente]} userId="u1" isAdmin={!isPreventista} isPreventista={isPreventista} onClose={() => {}} />,
  )

describe('ModalMarcarVisita con la ubicación bloqueada', () => {
  it('el preventista con denied tiene que escribir el motivo, y se guarda con el diagnóstico', async () => {
    const user = userEvent.setup()
    capturar.mockResolvedValue({ status: 'denied', diagnostico })
    montar(true)
    await user.click(screen.getByRole('button', { name: /Almacén Norte/ }))

    // No se registra nada hasta que escriba el motivo.
    expect(await screen.findByText('La ubicación está bloqueada en este teléfono.')).toBeInTheDocument()
    expect(mutateAsync).not.toHaveBeenCalled()

    await user.type(screen.getByRole('textbox', { name: /Motivo/ }), 'no me deja activarla')
    await user.click(screen.getByRole('button', { name: 'Confirmar sin GPS' }))
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    expect(mutateAsync.mock.calls[0][0]).toEqual({
      clienteId: 41,
      status: 'denied',
      motivoOmision: 'no me deja activarla',
      diagnostico,
    })
  })

  it('con ok registra directo, sin motivo y con el diagnóstico', async () => {
    const user = userEvent.setup()
    capturar.mockResolvedValue({
      status: 'ok', lat: -26.8, lng: -65.2, accuracy: 9, capturadoAt: '2026-11-15T12:00:00.000Z',
      diagnostico: { ...diagnostico, permiso: 'granted', error: null },
    })
    montar(true)
    await user.click(screen.getByRole('button', { name: /Almacén Norte/ }))
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    expect(mutateAsync.mock.calls[0][0]).toMatchObject({ status: 'ok', lat: -26.8, diagnostico: { permiso: 'granted' } })
    expect(screen.queryByText('Continuar sin GPS')).toBeNull()
  })

  it('el admin sigue sin motivo, también con denied', async () => {
    const user = userEvent.setup()
    capturar.mockResolvedValue({ status: 'denied', diagnostico })
    montar(false)
    await user.click(screen.getByRole('button', { name: /Almacén Norte/ }))
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    expect(mutateAsync.mock.calls[0][0]).not.toHaveProperty('motivoOmision')
  })
})
