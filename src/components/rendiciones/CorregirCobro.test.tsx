/**
 * T4 (#1710): «le faltan $ 100.000 de efectivo y le sobran $ 100.000 de transferencia»: se corrige
 * la forma del cobro en la rendición, con motivo, y no queda faltante.
 */
import React from 'react'
import { describe, it, expect, vi, afterEach, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor, cleanup } from '@testing-library/react'

const corregir = vi.fn()
const cobrarFaltante = vi.fn()
vi.mock('../../hooks/supabase/cobrosRendicion', () => ({
  corregirCobroRendicion: (...a: unknown[]) => corregir(...a),
  cobrarFaltanteRendicion: (...a: unknown[]) => cobrarFaltante(...a),
}))

import CorregirCobro from './CorregirCobro'
import CobrarFaltante from './CobrarFaltante'

beforeEach(() => {
  corregir.mockReset().mockResolvedValue(undefined)
  cobrarFaltante.mockReset().mockResolvedValue(undefined)
})
afterEach(cleanup)

describe('CorregirCobro', () => {
  it('el encargado pasa un cobro de transferencia a efectivo, con motivo', async () => {
    const onHecho = vi.fn()
    render(<CorregirCobro pagoId={7} formaActual="transferencia" esAdmin={false} onHecho={onHecho} onCancelar={vi.fn()} />)
    const boton = screen.getByRole('button', { name: 'Corregir' })
    fireEvent.change(screen.getByLabelText(/forma de pago/i), { target: { value: 'efectivo' } })
    // Sin motivo no se corrige.
    expect((boton as HTMLButtonElement).disabled).toBe(true)
    fireEvent.change(screen.getByLabelText(/motivo/i), { target: { value: 'Marcó mal la forma' } })
    fireEvent.click(boton)
    await waitFor(() => expect(onHecho).toHaveBeenCalled())
    expect(corregir).toHaveBeenCalledWith({ pagoId: 7, formaPago: 'efectivo', cobradoPor: null, motivo: 'Marcó mal la forma' })
    // El encargado no elige quién cobró.
    expect(screen.queryByLabelText(/quién cobró/i)).toBeNull()
  })

  it('el admin además le pasa el cobro a otra caja', async () => {
    render(<CorregirCobro pagoId={7} formaActual="efectivo" esAdmin personas={[{ id: 'e1', nombre: 'Encargada' }]}
                          onHecho={vi.fn()} onCancelar={vi.fn()} />)
    fireEvent.change(screen.getByLabelText(/quién cobró/i), { target: { value: 'e1' } })
    fireEvent.change(screen.getByLabelText(/motivo/i), { target: { value: 'Lo cobró en el mostrador' } })
    fireEvent.click(screen.getByRole('button', { name: 'Corregir' }))
    await waitFor(() => expect(corregir).toHaveBeenCalled())
    expect(corregir.mock.calls[0][0]).toEqual({ pagoId: 7, formaPago: null, cobradoPor: 'e1', motivo: 'Lo cobró en el mostrador' })
  })

  it('el rechazo del server se muestra', async () => {
    corregir.mockRejectedValue(new Error('La rendición de ese cobro ya está cerrada: para corregirlo, reabrila'))
    render(<CorregirCobro pagoId={7} formaActual="transferencia" esAdmin={false} onHecho={vi.fn()} onCancelar={vi.fn()} />)
    fireEvent.change(screen.getByLabelText(/forma de pago/i), { target: { value: 'efectivo' } })
    fireEvent.change(screen.getByLabelText(/motivo/i), { target: { value: 'x' } })
    fireEvent.click(screen.getByRole('button', { name: 'Corregir' }))
    expect((await screen.findByRole('alert')).textContent).toMatch(/ya está cerrada/)
  })
})

describe('CobrarFaltante', () => {
  it('el cliente paga $ 5.000 del faltante en efectivo y los recibe la encargada', async () => {
    const onHecho = vi.fn()
    render(<CobrarFaltante faltanteId={3} pendiente={5000} personas={[{ id: 'e1', nombre: 'Encargada' }]}
                           yoId="admin-1" onHecho={onHecho} onCancelar={vi.fn()} />)
    fireEvent.change(screen.getByLabelText(/quién cobró/i), { target: { value: 'e1' } })
    fireEvent.click(screen.getByRole('button', { name: /cargar lo que pagó/i }))
    await waitFor(() => expect(onHecho).toHaveBeenCalled())
    const arg = cobrarFaltante.mock.calls[0][0]
    expect(arg).toMatchObject({ faltanteId: 3, monto: 5000, formaPago: 'efectivo', cobradoPor: 'e1' })
    expect(typeof arg.clave).toBe('string')
  })

  it('por transferencia no pregunta quién lo recibió (no entra en ninguna caja)', () => {
    render(<CobrarFaltante faltanteId={3} pendiente={5000} personas={[]} onHecho={vi.fn()} onCancelar={vi.fn()} />)
    fireEvent.change(screen.getByLabelText(/forma de pago/i), { target: { value: 'transferencia' } })
    expect(screen.queryByLabelText(/quién cobró/i)).toBeNull()
  })
})
