import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

// usePromocionPedido depende de estos dos hooks de query. Maps vacíos => sin
// mayorista ni promos, así el recálculo parte del precio de lista del producto.
vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false }),
}))

vi.mock('../../utils/formatters', () => ({
  formatPrecio: (value) => `$${Number(value).toFixed(2)}`,
}))

import ModalCambiarCliente from './ModalCambiarCliente'

describe('ModalCambiarCliente', () => {
  // Pedido del cliente equivocado (id 10). El precio_unitario viejo (250) NO
  // debe usarse: el recálculo parte del precio de LISTA del producto (300).
  const pedido = {
    id: 123,
    cliente_id: 10,
    total: 1000,
    estado: 'pendiente',
    tipo_factura: 'ZZ',
    items: [
      { producto_id: 1, cantidad: 2, precio_unitario: 250 },
      { producto_id: 2, cantidad: 1, precio_unitario: 500 },
    ],
  }

  const productos = [
    { id: 1, nombre: 'Producto 1', precio: 300, stock: 10, categoria: 'BEBIDAS' },
    { id: 2, nombre: 'Producto 2', precio: 500, stock: 5, categoria: 'BEBIDAS' },
  ]

  const clientes = [
    { id: 10, nombre_fantasia: 'Cliente Actual', direccion: 'Calle Vieja 1' },
    { id: 20, nombre_fantasia: 'Cliente Nuevo', direccion: 'Calle Nueva 2' },
    { id: 30, nombre_fantasia: 'Cliente Descuento', direccion: 'Calle Desc 3', descuento_porcentaje: 10 },
  ]

  const baseProps = { pedido, productos, clientes, guardando: false }

  it('muestra el cliente actual y deshabilita el botón sin cliente nuevo', () => {
    render(<ModalCambiarCliente {...baseProps} onConfirmar={vi.fn()} onClose={vi.fn()} />)
    expect(screen.getByText('Cliente Actual')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Confirmar cambio/i })).toBeDisabled()
  })

  it('recalcula con el precio de lista (no el precio viejo) al elegir cliente nuevo', async () => {
    const user = userEvent.setup()
    const onConfirmar = vi.fn()
    render(<ModalCambiarCliente {...baseProps} onConfirmar={onConfirmar} onClose={vi.fn()} />)

    await user.type(screen.getByPlaceholderText(/Buscar por nombre/i), 'Nuevo')
    await user.click(await screen.findByText('Cliente Nuevo'))

    const confirmar = screen.getByRole('button', { name: /Confirmar cambio/i })
    expect(confirmar).toBeEnabled()
    await user.click(confirmar)

    expect(onConfirmar).toHaveBeenCalledTimes(1)
    const payload = onConfirmar.mock.calls[0][0]
    expect(payload.nuevoClienteId).toBe('20')
    // 2×300 + 1×500 = 1100 (precio de lista, NO 2×250+500=1000)
    expect(payload.total).toBe(1100)
    expect(payload.items).toHaveLength(2)
    expect(payload.items[0]).toMatchObject({ productoId: '1', cantidad: 2, precioUnitario: 300 })
  })

  it('aplica el descuento del cliente nuevo al total recalculado', async () => {
    const user = userEvent.setup()
    const onConfirmar = vi.fn()
    render(<ModalCambiarCliente {...baseProps} onConfirmar={onConfirmar} onClose={vi.fn()} />)

    await user.type(screen.getByPlaceholderText(/Buscar por nombre/i), 'Descuento')
    await user.click(await screen.findByText('Cliente Descuento'))

    await user.click(screen.getByRole('button', { name: /Confirmar cambio/i }))

    const payload = onConfirmar.mock.calls[0][0]
    // 1100 con 10% de descuento general => 990 (270×2 + 450)
    expect(payload.total).toBe(990)
    expect(payload.items[0].precioUnitario).toBe(270)
    expect(payload.items[1].precioUnitario).toBe(450)
  })
})
