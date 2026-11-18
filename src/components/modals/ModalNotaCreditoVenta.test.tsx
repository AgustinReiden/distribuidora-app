/**
 * #833 — ModalNotaCreditoVenta: la leyenda de comisión, el total en vivo, lo ya
 * acreditado y el payload que llega a la RPC (precio del pedido, ids numéricos,
 * sólo líneas con cantidad, sin regalos), y el paso final tras emitir: ofrecer
 * imputar el crédito a otro pedido (nunca al de origen) o dejarlo a favor.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'

const mutateAsync = vi.fn()
let notasPedido: unknown[] = []

vi.mock('../../hooks/queries/useNotasCreditoVentaQuery', () => ({
  useNotasCreditoVentaPedidoQuery: () => ({ data: notasPedido, isLoading: false }),
  useCrearNotaCreditoVentaMutation: () => ({ mutateAsync, isPending: false }),
}))
const imputarMutate = vi.fn()
let pedidosCliente: unknown[] = []
vi.mock('../../hooks/queries/useImputarCreditoQuery', () => ({
  usePedidosParaImputarQuery: () => ({ data: pedidosCliente, isLoading: false, error: null }),
  usePedidoOrigenNCQuery: () => ({ data: undefined, isLoading: false }),
  useImputarCreditoMutation: () => ({ mutateAsync: imputarMutate, isPending: false }),
}))
vi.mock('../../contexts/NotificationContext', () => ({
  useNotification: () => ({ success: vi.fn(), error: vi.fn() }),
}))

import ModalNotaCreditoVenta, { descuentoNCVentaSchema, notaCreditoVentaSchema } from './ModalNotaCreditoVenta'
import type { PedidoDB } from '../../types'

// B22 (H1 de la revisión): el motivo no viene elegido; sin él no se emite.
function elegirMotivo(valor: string) {
  fireEvent.change(screen.getByRole('combobox'), { target: { value: valor } })
}

const pedido = {
  id: '6510',
  cliente_id: '858',
  estado: 'entregado',
  cliente: { nombre_fantasia: 'Kiosco' },
  items: [
    { id: '23807', producto_id: '10', cantidad: 1, precio_unitario: 11100, producto: { nombre: 'Fideos' } },
    { id: '23808', producto_id: '11', cantidad: 2, precio_unitario: 5600, producto: { nombre: 'Arroz' } },
    { id: '23811', producto_id: '12', cantidad: 2, precio_unitario: 0, es_bonificacion: true, producto: { nombre: 'Regalo' } },
  ],
} as unknown as PedidoDB

describe('ModalNotaCreditoVenta', () => {
  beforeEach(() => {
    mutateAsync.mockReset()
    mutateAsync.mockResolvedValue({ nota_credito_id: 1, pago_id: 901, total: 16700 })
    notasPedido = []
    imputarMutate.mockReset()
    pedidosCliente = []
  })

  // Cambió de regla (B16, decisiones del dueño del 16/11 y del 17/11): la nota se
  // imputa al mes de la boleta y le descuenta o no al vendedor según el motivo;
  // antes decía que no afectaba la comisión.
  it('muestra la leyenda de comisión y no ofrece los regalos', () => {
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    expect(screen.getByText('Se imputa al mes de la boleta. Según el motivo, le descuenta o no al vendedor')).toBeInTheDocument()
    expect(screen.queryByText(/No afecta la comisión/)).toBeNull()
    expect(screen.queryByText('Regalo')).toBeNull()
  })

  // B16 v3: al elegir el motivo, el modal dice si le descuenta al vendedor.
  it('dice, según el motivo, si la nota le descuenta al vendedor', () => {
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    const motivo = screen.getByRole('combobox')
    fireEvent.change(motivo, { target: { value: 'otro' } })
    expect(screen.getByText('Este motivo no le descuenta nada al vendedor.')).toBeInTheDocument()
    fireEvent.change(motivo, { target: { value: 'cliente_rechaza' } })
    expect(screen.getByText(/le descuenta al vendedor la plata y las unidades/)).toBeInTheDocument()
    fireEvent.change(motivo, { target: { value: 'descuento_comercial' } })
    expect(screen.getByText(/le descuenta al vendedor la plata \(no las unidades\)/)).toBeInTheDocument()
  })

  // Antes de la imputación elegida el modal se cerraba al emitir. Ahora queda
  // abierto en un paso final (imputar ya o dejar a favor), así que este test
  // fija que NO cierra solo y que «Dejar como saldo a favor» es lo que cierra.
  // B22 (H1): con un motivo que mueve mercadería, cada renglón la pide al server, y antes de
  // emitir el modal dice cuántas unidades van a merma.
  it('manda a la RPC sólo las líneas elegidas y pasa al paso final', async () => {
    const onClose = vi.fn()
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={onClose} />)
    elegirMotivo('producto_vencido')
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Fideos'), { target: { value: '1' } })
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Arroz'), { target: { value: '1' } })
    expect(screen.getByText(/16\.700/)).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Van a merma 2 u.')
    fireEvent.click(screen.getByRole('button', { name: /Emitir nota de crédito/ }))
    await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
    const arg = mutateAsync.mock.calls[0][0]
    expect(arg).toMatchObject({
      pedidoId: '6510',
      clienteId: '858',
      motivo: 'producto_vencido',
      items: [
        { pedido_item_id: 23807, cantidad: 1, mercaderia: true },
        { pedido_item_id: 23808, cantidad: 1, mercaderia: true },
      ],
    })
    expect(typeof arg.clientRequestId).toBe('string')
    expect(await screen.findByText(/emitido \(nota de crédito #1\)/)).toBeInTheDocument()
    expect(screen.getByText('¿Imputar lo que quedó a favor ahora a un pedido?')).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
    fireEvent.click(screen.getByRole('button', { name: 'Dejar como saldo a favor' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  // COB-1 (mig 479): el crédito baja primero este pedido y lo que sobra va FIFO a las otras
  // boletas. El modal cuenta adónde fue, sólo con las líneas que no son 0.
  async function emitir16700() {
    elegirMotivo('otro')
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Fideos'), { target: { value: '1' } })
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Arroz'), { target: { value: '1' } })
    fireEvent.click(screen.getByRole('button', { name: /Emitir nota de crédito/ }))
  }

  it('dice cuánto se aplicó a este pedido, cuánto a otras boletas y cuánto quedó a favor', async () => {
    mutateAsync.mockResolvedValue({
      nota_credito_id: 1, pago_id: 901, total: 16700,
      credito_aplicado_pedido: 10000, credito_aplicado_otras: 4000, credito_disponible: 2700,
    })
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    await emitir16700()

    expect(await screen.findByText(/Se aplicaron .*10\.000.* a este pedido/)).toBeInTheDocument()
    expect(screen.getByText(/4\.000.* a otras boletas del cliente/)).toBeInTheDocument()
    expect(screen.getByText(/Quedan .*2\.700.* de saldo a favor/)).toBeInTheDocument()
    // Quedó algo suelto: se ofrece imputarlo.
    expect(screen.getByRole('button', { name: 'Imputar a un pedido' })).toBeInTheDocument()
  })

  it('si todo se aplicó no hay saldo suelto: no ofrece imputar y sólo deja cerrar', async () => {
    mutateAsync.mockResolvedValue({
      nota_credito_id: 1, pago_id: 901, total: 16700,
      credito_aplicado_pedido: 16700, credito_aplicado_otras: 0, credito_disponible: 0,
    })
    const onClose = vi.fn()
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={onClose} />)
    await emitir16700()

    expect(await screen.findByText(/Se aplicaron .*16\.700.* a este pedido/)).toBeInTheDocument()
    expect(screen.queryByText(/otras boletas del cliente/)).toBeNull()
    expect(screen.queryByText(/de saldo a favor/)).toBeNull()
    expect(screen.queryByRole('button', { name: 'Imputar a un pedido' })).toBeNull()
    expect(screen.queryByRole('button', { name: 'Dejar como saldo a favor' })).toBeNull()
    // «Cerrar» está también en la X del modal: el del pie es el último.
    const cerrar = screen.getAllByRole('button', { name: 'Cerrar' })
    fireEvent.click(cerrar[cerrar.length - 1])
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('«Imputar a un pedido» muestra la imputación inline, sin el pedido de origen', async () => {
    pedidosCliente = [
      { id: 6510, fecha: '2026-09-01', total: 50000, monto_pagado: 0, estado: 'entregado' },
      { id: 7001, fecha: '2026-09-20', total: 12000, monto_pagado: 2000, estado: 'entregado' },
    ]
    imputarMutate.mockResolvedValue({ pagoId: '901', pedidoId: '7001', montoImputado: 10000, restoAFavor: 6700, pagoRestoId: '902', idempotentReplay: false })
    const onClose = vi.fn()
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={onClose} />)
    elegirMotivo('otro')
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Fideos'), { target: { value: '1' } })
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Arroz'), { target: { value: '1' } })
    fireEvent.click(screen.getByRole('button', { name: /Emitir nota de crédito/ }))
    fireEvent.click(await screen.findByRole('button', { name: 'Imputar a un pedido' }))

    expect(await screen.findByRole('option', { name: /^Pedido #7001 / })).toBeInTheDocument()
    expect(screen.queryByRole('option', { name: /^Pedido #6510 / })).toBeNull()
    expect(screen.queryByText(/ya no se puede anular/)).toBeNull()

    fireEvent.click(screen.getByRole('button', { name: /^Imputar$/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Sí, imputar' }))
    await waitFor(() => expect(imputarMutate).toHaveBeenCalledTimes(1))
    expect(imputarMutate.mock.calls[0][0]).toMatchObject({ pagoId: '901', pedidoId: '7001', monto: 10000 })
    await waitFor(() => expect(onClose).toHaveBeenCalled())
  })

  it('el título y el pie dicen qué se emite y adónde va el crédito', () => {
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    expect(screen.getByText('Nota de crédito de venta')).toBeInTheDocument()
    expect(screen.getByText('Total a acreditar:', { exact: false })).toBeInTheDocument()
    expect(screen.getByText('Pedido de origen #6510 · el crédito se aplica a las boletas abiertas del cliente')).toBeInTheDocument()
  })

  it('descuenta lo acreditado en NCs vigentes del mismo pedido', () => {
    notasPedido = [{ id: '1', fecha: '2026-09-29', anulada: false, items: [{ pedido_item_id: '23807', cantidad: 1 }] }]
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    expect(screen.getByLabelText('Cantidad a acreditar de Fideos')).toBeDisabled()
    expect(screen.getByText('1 ya acreditado')).toBeInTheDocument()
  })

  it('el schema co-locado acepta los motivos de la tabla', () => {
    expect(notaCreditoVentaSchema.safeParse({ motivo: 'producto_vencido' }).success).toBe(true)
    expect(notaCreditoVentaSchema.safeParse({ motivo: 'devolucion' }).success).toBe(false)
    expect(descuentoNCVentaSchema.safeParse({ modo: 'boleta', total: 100 }).success).toBe(true)
    expect(descuentoNCVentaSchema.safeParse({ modo: 'boleta', total: 0 }).success).toBe(false)
  })

  // B22 (17/11): según el motivo, la mercadería reingresa, queda como merma o no se mueve.
  // Cambió de regla (H1 de la revisión, 18/11): el motivo ya no viene puesto («Producto vencido»
  // movía stock sin que nadie lo eligiera) y, antes de emitir, el modal dice qué pasa con las
  // unidades elegidas.
  it('dice qué pasa con la mercadería según el motivo, con las unidades, antes de emitir', () => {
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    expect(screen.getByRole('combobox')).toHaveValue('')
    expect(screen.queryByText(/quedan como merma/)).toBeNull()
    expect(screen.queryByRole('status')).toBeNull()
    elegirMotivo('producto_vencido')
    expect(screen.getByText(/quedan como merma/)).toBeInTheDocument()
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Arroz'), { target: { value: '2' } })
    expect(screen.getByRole('status')).toHaveTextContent('Van a merma 2 u.')
    elegirMotivo('cliente_rechaza')
    expect(screen.getByText('Las unidades vuelven al stock, al lote del que salieron.')).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('Vuelven al stock 2 u.')
    elegirMotivo('otro')
    expect(screen.getByText('No se mueve mercadería.')).toBeInTheDocument()
    expect(screen.getByRole('status')).toHaveTextContent('No mueve stock')
  })

  it('sin motivo no se emite', () => {
    render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
    fireEvent.change(screen.getByLabelText('Cantidad a acreditar de Fideos'), { target: { value: '1' } })
    expect(screen.getByRole('button', { name: /Emitir nota de crédito/ })).toBeDisabled()
    elegirMotivo('otro')
    expect(screen.getByRole('button', { name: /Emitir nota de crédito/ })).toBeEnabled()
  })

  // B22 (18/11): el descuento comercial va por monto, sin unidades, sobre toda la boleta
  // (prorrateado) por defecto.
  describe('descuento comercial por monto', () => {
    // Fideos 1 × 11.100 y Arroz 2 × 5.600: le quedan 22.300 a la boleta.
    function elegirDescuento() {
      render(<ModalNotaCreditoVenta pedido={pedido} onClose={() => {}} />)
      fireEvent.change(screen.getByRole('combobox'), { target: { value: 'descuento_comercial' } })
    }

    it('cambia la carga: monto sobre toda la boleta, sin cantidades, y dice cuánto queda', () => {
      elegirDescuento()
      expect(screen.queryByLabelText('Cantidad a acreditar de Fideos')).toBeNull()
      expect(screen.getByLabelText('Sobre toda la boleta')).toBeChecked()
      expect(screen.getByText(/Queda por acreditar de la boleta/)).toHaveTextContent(/22\.300/)
      expect(screen.getByRole('status')).toHaveTextContent('No mueve stock')
    })

    it('muestra cómo se reparte y manda un solo monto a la RPC', async () => {
      elegirDescuento()
      fireEvent.change(screen.getByLabelText('Monto del descuento'), { target: { value: '1000' } })
      // 1.000 × 11.100 / 22.300 = 497,76; el resto (502,24) a Arroz, que pesa más.
      expect(screen.getByText('Cómo se reparte')).toBeInTheDocument()
      expect(screen.getByText(/497,76/)).toBeInTheDocument()
      expect(screen.getByText(/502,24/)).toBeInTheDocument()
      fireEvent.click(screen.getByRole('button', { name: /Emitir nota de crédito/ }))
      await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
      expect(mutateAsync.mock.calls[0][0]).toMatchObject({ motivo: 'descuento_comercial', items: [{ monto: 1000 }] })
    })

    it('un porcentaje se convierte a plata y la pantalla lo muestra', async () => {
      elegirDescuento()
      fireEvent.click(screen.getByLabelText('%'))
      fireEvent.change(screen.getByLabelText('Porcentaje del descuento'), { target: { value: '10' } })
      // D6 de la revisión: con sus números, sobre qué se calcula.
      expect(screen.getByText(/^10 % de .*22\.300,00 que quedan por acreditar = .*2\.230,00$/)).toBeInTheDocument()
      fireEvent.click(screen.getByRole('button', { name: /Emitir nota de crédito/ }))
      await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
      expect(mutateAsync.mock.calls[0][0].items).toEqual([{ monto: 2230 }])
    })

    // H8 de la revisión: lo que pasa lo que queda va en rojo con su motivo y no se emite; no se
    // recorta en silencio al máximo.
    it('no deja pasar lo que le queda a la boleta: en rojo, con lo que queda', () => {
      elegirDescuento()
      fireEvent.change(screen.getByLabelText('Monto del descuento'), { target: { value: '22300,01' } })
      expect(screen.getByLabelText('Monto del descuento')).toHaveValue('22.300,01')
      expect(screen.getByText(/Quedan .*22\.300,00 por acreditar/)).toBeInTheDocument()
      expect(screen.getByRole('button', { name: /Emitir nota de crédito/ })).toBeDisabled()
      fireEvent.click(screen.getByRole('button', { name: /Emitir nota de crédito/ }))
      expect(mutateAsync).not.toHaveBeenCalled()
      // Todo lo que queda, entero, entra.
      fireEvent.change(screen.getByLabelText('Monto del descuento'), { target: { value: '22300' } })
      expect(screen.queryByText(/por acreditar$/)).toBeNull()
      expect(screen.getByRole('button', { name: /Emitir nota de crédito/ })).toBeEnabled()
    })

    it('un porcentaje de más de 100 va en rojo', () => {
      elegirDescuento()
      fireEvent.click(screen.getByLabelText('%'))
      fireEvent.change(screen.getByLabelText('Porcentaje del descuento'), { target: { value: '101' } })
      expect(screen.getByText(/Hasta 100 %/)).toBeInTheDocument()
      expect(screen.getByRole('button', { name: /Emitir nota de crédito/ })).toBeDisabled()
    })

    it('en avanzado, más de lo que le queda a un producto va en rojo', () => {
      elegirDescuento()
      fireEvent.click(screen.getByLabelText('Sobre productos (avanzado)'))
      fireEvent.change(screen.getByLabelText('Monto a descontar de Fideos'), { target: { value: '11100,01' } })
      expect(screen.getByText(/Quedan .*11\.100,00 por acreditar/)).toBeInTheDocument()
      expect(screen.getByRole('button', { name: /Emitir nota de crédito/ })).toBeDisabled()
    })

    it('en avanzado manda un monto por producto', async () => {
      elegirDescuento()
      fireEvent.click(screen.getByLabelText('Sobre productos (avanzado)'))
      fireEvent.change(screen.getByLabelText('Monto a descontar de Arroz'), { target: { value: '500' } })
      fireEvent.click(screen.getByRole('button', { name: /Emitir nota de crédito/ }))
      await waitFor(() => expect(mutateAsync).toHaveBeenCalledTimes(1))
      expect(mutateAsync.mock.calls[0][0].items).toEqual([{ pedido_item_id: 23808, monto: 500 }])
    })

    it('lo que ya descontó otra nota no se vuelve a ofrecer', () => {
      notasPedido = [{ id: '1', fecha: '2026-09-29', anulada: false, items: [{ pedido_item_id: '23807', cantidad: 0, subtotal: 11100 }] }]
      elegirDescuento()
      expect(screen.getByText(/Queda por acreditar de la boleta/)).toHaveTextContent(/11\.200/)
    })
  })
})
