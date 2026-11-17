/**
 * `ModalEntregaYPagoMasivos` (GTO-15 #1597): el admin fecha la entrega hasta 60 días atrás y
 * nunca después de hoy, como `marcar_entrega_y_pago_masivo_impl`; el encargado sigue fijo en hoy.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { fechaLocalISO } from '../../utils/formatters'
import type { PerfilDB } from '../../types'

const pedidos = [{ id: '7', estado: 'asignado', estado_pago: 'pendiente', total: 100, monto_pagado: 0, cliente: { nombre_fantasia: 'Kiosco' } }]
vi.mock('../../hooks/queries', () => ({
  usePedidosParaEntregaYPagoQuery: () => ({ data: pedidos, isLoading: false }),
  useRendicionCerradaQuery: () => ({ data: false }),
}))

import ModalEntregaYPagoMasivos from './ModalEntregaYPagoMasivos'

const choferes = [{ id: 'c-1', nombre: 'Chofer Uno' }] as unknown as PerfilDB[]

const menos = (n: number): string => {
  const [y, m, d] = fechaLocalISO().split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d - n)).toISOString().slice(0, 10)
}

const renderModal = (rol: { isAdmin?: boolean; isEncargado?: boolean }) => {
  render(
    <ModalEntregaYPagoMasivos transportistas={choferes} onConfirm={vi.fn().mockResolvedValue(undefined)}
      onClose={vi.fn()} guardando={false} {...rol} />,
  )
  const [chofer, forma] = screen.getAllByRole('combobox')
  fireEvent.change(chofer, { target: { value: 'c-1' } })
  fireEvent.change(forma, { target: { value: 'efectivo' } })
  fireEvent.click(screen.getByText('Kiosco'))
}

describe('ModalEntregaYPagoMasivos · fecha de entrega', () => {
  it('el admin: de 60 días atrás hasta hoy', () => {
    renderModal({ isAdmin: true })
    const campo = screen.getByLabelText('Fecha')
    expect(campo).toHaveAttribute('min', menos(60))
    expect(campo).toHaveAttribute('max', fechaLocalISO())
  })

  it('el admin: más vieja que el piso o futura no se confirma', () => {
    renderModal({ isAdmin: true })
    const boton = screen.getByRole('button', { name: /Entregar y registrar pago/ })
    expect(boton).toBeEnabled()
    fireEvent.change(screen.getByLabelText('Fecha'), { target: { value: menos(61) } })
    expect(screen.getByRole('alert')).toHaveTextContent('hasta 60 días atrás')
    expect(boton).toBeDisabled()
    fireEvent.change(screen.getByLabelText('Fecha'), { target: { value: menos(-1) } })
    expect(screen.getByRole('alert')).toHaveTextContent('no puede ser posterior a hoy')
    expect(boton).toBeDisabled()
    fireEvent.change(screen.getByLabelText('Fecha'), { target: { value: menos(60) } })
    expect(boton).toBeEnabled()
  })

  it('el encargado ve el aviso con su coma: «otra fecha, pedíselo»', () => {
    renderModal({ isEncargado: true })
    expect(screen.getByText(/Si necesitás otra fecha, pedíselo a un admin\./)).toBeInTheDocument()
  })

  it('el encargado sigue fijo en hoy', () => {
    renderModal({ isEncargado: true })
    const campo = screen.getByLabelText('Fecha')
    expect(campo).toBeDisabled()
    expect(campo).toHaveAttribute('min', fechaLocalISO())
    expect(campo).toHaveAttribute('max', fechaLocalISO())
  })
})
