/**
 * 1600-b8 (decisión D58 del dueño, #1600): los pedidos sin sincronizar guardados
 * en otra sucursal se avisan, con cuántos son, y se ofrece cambiar de sucursal.
 * Datos inventados.
 */
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const switchSucursal = vi.fn()

vi.mock('../../contexts/SucursalContext', () => ({
  useSucursal: () => ({
    sucursales: [
      { id: 1, nombre: 'Sucursal Norte', rol: 'preventista', rolesExtra: [] },
      { id: 2, nombre: 'Sucursal Sur', rol: 'preventista', rolesExtra: [] },
    ],
    currentSucursalId: 1,
    switchSucursal,
  }),
}))

import AvisoColaOtraSucursal from './AvisoColaOtraSucursal'

describe('AvisoColaOtraSucursal (1600-b8)', () => {
  beforeEach(() => {
    switchSucursal.mockReset()
    switchSucursal.mockResolvedValue(undefined)
  })

  it('sin pendientes en otras sucursales no muestra nada', () => {
    render(<AvisoColaOtraSucursal pendientes={[]} />)
    expect(screen.queryByRole('status')).toBeNull()
  })

  it('dice cuántos hay y en qué sucursal, y el botón cambia a esa sucursal', async () => {
    render(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 2, cantidad: 2 }]} />)

    expect(screen.getByRole('status')).toHaveTextContent('Tenés 2 pedidos sin sincronizar guardados en Sucursal Sur')
    await userEvent.click(screen.getByRole('button', { name: 'Cambiar a Sucursal Sur' }))

    expect(switchSucursal).toHaveBeenCalledWith(2)
  })

  it('de una sucursal que ya no tiene, no ofrece el cambio', () => {
    render(<AvisoColaOtraSucursal pendientes={[{ sucursalId: 9, cantidad: 1 }]} />)

    expect(screen.getByRole('status')).toHaveTextContent(/ya no tenés acceso/)
    expect(screen.queryByRole('button')).toBeNull()
  })
})
