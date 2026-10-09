/**
 * SucursalSelector en la barra superior del celular (#1047).
 *
 * jsdom no aplica Tailwind, asi que no se mide el ancho: se fijan las clases que
 * hacen que el selector sea lo que cede cuando el lado derecho de la barra no
 * entra en 375 px. Un item de flex tiene `min-width: auto`: sin `min-w-0` en la
 * raiz el nombre, aunque este truncado, empuja el ancho y el avatar se corta.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'

let ctxMock = {
  currentSucursalId: 1 as number | null,
  currentSucursalNombre: 'Tucumán',
  sucursales: [{ id: 1, nombre: 'Tucumán', rol: 'admin' }],
  hasMultipleSucursales: false,
  switchSucursal: vi.fn(),
}
vi.mock('../../../contexts/SucursalContext', () => ({
  useSucursal: () => ctxMock,
}))

import SucursalSelector from '../SucursalSelector'

describe('SucursalSelector — cede ancho en la barra superior', () => {
  it('con varias sucursales: la raiz y el boton pueden achicarse y el nombre se trunca', () => {
    ctxMock = {
      ...ctxMock,
      hasMultipleSucursales: true,
      sucursales: [
        { id: 1, nombre: 'Tucumán', rol: 'admin' },
        { id: 2, nombre: 'Taco Pozo', rol: 'admin' },
      ],
    }
    render(<SucursalSelector />)
    const boton = screen.getByRole('button', { name: 'Cambiar sucursal' })

    expect(boton.parentElement).toHaveClass('min-w-0')
    expect(boton).toHaveClass('min-w-0')
    expect(boton).toHaveClass('max-w-full')
    expect(screen.getByText('Tucumán')).toHaveClass('truncate')
  })

  it('con una sola sucursal: el distintivo puede achicarse y el nombre se trunca', () => {
    ctxMock = { ...ctxMock, hasMultipleSucursales: false }
    render(<SucursalSelector />)
    const nombre = screen.getByText('Tucumán')
    const distintivo = nombre.parentElement as HTMLElement

    expect(distintivo).toHaveClass('min-w-0')
    expect(nombre).toHaveClass('truncate')
  })
})
