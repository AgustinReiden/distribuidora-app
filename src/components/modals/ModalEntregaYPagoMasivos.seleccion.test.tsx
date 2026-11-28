/**
 * Fr-B6 de #1554 (T14 de #1690): la selección de boletas sobrevivía a un cambio de filtro. Lo
 * tildado que el filtro esconde se mandaba (entregar y cobrar) y se contaba en la confirmación y en
 * el pie. Lo que se manda y se dice es lo que está tildado Y se ve.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { fechaLocalISO } from '../../utils/formatters'
import type { PerfilDB } from '../../types'

const pedidos = [
  { id: '1', estado: 'asignado', estado_pago: 'pendiente', total: 100, monto_pagado: 0, cliente: { nombre_fantasia: 'Kiosco Norte', direccion: 'Calle 1' } },
  { id: '2', estado: 'asignado', estado_pago: 'pendiente', total: 250, monto_pagado: 50, cliente: { nombre_fantasia: 'Almacén Sur', direccion: 'Calle 2' } },
  // Ya entregado: sólo se cobra.
  { id: '3', estado: 'entregado', estado_pago: 'pendiente', total: 400, monto_pagado: 0, cliente: { nombre_fantasia: 'Despensa Este', direccion: 'Calle 3' } },
]
vi.mock('../../hooks/queries', () => ({
  usePedidosParaEntregaYPagoQuery: () => ({ data: pedidos, isLoading: false }),
  useRendicionCerradaQuery: () => ({ data: false }),
  useControlRendicionCerradoQuery: () => ({ data: false }),
}))

import ModalEntregaYPagoMasivos from './ModalEntregaYPagoMasivos'

const choferes = [{ id: 'c-1', nombre: 'Chofer Uno' }] as unknown as PerfilDB[]

function montar() {
  const onConfirm = vi.fn().mockResolvedValue(undefined)
  render(
    <ModalEntregaYPagoMasivos transportistas={choferes} onConfirm={onConfirm} onClose={vi.fn()} guardando={false} isAdmin />,
  )
  const [chofer, forma] = screen.getAllByRole('combobox')
  fireEvent.change(chofer, { target: { value: 'c-1' } })
  fireEvent.change(forma, { target: { value: 'efectivo' } })
  return onConfirm
}
const buscar = (texto: string) =>
  fireEvent.change(screen.getByPlaceholderText(/Buscar por cliente/), { target: { value: texto } })

describe('ModalEntregaYPagoMasivos · la selección sigue al filtro (Fr-B6)', () => {
  it('lo tildado que el filtro esconde no se entrega, ni se cobra, ni se cuenta', async () => {
    const onConfirm = montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    fireEvent.click(screen.getByText('Almacén Sur'))
    fireEvent.click(screen.getByText('Despensa Este'))
    expect(screen.getByText(/3 pedidos seleccionados/)).toBeInTheDocument()

    buscar('almac')
    expect(screen.getByText(/1 pedido seleccionado/)).toBeInTheDocument()
    // A cobrar es el saldo de lo que se ve: 250 − 50.
    expect(screen.getByText(/A cobrar:/, { selector: 'span' })).toHaveTextContent(/\$\s*200,00/)

    fireEvent.click(screen.getByRole('button', { name: /Entregar y registrar pago/ }))
    expect(await screen.findByText(/Se va a entregar 1 pedido por Chofer Uno y cobrar/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /Confirmar|Aceptar/ }))

    await waitFor(() => expect(onConfirm).toHaveBeenCalledTimes(1))
    expect(onConfirm).toHaveBeenCalledWith('c-1', 'efectivo', { idsEntregar: ['2'], idsCobrar: [] }, fechaLocalISO())
  })

  it('un entregado oculto por el filtro no se cobra', async () => {
    const onConfirm = montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    fireEvent.click(screen.getByText('Despensa Este'))
    buscar('kiosco')

    fireEvent.click(screen.getByRole('button', { name: /Entregar y registrar pago/ }))
    fireEvent.click(await screen.findByRole('button', { name: /Confirmar|Aceptar/ }))

    await waitFor(() => expect(onConfirm).toHaveBeenCalledTimes(1))
    expect(onConfirm.mock.calls[0][2]).toEqual({ idsEntregar: ['1'], idsCobrar: [] })
  })

  it('al volver a mostrarse, lo que estaba tildado sigue tildado', () => {
    montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    buscar('almac')
    expect(screen.getByText(/0 pedidos seleccionados/)).toBeInTheDocument()
    buscar('')
    expect(screen.getByText(/1 pedido seleccionado/)).toBeInTheDocument()
  })

  it('«Seleccionar todos» está tildado cuando lo visible está todo tildado, aunque haya tildados ocultos', () => {
    montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    fireEvent.click(screen.getByText('Almacén Sur'))
    buscar('almac')
    expect(screen.getByLabelText(/Seleccionar todos/)).toBeChecked()
  })
})
