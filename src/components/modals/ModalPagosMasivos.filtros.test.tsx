/**
 * #1698: pagos masivos filtra por fecha de entrega (por defecto) o de pedido, y por forma de pago.
 * Lo que se manda y lo que dice la confirmación es lo tildado Y visible con los filtros puestos.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { fechaLocalISO } from '../../utils/formatters'

const hoy = fechaLocalISO()
const mes = hoy.slice(0, 7)
const cli = (n: string) => ({ nombre_fantasia: n, direccion: 'Calle' })
const pedidos = [
  { id: '1', estado: 'entregado', estado_pago: 'pendiente', total: 100, monto_pagado: 0, fecha: `${mes}-01`, fecha_entrega_programada: `${mes}-10`, forma_pago: 'efectivo', cliente: cli('Kiosco Norte') },
  { id: '2', estado: 'entregado', estado_pago: 'pendiente', total: 250, monto_pagado: 0, fecha: `${mes}-10`, fecha_entrega_programada: `${mes}-12`, forma_pago: 'transferencia', cliente: cli('Almacén Sur') },
  { id: '3', estado: 'entregado', estado_pago: 'pendiente', total: 400, monto_pagado: 0, fecha: `${mes}-10`, fecha_entrega_programada: `${mes}-10`, forma_pago: 'efectivo', cliente: cli('Despensa Este') },
]
vi.mock('../../hooks/queries', () => ({
  usePedidosNoPagadosQuery: () => ({ data: pedidos, isLoading: false }),
  useRendicionCerradaQuery: () => ({ data: false }),
}))

import ModalPagosMasivos from './ModalPagosMasivos'

function montar() {
  const onConfirm = vi.fn().mockResolvedValue(undefined)
  render(<ModalPagosMasivos onConfirm={onConfirm} onClose={vi.fn()} guardando={false} isAdmin />)
  fireEvent.change(screen.getAllByRole('combobox')[0], { target: { value: 'efectivo' } })
  return onConfirm
}
const desde = (v: string) => fireEvent.change(screen.getByLabelText('Desde'), { target: { value: v } })
const hasta = (v: string) => fireEvent.change(screen.getByLabelText('Hasta'), { target: { value: v } })
const formaFiltro = (v: string) => fireEvent.change(screen.getByLabelText(/Forma de pago del pedido/), { target: { value: v } })

describe('ModalPagosMasivos · filtros de fecha y forma de pago (#1698)', () => {
  it('filtra por fecha de entrega por defecto', () => {
    montar()
    desde(`${mes}-10`)
    hasta(`${mes}-10`)
    expect(screen.getByText('Kiosco Norte')).toBeInTheDocument()
    expect(screen.getByText('Despensa Este')).toBeInTheDocument()
    expect(screen.queryByText('Almacén Sur')).not.toBeInTheDocument()
  })

  it('la fecha del pedido es la segunda opción', () => {
    montar()
    fireEvent.click(screen.getByRole('button', { name: 'Fecha del pedido' }))
    desde(`${mes}-10`)
    hasta(`${mes}-10`)
    expect(screen.queryByText('Kiosco Norte')).not.toBeInTheDocument()
    expect(screen.getByText('Almacén Sur')).toBeInTheDocument()
    expect(screen.getByText('Despensa Este')).toBeInTheDocument()
  })

  it('filtra por forma de pago', () => {
    montar()
    formaFiltro('efectivo')
    expect(screen.getByText('Kiosco Norte')).toBeInTheDocument()
    expect(screen.queryByText('Almacén Sur')).not.toBeInTheDocument()
    expect(screen.getByText('Despensa Este')).toBeInTheDocument()
  })

  it('lo que el filtro esconde no se manda ni se cuenta, y al volver sigue tildado', async () => {
    const onConfirm = montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    fireEvent.click(screen.getByText('Almacén Sur'))
    fireEvent.click(screen.getByText('Despensa Este'))
    expect(screen.getByText(/3 pedidos seleccionados/)).toBeInTheDocument()

    formaFiltro('efectivo')
    expect(screen.getByText(/2 pedidos seleccionados/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Marcar como Pagados' }))
    // 100 + 400: el pedido de transferencia, escondido, no entra en el total.
    expect(await screen.findByText(/Se van a registrar 2 pagos por/)).toHaveTextContent(/\$\s*500,00/)
    fireEvent.click(screen.getByRole('button', { name: /Confirmar|Aceptar|Cobrar/ }))
    await waitFor(() => expect(onConfirm).toHaveBeenCalledTimes(1))
    expect(onConfirm).toHaveBeenCalledWith('efectivo', ['1', '3'], hoy)

    formaFiltro('')
    expect(screen.getByText(/3 pedidos seleccionados/)).toBeInTheDocument()
  })
})
