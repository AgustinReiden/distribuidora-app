/**
 * 1600-b8 (decisión D58 del dueño, #1600): los pedidos sin sincronizar guardados
 * en otra sucursal se avisan, con cuántos son, y se ofrece cambiar de sucursal.
 * H5 de la revisión de B12a: se puede cerrar, no ofrece el cambio a una sucursal
 * inactiva o rechazada, y después de cambiar dice que la app se queda ahí.
 * Datos inventados.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const estado = vi.hoisted(() => ({
  actual: 1,
  header: 1 as number | null,
  activas: undefined as Array<{ id: number; nombre: string }> | undefined,
}))
const switchSucursal = vi.fn()
const notify = { info: vi.fn(), success: vi.fn(), warning: vi.fn(), error: vi.fn() }

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    sucursales: [
      { id: 1, nombre: 'Sucursal Norte', rol: 'preventista', rolesExtra: [] },
      { id: 2, nombre: 'Sucursal Sur', rol: 'preventista', rolesExtra: [] },
    ],
    currentSucursalId: estado.actual,
    switchSucursal,
  }),
}))
vi.mock('../../contexts/NotificationContext', () => ({ useNotification: () => notify }))
vi.mock('../../hooks/queries/useSucursalesActivasQuery', () => ({
  useSucursalesActivasQuery: () => ({ data: estado.activas }),
}))
vi.mock('../../lib/supabase', () => ({ getSucursalHeader: () => estado.header }))

import AvisoColaOtraSucursal from './AvisoColaOtraSucursal'

describe('AvisoColaOtraSucursal (1600-b8)', () => {
  beforeEach(() => {
    vi.clearAllMocks()
    estado.actual = 1
    estado.header = 1
    estado.activas = undefined
    // El cambio que confirma el servidor: header y sucursal activa.
    switchSucursal.mockImplementation(async (id: number) => { estado.header = id; estado.actual = id; return 'ok' })
  })

  it('sin pendientes en otras sucursales no muestra nada', () => {
    render(<AvisoColaOtraSucursal pendientes={[]} />)
    expect(screen.queryByRole('status')).toBeNull()
  })

  it('dice cuántos hay y en qué sucursal; el botón cambia y después dice que la app se queda ahí', async () => {
    render(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 2, pendientes: 2, fallidos: 0 }]} />)

    expect(screen.getByRole('status')).toHaveTextContent('Tenés 2 pedidos sin mandar guardados en Sucursal Sur')
    await userEvent.click(screen.getByRole('button', { name: 'Cambiar a Sucursal Sur' }))
    expect(switchSucursal).toHaveBeenCalledWith(2)

    await waitFor(() => expect(notify.info).toHaveBeenCalledWith(
      expect.stringMatching(/Ahora estás trabajando en Sucursal Sur.*se queda en esta sucursal/),
      { persist: true },
    ))
  })

  it('H5: se puede cerrar, y vuelve si cambia la cuenta', async () => {
    const { rerender } = render(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 2, pendientes: 1, fallidos: 0 }]} />)

    await userEvent.click(screen.getByRole('button', { name: 'Cerrar aviso de pedidos en otra sucursal' }))
    expect(screen.queryByRole('status')).toBeNull()

    rerender(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 2, pendientes: 1, fallidos: 0 }]} />)
    expect(screen.queryByRole('status')).toBeNull()
    rerender(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 2, pendientes: 2, fallidos: 0 }]} />)
    expect(screen.getByRole('status')).toHaveTextContent('Tenés 2 pedidos')
  })

  it('H5: los fallidos se avisan aparte, para revisarlos', () => {
    render(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 2, pendientes: 0, fallidos: 1 }]} />)
    expect(screen.getByRole('status')).toHaveTextContent('1 pedido de Sucursal Sur tiene error: hay que revisarlo (reintentar o eliminar)')
  })

  it('H5: a una sucursal inactiva no le ofrece el cambio', () => {
    estado.activas = [{ id: 1, nombre: 'Sucursal Norte' }]
    render(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 2, pendientes: 1, fallidos: 0 }]} />)

    expect(screen.getByRole('status')).toHaveTextContent(/Avisale al administrador/)
    expect(screen.queryByRole('button', { name: /Cambiar a/ })).toBeNull()
  })

  it('si el servidor rechaza el cambio, deja de ofrecerlo y no dice que cambió', async () => {
    switchSucursal.mockResolvedValue('rechazado')
    render(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 2, pendientes: 1, fallidos: 0 }]} />)

    await userEvent.click(screen.getByRole('button', { name: 'Cambiar a Sucursal Sur' }))

    await waitFor(() => expect(screen.queryByRole('button', { name: /Cambiar a/ })).toBeNull())
    expect(screen.getByRole('status')).toHaveTextContent(/Avisale al administrador/)
    expect(notify.info).not.toHaveBeenCalled()
  })

  it('N1: si falla la red, el botón sigue y dice que no hubo señal (no «avisale al administrador»)', async () => {
    switchSucursal.mockResolvedValueOnce('fallo')
    render(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 2, pendientes: 1, fallidos: 0 }]} />)

    await userEvent.click(screen.getByRole('button', { name: 'Cambiar a Sucursal Sur' }))

    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('No se pudo cambiar de sucursal: no hubo señal'))
    expect(screen.getByRole('status')).not.toHaveTextContent(/administrador/)
    expect(notify.info).not.toHaveBeenCalled()
    // Con señal, el mismo botón lo cambia.
    await userEvent.click(screen.getByRole('button', { name: 'Cambiar a Sucursal Sur' }))
    await waitFor(() => expect(notify.info).toHaveBeenCalled())
  })

  it('de una sucursal que ya no tiene, no ofrece el cambio', () => {
    render(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 9, pendientes: 1, fallidos: 0 }]} />)

    expect(screen.getByRole('status')).toHaveTextContent(/ya no tenés acceso/)
    expect(screen.queryByRole('button', { name: /Cambiar a/ })).toBeNull()
  })
})
