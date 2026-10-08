/**
 * #832 — "Adelanto de sueldo" en ModalRegistrarPago.
 * Se ofrece SOLO cuando el caller es la ficha del cliente (`permitirAdelantoSueldo`);
 * cuenta_corriente sigue sin ofrecerse. El schema acepta adelanto_sueldo.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalRegistrarPago, { modalPagoSchema } from './ModalRegistrarPago'
import type { ClienteDB } from '../../types'

const cliente = { id: '1', nombre_fantasia: 'Empleado Pérez' } as unknown as ClienteDB

function renderModal(permitirAdelantoSueldo?: boolean) {
  return render(
    <ModalRegistrarPago
      cliente={cliente}
      saldoPendiente={1000}
      pedidos={[]}
      onClose={() => {}}
      onConfirmar={async () => ({}) as never}
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

  it('el schema acepta adelanto_sueldo', () => {
    const r = modalPagoSchema.safeParse({ monto: 500, formaPago: 'adelanto_sueldo' })
    expect(r.success).toBe(true)
  })
})
