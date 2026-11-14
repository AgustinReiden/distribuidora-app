/**
 * #1560: el precio de una escala que se edita se precarga con coma decimal (`numeroEditable`) y lo
 * vuelve a leer `parsePrecio`. Con `String(precio)`, un precio de tres decimales («125.125») se
 * releía ciento veinticinco mil al guardar sin tocarlo.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import FormEscalaMayorista from './FormEscalaMayorista'

function montar(precioUnitario: number) {
  const onGuardar = vi.fn()
  render(
    <FormEscalaMayorista
      inicial={{ cantidadMinima: 12, precioUnitario, etiqueta: null }}
      precioLista={200}
      costoTotal={0}
      costoReal={0}
      porcentajeIva={21}
      onGuardar={onGuardar}
      onCancelar={vi.fn()}
    />,
  )
  return onGuardar
}

describe('FormEscalaMayorista · el precio inicial', () => {
  it('se precarga con coma decimal', () => {
    montar(1234.5)
    expect(screen.getByLabelText('Precio mayorista')).toHaveValue('1234,5')
  })

  it('guardar sin tocarlo no lo multiplica por mil', async () => {
    const onGuardar = montar(125.125)
    await userEvent.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onGuardar).toHaveBeenCalledWith(expect.objectContaining({ precioUnitario: 125.13 }))
  })
})
