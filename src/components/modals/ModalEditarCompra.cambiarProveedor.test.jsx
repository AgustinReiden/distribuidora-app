import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../utils/formatters', () => ({
  formatPrecio: (value) => `$${Number(value).toFixed(2)}`,
}))

import ModalEditarCompra from './ModalEditarCompra'

describe('ModalEditarCompra · botón "Cambiar proveedor"', () => {
  const compra = {
    id: 133,
    estado: 'recibida',
    tipo_factura: 'FC',
    proveedor_id: 6,
    proveedor: { id: 6, nombre: 'Proveedor Viejo' },
    numero_factura: '0001-1',
    fecha_compra: '2026-07-12',
    total: 1000,
    otros_impuestos: 0,
    percepcion_iva: 0,
    percepcion_iibb: 0,
    no_gravado: 0,
    items: [
      {
        producto_id: 1,
        cantidad: 2,
        costo_unitario: 100,
        bonificacion: 0,
        porcentaje_iva: 21,
        impuestos_internos: 0,
        producto: { nombre: 'Prod 1' },
      },
    ],
  }
  const proveedores = [
    { id: 6, nombre: 'Proveedor Viejo' },
    { id: 20, nombre: 'Proveedor Nuevo' },
  ]
  const baseProps = { compra, usuarioId: 'u1', onGuardar: vi.fn(), onClose: vi.fn(), guardando: false }
  const adminProps = { ...baseProps, canCambiarProveedor: true, onCambiarProveedor: vi.fn(), proveedores }

  it('no muestra el botón si no es admin', () => {
    render(<ModalEditarCompra {...baseProps} />)
    expect(screen.queryByRole('button', { name: /Cambiar proveedor/i })).not.toBeInTheDocument()
  })

  it('muestra el botón habilitado para admin sin cambios de items', () => {
    render(<ModalEditarCompra {...adminProps} />)
    expect(screen.getByRole('button', { name: /Cambiar proveedor/i })).toBeEnabled()
  })

  it('deshabilita el botón si hay cambios de items sin guardar', async () => {
    const user = userEvent.setup()
    render(<ModalEditarCompra {...adminProps} />)
    expect(screen.getByRole('button', { name: /Cambiar proveedor/i })).toBeEnabled()
    // marcar el item para eliminar => hay cambios sin guardar
    await user.click(screen.getByTitle('Eliminar item'))
    expect(screen.getByRole('button', { name: /Cambiar proveedor/i })).toBeDisabled()
  })
})
