/**
 * El código se guarda sin los espacios de los bordes (`codigoParaGuardar`, 1561-b1): el campo
 * lo muestra así al salir, antes de guardar. Lo que se ve es lo que se guarda (H4 de la
 * revisión de C4a, ola 2 de #1603).
 */
import { describe, it, expect, vi } from 'vitest'
import { fireEvent, render, screen } from '@testing-library/react'
import ModalProducto from './ModalProducto'

vi.mock('../../hooks/queries', () => ({
  useMarcasQuery: () => ({ data: [] }),
  useCatalogoIIQuery: () => ({ data: { encuadres: [], alicuotas: [] } }),
}))
vi.mock('../productos/ProductoCondicionesMayoristas', () => ({ default: () => null }))
vi.mock('../productos/ProductoLotes', () => ({ default: () => null }))
vi.mock('../productos/ProductoMedidas', () => ({ default: () => null }))
vi.mock('../productos/ProductoUltimaCompra', () => ({ default: () => null }))

function abrir() {
  render(
    <ModalProducto
      producto={null}
      categorias={[]}
      subrubros={[]}
      proveedores={[]}
      onSave={vi.fn()}
      onClose={vi.fn()}
      guardando={false}
      esAdmin
    />,
  )
  return screen.getByPlaceholderText('SKU o codigo interno') as HTMLInputElement
}

describe('ModalProducto — el código al salir del campo', () => {
  it('queda sin los espacios de los bordes, como se va a guardar', () => {
    const campo = abrir()
    fireEvent.change(campo, { target: { value: '  0802 ' } })
    expect(campo.value).toBe('  0802 ')
    fireEvent.blur(campo)
    expect(campo.value).toBe('0802')
  })

  it('sólo espacios queda vacío (sin código)', () => {
    const campo = abrir()
    fireEvent.change(campo, { target: { value: '   ' } })
    fireEvent.blur(campo)
    expect(campo.value).toBe('')
  })

  it('las mayúsculas y el espacio de adentro quedan como se tipearon', () => {
    const campo = abrir()
    fireEvent.change(campo, { target: { value: 'ab 1' } })
    fireEvent.blur(campo)
    expect(campo.value).toBe('ab 1')
  })
})
