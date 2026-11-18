/**
 * H5 de la revisión de B23 (#1603): el rojo por límite sólo miraba lo tipeado. Si el límite baja DESPUÉS
 * de confirmar (en la edición de un pedido, el stock disponible cambia de fondo), el valor ya cargado
 * seguía en limpio y el formulario dejaba guardar un número que el server iba a rechazar.
 *
 * Ahora, cuando un límite que ya tenía el campo se vuelve más estricto y el valor confirmado deja de
 * cumplirlo, el campo se pone en rojo con su motivo y el formulario no guarda. No se recorta nada: el
 * valor sigue siendo el que era, y lo cambia quien edita.
 *
 * Lo que NO se pone en rojo: un valor que ya estaba fuera del límite al abrir (un pedido viejo con una
 * cantidad bajo el mínimo de hoy se sigue editando) ni un límite que aparece de golpe (undefined → número:
 * el dato que lo calcula recién llegó).
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import { useState, type ComponentProps } from 'react'
import { NumberInput } from './NumberInput'
import { AvisoCamposEnRojo } from './AvisoCamposEnRojo'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'

type Limites = Pick<ComponentProps<typeof NumberInput>, 'min' | 'max' | 'motivoMin' | 'motivoMax'>

function Formulario({ inicial, limites, onGuardar }: { inicial: number; limites: Limites; onGuardar: (n: number | null) => void }) {
  const [v, setV] = useState<number | null>(inicial)
  const ilegibles = useRegistroIlegibles()
  return (
    <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
      <NumberInput aria-label="num" integer value={v} onChange={setV} {...limites} />
      <AvisoCamposEnRojo />
      <button type="button" disabled={ilegibles.hay} onClick={() => { if (!ilegibles.hay) onGuardar(v) }}>Guardar</button>
    </RegistroIlegiblesContext.Provider>
  )
}

describe('NumberInput · el límite cambia después de confirmar el valor (H5)', () => {
  it('si el máximo baja por debajo del valor ya cargado, el campo se pone en rojo con su motivo y no guarda', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn()
    const { rerender } = render(
      <Formulario inicial={8} limites={{ min: 1, max: 10, motivoMax: 'Hay 10 en stock' }} onGuardar={onGuardar} />,
    )
    const input = screen.getByLabelText('num')
    expect(input).not.toHaveAttribute('aria-invalid', 'true')

    // El stock cae de fondo a 5: el 8 ya cargado no se puede entregar.
    rerender(<Formulario inicial={8} limites={{ min: 1, max: 5, motivoMax: 'Hay 5 en stock' }} onGuardar={onGuardar} />)

    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('Hay 5 en stock')
    expect(input).toHaveValue('8') // no se recorta a 5
    expect(screen.getByText('Hay un campo en rojo para corregir')).toBeInTheDocument()
    const guardar = screen.getByRole('button', { name: 'Guardar' })
    expect(guardar).toBeDisabled()
    await user.click(guardar)
    expect(onGuardar).not.toHaveBeenCalled()
  })

  it('corregir el valor a mano saca el rojo y guarda lo tipeado', async () => {
    const user = userEvent.setup()
    const onGuardar = vi.fn()
    const { rerender } = render(<Formulario inicial={8} limites={{ min: 1, max: 10 }} onGuardar={onGuardar} />)
    rerender(<Formulario inicial={8} limites={{ min: 1, max: 5 }} onGuardar={onGuardar} />)
    const input = screen.getByLabelText('num')
    expect(input).toHaveAttribute('aria-invalid', 'true')

    await user.clear(input)
    await user.type(input, '4')
    await user.click(screen.getByRole('button', { name: 'Guardar' }))

    expect(input).not.toHaveAttribute('aria-invalid', 'true')
    expect(onGuardar).toHaveBeenCalledWith(4)
  })

  it('si el límite vuelve a subir, el rojo se va solo', () => {
    const { rerender } = render(<Formulario inicial={8} limites={{ max: 10 }} onGuardar={vi.fn()} />)
    rerender(<Formulario inicial={8} limites={{ max: 5 }} onGuardar={vi.fn()} />)
    const input = screen.getByLabelText('num')
    expect(input).toHaveAttribute('aria-invalid', 'true')

    rerender(<Formulario inicial={8} limites={{ max: 12 }} onGuardar={vi.fn()} />)
    expect(input).not.toHaveAttribute('aria-invalid', 'true')
    expect(screen.queryByRole('alert')).toBeNull()
  })

  it('lo mismo con el mínimo: si sube por encima del valor ya cargado, queda en rojo', () => {
    const { rerender } = render(<Formulario inicial={4} limites={{ min: 2, motivoMin: 'El mínimo de venta es 2' }} onGuardar={vi.fn()} />)
    rerender(<Formulario inicial={4} limites={{ min: 6, motivoMin: 'El mínimo de venta es 6' }} onGuardar={vi.fn()} />)
    const input = screen.getByLabelText('num')
    expect(input).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByRole('alert')).toHaveTextContent('El mínimo de venta es 6')
  })

  it('un valor que ya estaba fuera del límite al abrir no se pone en rojo (el pedido viejo se sigue editando)', () => {
    render(<Formulario inicial={3} limites={{ min: 6 }} onGuardar={vi.fn()} />)
    expect(screen.getByLabelText('num')).not.toHaveAttribute('aria-invalid', 'true')
  })

  it('un límite que aparece de golpe (llegó el dato que lo calcula) no pone en rojo lo ya cargado', () => {
    const { rerender } = render(<Formulario inicial={8} limites={{}} onGuardar={vi.fn()} />)
    rerender(<Formulario inicial={8} limites={{ max: 5 }} onGuardar={vi.fn()} />)
    expect(screen.getByLabelText('num')).not.toHaveAttribute('aria-invalid', 'true')
  })

  it('un límite que cambia pero que el valor cumple no pone nada en rojo', () => {
    const { rerender } = render(<Formulario inicial={3} limites={{ min: 1, max: 10 }} onGuardar={vi.fn()} />)
    rerender(<Formulario inicial={3} limites={{ min: 2, max: 5 }} onGuardar={vi.fn()} />)
    expect(screen.getByLabelText('num')).not.toHaveAttribute('aria-invalid', 'true')
  })
})
