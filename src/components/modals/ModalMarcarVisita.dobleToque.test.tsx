/**
 * Fr-B7 (T8 de la ola 3): un doble toque registra UNA visita.
 *
 * Los dos toques llegan antes de que React vuelva a pintar (los dos `click` van en el mismo
 * `act`): el botón todavía no está deshabilitado y el estado todavía no cambió. Lo frena una
 * marca que se toma en el primer toque, no el estado.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { act, render, screen, waitFor } from '@testing-library/react'
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
  // isPending fijo en false: lo que frena el segundo toque no puede depender de él, que se
  // actualiza recién en la vuelta siguiente.
  useRegistrarVisitaMutation: () => ({ mutateAsync, isPending: false }),
}))
vi.mock('../../hooks/useGeolocationCapture', () => ({ useGeolocationCapture: () => capturar }))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => notify }))

import ModalMarcarVisita from './ModalMarcarVisita'

const cliente = { id: '41', nombre_fantasia: 'Almacén Norte', activo: true, preventista_ids: [] } as unknown as ClienteDB
const diagnostico = { permiso: 'prompt', error: 3, instalada: true, navegador: 'chrome 131', so: 'android 10' } as const

beforeEach(() => {
  vi.clearAllMocks()
  localStorage.clear()
  sessionStorage.clear()
})

const montar = () =>
  render(<ModalMarcarVisita clientes={[cliente]} userId="u1" isAdmin={false} isPreventista onClose={() => {}} />)

describe('ModalMarcarVisita › doble toque (Fr-B7)', () => {
  it('dos toques seguidos sobre el cliente capturan y registran una sola vez', async () => {
    let soltar: (v: unknown) => void = () => {}
    capturar.mockReturnValue(new Promise(res => { soltar = res }))
    mutateAsync.mockResolvedValue({ success: true, visita_id: 1 })
    montar()
    const boton = screen.getByRole('button', { name: /Almacén Norte/ })
    act(() => {
      boton.click()
      boton.click()
    })
    await act(async () => {
      soltar({ status: 'ok', lat: -26.8, lng: -65.2, accuracy: 9, capturadoAt: '2026-11-25T12:00:00.000Z' })
    })
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    expect(capturar).toHaveBeenCalledTimes(1)
  })

  it('dos toques seguidos sobre «Confirmar sin GPS» registran una sola visita, y el botón queda deshabilitado mientras guarda', async () => {
    const user = userEvent.setup()
    capturar.mockResolvedValue({ status: 'timeout', diagnostico })
    let soltar: (v: unknown) => void = () => {}
    mutateAsync.mockReturnValue(new Promise(res => { soltar = res }))
    montar()
    await user.click(screen.getByRole('button', { name: /Almacén Norte/ }))
    await user.type(await screen.findByRole('textbox', { name: /Motivo/ }), 'sin señal en la zona')
    const confirmar = screen.getByRole('button', { name: 'Confirmar sin GPS' })
    act(() => {
      confirmar.click()
      confirmar.click()
    })
    expect(screen.getByRole('button', { name: 'Confirmar sin GPS' })).toBeDisabled()
    await act(async () => { soltar({ success: true, visita_id: 1 }) })
    expect(mutateAsync).toHaveBeenCalledTimes(1)
  })
})
