import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ProductosTabs, { PANEL_PRODUCTOS_ID } from './ProductosTabs'

describe('ProductosTabs', () => {
  it('marca como seleccionada la pestaña activa', () => {
    render(<ProductosTabs value="productos" onChange={() => {}} />)
    expect(screen.getByRole('tab', { name: /^Productos$/ })).toHaveAttribute('aria-selected', 'true')
    expect(screen.getByRole('tab', { name: /Condiciones mayoristas/ })).toHaveAttribute('aria-selected', 'false')
  })

  it('avisa el cambio de pestaña', async () => {
    const onChange = vi.fn()
    render(<ProductosTabs value="productos" onChange={onChange} />)
    await userEvent.click(screen.getByRole('tab', { name: /Condiciones mayoristas/ }))
    expect(onChange).toHaveBeenCalledWith('condiciones')
  })

  it('muestra el contador de condiciones cuando hay alguna', () => {
    render(<ProductosTabs value="productos" onChange={() => {}} contadorCondiciones={12} />)
    expect(screen.getByRole('tab', { name: /Condiciones mayoristas/ })).toHaveTextContent('12')
  })

  it('sin condiciones cargadas no muestra un 0 que confunda', () => {
    render(<ProductosTabs value="productos" onChange={() => {}} contadorCondiciones={0} />)
    expect(screen.queryByText('0')).not.toBeInTheDocument()
  })

  it('apunta al contenedor del contenido para lectores de pantalla', () => {
    render(<ProductosTabs value="condiciones" onChange={() => {}} />)
    for (const tab of screen.getAllByRole('tab')) {
      expect(tab).toHaveAttribute('aria-controls', PANEL_PRODUCTOS_ID)
    }
  })
})
