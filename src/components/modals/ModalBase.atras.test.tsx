/**
 * ModalBase y el «atrás» del teléfono (decisión 4 del dueño, #1603), con el historial real de jsdom: el
 * «atrás» cierra el modal por el mismo camino que la X y Escape, y con cambios sin guardar los tres
 * preguntan «Salir sin guardar» y cierran recién con «Salir igual».
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { asentar, atras, marca } from '../../test/atrasHelpers'
import { render, screen, cleanup, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import ModalBase from './ModalBase'
import { reiniciarAtrasModales } from '../../utils/atrasModales'


beforeEach(() => {
  reiniciarAtrasModales()
  window.history.replaceState(null, '', '/')
})
afterEach(async () => {
  cleanup()
  await asentar()
  reiniciarAtrasModales()
})

async function abrir(hayCambios: boolean) {
  const onClose = vi.fn()
  const user = userEvent.setup()
  const r = render(
    <ModalBase title="Ventana de prueba" onClose={onClose} hayCambios={hayCambios}>
      <p>contenido</p>
    </ModalBase>,
  )
  await asentar()
  return { onClose, user, ...r }
}

const pregunta = () => screen.queryByText('Lo que cargaste todavía no se guardó. ¿Salir igual?')
const botonX = () => screen.getByRole('button', { name: /cerrar/i })

describe('ModalBase · sin cambios cierra de una, por los tres caminos', () => {
  it('el «atrás» cierra el modal y no pregunta', async () => {
    const { onClose } = await abrir(false)
    expect(marca()).toBe(1)
    await atras()
    expect(onClose).toHaveBeenCalledTimes(1)
    expect(pregunta()).not.toBeInTheDocument()
  })

  it('la X cierra y no pregunta', async () => {
    const { onClose, user } = await abrir(false)
    await user.click(botonX())
    expect(onClose).toHaveBeenCalledTimes(1)
    expect(pregunta()).not.toBeInTheDocument()
  })

  it('Escape cierra y no pregunta', async () => {
    const { onClose, user } = await abrir(false)
    await user.keyboard('{Escape}')
    expect(onClose).toHaveBeenCalledTimes(1)
    expect(pregunta()).not.toBeInTheDocument()
  })
})

describe('ModalBase · con cambios sin guardar pregunta, por los tres caminos', () => {
  it.each([
    ['la X', async (user: ReturnType<typeof userEvent.setup>) => { await user.click(botonX()) }],
    ['Escape', async (user: ReturnType<typeof userEvent.setup>) => { await user.keyboard('{Escape}') }],
    ['el «atrás» del teléfono', async () => { await atras() }],
  ])('%s: pregunta «Salir sin guardar» y no cierra todavía', async (_camino, accion) => {
    const { onClose, user } = await abrir(true)
    await accion(user)

    expect(await screen.findByText('Lo que cargaste todavía no se guardó. ¿Salir igual?')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Salir igual' })).toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
  })

  it.each([
    ['la X', async (user: ReturnType<typeof userEvent.setup>) => { await user.click(botonX()) }],
    ['Escape', async (user: ReturnType<typeof userEvent.setup>) => { await user.keyboard('{Escape}') }],
    ['el «atrás» del teléfono', async () => { await atras() }],
  ])('%s: «Seguir editando» vuelve al formulario; «Salir igual» cierra', async (_camino, accion) => {
    const { onClose, user } = await abrir(true)
    await accion(user)
    await user.click(await screen.findByRole('button', { name: 'Seguir editando' }))
    expect(pregunta()).not.toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByText('contenido')).toBeInTheDocument()
    // Quien toca «atrás» no lo hace en el mismo milisegundo en que cerró la pregunta.
    await asentar()

    await accion(user)
    await user.click(await screen.findByRole('button', { name: 'Salir igual' }))
    expect(onClose).toHaveBeenCalledTimes(1)
  })

  it('con la pregunta abierta, el «atrás» cierra sólo la pregunta (la de arriba primero), no el modal', async () => {
    const { onClose } = await abrir(true)
    await atras()
    expect(await screen.findByText('Lo que cargaste todavía no se guardó. ¿Salir igual?')).toBeInTheDocument()
    expect(marca()).toBe(2)

    await atras()
    expect(pregunta()).not.toBeInTheDocument()
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByText('contenido')).toBeInTheDocument()
    expect(marca()).toBe(1)

    // Y un «atrás» más vuelve a preguntar.
    await atras()
    expect(await screen.findByText('Lo que cargaste todavía no se guardó. ¿Salir igual?')).toBeInTheDocument()
  })

  it('al salir igual no queda ninguna entrada de historial del modal ni de la pregunta', async () => {
    const { user, rerender, onClose } = await abrir(true)
    await atras()
    await user.click(await screen.findByRole('button', { name: 'Salir igual' }))
    expect(onClose).toHaveBeenCalledTimes(1)
    // El padre cierra el modal.
    rerender(<div />)
    await waitFor(() => expect(marca()).toBeUndefined())
  })

  it('«atrás» con el formulario sin cambios después de haberlos tenido: no pregunta', async () => {
    const onClose = vi.fn()
    const { rerender } = render(<ModalBase title="Ventana de prueba" onClose={onClose} hayCambios><p>contenido</p></ModalBase>)
    await asentar()
    rerender(<ModalBase title="Ventana de prueba" onClose={onClose} hayCambios={false}><p>contenido</p></ModalBase>)
    await atras()
    expect(onClose).toHaveBeenCalledTimes(1)
    expect(pregunta()).not.toBeInTheDocument()
  })
})

describe('ModalBase · modales apilados', () => {
  it('el «atrás» cierra el de arriba primero y después el de abajo', async () => {
    const cierraAbajo = vi.fn()
    const cierraArriba = vi.fn()
    render(
      <ModalBase title="Abajo" onClose={cierraAbajo}>
        <ModalBase title="Arriba" onClose={cierraArriba}><p>arriba</p></ModalBase>
      </ModalBase>,
    )
    await asentar()
    expect(marca()).toBe(2)

    await atras()
    expect(cierraArriba).toHaveBeenCalledTimes(1)
    expect(cierraAbajo).not.toHaveBeenCalled()
  })
})
