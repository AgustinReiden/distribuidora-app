/**
 * 1598-b8: la selección de boletas sobrevivía a un cambio de filtro. Se tildaba, se filtraba por
 * otro cliente o fecha, y «Marcar como Pagados» mandaba también las boletas que ya no se veían
 * (y el total y la confirmación las contaban). Lo que se manda es lo que se ve y está tildado.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { fechaLocalISO } from '../../utils/formatters'

const hoy = fechaLocalISO()
const pedidos = [
  { id: '1', estado: 'entregado', estado_pago: 'pendiente', total: 100, monto_pagado: 0, fecha: hoy, cliente: { nombre_fantasia: 'Kiosco Norte', direccion: 'Calle 1' } },
  { id: '2', estado: 'entregado', estado_pago: 'pendiente', total: 250, monto_pagado: 0, fecha: hoy, cliente: { nombre_fantasia: 'Almacén Sur', direccion: 'Calle 2' } },
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

describe('ModalPagosMasivos · la selección sigue al filtro (1598-b8)', () => {
  it('lo tildado que el filtro esconde no se manda ni se cuenta', async () => {
    const onConfirm = montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    fireEvent.click(screen.getByText('Almacén Sur'))
    expect(screen.getByText(/2 pedidos seleccionados/)).toBeInTheDocument()

    // Se filtra por el segundo: el primero deja de verse.
    fireEvent.change(screen.getByPlaceholderText(/Buscar por cliente/), { target: { value: 'almac' } })
    expect(screen.queryByText('Kiosco Norte')).not.toBeInTheDocument()
    expect(screen.getByText(/1 pedido seleccionado/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Marcar como Pagados' }))
    fireEvent.click(await screen.findByRole('button', { name: /Confirmar|Aceptar|Cobrar/ }))
    await waitFor(() => expect(onConfirm).toHaveBeenCalledTimes(1))
    expect(onConfirm).toHaveBeenCalledWith('efectivo', ['2'], hoy)
  })

  it('al volver a mostrarse, lo que estaba tildado sigue tildado', () => {
    montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    fireEvent.change(screen.getByPlaceholderText(/Buscar por cliente/), { target: { value: 'almac' } })
    expect(screen.queryByText(/pedido.* seleccionado/)).toHaveTextContent('0 pedidos seleccionados')
    fireEvent.change(screen.getByPlaceholderText(/Buscar por cliente/), { target: { value: '' } })
    expect(screen.getByText(/1 pedido seleccionado/)).toBeInTheDocument()
  })

  it('el aviso del encargado lleva su coma: «otra fecha, pedíselo»', () => {
    render(<ModalPagosMasivos onConfirm={vi.fn()} onClose={vi.fn()} guardando={false} isEncargado />)
    expect(screen.getByText(/Si necesitás otra fecha, pedíselo a un admin\./)).toBeInTheDocument()
  })

  it('«Seleccionar todos» sólo toma lo visible y se destilda con el mismo gesto', () => {
    montar()
    fireEvent.change(screen.getByPlaceholderText(/Buscar por cliente/), { target: { value: 'almac' } })
    const todos = screen.getByLabelText(/Seleccionar todos/)
    fireEvent.click(todos)
    expect(screen.getByText(/1 pedido seleccionado/)).toBeInTheDocument()
    fireEvent.click(todos)
    expect(screen.getByText(/0 pedidos seleccionados/)).toBeInTheDocument()
  })
})
