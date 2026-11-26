/**
 * #1698: entregas masivas filtra por fecha de entrega (por defecto) o de pedido. No tiene filtro por
 * forma de pago: no cobra. Lo que se manda y lo que dice la confirmación es lo tildado Y visible.
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { fechaLocalISO } from '../../utils/formatters'
import type { PerfilDB } from '../../types'

vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { diasAtrasFechaPedido: 7 } }),
}))
const cli = (n: string) => ({ nombre_fantasia: n, direccion: 'Calle' })
const pedidos = [
  { id: '1', estado: 'asignado', total: 100, fecha: '2026-11-20', fecha_entrega_programada: '2026-11-26', cliente: cli('Kiosco Norte') },
  { id: '2', estado: 'asignado', total: 250, fecha: '2026-11-26', fecha_entrega_programada: '2026-11-27', cliente: cli('Almacén Sur') },
]
vi.mock('../../hooks/queries', () => ({
  usePedidosNoEntregadosQuery: () => ({ data: pedidos, isLoading: false }),
}))

import ModalEntregasMasivas from './ModalEntregasMasivas'

const choferes = [{ id: 'c-1', nombre: 'Chofer Uno' }] as unknown as PerfilDB[]
const desde = (v: string) => fireEvent.change(screen.getByLabelText('Desde'), { target: { value: v } })
const hasta = (v: string) => fireEvent.change(screen.getByLabelText('Hasta'), { target: { value: v } })

function montar() {
  const onConfirm = vi.fn().mockResolvedValue(undefined)
  render(<ModalEntregasMasivas transportistas={choferes} onConfirm={onConfirm} onClose={vi.fn()} guardando={false} isAdmin />)
  fireEvent.change(screen.getByRole('combobox'), { target: { value: 'c-1' } })
  return onConfirm
}

describe('ModalEntregasMasivas · filtro de fecha (#1698)', () => {
  it('filtra por fecha de entrega por defecto, y no ofrece forma de pago', () => {
    montar()
    expect(screen.queryByLabelText(/Forma de pago del pedido/)).not.toBeInTheDocument()
    desde('2026-11-26')
    hasta('2026-11-26')
    expect(screen.getByText('Kiosco Norte')).toBeInTheDocument()
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

  it('lo que el filtro esconde no se manda ni se cuenta; al volver sigue tildado', async () => {
    const onConfirm = montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    fireEvent.click(screen.getByText('Almacén Sur'))
    desde('2026-11-26')
    hasta('2026-11-26')
    expect(screen.getByText(/1 pedido seleccionado/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /Marcar como Entregados/ }))
    expect(await screen.findByText(/Se van a marcar 1 pedido como entregados/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /Confirmar|Aceptar|Marcar/ , hidden: false }))
    await waitFor(() => expect(onConfirm).toHaveBeenCalledTimes(1))
    expect(onConfirm).toHaveBeenCalledWith('c-1', ['1'], fechaLocalISO())

    desde('')
    hasta('')
    expect(screen.getByText(/2 pedidos seleccionados/)).toBeInTheDocument()
  })
})
