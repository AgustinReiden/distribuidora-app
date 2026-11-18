/**
 * B23 de #1603 (decisión del dueño, 18/11): la cantidad de un envío a otra sucursal sobre el stock
 * disponible queda en rojo, con el disponible en el motivo, y la salida no se crea. Antes el blur del
 * toque en «Crear salida» la recortaba al stock. Vacía vale 0 (ese producto no viaja), a la vista.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalCrearMovimiento from './ModalCrearMovimiento'
import type { ProductoDB, SucursalDB } from '../../types'

const SUCURSALES = [{ id: 2, nombre: 'Sucursal de prueba' }] as unknown as SucursalDB[]
const PRODUCTOS = [{ id: '5', nombre: 'Fideos de prueba', codigo: 'F1', stock: 12 }] as unknown as ProductoDB[]

async function abrir() {
  const onConfirmar = vi.fn(() => Promise.resolve())
  const user = userEvent.setup()
  render(<ModalCrearMovimiento sucursales={SUCURSALES} productos={PRODUCTOS} guardando={false} onClose={vi.fn()} onConfirmar={onConfirmar} />)
  await user.selectOptions(screen.getByRole('combobox'), '2')
  await user.type(screen.getByPlaceholderText('Buscar por nombre o código...'), 'Fideos')
  await user.click(screen.getByRole('button', { name: /Fideos de prueba/ }))
  return { onConfirmar, user }
}

const crear = (): HTMLElement => screen.getByRole('button', { name: 'Crear salida' })

describe('ModalCrearMovimiento — la cantidad fuera de su límite (B23)', () => {
  it('más que el stock disponible queda en rojo, dice el disponible y no se crea', async () => {
    const { onConfirmar, user } = await abrir()
    const input = screen.getByLabelText('Cantidad de Fideos de prueba')

    await user.clear(input)
    await user.type(input, '50')
    await user.click(crear())

    expect(onConfirmar).not.toHaveBeenCalled()
    expect(input).toHaveValue('50')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Hay 12 disponibles')
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
  })

  it('hasta el stock crea con lo tipeado, sin salir antes del campo', async () => {
    const { onConfirmar, user } = await abrir()
    const input = screen.getByLabelText('Cantidad de Fideos de prueba')

    await user.clear(input)
    await user.type(input, '12')
    await user.click(crear())

    expect(onConfirmar).toHaveBeenCalledWith(expect.objectContaining({ items: [{ producto_id: 5, cantidad: 12 }] }))
  })

  it('vacía vale 0, y el campo lo muestra en gris', async () => {
    const { user } = await abrir()
    const input = screen.getByLabelText('Cantidad de Fideos de prueba')

    await user.clear(input)
    expect(input).toHaveAttribute('placeholder', '0')
    expect(input).not.toHaveAttribute('aria-invalid', 'true')
  })
})
