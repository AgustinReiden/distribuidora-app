/**
 * #1560: el precio de una escala que se edita se precarga con coma decimal (`numeroEditable`) y lo
 * vuelve a leer `parsePrecio`. Con `String(precio)`, un precio de tres decimales («125.125») se
 * releía ciento veinticinco mil al guardar sin tocarlo.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import FormEscalaMayorista from './FormEscalaMayorista'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'

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
  it('se precarga con coma decimal y los miles que pone el campo', () => {
    montar(1234.5)
    expect(screen.getByLabelText('Precio mayorista')).toHaveValue('1.234,5')
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

  it('los miles los pone el campo al tipear', async () => {
    const onGuardar = montarVacio()
    await userEvent.type(screen.getByLabelText('Cantidad mínima'), '1500')
    await userEvent.type(screen.getByLabelText('Precio mayorista'), '150000,5')
    expect(screen.getByLabelText('Cantidad mínima')).toHaveValue('1.500')
    expect(screen.getByLabelText('Precio mayorista')).toHaveValue('150.000,5')
    await userEvent.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onGuardar).toHaveBeenCalledWith(expect.objectContaining({ cantidadMinima: 1500, precioUnitario: 150000.5 }))
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
    // N3 de la segunda pasada: el campo dice el motivo y el Guardar de la escala queda frenado.
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled()
    await userEvent.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onGuardar).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toHaveTextContent('Van sin coma: para mil escribí 1000')
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
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled()
    await userEvent.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onGuardar).not.toHaveBeenCalled()
    expect(screen.getByRole('alert')).toHaveTextContent('No se entiende el número')
  })
})

// N3 y N7 de la segunda pasada de #1644: el precio mayorista es el piso de precio para todos los
// roles. «1.500» tipeado (se escribe «1,500») se guarda $ 1,50 con el aviso amarillo, y un rojo en
// esta escala frena SU Guardar, no el de la ficha que la contiene.
describe('FormEscalaMayorista · la regla de la tarjeta', () => {
  it('«1.500» tipeado en el precio sale con el aviso amarillo y guarda 1,5', async () => {
    const onGuardar = montarVacio()
    await userEvent.type(screen.getByLabelText('Cantidad mínima'), '12')
    await userEvent.type(screen.getByLabelText('Precio mayorista'), '1.500')
    expect(screen.getByLabelText('Precio mayorista')).not.toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('status')).toHaveTextContent(/Se guarda \$\s1,50\. Para \$\s1\.500,00 escribí 1500\./)
    await userEvent.click(screen.getByRole('button', { name: 'Guardar' }))
    expect(onGuardar).toHaveBeenCalledWith(expect.objectContaining({ precioUnitario: 1.5 }))
  })

  it('un rojo adentro no frena el Guardar del formulario de afuera', async () => {
    function Ficha() {
      const ilegibles = useRegistroIlegibles()
      return (
        <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
          <FormEscalaMayorista precioLista={200} costoTotal={0} costoReal={0} porcentajeIva={21} onGuardar={vi.fn()} onCancelar={vi.fn()} />
          <button type="button" disabled={ilegibles.hay}>Guardar ficha</button>
        </RegistroIlegiblesContext.Provider>
      )
    }
    render(<Ficha />)
    await userEvent.type(screen.getByLabelText('Cantidad mínima'), '1.5')
    expect(screen.getByLabelText('Cantidad mínima')).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('button', { name: 'Guardar' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Guardar ficha' })).toBeEnabled()
  })
})
