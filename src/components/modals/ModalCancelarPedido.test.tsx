/**
 * `ModalCancelarPedido` — cancelar por falta de stock (#827, mig 269).
 *
 * Con `falta_stock` la mercadería no vuelve al stock: se merma. Eso no se
 * deshace desde la app, así que el modal pide un segundo paso DENTRO de sí
 * mismo (no un confirm hermano, que quedaría detrás del overlay de Radix) con
 * la lista de lo que no vuelve y un tilde obligatorio.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ModalCancelarPedido from './ModalCancelarPedido'
import type { PedidoDB } from '../../types'

const PEDIDO = {
  id: '6415',
  total: 5500,
  cliente: { nombre_fantasia: 'Almacén Don Pepe' },
  items: [
    { id: 'a', pedido_id: '6415', producto_id: '7', cantidad: 10, precio_unitario: 100, producto: { nombre: 'Yerba 1kg' } },
    { id: 'b', pedido_id: '6415', producto_id: '9', cantidad: 45, precio_unitario: 100, producto: { nombre: 'Azúcar 1kg' } },
    // Regalo de una promo que no mueve stock: no aparece en la lista.
    { id: 'c', pedido_id: '6415', producto_id: '11', cantidad: 1, precio_unitario: 0, es_bonificacion: true,
      promocion: { regalo_mueve_stock: false }, producto: { nombre: 'Vaso de regalo' } },
  ],
} as unknown as PedidoDB

const renderModal = (onConfirm = vi.fn().mockResolvedValue(undefined)) => {
  render(<ModalCancelarPedido pedido={PEDIDO} onConfirm={onConfirm} onClose={vi.fn()} guardando={false} />)
  return onConfirm
}

const elegir = (valor: string) =>
  fireEvent.change(screen.getByLabelText(/motivo de cancelación/i), { target: { value: valor } })

describe('ModalCancelarPedido — motivo falta de stock', () => {
  it('ofrece el motivo "Falta de stock"', () => {
    renderModal()
    expect(screen.getByRole('option', { name: 'Falta de stock' })).toBeInTheDocument()
  })

  it('un motivo común cancela directo y avisa que restaura el stock', () => {
    const onConfirm = renderModal()
    expect(screen.getByText(/restaurará el stock/i)).toBeInTheDocument()
    elegir('cerrado')
    fireEvent.click(screen.getByRole('button', { name: /cancelar pedido/i }))
    expect(onConfirm).toHaveBeenCalledWith('Estaba cerrado', 'cerrado')
  })

  it('con falta de stock no dice "restaurará" y pide un segundo paso', () => {
    const onConfirm = renderModal()
    elegir('falta_stock')
    expect(screen.queryByText(/restaurará el stock/i)).not.toBeInTheDocument()
    expect(screen.getByText(/NO vuelve al stock/)).toBeInTheDocument()
    // Todavía no hay botón de cancelar: primero "Continuar".
    expect(screen.queryByRole('button', { name: /cancelar pedido/i })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /continuar/i }))
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('lista productos y cantidades que no vuelven, y exige el tilde', () => {
    const onConfirm = renderModal()
    elegir('falta_stock')
    fireEvent.click(screen.getByRole('button', { name: /continuar/i }))

    const lista = screen.getByRole('list', { name: /no vuelven al stock/i })
    expect(lista).toHaveTextContent('Yerba 1kg')
    expect(lista).toHaveTextContent('10 u.')
    expect(lista).toHaveTextContent('Azúcar 1kg')
    expect(lista).toHaveTextContent('45 u.')
    expect(lista).not.toHaveTextContent('Vaso de regalo')

    const cancelar = screen.getByRole('button', { name: /cancelar pedido/i })
    expect(cancelar).toBeDisabled()
    fireEvent.click(cancelar)
    expect(onConfirm).not.toHaveBeenCalled()

    fireEvent.click(screen.getByLabelText(/confirmo que la mercadería no existe físicamente/i))
    expect(cancelar).not.toBeDisabled()
    fireEvent.click(cancelar)
    expect(onConfirm).toHaveBeenCalledWith('Falta de stock', 'falta_stock')
  })

  it('"Volver" en la confirmación regresa al motivo y el tilde no sobrevive', () => {
    renderModal()
    elegir('falta_stock')
    fireEvent.click(screen.getByRole('button', { name: /continuar/i }))
    fireEvent.click(screen.getByLabelText(/confirmo que la mercadería/i))
    fireEvent.click(screen.getByRole('button', { name: /volver/i }))

    expect(screen.queryByRole('list', { name: /no vuelven al stock/i })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /continuar/i }))
    expect(screen.getByLabelText(/confirmo que la mercadería/i)).not.toBeChecked()
    expect(screen.getByRole('button', { name: /cancelar pedido/i })).toBeDisabled()
  })
})
