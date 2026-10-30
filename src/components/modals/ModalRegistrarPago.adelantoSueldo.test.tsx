/**
 * #832 — "Adelanto de sueldo" en ModalRegistrarPago.
 * Se ofrece SOLO cuando el caller es la ficha del cliente (`permitirAdelantoSueldo`);
 * cuenta_corriente sigue sin ofrecerse. El schema acepta adelanto_sueldo.
 *
 * #1293: con una boleta elegida no se ofrece. Esa boleta se cobra por
 * `registrar_pagos_pedido`, que sólo toma plata; el adelanto va a cuenta, por el
 * FIFO de la ficha.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalRegistrarPago, { modalPagoSchema } from './ModalRegistrarPago'
import type { ClienteDB, Pedido } from '../../types'

const cliente = { id: '1', nombre_fantasia: 'Empleado Pérez' } as unknown as ClienteDB

const boleta = { id: '5', cliente_id: '1', estado_pago: 'pendiente', total: 1000, monto_pagado: 0 } as unknown as Pedido

function renderModal(
  permitirAdelantoSueldo?: boolean,
  pedidos: Pedido[] = [],
  onConfirmar: () => Promise<never> = async () => ({}) as never,
) {
  return render(
    <ModalRegistrarPago
      cliente={cliente}
      saldoPendiente={1000}
      pedidos={pedidos}
      onClose={() => {}}
      onConfirmar={onConfirmar}
      permitirAdelantoSueldo={permitirAdelantoSueldo}
    />,
  )
}

describe('ModalRegistrarPago · adelanto de sueldo', () => {
  it('no se ofrece por defecto', () => {
    renderModal()
    expect(screen.queryByText('Adelanto de sueldo')).toBeNull()
    expect(screen.getByText('Efectivo')).toBeTruthy()
  })

  it('se ofrece desde la ficha (permitirAdelantoSueldo) y cuenta_corriente no', () => {
    renderModal(true)
    expect(screen.getByText('Adelanto de sueldo')).toBeTruthy()
    expect(screen.queryByText('Cuenta corriente')).toBeNull()
  })

  it('el schema ya no acepta vale_blanco (ahora es un comprobante, no una forma de pago)', () => {
    const r = modalPagoSchema.safeParse({ monto: 500, formaPago: 'vale_blanco' })
    expect(r.success).toBe(false)
  })

  it('con una boleta elegida deja de ofrecerse, y vuelve a cuenta general', async () => {
    const user = userEvent.setup()
    renderModal(true, [boleta])
    expect(screen.getByText('Adelanto de sueldo')).toBeTruthy()

    await user.selectOptions(screen.getByRole('combobox'), '5')
    expect(screen.queryByText('Adelanto de sueldo')).toBeNull()

    await user.selectOptions(screen.getByRole('combobox'), '')
    expect(screen.getByText('Adelanto de sueldo')).toBeTruthy()
  })

  it('si estaba elegido y se elige una boleta, la boleta se cobra en efectivo', async () => {
    const user = userEvent.setup()
    const onConfirmar = vi.fn(async () => ({ monto: 1000 }) as never)
    renderModal(true, [boleta], onConfirmar)

    await user.click(screen.getByText('Adelanto de sueldo'))
    await user.selectOptions(screen.getByRole('combobox'), '5')
    await user.click(screen.getByRole('button', { name: 'Total' }))
    await user.click(screen.getByRole('button', { name: 'Registrar' }))

    expect(onConfirmar).toHaveBeenCalledTimes(1)
    expect(onConfirmar).toHaveBeenCalledWith(expect.objectContaining({ pedidoId: '5', formaPago: 'efectivo' }))
  })

  it('el schema acepta adelanto_sueldo', () => {
    const r = modalPagoSchema.safeParse({ monto: 500, formaPago: 'adelanto_sueldo' })
    expect(r.success).toBe(true)
  })
})
