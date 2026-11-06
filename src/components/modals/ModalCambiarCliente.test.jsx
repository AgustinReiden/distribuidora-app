import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

// usePromocionPedido depende de estos hooks de query. Maps vacíos => sin
// mayorista, promos ni mínimos de venta, así el recálculo parte del precio de
// lista del producto.
// #1191: los combos tienen su propia query (y su sucursal): acá no hay combos.
vi.mock('../../hooks/queries/useCombosQuery', () => ({
  useCombosVigentesQuery: () => ({ data: [], isLoading: false }),
  useFotosCombosPedidoQuery: () => ({ data: [] }),
  useNombresCombosQuery: () => ({ data: new Map() }),
}))

vi.mock('../../hooks/queries/useGruposPrecioQuery', () => ({
  usePricingMapQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/usePromocionesQuery', () => ({
  usePromoMapQuery: () => ({ data: new Map(), isLoading: false }),
}))
vi.mock('../../hooks/queries/useProductosQuery', () => ({
  useMinimosVentaQuery: () => ({ data: new Map(), isLoading: false }),
}))

vi.mock('../../utils/formatters', async (importOriginal) => ({
  ...(await importOriginal()),
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

  // #1274: en prod todo es gravado al 21, así que un caso al 21 no prueba nada.
  it('la alícuota de cada línea sale de alicuotaIvaVenta, no de `porcentaje_iva ?? 21`', async () => {
    const user = userEvent.setup()
    const onConfirmar = vi.fn()
    const pedidoFC = {
      ...pedido,
      tipo_factura: 'FC',
      items: [
        { producto_id: 1, cantidad: 1, precio_unitario: 1210 },
        { producto_id: 2, cantidad: 1, precio_unitario: 1210 },
        { producto_id: 3, cantidad: 1, precio_unitario: 1210 },
        { producto_id: 4, cantidad: 1, precio_unitario: 1210 },
      ],
    }
    const conCondicion = (id, condicion_iva, porcentaje_iva) =>
      ({ id, nombre: `Producto ${id}`, precio: 1210, stock: 10, categoria: 'X', condicion_iva, porcentaje_iva })
    const fiscales = [
      conCondicion(1, 'exento', null),
      conCondicion(2, 'no_gravado', null),
      conCondicion(3, 'gravado', 10.5),
      conCondicion(4, 'gravado', null),
    ]
    render(
      <ModalCambiarCliente
        {...baseProps}
        pedido={pedidoFC}
        productos={fiscales}
        onConfirmar={onConfirmar}
        onClose={vi.fn()}
      />,
    )

    await user.type(screen.getByPlaceholderText(/Buscar por nombre/i), 'Nuevo')
    await user.click(await screen.findByText('Cliente Nuevo'))
    await user.click(screen.getByRole('button', { name: /Confirmar cambio/i }))

    const { items, totalIva, totalNeto } = onConfirmar.mock.calls[0][0]
    const porProducto = Object.fromEntries(items.map(i => [i.productoId, i]))
    expect(porProducto['1']).toMatchObject({ porcentaje_iva: 0, iva_unitario: 0, neto_unitario: 1210 })
    expect(porProducto['2']).toMatchObject({ porcentaje_iva: 0, iva_unitario: 0, neto_unitario: 1210 })
    expect(porProducto['3'].porcentaje_iva).toBe(10.5)
    expect(porProducto['3'].neto_unitario).toBeCloseTo(1210 / 1.105, 2)
    expect(porProducto['4']).toMatchObject({ porcentaje_iva: 21 })
    expect(porProducto['4'].neto_unitario).toBeCloseTo(1000, 2)
    // Los dos sin IVA no aportan: sólo el 10,5 y el 21.
    expect(totalIva).toBeCloseTo(1210 - 1210 / 1.105 + 210, 2)
    expect(totalNeto + totalIva).toBeCloseTo(4840, 2)
  })

  describe('destino de los pagos (#1248)', () => {
    const pedidoPagado = { ...pedido, monto_pagado: 500 }
    const propsPagado = { ...baseProps, pedido: pedidoPagado }

    async function elegirClienteNuevo(user) {
      await user.type(screen.getByPlaceholderText(/Buscar por nombre/i), 'Nuevo')
      await user.click(await screen.findByText('Cliente Nuevo'))
    }

    it('con pagos, el botón sigue deshabilitado tras elegir cliente hasta marcar un radio', async () => {
      const user = userEvent.setup()
      const onConfirmar = vi.fn()
      render(<ModalCambiarCliente {...propsPagado} onConfirmar={onConfirmar} onClose={vi.fn()} />)

      await elegirClienteNuevo(user)

      const confirmar = screen.getByRole('button', { name: /Confirmar cambio/i })
      expect(confirmar).toBeDisabled()

      await user.click(screen.getByRole('radio', { name: /Fue un error de carga/i }))
      expect(confirmar).toBeEnabled()
    })

    it('el payload lleva el destino elegido: cliente_original o pedido_nuevo', async () => {
      const user = userEvent.setup()
      const onConfirmar = vi.fn()
      render(<ModalCambiarCliente {...propsPagado} onConfirmar={onConfirmar} onClose={vi.fn()} />)

      await elegirClienteNuevo(user)
      await user.click(screen.getByRole('radio', { name: /El cliente no tomó el pedido/i }))
      await user.click(screen.getByRole('button', { name: /Confirmar cambio/i }))
      expect(onConfirmar.mock.calls[0][0].destinoPagos).toBe('cliente_original')

      await user.click(screen.getByRole('radio', { name: /Fue un error de carga/i }))
      await user.click(screen.getByRole('button', { name: /Confirmar cambio/i }))
      expect(onConfirmar.mock.calls[1][0].destinoPagos).toBe('pedido_nuevo')
    })

    it('sin pagos no hay fieldset y el payload no tiene la clave destinoPagos', async () => {
      const user = userEvent.setup()
      const onConfirmar = vi.fn()
      const { container } = render(
        <ModalCambiarCliente {...baseProps} onConfirmar={onConfirmar} onClose={vi.fn()} />,
      )

      expect(container.querySelector('fieldset')).toBeNull()
      expect(screen.queryByRole('radio')).toBeNull()

      await elegirClienteNuevo(user)
      await user.click(screen.getByRole('button', { name: /Confirmar cambio/i }))

      expect(onConfirmar).toHaveBeenCalledTimes(1)
      expect(onConfirmar.mock.calls[0][0]).not.toHaveProperty('destinoPagos')
    })

    it('#1489: lo que vino del saldo a favor se avisa aparte y la pregunta es sólo por el cobro', () => {
      const pedidoMixto = {
        ...pedido,
        monto_pagado: 500,
        pagos: [
          { forma_pago: 'efectivo', monto: 400, de_saldo_a_favor: true },
          { forma_pago: 'efectivo', monto: 100, de_saldo_a_favor: false },
        ],
      }
      render(<ModalCambiarCliente {...baseProps} pedido={pedidoMixto} onConfirmar={vi.fn()} onClose={vi.fn()} />)

      expect(screen.getByText(/vinieron del saldo a favor o de un pago a cuenta/i).textContent).toMatch(/400/)
      expect(screen.getByText(/¿Qué pasa con ese pago\?/i).textContent).toMatch(/100/)
      expect(screen.getByText(/¿Qué pasa con ese pago\?/i).textContent).not.toMatch(/500/)
    })

    it('#1489: si todo vino del saldo a favor o de un pago a cuenta, no hay nada que elegir', async () => {
      const user = userEvent.setup()
      const onConfirmar = vi.fn()
      const pedidoSoloSaldo = {
        ...pedido,
        monto_pagado: 500,
        pagos: [
          { forma_pago: 'efectivo', monto: 300, de_saldo_a_favor: true },
          { forma_pago: 'efectivo', monto: 200, a_cuenta: true },
        ],
      }
      const { container } = render(
        <ModalCambiarCliente {...baseProps} pedido={pedidoSoloSaldo} onConfirmar={onConfirmar} onClose={vi.fn()} />,
      )

      expect(container.querySelector('fieldset')).toBeNull()
      await elegirClienteNuevo(user)
      await user.click(screen.getByRole('button', { name: /Confirmar cambio/i }))
      expect(onConfirmar).toHaveBeenCalledTimes(1)
      expect(onConfirmar.mock.calls[0][0]).not.toHaveProperty('destinoPagos')
    })
  })
})
