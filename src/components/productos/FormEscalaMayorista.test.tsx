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

function montarVacio() {
  const onGuardar = vi.fn()
  render(
    <FormEscalaMayorista
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

// D17 (#1560, #1542): la tecla del punto es la coma decimal; lo pegado se lee como se muestra.
describe('FormEscalaMayorista · lo tipeado', () => {
  it('la cantidad es texto con teclado numérico, no `type="number"` (#1560-b3)', () => {
    montarVacio()
    const cantidad = screen.getByLabelText('Cantidad mínima')
    expect(cantidad).toHaveAttribute('type', 'text')
    expect(cantidad).toHaveAttribute('inputmode', 'numeric')
  })

  it('una cantidad pegada «1.250» son 1250 unidades, no 1', async () => {
    const onGuardar = montarVacio()
    await userEvent.click(screen.getByLabelText('Cantidad mínima'))
    await userEvent.paste('1.250')
    await userEvent.type(screen.getByLabelText('Precio mayorista'), '150')
    await userEvent.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onGuardar).toHaveBeenCalledWith(expect.objectContaining({ cantidadMinima: 1250, precioUnitario: 150 }))
  })

  it('una cantidad tipeada «1.5» se ve «1,5» y no se guarda: no es entera', async () => {
    const onGuardar = montarVacio()
    await userEvent.type(screen.getByLabelText('Cantidad mínima'), '1.5')
    expect(screen.getByLabelText('Cantidad mínima')).toHaveValue('1,5')
    await userEvent.type(screen.getByLabelText('Precio mayorista'), '150')
    await userEvent.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onGuardar).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toHaveTextContent('La cantidad va en unidades enteras, sin coma')
  })

  it.each([
    ['1.250', 'tipea', 1.25],
    ['1500,50', 'tipea', 1500.5],
    ['1.250,50', 'pega', 1250.5],
  ])('el precio %j que se %s se guarda %d', async (texto, como, esperado) => {
    const onGuardar = montarVacio()
    await userEvent.type(screen.getByLabelText('Cantidad mínima'), '12')
    const precio = screen.getByLabelText('Precio mayorista')
    if (como === 'tipea') await userEvent.type(precio, texto)
    else { await userEvent.click(precio); await userEvent.paste(texto) }
    await userEvent.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onGuardar).toHaveBeenCalledWith(expect.objectContaining({ cantidadMinima: 12, precioUnitario: esperado }))
  })

  it('un precio que no se entiende no se guarda como otro número (#1560-b2)', async () => {
    const onGuardar = montarVacio()
    await userEvent.type(screen.getByLabelText('Cantidad mínima'), '12')
    await userEvent.click(screen.getByLabelText('Precio mayorista'))
    await userEvent.paste('1,234,567')
    expect(screen.getByLabelText('Precio mayorista')).toHaveAttribute('aria-invalid', 'true')
    await userEvent.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onGuardar).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toHaveTextContent('No se entiende el precio')
  })
})
