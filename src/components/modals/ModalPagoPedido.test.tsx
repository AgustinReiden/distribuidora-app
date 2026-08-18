/**
 * Tests de `ModalPagoPedido` — la acción que se le ofrece al chofer.
 *
 * El botón de abajo cierra dos situaciones distintas con el mismo handler:
 * entregar fiado, o confirmar la entrega de un pedido ya cobrado. El texto es
 * lo único que las separa, y equivocarlo tiene costo real: en Taco Pozo el
 * chofer cobraba en la mano, el modal le ofrecía "Entregar a cuenta corriente
 * (sin cobrar)", y cancelaba — la parada le quedaba sin entregar.
 *
 * La regla: si no queda saldo, nunca se nombra la cuenta corriente.
 */
import React from 'react'
import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'

/** Primer día con la caja abierta. `undefined` = ninguna rendición cerrada. */
let fechaMinimaMock: string | undefined
vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => fechaMinimaMock,
}))

import ModalPagoPedido from './ModalPagoPedido'
import type { PedidoDB, PagoDBWithUsuario } from '../../types'

const pedido = { id: '4625', cliente_id: '1', total: 21600 } as unknown as PedidoDB

const pagoDe = (monto: number, fecha = '2026-08-08'): PagoDBWithUsuario =>
  ({ id: '1', monto, forma_pago: 'efectivo', fecha }) as unknown as PagoDBWithUsuario

function renderModal(pagosPrevios: PagoDBWithUsuario[], loadingPagosPrevios?: boolean) {
  return render(
    <ModalPagoPedido
      pedido={pedido}
      pagosPrevios={pagosPrevios}
      loadingPagosPrevios={loadingPagosPrevios}
      onConfirmar={vi.fn()}
      modoEntregaTransportista
      onEntregarSinPago={vi.fn()}
      onClose={vi.fn()}
      guardando={false}
    />,
  )
}

/**
 * El input de monto de la primera línea de cobro.
 *
 * Es un `NumberInput` que renderiza `Number(monto) || 0`, así que el valor que
 * se lee del DOM viene normalizado: `''` se ve como `"0"` y `"11600.00"` como
 * `"11600"`.
 */
const inputMonto = (): HTMLInputElement =>
  screen.getAllByPlaceholderText(/0[.,]00/i)[0] as HTMLInputElement

describe('ModalPagoPedido — botón de entrega del chofer', () => {
  it('con saldo pendiente ofrece la cuenta corriente', () => {
    renderModal([])

    expect(screen.getByRole('button', { name: /cuenta corriente \(sin cobrar\)/i })).toBeTruthy()
    expect(screen.queryByRole('button', { name: /^confirmar entrega$/i })).toBeNull()
  })

  it('sin saldo dice "Confirmar entrega" y NO nombra la cuenta corriente', () => {
    renderModal([pagoDe(21600)])

    expect(screen.getByRole('button', { name: /^confirmar entrega$/i })).toBeTruthy()
    // Lo que hacía cancelar al chofer que ya tenía la plata en la mano.
    expect(screen.queryByRole('button', { name: /cuenta corriente/i })).toBeNull()
  })

  it('cobro parcial sigue siendo cuenta corriente: queda saldo en la calle', () => {
    renderModal([pagoDe(10000)])

    expect(screen.getByRole('button', { name: /cuenta corriente \(sin cobrar\)/i })).toBeTruthy()
  })

  it('un sobrepago no reabre la cuenta corriente', () => {
    renderModal([pagoDe(25000)])

    expect(screen.getByRole('button', { name: /^confirmar entrega$/i })).toBeTruthy()
  })
})

/**
 * El monto prellenado y la carrera de montaje.
 *
 * EL INCIDENTE
 * ------------
 * En un pedido con pago parcial el modal se abría pidiendo el TOTAL, en rojo
 * ("Excede el saldo pendiente") y con el botón muerto: había que borrar y
 * retipear el saldo a mano. En el mostrador se lee como "la app no me deja
 * cobrar".
 *
 * La causa no era el cálculo del saldo —que está bien— sino el orden: el
 * container hace `setPagosPreviosPedido([])` y recién DESPUÉS `await
 * refreshPagosPedido(...)`, así que el modal monta con `pagosPrevios = []` y en
 * ese instante `saldoPendiente === total`. El initializer de `useState` congela
 * ese valor, y el efecto que lo corrige sólo pisa montos vacíos o en 0 — el
 * total no lo está.
 */
describe('ModalPagoPedido — monto sugerido', () => {
  it('mientras cargan los pagos previos NO prellena el total', () => {
    // Lo que ve el modal en el primer render: sin pagos y cargando. Antes acá
    // quedaba clavado el total ($21.600).
    renderModal([], true)

    expect(inputMonto().value).toBe('0')
  })

  it('con los pagos resueltos sugiere el SALDO, no el total — el caso del incidente', async () => {
    const { rerender } = renderModal([], true)

    // Llegan los pagos previos: $10.000 de $21.600.
    rerender(
      <ModalPagoPedido
        pedido={pedido}
        pagosPrevios={[pagoDe(10000)]}
        loadingPagosPrevios={false}
        onConfirmar={vi.fn()}
        modoEntregaTransportista
        onEntregarSinPago={vi.fn()}
        onClose={vi.fn()}
        guardando={false}
      />,
    )

    // El saldo (21.600 - 10.000), no el total. Ese era el bug.
    await waitFor(() => expect(inputMonto().value).toBe('11600'))
    // Y por lo tanto el botón de cobrar queda usable, sin retipear nada.
    expect(screen.queryByText(/excede el saldo pendiente/i)).toBeNull()
  })

  it('sin pagos previos sugiere el total entero', async () => {
    renderModal([], false)
    await waitFor(() => expect(inputMonto().value).toBe('21600'))
  })
})

/**
 * Anular un pago de una caja cerrada.
 *
 * EL INCIDENTE: `eliminarPago` era un DELETE pelado. Ya existía un guard para
 * INSERT/UPDATE de pagos con fecha cerrada (mig 165), pero el DELETE quedaba
 * libre: se vació plata de rendiciones ya confirmadas 15 veces, por $936.100.
 * La mig 181 lo rechaza en la base; acá el botón se apaga para que el admin vea
 * por qué en vez de comerse un error crudo de Postgres.
 */
describe('ModalPagoPedido — anular pago', () => {
  afterEach(() => { fechaMinimaMock = undefined })

  const renderConAnular = (pago: PagoDBWithUsuario) => {
    const onAnularPago = vi.fn()
    render(
      <ModalPagoPedido
        pedido={pedido}
        pagosPrevios={[pago]}
        onConfirmar={vi.fn()}
        onAnularPago={onAnularPago}
        onClose={vi.fn()}
        guardando={false}
      />,
    )
    return onAnularPago
  }

  it('con la caja abierta se puede anular', () => {
    fechaMinimaMock = '2026-08-01'
    const onAnularPago = renderConAnular(pagoDe(5000, '2026-08-08'))

    const boton = screen.getByRole('button', { name: /anular pago/i }) as HTMLButtonElement
    expect(boton.disabled).toBe(false)
    boton.click()
    expect(onAnularPago).toHaveBeenCalledWith('1')
  })

  it('con la caja cerrada el botón queda apagado y no llama al handler', () => {
    // La caja está cerrada hasta el 09/08; el pago es del 08.
    fechaMinimaMock = '2026-08-10'
    const onAnularPago = renderConAnular(pagoDe(5000, '2026-08-08'))

    const boton = screen.getByRole('button', { name: /anular pago/i }) as HTMLButtonElement
    expect(boton.disabled).toBe(true)
    boton.click()
    expect(onAnularPago).not.toHaveBeenCalled()
  })

  it('explica por qué no se puede, en vez de apagarse en silencio', () => {
    fechaMinimaMock = '2026-08-10'
    renderConAnular(pagoDe(5000, '2026-08-08'))

    expect(
      screen.getByRole('button', { name: /anular pago/i }).getAttribute('title'),
    ).toMatch(/caja de ese día ya está cerrada/i)
  })

  it('sin ninguna rendición cerrada no bloquea nada', () => {
    fechaMinimaMock = undefined
    const onAnularPago = renderConAnular(pagoDe(5000, '2026-03-01'))

    expect((screen.getByRole('button', { name: /anular pago/i }) as HTMLButtonElement).disabled).toBe(false)
    screen.getByRole('button', { name: /anular pago/i }).click()
    expect(onAnularPago).toHaveBeenCalled()
  })
})
