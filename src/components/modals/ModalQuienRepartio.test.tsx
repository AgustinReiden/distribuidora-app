/**
 * `ModalQuienRepartio` (#1204) — antes de entregar un pedido sin chofer, quién
 * lo repartió. "Retiró en depósito" sólo para admin y encargado.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import ModalQuienRepartio from './ModalQuienRepartio'
import type { PedidoDB, PerfilDB } from '../../types'

const pedido = { id: '42', cliente_id: '1', estado: 'pendiente', total: 100 } as unknown as PedidoDB
const choferes = [
  { id: 'c-1', nombre: 'Chofer Uno' },
  { id: 'c-2', nombre: 'Chofer Dos' },
] as unknown as PerfilDB[]

const renderModal = (permitirRetiro: boolean, onConfirm = vi.fn()) => {
  render(
    <ModalQuienRepartio
      pedido={pedido}
      transportistas={choferes}
      permitirRetiro={permitirRetiro}
      onConfirm={onConfirm}
      onClose={vi.fn()}
    />
  )
  return onConfirm
}

describe('ModalQuienRepartio', () => {
  it('no deja continuar sin elegir', () => {
    renderModal(true)
    expect(screen.getByRole('button', { name: 'Continuar' })).toBeDisabled()
  })

  it('devuelve el chofer elegido', () => {
    const onConfirm = renderModal(true)
    fireEvent.change(screen.getByLabelText('Chofer'), { target: { value: 'c-2' } })
    fireEvent.click(screen.getByRole('button', { name: 'Continuar' }))
    expect(onConfirm).toHaveBeenCalledWith({ tipo: 'chofer', transportistaId: 'c-2' })
  })

  it('el retiro en depósito va sin chofer', () => {
    const onConfirm = renderModal(true)
    fireEvent.change(screen.getByLabelText('Chofer'), { target: { value: '__retiro__' } })
    fireEvent.click(screen.getByRole('button', { name: 'Continuar' }))
    expect(onConfirm).toHaveBeenCalledWith({ tipo: 'retiro' })
  })

  it('sin permiso no ofrece el retiro', () => {
    renderModal(false)
    expect(screen.queryByRole('option', { name: /Retiró en depósito/ })).not.toBeInTheDocument()
    expect(screen.getByRole('option', { name: 'Chofer Uno' })).toBeInTheDocument()
  })
})
