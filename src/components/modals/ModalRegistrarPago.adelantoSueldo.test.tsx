/**
 * #832 — "Adelanto de sueldo" en ModalRegistrarPago.
 * Se ofrece SOLO cuando el caller es la ficha del cliente (`permitirAdelantoSueldo`);
 * vale_blanco y cuenta_corriente siguen sin ofrecerse. El schema lo acepta.
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

  it('se ofrece desde la ficha (permitirAdelantoSueldo) y vale_blanco no', () => {
    renderModal(true)
    expect(screen.getByText('Adelanto de sueldo')).toBeTruthy()
    expect(screen.queryByText('Vale Blanco')).toBeNull()
  })

  it('el schema acepta adelanto_sueldo', () => {
    const r = modalPagoSchema.safeParse({ monto: 500, formaPago: 'adelanto_sueldo' })
    expect(r.success).toBe(true)
  })
})
