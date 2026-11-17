/**
 * 1600-b6 (#1600): el cierre por inactividad se lo dice al usuario.
 *
 * Antes el cierre disparaba un evento de `window` que nadie escuchaba: el usuario volvía al
 * login sin saber por qué. Ahora `useAuth` deja el motivo guardado y el login lo muestra una vez.
 */
import '@testing-library/jest-dom/vitest'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'

vi.mock('../../hooks/supabase', () => ({
  useAuth: () => ({ login: vi.fn() }),
}))

import LoginScreen from './LoginScreen'
import {
  guardarAvisoDeCierre,
  leerAvisoDeCierre,
  olvidarAvisoDeCierre,
} from '../../utils/avisoDeCierreDeSesion'

describe('LoginScreen: por qué se cerró la sesión', () => {
  beforeEach(() => {
    olvidarAvisoDeCierre()
  })

  it('tras un cierre por inactividad lo dice, con rol status', () => {
    guardarAvisoDeCierre('inactividad')

    render(<LoginScreen />)

    expect(screen.getByRole('status')).toHaveTextContent('Tu sesión se cerró por inactividad')
  })

  it('tras sacar a un usuario desactivado (1600-b15) se lo dice', () => {
    guardarAvisoDeCierre('desactivado')

    render(<LoginScreen />)

    expect(screen.getByRole('status')).toHaveTextContent('Tu usuario está desactivado')
  })

  it('lo muestra una sola vez: el siguiente ingreso no lo repite', () => {
    guardarAvisoDeCierre('inactividad')
    const primera = render(<LoginScreen />)
    expect(screen.getByRole('status')).toBeInTheDocument()
    primera.unmount()

    expect(leerAvisoDeCierre()).toBeNull()
    render(<LoginScreen />)
    expect(screen.queryByRole('status')).toBeNull()
  })

  it('sin cierre previo no hay ningún aviso', () => {
    render(<LoginScreen />)
    expect(screen.queryByRole('status')).toBeNull()
  })
})
