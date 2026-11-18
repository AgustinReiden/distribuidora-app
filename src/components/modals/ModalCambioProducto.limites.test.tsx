/**
 * B23 de #1603 (decisión del dueño, 18/11): las cantidades del cambio de producto fuera de su límite
 * quedan en rojo, con su motivo, y el cambio no se registra. Antes el blur del toque en «Registrar
 * cambio» recortaba: «50» a entregar con 8 en stock registraba 8, y vacío registraba 1.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalCambioProducto from './ModalCambioProducto'
import type { ClienteDB, ProductoDB } from '../../types'

const CLIENTE = { id: 7, nombre_fantasia: 'Almacén de prueba', razon_social: 'Prueba SA', activo: true } as unknown as ClienteDB
const PRODUCTOS = [
  { id: 1, nombre: 'Galletitas de prueba', codigo: 'G1', precio: 100, stock: 20, activo: true },
  { id: 2, nombre: 'Jugo de prueba', codigo: 'J1', precio: 150, stock: 8, activo: true },
] as unknown as ProductoDB[]

async function abrir() {
  const onSave = vi.fn(() => Promise.resolve())
  const user = userEvent.setup()
  render(<ModalCambioProducto clientes={[CLIENTE]} productos={PRODUCTOS} clienteFijo={CLIENTE} onSave={onSave} onClose={vi.fn()} />)
  const [buscarDevuelto, buscarEntregado] = screen.getAllByPlaceholderText('Buscar por nombre o código...')
  await user.type(buscarDevuelto, 'Galletitas')
  await user.click(screen.getByRole('button', { name: /Galletitas de prueba/ }))
  await user.type(buscarEntregado, 'Jugo')
  await user.click(screen.getByRole('button', { name: /Jugo de prueba/ }))
  return { onSave, user }
}

const registrar = (): HTMLElement => screen.getByRole('button', { name: /registrar cambio/i })

describe('ModalCambioProducto — las cantidades fuera de su límite (B23)', () => {
  it.each([
    ['entregada: 50 con 8 en stock', 'Cantidad entregada', '50', 'Hay 8 en stock'],
    ['entregada: 0', 'Cantidad entregada', '0', 'El mínimo es 1'],
    ['entregada: vacía', 'Cantidad entregada', '', 'Poné una cantidad'],
    ['devuelta: 0', 'Cantidad devuelta', '0', 'El mínimo es 1'],
    ['devuelta: vacía', 'Cantidad devuelta', '', 'Poné una cantidad'],
  ])('%s: queda en rojo con su motivo y no se registra', async (_caso, campo, texto, motivo) => {
    const { onSave, user } = await abrir()
    const input = screen.getByLabelText(campo)

    await user.clear(input)
    if (texto) await user.type(input, texto)
    await user.click(registrar())

    expect(onSave).not.toHaveBeenCalled()
    expect(input).toHaveValue(texto)
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent(motivo)
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
  })

  it('dentro del límite registra lo tipeado, sin salir antes del campo', async () => {
    const { onSave, user } = await abrir()

    await user.clear(screen.getByLabelText('Cantidad devuelta'))
    await user.type(screen.getByLabelText('Cantidad devuelta'), '30')
    await user.clear(screen.getByLabelText('Cantidad entregada'))
    await user.type(screen.getByLabelText('Cantidad entregada'), '8')
    await user.click(registrar())

    expect(onSave).toHaveBeenCalledWith(expect.objectContaining({ cantidadDevuelta: 30, cantidadEntregada: 8 }))
  })
})
