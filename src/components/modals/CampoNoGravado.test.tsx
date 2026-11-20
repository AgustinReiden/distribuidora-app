/**
 * H7 de la revisión de C3 (#1603, #1590): el «No gravado» de la cabecera de una FC puede ser
 * negativo (un descuento sobre renglones exentos o no gravados), hasta lo que suman esos
 * descuentos. Con `NumberInput` no se podía tipear: rechaza todo negativo antes de mirar el
 * mínimo y frenaba el Guardar. El campo es `CampoNumero` con `negativo` y el piso como motivo.
 */
import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { useState } from 'react'
import CampoNoGravado from './CampoNoGravado'

function Envoltorio({ inicial, piso, onChange }: { inicial: number; piso: number; onChange: (n: number) => void }) {
  const [valor, setValor] = useState(inicial)
  return (
    <CampoNoGravado
      valor={valor}
      piso={piso}
      onChange={(n) => { setValor(n); onChange(n) }}
    />
  )
}

const campo = () => screen.getByRole('textbox', { name: 'No gravado' })

describe('CampoNoGravado', () => {
  it('se puede tipear un negativo dentro del piso, y lo guarda', async () => {
    const onChange = vi.fn()
    render(<Envoltorio inicial={0} piso={-150} onChange={onChange} />)
    await userEvent.clear(campo())
    await userEvent.type(campo(), '-100')
    expect(onChange).toHaveBeenLastCalledWith(-100)
    expect(screen.queryByText(/No puede bajar de/)).not.toBeInTheDocument()
  })

  it('debajo del piso queda en rojo con su motivo y no lo guarda', async () => {
    const onChange = vi.fn()
    render(<Envoltorio inicial={0} piso={-150} onChange={onChange} />)
    await userEvent.clear(campo())
    await userEvent.type(campo(), '-200')
    expect(screen.getByText(/No puede bajar de/)).toBeInTheDocument()
    expect(onChange).not.toHaveBeenCalledWith(-200)
  })

  it('sin descuentos no gravados el piso es 0: un negativo queda en rojo', async () => {
    const onChange = vi.fn()
    render(<Envoltorio inicial={0} piso={0} onChange={onChange} />)
    await userEvent.clear(campo())
    await userEvent.type(campo(), '-10')
    expect(screen.getByText(/No puede bajar de/)).toBeInTheDocument()
    expect(onChange).not.toHaveBeenCalledWith(-10)
  })

  it('muestra el valor que viene de los cargos, negativo, sin rojo', () => {
    render(<Envoltorio inicial={-150} piso={-150} onChange={vi.fn()} />)
    expect(campo()).toHaveValue('-150')
    expect(screen.queryByText(/No puede bajar de/)).not.toBeInTheDocument()
  })
})
