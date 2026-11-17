/**
 * `ModalQuienRepartio` (#1204) — la confirmación de entrega de un pedido sin
 * chofer que no pasa por el cobro: chofer y fecha en un solo paso.
 * "Retiró en depósito" sólo para admin y encargado.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ModalQuienRepartio from './ModalQuienRepartio'
import { fechaLocalISO } from '../../utils/formatters'
import type { PedidoDB, PerfilDB } from '../../types'

const pedido = { id: '42', cliente_id: '1', estado: 'pendiente', total: 100 } as unknown as PedidoDB
const choferes = [
  { id: 'c-1', nombre: 'Chofer Uno' },
  { id: 'c-2', nombre: 'Chofer Dos' },
] as unknown as PerfilDB[]

const renderModal = (
  permitirRetiro: boolean,
  onConfirm = vi.fn(),
  p: PedidoDB = pedido,
  regla: { esAdmin?: boolean; diasAtrasFechaEntrega?: number } = { esAdmin: true },
) => {
  render(
    <ModalQuienRepartio
      pedido={p}
      transportistas={choferes}
      permitirRetiro={permitirRetiro}
      onConfirm={onConfirm}
      onClose={vi.fn()}
      {...regla}
    />
  )
  return onConfirm
}

/** `dias` días antes de hoy. */
const atras = (dias: number): string => {
  const [y, m, d] = fechaLocalISO().split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d - dias)).toISOString().slice(0, 10)
}

describe('ModalQuienRepartio', () => {
  it('no deja confirmar sin elegir quién lo repartió', () => {
    renderModal(true)
    expect(screen.getByRole('button', { name: 'Confirmar' })).toBeDisabled()
  })

  it('devuelve el chofer elegido y la fecha, arrancando en hoy', () => {
    const onConfirm = renderModal(true)
    expect(screen.getByLabelText('Fecha de entrega')).toHaveValue(fechaLocalISO())
    fireEvent.change(screen.getByLabelText('¿Quién lo repartió?'), { target: { value: 'c-2' } })
    fireEvent.click(screen.getByRole('button', { name: 'Confirmar' }))
    expect(onConfirm).toHaveBeenCalledWith({ tipo: 'chofer', transportistaId: 'c-2' }, fechaLocalISO())
  })

  it('la fecha elegida viaja con la entrega', () => {
    const onConfirm = renderModal(true)
    fireEvent.change(screen.getByLabelText('¿Quién lo repartió?'), { target: { value: 'c-1' } })
    fireEvent.change(screen.getByLabelText('Fecha de entrega'), { target: { value: atras(3) } })
    fireEvent.click(screen.getByRole('button', { name: 'Confirmar' }))
    expect(onConfirm).toHaveBeenCalledWith({ tipo: 'chofer', transportistaId: 'c-1' }, atras(3))
  })

  // 1598: el campo sólo tenía `max`; el piso es el de `fechaEntrega.ts` (espejo del server).
  it('quien no es admin: de hoy hasta los días de la política', () => {
    renderModal(false, vi.fn(), pedido, { esAdmin: false, diasAtrasFechaEntrega: 3 })
    const campo = screen.getByLabelText('Fecha de entrega')
    expect(campo).toHaveAttribute('min', atras(3))
    expect(campo).toHaveAttribute('max', fechaLocalISO())
  })

  it('el admin: hasta 60 días atrás', () => {
    renderModal(true)
    expect(screen.getByLabelText('Fecha de entrega')).toHaveAttribute('min', atras(60))
  })

  it('una fecha fuera del rango muestra el motivo del server y no se confirma', () => {
    const onConfirm = renderModal(false, vi.fn(), pedido, { esAdmin: false, diasAtrasFechaEntrega: 3 })
    fireEvent.change(screen.getByLabelText('¿Quién lo repartió?'), { target: { value: 'c-1' } })
    fireEvent.change(screen.getByLabelText('Fecha de entrega'), { target: { value: atras(4) } })
    expect(screen.getByRole('alert')).toHaveTextContent('hasta 3 días atrás')
    expect(screen.getByRole('button', { name: 'Confirmar' })).toBeDisabled()
    fireEvent.click(screen.getByRole('button', { name: 'Confirmar' }))
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('el retiro en depósito va sin chofer', () => {
    const onConfirm = renderModal(true)
    fireEvent.change(screen.getByLabelText('¿Quién lo repartió?'), { target: { value: '__retiro__' } })
    fireEvent.click(screen.getByRole('button', { name: 'Confirmar' }))
    expect(onConfirm).toHaveBeenCalledWith({ tipo: 'retiro' }, fechaLocalISO())
  })

  it('sin permiso no ofrece el retiro', () => {
    renderModal(false)
    expect(screen.queryByRole('option', { name: /Retiró en depósito/ })).not.toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Chofer Uno' })).toBeInTheDocument()
  })

  it('una parada de cambio se titula como tal', () => {
    renderModal(true, vi.fn(), { ...pedido, canal: 'cambio' } as unknown as PedidoDB)
    expect(screen.getByRole('dialog', { name: 'Confirmar cambio/devolución' })).toBeInTheDocument()
  })
})
