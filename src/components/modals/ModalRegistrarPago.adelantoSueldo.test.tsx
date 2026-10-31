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
import { render, screen, within, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

vi.mock('../../hooks/queries/useUltimaFechaCajaCerradaQuery', () => ({
  useFechaMinimaPago: () => undefined,
}))

import ModalRegistrarPago, { modalPagoSchema } from './ModalRegistrarPago'
import type { ClienteDB, Pedido } from '../../types'

const cliente = { id: '1', nombre_fantasia: 'Empleado Pérez' } as unknown as ClienteDB

const AVISO_NO_EMPLEADO =
  'Este cliente no es la ficha de un empleado: el adelanto de sueldo no se le puede descontar. Vinculá la ficha desde Personal o elegí otra forma de pago.'
const AVISO_COMPROBANDO = 'Comprobando si es la ficha de un empleado…'

const boleta = { id: '5', cliente_id: '1', estado_pago: 'pendiente', total: 1000, monto_pagado: 0 } as unknown as Pedido

function renderModal(
  permitirAdelantoSueldo?: boolean,
  pedidos: Pedido[] = [],
  onConfirmar: () => Promise<never> = async () => ({}) as never,
  clienteEsEmpleado?: boolean | null,
) {
  return render(
    <ModalRegistrarPago
      cliente={cliente}
      saldoPendiente={1000}
      pedidos={pedidos}
      onClose={() => {}}
      onConfirmar={onConfirmar}
      permitirAdelantoSueldo={permitirAdelantoSueldo}
      clienteEsEmpleado={clienteEsEmpleado}
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

  describe('aviso según si el cliente es la ficha de un empleado', () => {
    const botonRegistrar = () => screen.getByRole('button', { name: 'Registrar' }) as HTMLButtonElement

    it('adelanto con un cliente que no es empleado: avisa y no deja confirmar', async () => {
      const user = userEvent.setup()
      const onConfirmar = vi.fn(async () => ({ monto: 1000 }) as never)
      renderModal(true, [], onConfirmar, false)
      expect(screen.queryByRole('alert')).toBeNull()

      await user.click(screen.getByText('Adelanto de sueldo'))
      await user.click(screen.getByRole('button', { name: 'Total' }))

      expect(within(screen.getByRole('alert')).getByText(AVISO_NO_EMPLEADO)).toBeTruthy()
      expect(botonRegistrar().disabled).toBe(true)

      // Aunque algo fuerce el submit, handleSubmit corta con el mismo texto.
      fireEvent.submit(botonRegistrar().closest('form') as HTMLFormElement)
      expect(onConfirmar).not.toHaveBeenCalled()
      expect(screen.getAllByText(AVISO_NO_EMPLEADO).length).toBeGreaterThan(0)
    })

    it('en el dividido, una línea con adelanto avisa igual', async () => {
      const user = userEvent.setup()
      const onConfirmar = vi.fn(async () => ({ monto: 500 }) as never)
      renderModal(true, [], onConfirmar, false)

      await user.click(screen.getByLabelText(/Pago dividido/))
      const montos = screen.getAllByPlaceholderText('0.00')
      await user.type(montos[0], '500')
      await user.type(montos[1], '500')
      expect(screen.queryByRole('alert')).toBeNull()
      expect(botonRegistrar().disabled).toBe(false)

      await user.selectOptions(screen.getAllByRole('combobox')[1], 'adelanto_sueldo')

      expect(within(screen.getByRole('alert')).getByText(AVISO_NO_EMPLEADO)).toBeTruthy()
      expect(botonRegistrar().disabled).toBe(true)

      fireEvent.submit(botonRegistrar().closest('form') as HTMLFormElement)
      expect(onConfirmar).not.toHaveBeenCalled()
    })

    it('comprobando, no deja confirmar', async () => {
      const user = userEvent.setup()
      renderModal(true, [], undefined, null)
      await user.click(screen.getByText('Adelanto de sueldo'))
      await user.click(screen.getByRole('button', { name: 'Total' }))
      expect(screen.getByText(AVISO_COMPROBANDO)).toBeTruthy()
      expect(screen.queryByText(AVISO_NO_EMPLEADO)).toBeNull()
      expect(botonRegistrar().disabled).toBe(true)
    })

    it('comprobando (sin dato todavía), tampoco deja confirmar', async () => {
      const user = userEvent.setup()
      renderModal(true)
      await user.click(screen.getByText('Adelanto de sueldo'))
      await user.click(screen.getByRole('button', { name: 'Total' }))
      expect(screen.getByText(AVISO_COMPROBANDO)).toBeTruthy()
      expect(botonRegistrar().disabled).toBe(true)
    })

    it('con un empleado, registra como hoy', async () => {
      const user = userEvent.setup()
      const onConfirmar = vi.fn(async () => ({ monto: 1000 }) as never)
      renderModal(true, [], onConfirmar, true)

      await user.click(screen.getByText('Adelanto de sueldo'))
      await user.click(screen.getByRole('button', { name: 'Total' }))

      expect(screen.queryByRole('alert')).toBeNull()
      expect(screen.queryByText(AVISO_COMPROBANDO)).toBeNull()
      expect(botonRegistrar().disabled).toBe(false)

      await user.click(botonRegistrar())
      expect(onConfirmar).toHaveBeenCalledTimes(1)
      expect(onConfirmar).toHaveBeenCalledWith(expect.objectContaining({ formaPago: 'adelanto_sueldo' }))
    })

    it('efectivo no avisa nada', async () => {
      const user = userEvent.setup()
      for (const esEmpleado of [false, null, undefined]) {
        const { unmount } = renderModal(true, [], undefined, esEmpleado)
        await user.click(screen.getByRole('button', { name: 'Total' }))
        expect(screen.queryByRole('alert')).toBeNull()
        expect(screen.queryByText(AVISO_COMPROBANDO)).toBeNull()
        expect(botonRegistrar().disabled).toBe(false)
        unmount()
      }
    })

    it('si se elige una boleta, el adelanto vuelve a efectivo y el aviso se va', async () => {
      const user = userEvent.setup()
      renderModal(true, [boleta], undefined, false)
      await user.click(screen.getByText('Adelanto de sueldo'))
      expect(screen.getByRole('alert')).toBeTruthy()

      await user.selectOptions(screen.getByRole('combobox'), '5')
      expect(screen.queryByRole('alert')).toBeNull()
    })
  })
})
