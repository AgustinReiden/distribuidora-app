import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../utils/formatters', () => ({
  formatPrecio: (value) => `$${Number(value).toFixed(2)}`,
}))

import ModalCambiarProveedor from './ModalCambiarProveedor'

describe('ModalCambiarProveedor', () => {
  // Compra cargada al proveedor equivocado (id 6). Al cambiarlo, se anula y se
  // recrea idéntica; el modal solo elige el proveedor nuevo, no toca importes.
  const compra = {
    id: 133,
    proveedor_id: 6,
    proveedor_nombre: null,
    proveedor: { id: 6, nombre: 'Proveedor Viejo' },
    numero_factura: '0001-00025144',
    fecha_compra: '2026-07-12',
    tipo_factura: 'FC',
    total: 3273780.84,
    items: [
      { producto_id: 1, cantidad: 2 },
      { producto_id: 2, cantidad: 3 },
    ],
  }

  const proveedores = [
    { id: 6, nombre: 'Proveedor Viejo' },
    { id: 20, nombre: 'Proveedor Nuevo' },
    { id: 21, nombre: 'Otro Proveedor' },
  ]

  const baseProps = { compra, proveedores, guardando: false }

  it('muestra el proveedor actual y deshabilita confirmar sin proveedor nuevo', () => {
    render(<ModalCambiarProveedor {...baseProps} onConfirmar={vi.fn()} onClose={vi.fn()} />)
    expect(screen.getByText('Proveedor Viejo')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Cambiar proveedor/i })).toBeDisabled()
  })

  it('deja el proveedor actual como opción deshabilitada (no se puede elegir el mismo)', () => {
    render(<ModalCambiarProveedor {...baseProps} onConfirmar={vi.fn()} onClose={vi.fn()} />)
    const opcionActual = screen.getByRole('option', { name: /Proveedor Viejo — actual/i })
    expect(opcionActual).toBeDisabled()
  })

  it('al elegir un proveedor nuevo, confirma con el id correcto y sin tocar importes', async () => {
    const user = userEvent.setup()
    const onConfirmar = vi.fn()
    render(<ModalCambiarProveedor {...baseProps} onConfirmar={onConfirmar} onClose={vi.fn()} />)

    await user.selectOptions(screen.getByRole('combobox'), '20')

    const confirmar = screen.getByRole('button', { name: /Cambiar proveedor/i })
    expect(confirmar).toBeEnabled()
    await user.click(confirmar)

    expect(onConfirmar).toHaveBeenCalledTimes(1)
    expect(onConfirmar.mock.calls[0][0]).toEqual({
      nuevoProveedorId: '20',
      nuevoProveedorNombre: null,
      motivo: 'Cambio de proveedor',
    })
  })
})
