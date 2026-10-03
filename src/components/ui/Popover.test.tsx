/**
 * El primitivo `Popover` (Radix): lo que el panel de filtros de /pedidos en
 * escritorio (#769) da por sentado. Se asevera por rol ARIA y comportamiento.
 */
import '@testing-library/jest-dom/vitest'
import { useState } from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { Popover, PopoverClose, PopoverContent, PopoverTrigger } from './Popover'

const dejarCorrerFocusScope = () => act(() => new Promise<void>(resolve => setTimeout(resolve, 0)))

function Ejemplo({ onCambio = vi.fn() }: { onCambio?: (v: string) => void }) {
  const [abierto, setAbierto] = useState(false)
  return (
    <>
      <button type="button">Afuera</button>
      <Popover open={abierto} onOpenChange={setAbierto}>
        <PopoverTrigger asChild>
          <button type="button">Abrir panel</button>
        </PopoverTrigger>
        <PopoverContent aria-label="Panel de prueba">
          <label>
            Campo
            <input onChange={e => onCambio(e.target.value)} />
          </label>
          <PopoverClose asChild>
            <button type="button">Listo</button>
          </PopoverClose>
        </PopoverContent>
      </Popover>
    </>
  )
}

describe('Popover', () => {
  it('cerrado no monta el contenido; el trigger anuncia que abre un diálogo', () => {
    render(<Ejemplo />)

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    const trigger = screen.getByRole('button', { name: 'Abrir panel' })
    expect(trigger).toHaveAttribute('aria-haspopup', 'dialog')
    expect(trigger).toHaveAttribute('aria-expanded', 'false')
  })

  it('el trigger lo abre como un diálogo con nombre, controlado por el trigger', async () => {
    const user = userEvent.setup()
    render(<Ejemplo />)

    await user.click(screen.getByRole('button', { name: 'Abrir panel' }))

    const dialogo = await screen.findByRole('dialog', { name: 'Panel de prueba' })
    const trigger = screen.getByRole('button', { name: 'Abrir panel' })
    expect(trigger).toHaveAttribute('aria-expanded', 'true')
    expect(trigger).toHaveAttribute('aria-controls', dialogo.id)
  })

  it('el contenido es interactivo mientras está abierto', async () => {
    const user = userEvent.setup()
    const onCambio = vi.fn()
    render(<Ejemplo onCambio={onCambio} />)

    await user.click(screen.getByRole('button', { name: 'Abrir panel' }))
    await user.type(await screen.findByRole('textbox', { name: 'Campo' }), 'x')

    expect(onCambio).toHaveBeenCalledWith('x')
    expect(screen.getByRole('dialog')).toBeInTheDocument()
  })

  it('Escape lo cierra y el foco vuelve al trigger', async () => {
    const user = userEvent.setup()
    render(<Ejemplo />)

    await user.click(screen.getByRole('button', { name: 'Abrir panel' }))
    await screen.findByRole('dialog')
    await user.keyboard('{Escape}')
    await dejarCorrerFocusScope()

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Abrir panel' })).toHaveFocus()
  })

  it('un click afuera lo cierra', async () => {
    const user = userEvent.setup()
    render(<Ejemplo />)

    await user.click(screen.getByRole('button', { name: 'Abrir panel' }))
    await screen.findByRole('dialog')
    await user.click(screen.getByRole('button', { name: 'Afuera' }))

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('PopoverClose lo cierra', async () => {
    const user = userEvent.setup()
    render(<Ejemplo />)

    await user.click(screen.getByRole('button', { name: 'Abrir panel' }))
    await user.click(await screen.findByRole('button', { name: 'Listo' }))

    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })
})
