/**
 * 1601-b5 (#1601, D53; H2 de la revisión de C6): los emails de los usuarios llegan por la RPC
 * emails_de_usuarios. Si fallan, la lista sale igual y lo dice, con «Reintentar».
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import VistaUsuarios from '../VistaUsuarios'
import type { PerfilDB } from '../../../types'

const usuarios = [
  { id: 'u1', nombre: 'Persona Uno', rol: 'preventista', activo: true },
  { id: 'u2', nombre: 'Persona Dos', email: 'dos@example.invalid', rol: 'encargado', activo: true },
] as unknown as PerfilDB[]

describe('VistaUsuarios — los emails', () => {
  it('sin error no avisa nada y muestra los emails que hay', () => {
    render(<VistaUsuarios usuarios={usuarios} loading={false} onEditarUsuario={vi.fn()} />)
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(screen.getByText('dos@example.invalid')).toBeInTheDocument()
  })

  it('si no se pudieron cargar, la lista sale igual con el aviso y su «Reintentar»', () => {
    const reintentar = vi.fn()
    render(<VistaUsuarios usuarios={usuarios} loading={false} errorEmails onReintentarEmails={reintentar} onEditarUsuario={vi.fn()} />)
    expect(screen.getByRole('alert')).toHaveTextContent('No se pudieron cargar los emails de los usuarios.')
    expect(screen.getByText('Persona Uno')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Reintentar' }))
    expect(reintentar).toHaveBeenCalledTimes(1)
  })
})
