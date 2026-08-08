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
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalPagoPedido from './ModalPagoPedido'
import type { PedidoDB, PagoDBWithUsuario } from '../../types'

const pedido = { id: '4625', cliente_id: '1', total: 21600 } as unknown as PedidoDB

const pagoDe = (monto: number): PagoDBWithUsuario =>
  ({ id: '1', monto, forma_pago: 'efectivo', fecha: '2026-08-08' }) as unknown as PagoDBWithUsuario

function renderModal(pagosPrevios: PagoDBWithUsuario[]) {
  return render(
    <ModalPagoPedido
      pedido={pedido}
      pagosPrevios={pagosPrevios}
      onConfirmar={vi.fn()}
      modoEntregaTransportista
      onEntregarSinPago={vi.fn()}
      onClose={vi.fn()}
      guardando={false}
    />,
  )
}

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
