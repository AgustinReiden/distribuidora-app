/**
 * Caracterización de LoginScreen (WP-56, #780).
 *
 * Escrito contra el código de ANTES del rediseño y verde antes de tocarlo: es lo
 * que ata el restyle a lo que no se puede mover. Los selectores son por rol y por
 * texto, no por clase, así que el cambio de marca no los afecta.
 *
 * Qué custodia, y por qué importa (lo mide e2e/login.spec.js en Playwright):
 *  - el heading con «Distribuidora» (también lo mide accessibility.spec.js);
 *  - `#email` y `#password`, cada uno con su `<label for>`;
 *  - el botón «Ingresar», `type="submit"` dentro del `<form>`;
 *  - el orden de Tab: email -> contraseña -> botón, SIN nada enfocable antes del
 *    email ni en el medio (un «olvidé mi contraseña» agregado de paso rompe el
 *    test de teclado del e2e);
 *  - que enviar llama al login con email y contraseña, el estado de carga y el
 *    mensaje de error.
 */
import '@testing-library/jest-dom/vitest'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'

const loginMock = vi.fn<(email: string, password: string) => Promise<void>>()
vi.mock('../../hooks/supabase', () => ({
  useAuth: () => ({ login: loginMock }),
}))

import LoginScreen from './LoginScreen'

/** Lo que el navegador recorre con Tab, en orden de DOM (ningún tabindex positivo en esta pantalla). */
function enfocables(contenedor: HTMLElement): Element[] {
  return Array.from(
    contenedor.querySelectorAll('a[href], button, input, select, textarea, [tabindex]'),
  ).filter(
    (el) => !el.hasAttribute('disabled') && el.getAttribute('tabindex') !== '-1',
  )
}

/** Una promesa que se resuelve o rechaza a mano, para ver la pantalla a mitad del login. */
function promesaPendiente() {
  let resolver!: () => void
  let rechazar!: (e: unknown) => void
  const promesa = new Promise<void>((res, rej) => {
    resolver = res
    rechazar = rej
  })
  return { promesa, resolver, rechazar }
}

beforeEach(() => {
  loginMock.mockReset()
  loginMock.mockResolvedValue(undefined)
})

describe('LoginScreen: lo que hay en pantalla', () => {
  it('tiene un heading de nivel 1 con «Distribuidora»', () => {
    render(<LoginScreen />)
    expect(screen.getByRole('heading', { level: 1, name: /distribuidora/i })).toBeVisible()
  })

  it('el email es #email, con su label, de tipo email y obligatorio', () => {
    const { container } = render(<LoginScreen />)
    const email = screen.getByLabelText('Email')
    expect(email).toBe(container.querySelector('#email'))
    expect(email).toHaveAttribute('id', 'email')
    expect(email).toHaveAttribute('type', 'email')
    expect(email).toBeRequired()
    expect(container.querySelector('label[for="email"]')).toHaveTextContent('Email')
  })

  it('la contraseña es #password, con su label, de tipo password y obligatoria', () => {
    const { container } = render(<LoginScreen />)
    const password = screen.getByLabelText('Contraseña')
    expect(password).toBe(container.querySelector('#password'))
    expect(password).toHaveAttribute('id', 'password')
    expect(password).toHaveAttribute('type', 'password')
    expect(password).toBeRequired()
    expect(container.querySelector('label[for="password"]')).toHaveTextContent('Contraseña')
  })

  it('«Ingresar» es el botón submit, y está adentro del <form> junto con los dos campos', () => {
    const { container } = render(<LoginScreen />)
    const boton = screen.getByRole('button', { name: /ingresar/i })
    expect(boton).toHaveAttribute('type', 'submit')
    expect(boton).toBeEnabled()
    const form = container.querySelector('form')
    expect(form).not.toBeNull()
    expect(boton.closest('form')).toBe(form)
    expect(container.querySelector('#email')?.closest('form')).toBe(form)
    expect(container.querySelector('#password')?.closest('form')).toBe(form)
  })

  it('es el único botón de la pantalla', () => {
    render(<LoginScreen />)
    expect(screen.getAllByRole('button')).toHaveLength(1)
  })

  it('no muestra ningún error hasta que falla un intento', () => {
    render(<LoginScreen />)
    expect(screen.queryByText(/incorrectos/i)).not.toBeInTheDocument()
  })
})

describe('LoginScreen: teclado', () => {
  it('lo enfocable es exactamente email, contraseña y botón, en ese orden', () => {
    const { container } = render(<LoginScreen />)
    const esperado = [
      container.querySelector('#email'),
      container.querySelector('#password'),
      screen.getByRole('button', { name: /ingresar/i }),
    ]
    expect(esperado.every(Boolean)).toBe(true)
    expect(enfocables(container)).toEqual(esperado)
  })

  it('Tab va email -> contraseña -> botón, sin nada en el medio', async () => {
    const user = userEvent.setup()
    render(<LoginScreen />)
    const email = screen.getByLabelText('Email')
    const password = screen.getByLabelText('Contraseña')
    const boton = screen.getByRole('button', { name: /ingresar/i })

    await user.click(email)
    expect(email).toHaveFocus()
    await user.tab()
    expect(password).toHaveFocus()
    await user.tab()
    expect(boton).toHaveFocus()
  })

  it('el primer Tab desde el borde de la página cae en el email', async () => {
    const user = userEvent.setup()
    render(<LoginScreen />)
    await user.tab()
    expect(screen.getByLabelText('Email')).toHaveFocus()
  })
})

describe('LoginScreen: enviar', () => {
  it('al apretar «Ingresar» llama al login con el email y la contraseña escritos', async () => {
    const user = userEvent.setup()
    render(<LoginScreen />)

    await user.type(screen.getByLabelText('Email'), 'ana@distribuidora.com')
    await user.type(screen.getByLabelText('Contraseña'), 'clave-secreta')
    await user.click(screen.getByRole('button', { name: /ingresar/i }))

    expect(loginMock).toHaveBeenCalledTimes(1)
    expect(loginMock).toHaveBeenCalledWith('ana@distribuidora.com', 'clave-secreta')
  })

  it('Enter en la contraseña también envía el formulario', async () => {
    const user = userEvent.setup()
    render(<LoginScreen />)

    await user.type(screen.getByLabelText('Email'), 'ana@distribuidora.com')
    await user.type(screen.getByLabelText('Contraseña'), 'clave-secreta{Enter}')

    expect(loginMock).toHaveBeenCalledTimes(1)
    expect(loginMock).toHaveBeenCalledWith('ana@distribuidora.com', 'clave-secreta')
  })

  it('con el formulario incompleto no llama al login (los campos son obligatorios)', async () => {
    const user = userEvent.setup()
    render(<LoginScreen />)

    await user.type(screen.getByLabelText('Contraseña'), 'clave-secreta')
    await user.click(screen.getByRole('button', { name: /ingresar/i }))

    expect(loginMock).not.toHaveBeenCalled()
  })
})

describe('LoginScreen: cargando', () => {
  it('mientras el login está en vuelo el botón queda deshabilitado, con spinner, y no envía dos veces', async () => {
    const user = userEvent.setup()
    const { promesa, resolver } = promesaPendiente()
    loginMock.mockReturnValue(promesa)
    const { container } = render(<LoginScreen />)

    await user.type(screen.getByLabelText('Email'), 'ana@distribuidora.com')
    await user.type(screen.getByLabelText('Contraseña'), 'clave-secreta')
    await user.click(screen.getByRole('button', { name: /ingresar/i }))

    // Con el login en vuelo hay un solo botón: se lo busca por rol, sin nombre.
    const boton = screen.getByRole('button')
    expect(boton).toBeDisabled()
    expect(boton.querySelector('svg.animate-spin')).not.toBeNull()

    // Un segundo click sobre un botón deshabilitado no manda otro login.
    await user.click(boton)
    expect(loginMock).toHaveBeenCalledTimes(1)

    resolver()
    await waitFor(() => expect(screen.getByRole('button')).toBeEnabled())
    expect(container.querySelector('svg.animate-spin')).toBeNull()
    expect(screen.getByRole('button', { name: /ingresar/i })).toBeEnabled()
  })
})

describe('LoginScreen: error', () => {
  async function intentar(user: ReturnType<typeof userEvent.setup>) {
    await user.type(screen.getByLabelText('Email'), 'ana@distribuidora.com')
    await user.type(screen.getByLabelText('Contraseña'), 'clave-secreta')
    await user.click(screen.getByRole('button', { name: /ingresar/i }))
  }

  it('un error de credenciales muestra el mensaje genérico y devuelve el botón', async () => {
    const user = userEvent.setup()
    loginMock.mockRejectedValue(new Error('Invalid login credentials'))
    render(<LoginScreen />)

    await intentar(user)

    expect(await screen.findByText('Email o contraseña incorrectos')).toBeVisible()
    expect(screen.getByRole('button', { name: /ingresar/i })).toBeEnabled()
    // Lo escrito no se pierde: se reintenta sin volver a tipear.
    expect(screen.getByLabelText('Email')).toHaveValue('ana@distribuidora.com')
    expect(screen.getByLabelText('Contraseña')).toHaveValue('clave-secreta')
  })

  it('un error que no es un Error también cae en el mensaje genérico', async () => {
    const user = userEvent.setup()
    loginMock.mockRejectedValue('timeout')
    render(<LoginScreen />)

    await intentar(user)

    expect(await screen.findByText('Email o contraseña incorrectos')).toBeVisible()
  })

  it('un error que menciona el perfil se muestra tal cual', async () => {
    const user = userEvent.setup()
    loginMock.mockRejectedValue(new Error('No se pudo cargar el perfil del usuario'))
    render(<LoginScreen />)

    await intentar(user)

    expect(await screen.findByText('No se pudo cargar el perfil del usuario')).toBeVisible()
    expect(screen.queryByText('Email o contraseña incorrectos')).not.toBeInTheDocument()
  })

  it('el error se limpia al reintentar', async () => {
    const user = userEvent.setup()
    const { promesa, resolver } = promesaPendiente()
    loginMock.mockRejectedValueOnce(new Error('Invalid login credentials'))
    loginMock.mockReturnValueOnce(promesa)
    render(<LoginScreen />)

    await intentar(user)
    expect(await screen.findByText('Email o contraseña incorrectos')).toBeVisible()

    await user.click(screen.getByRole('button', { name: /ingresar/i }))
    await waitFor(() => expect(screen.queryByText('Email o contraseña incorrectos')).not.toBeInTheDocument())
    expect(loginMock).toHaveBeenCalledTimes(2)

    resolver()
    await waitFor(() => expect(screen.getByRole('button')).toBeEnabled())
  })
})
