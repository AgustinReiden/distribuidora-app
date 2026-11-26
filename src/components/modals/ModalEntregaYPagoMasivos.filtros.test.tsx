/**
 * #1698: entrega con pago masivo filtra por fecha de entrega (por defecto) o de pedido, y por forma
 * de pago. Lo que se manda y lo que dice la confirmación es lo tildado Y visible.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { fechaLocalISO } from '../../utils/formatters'
import type { PerfilDB } from '../../types'

const cli = (n: string) => ({ nombre_fantasia: n, direccion: 'Calle' })
const pedidos = [
  { id: '1', estado: 'asignado', estado_pago: 'pendiente', total: 100, monto_pagado: 0, fecha: '2026-11-20', fecha_entrega_programada: '2026-11-26', forma_pago: 'efectivo', cliente: cli('Kiosco Norte') },
  { id: '2', estado: 'asignado', estado_pago: 'pendiente', total: 250, monto_pagado: 0, fecha: '2026-11-26', fecha_entrega_programada: '2026-11-27', forma_pago: 'transferencia', cliente: cli('Almacén Sur') },
  { id: '3', estado: 'entregado', estado_pago: 'pendiente', total: 400, monto_pagado: 0, fecha: '2026-11-26', fecha_entrega_programada: '2026-11-26', forma_pago: 'efectivo', cliente: cli('Despensa Este') },
]
vi.mock('../../hooks/queries', () => ({
  usePedidosParaEntregaYPagoQuery: () => ({ data: pedidos, isLoading: false }),
  useRendicionCerradaQuery: () => ({ data: false }),
}))

import ModalEntregaYPagoMasivos from './ModalEntregaYPagoMasivos'

const choferes = [{ id: 'c-1', nombre: 'Chofer Uno' }] as unknown as PerfilDB[]

function montar() {
  const onConfirm = vi.fn().mockResolvedValue(undefined)
  render(<ModalEntregaYPagoMasivos transportistas={choferes} onConfirm={onConfirm} onClose={vi.fn()} guardando={false} isAdmin />)
  const [chofer, forma] = screen.getAllByRole('combobox')
  fireEvent.change(chofer, { target: { value: 'c-1' } })
  fireEvent.change(forma, { target: { value: 'efectivo' } })
  return onConfirm
}
const desde = (v: string) => fireEvent.change(screen.getByLabelText('Desde'), { target: { value: v } })
const hasta = (v: string) => fireEvent.change(screen.getByLabelText('Hasta'), { target: { value: v } })
const formaFiltro = (v: string) => fireEvent.change(screen.getByLabelText(/Forma de pago del pedido/), { target: { value: v } })

describe('ModalEntregaYPagoMasivos · filtros de fecha y forma de pago (#1698)', () => {
  it('filtra por fecha de entrega por defecto', () => {
    montar()
    desde('2026-11-26')
    hasta('2026-11-26')
    expect(screen.getByText('Kiosco Norte')).toBeInTheDocument()
    expect(screen.getByText('Despensa Este')).toBeInTheDocument()
    expect(screen.queryByText('Almacén Sur')).not.toBeInTheDocument()
  })

  it('la fecha del pedido es la segunda opción', () => {
    montar()
    fireEvent.click(screen.getByRole('button', { name: 'Fecha del pedido' }))
    desde('2026-11-26')
    hasta('2026-11-26')
    expect(screen.queryByText('Kiosco Norte')).not.toBeInTheDocument()
    expect(screen.getByText('Almacén Sur')).toBeInTheDocument()
  })

  it('filtra por forma de pago', () => {
    montar()
    formaFiltro('transferencia')
    expect(screen.getByText('Almacén Sur')).toBeInTheDocument()
    expect(screen.queryByText('Kiosco Norte')).not.toBeInTheDocument()
    expect(screen.queryByText('Despensa Este')).not.toBeInTheDocument()
  })

  it('lo que el filtro esconde no se entrega, ni se cobra, ni se cuenta; al volver sigue tildado', async () => {
    const onConfirm = montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    fireEvent.click(screen.getByText('Almacén Sur'))
    fireEvent.click(screen.getByText('Despensa Este'))
    expect(screen.getByText(/3 pedidos seleccionados/)).toBeInTheDocument()

    formaFiltro('efectivo')
    expect(screen.getByText(/2 pedidos seleccionados/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /Entregar y registrar pago/ }))
    const msg = await screen.findByText(/Se va a entregar 1 pedido por Chofer Uno y cobrar/)
    expect(msg).toHaveTextContent(/\$\s*500,00/)
    fireEvent.click(screen.getByRole('button', { name: /Confirmar|Aceptar/ }))
    await waitFor(() => expect(onConfirm).toHaveBeenCalledTimes(1))
    expect(onConfirm).toHaveBeenCalledWith('c-1', 'efectivo', { idsEntregar: ['1'], idsCobrar: ['3'] }, fechaLocalISO())

    formaFiltro('')
    expect(screen.getByText(/3 pedidos seleccionados/)).toBeInTheDocument()
  })
})
