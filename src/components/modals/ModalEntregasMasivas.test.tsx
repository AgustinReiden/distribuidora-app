/**
 * `ModalEntregasMasivas` (GTO-15 #1597, 1598-b2 #1598): el campo de fecha ofrece sólo el
 * rango que acepta `marcar_entregas_masivo` para el rol, y una fecha fuera de él no se confirma.
 */
import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { fechaLocalISO } from '../../utils/formatters'
import type { PerfilDB } from '../../types'

const politicas = { diasAtrasFechaPedido: 5 }
vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas }),
}))
vi.mock('../../hooks/queries', () => ({
  usePedidosNoEntregadosQuery: () => ({
    data: [{ id: '7', estado: 'asignado', total: 100, cliente: { nombre_fantasia: 'Kiosco' } }],
    isLoading: false,
  }),
}))

import ModalEntregasMasivas from './ModalEntregasMasivas'

const choferes = [{ id: 'c-1', nombre: 'Chofer Uno' }] as unknown as PerfilDB[]

/** 'YYYY-MM-DD' menos n días, contado aparte de la utilidad que se prueba. */
const menos = (n: number): string => {
  const [y, m, d] = fechaLocalISO().split('-').map(Number)
  return new Date(Date.UTC(y, m - 1, d - n)).toISOString().slice(0, 10)
}

const renderModal = (isAdmin: boolean) => {
  const onConfirm = vi.fn().mockResolvedValue(undefined)
  render(
    <ModalEntregasMasivas transportistas={choferes} onConfirm={onConfirm} onClose={vi.fn()} guardando={false} isAdmin={isAdmin} />,
  )
  fireEvent.change(screen.getByRole('combobox'), { target: { value: 'c-1' } })
  fireEvent.click(screen.getByText('Kiosco'))
  return onConfirm
}

describe('ModalEntregasMasivas · fecha de entrega', () => {
  beforeEach(() => {
    politicas.diasAtrasFechaPedido = 5
  })

  it('quien no es admin: de hoy hasta los días de la política', () => {
    renderModal(false)
    const campo = screen.getByLabelText('Fecha de entrega')
    expect(campo).toHaveAttribute('max', fechaLocalISO())
    expect(campo).toHaveAttribute('min', menos(5))
  })

  it('el admin: hasta 60 días atrás, nunca después de hoy', () => {
    renderModal(true)
    const campo = screen.getByLabelText('Fecha de entrega')
    expect(campo).toHaveAttribute('max', fechaLocalISO())
    expect(campo).toHaveAttribute('min', menos(60))
  })

  it('una fecha anterior al piso se avisa y no se confirma', () => {
    renderModal(false)
    const boton = screen.getByRole('button', { name: /Marcar como Entregados/ })
    expect(boton).toBeEnabled()
    fireEvent.change(screen.getByLabelText('Fecha de entrega'), { target: { value: menos(6) } })
    expect(screen.getByRole('alert')).toHaveTextContent('hasta 5 días atrás')
    expect(boton).toBeDisabled()
  })

  it('una fecha futura no se confirma, tampoco para el admin', () => {
    renderModal(true)
    fireEvent.change(screen.getByLabelText('Fecha de entrega'), { target: { value: menos(-1) } })
    expect(screen.getByRole('alert')).toHaveTextContent('no puede ser posterior a hoy')
    expect(screen.getByRole('button', { name: /Marcar como Entregados/ })).toBeDisabled()
  })

  it('dentro del rango viaja la fecha elegida', () => {
    const onConfirm = renderModal(false)
    fireEvent.change(screen.getByLabelText('Fecha de entrega'), { target: { value: menos(5) } })
    fireEvent.click(screen.getByRole('button', { name: /Marcar como Entregados/ }))
    fireEvent.click(screen.getByRole('button', { name: 'Confirmar' }))
    expect(onConfirm).toHaveBeenCalledWith('c-1', ['7'], menos(5))
  })
})
