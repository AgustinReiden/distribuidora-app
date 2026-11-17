import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalAceptarMovimiento from './ModalAceptarMovimiento'
import type { ProductoDB } from '../../types'
import type { MovimientoSucursalDB, MovimientoItemDB } from '../../hooks/queries'

// #1558 (D7): un producto desactivado del destino no se elige solo; elegirlo pide confirmar que se
// lo reactiva, y la resolución viaja con la marca `reactivar`.
const MOV = { id: 3, origen: { nombre: 'Sucursal 2' }, total_unidades: 5 } as unknown as MovimientoSucursalDB
const ITEM = {
  id: 40, cantidad: 5, origen_nombre: 'Agua 500', origen_codigo: 'A5', origen_costo_con_iva: 100,
} as unknown as MovimientoItemDB
const PRODUCTOS = [
  { id: '7', nombre: 'Agua 500', codigo: 'A5', precio: 1, stock: 0, activo: false },
  { id: '8', nombre: 'Soda', codigo: 'S1', precio: 1, stock: 0, activo: true },
] as unknown as ProductoDB[]

function renderModal() {
  const onConfirmar = vi.fn(() => Promise.resolve())
  render(
    <ModalAceptarMovimiento movimiento={MOV} items={[ITEM]} loadingItems={false} productosDestino={PRODUCTOS}
      guardando={false} onConfirmar={onConfirmar} onDenegar={vi.fn(() => Promise.resolve())} onClose={vi.fn()} />,
  )
  return { onConfirmar, user: userEvent.setup() }
}

describe('ModalAceptarMovimiento · el destino desactivado (#1558, D7)', () => {
  it('no preselecciona el desactivado que coincide por código y nombre: propone crear uno nuevo', async () => {
    const { user, onConfirmar } = renderModal()
    expect(screen.getByRole('button', { name: /Crear nuevo/ })).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /Aceptar e ingresar stock/ }))
    expect(onConfirmar).toHaveBeenCalledWith([{ item_id: 40, accion: 'crear_nuevo' }])
  })

  it('lista los desactivados aparte, y elegir uno pide confirmar; confirmado, viaja con reactivar', async () => {
    const { user, onConfirmar } = renderModal()
    await user.click(screen.getByRole('button', { name: /Crear nuevo/ }))
    expect(screen.getByText('Desactivados en esta sucursal')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /Agua 500.*desactivado/ }))

    expect(screen.getByText('Este producto está desactivado. ¿Lo reactivamos al recibir?')).toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: 'Sí, reactivarlo' }))
    expect(screen.getByText('Está desactivado: se reactiva al recibir.')).toBeInTheDocument()

    await user.click(screen.getByRole('button', { name: /Aceptar e ingresar stock/ }))
    expect(onConfirmar).toHaveBeenCalledWith([
      { item_id: 40, accion: 'match_existente', producto_destino_id: 7, reactivar: true },
    ])
  })

  it('«Elegir otro» no lo elige ni lo marca', async () => {
    const { user, onConfirmar } = renderModal()
    await user.click(screen.getByRole('button', { name: /Crear nuevo/ }))
    await user.click(screen.getByRole('button', { name: /Agua 500.*desactivado/ }))
    await user.click(screen.getByRole('button', { name: 'Elegir otro' }))

    expect(screen.queryByText('Este producto está desactivado. ¿Lo reactivamos al recibir?')).not.toBeInTheDocument()
    await user.click(screen.getByRole('button', { name: /Aceptar e ingresar stock/ }))
    expect(onConfirmar).toHaveBeenCalledWith([{ item_id: 40, accion: 'crear_nuevo' }])
  })

  it('un activo se elige sin preguntar y sin la marca', async () => {
    const { user, onConfirmar } = renderModal()
    await user.click(screen.getByRole('button', { name: /Crear nuevo/ }))
    await user.click(screen.getByRole('button', { name: /^Soda/ }))
    await user.click(screen.getByRole('button', { name: /Aceptar e ingresar stock/ }))
    expect(onConfirmar).toHaveBeenCalledWith([{ item_id: 40, accion: 'match_existente', producto_destino_id: 8 }])
  })
})
