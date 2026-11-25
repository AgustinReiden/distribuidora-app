/**
 * Fr-B6 de #1554 (T14 de #1690): la selección de pedidos sobrevivía a un cambio de filtro. Se
 * tildaban dos, se filtraba por uno, y «Marcar como Entregados» mandaba también el que ya no se
 * veía; la confirmación y el pie contaban los dos. Lo que se manda y lo que se dice es lo que
 * está tildado Y se ve. (Misma regla que ya tenía `ModalPagosMasivos`, 1598-b8.)
 */
import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent, waitFor } from '@testing-library/react'
import { fechaLocalISO } from '../../utils/formatters'
import type { PerfilDB } from '../../types'

vi.mock('../../hooks/queries/usePoliticasComercialesQuery', () => ({
  usePoliticasComercialesQuery: () => ({ politicas: { diasAtrasFechaPedido: 7 } }),
}))
const pedidos = [
  { id: '1', estado: 'asignado', total: 100, cliente: { nombre_fantasia: 'Kiosco Norte', direccion: 'Calle 1' } },
  { id: '2', estado: 'asignado', total: 250, cliente: { nombre_fantasia: 'Almacén Sur', direccion: 'Calle 2' } },
]
vi.mock('../../hooks/queries', () => ({
  usePedidosNoEntregadosQuery: () => ({ data: pedidos, isLoading: false }),
}))

import ModalEntregasMasivas from './ModalEntregasMasivas'

const choferes = [{ id: 'c-1', nombre: 'Chofer Uno' }] as unknown as PerfilDB[]

function montar() {
  const onConfirm = vi.fn().mockResolvedValue(undefined)
  render(<ModalEntregasMasivas transportistas={choferes} onConfirm={onConfirm} onClose={vi.fn()} guardando={false} isAdmin />)
  fireEvent.change(screen.getByRole('combobox'), { target: { value: 'c-1' } })
  return onConfirm
}
const buscar = (texto: string) =>
  fireEvent.change(screen.getByPlaceholderText(/Buscar por cliente/), { target: { value: texto } })

describe('ModalEntregasMasivas · la selección sigue al filtro (Fr-B6)', () => {
  it('lo tildado que el filtro esconde no se manda ni se cuenta en la confirmación', async () => {
    const onConfirm = montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    fireEvent.click(screen.getByText('Almacén Sur'))
    expect(screen.getByText(/2 pedidos seleccionados/)).toBeInTheDocument()

    buscar('almac')
    expect(screen.queryByText('Kiosco Norte')).not.toBeInTheDocument()
    expect(screen.getByText(/1 pedido seleccionado/)).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: /Marcar como Entregados/ }))
    // La confirmación habla de la única entrega que se va a hacer.
    expect(await screen.findByText(/Se van a marcar 1 pedido como entregados/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /Confirmar|Aceptar/ }))

    await waitFor(() => expect(onConfirm).toHaveBeenCalledTimes(1))
    expect(onConfirm).toHaveBeenCalledWith('c-1', ['2'], fechaLocalISO())
  })

  it('si el filtro esconde todo lo tildado no hay nada para confirmar', () => {
    montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    buscar('almac')
    expect(screen.getByText(/0 pedidos seleccionados/)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /Marcar como Entregados/ })).toBeDisabled()
  })

  it('al volver a mostrarse, lo que estaba tildado sigue tildado', () => {
    montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    buscar('almac')
    buscar('')
    expect(screen.getByText(/1 pedido seleccionado/)).toBeInTheDocument()
  })

  it('«Seleccionar todos» está tildado cuando lo visible está todo tildado, aunque haya tildados ocultos', () => {
    montar()
    fireEvent.click(screen.getByText('Kiosco Norte'))
    fireEvent.click(screen.getByText('Almacén Sur'))
    buscar('almac')
    // Los tamaños (2 tildados, 1 visible) no coinciden, pero lo visible está completo.
    expect(screen.getByLabelText(/Seleccionar todos/)).toBeChecked()
  })

  it('«Seleccionar todos» sólo toma lo visible y se destilda con el mismo gesto', () => {
    montar()
    buscar('almac')
    const todos = screen.getByLabelText(/Seleccionar todos/)
    fireEvent.click(todos)
    expect(screen.getByText(/1 pedido seleccionado/)).toBeInTheDocument()
    fireEvent.click(todos)
    expect(screen.getByText(/0 pedidos seleccionados/)).toBeInTheDocument()
  })
})
