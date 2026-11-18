/**
 * B20 (H4 y H11 de la segunda lente): las unidades de un vencimiento de la compra.
 * - Con `commitOnChange`, «1.200» tipeado no deja el último pedazo («1») en la compra: queda en rojo
 *   y la compra no se guarda.
 * - El `min=1` que tenía el `type="number"`: un vencimiento con 0 unidades se descartaba sin aviso;
 *   ahora se dice y frena el guardado.
 */
import { describe, it, expect } from 'vitest'
import { useState } from 'react'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import VencimientosLineaCompra from './VencimientosLineaCompra'
import { RegistroIlegiblesContext, useRegistroIlegibles } from '../../hooks/useRegistroIlegibles'
import type { VencimientoLinea } from '../modals/ModalCompra.reducer'

function Compra({ inicial }: { inicial: VencimientoLinea[] }) {
  const ilegibles = useRegistroIlegibles()
  const [v, setV] = useState(inicial)
  return (
    <RegistroIlegiblesContext.Provider value={ilegibles.registro}>
      <VencimientosLineaCompra cantidadLinea={2000} vencimientos={v} onChange={setV} />
      <span data-testid="cantidades">{v.map(x => x.cantidad).join(',')}</span>
      <button type="button" disabled={ilegibles.hay}>Registrar Compra</button>
    </RegistroIlegiblesContext.Provider>
  )
}

const abrir = async (user: ReturnType<typeof userEvent.setup>) => {
  // El badge dice «Vence 01/03/2027» con un vencimiento con fecha; abre la lista.
  await user.click(screen.getByRole('button', { name: /^Vence/ }))
}

describe('VencimientosLineaCompra · las unidades', () => {
  it('«1.200» tipeado queda en rojo, la compra conserva lo de antes y no se registra', async () => {
    const user = userEvent.setup()
    render(<Compra inicial={[{ fecha: '2027-03-01', cantidad: 5 }]} />)
    await abrir(user)
    const campo = screen.getByLabelText('Unidades del vencimiento 1')
    await user.click(campo)
    await user.keyboard('1.200')
    expect(campo).toHaveAttribute('aria-invalid', 'true')
    expect(screen.getByTestId('cantidades')).toHaveTextContent('5')
    expect(screen.getByRole('button', { name: 'Registrar Compra' })).toBeDisabled()
  })

  it('«1200» tipeado se ve «1.200» y entra', async () => {
    const user = userEvent.setup()
    render(<Compra inicial={[{ fecha: '2027-03-01', cantidad: 5 }]} />)
    await abrir(user)
    const campo = screen.getByLabelText('Unidades del vencimiento 1')
    await user.click(campo)
    await user.keyboard('1200')
    expect(campo).toHaveValue('1.200')
    expect(screen.getByTestId('cantidades')).toHaveTextContent('1200')
    expect(screen.getByRole('button', { name: 'Registrar Compra' })).toBeEnabled()
  })

  it('un vencimiento con 0 unidades lo dice y frena la compra', async () => {
    const user = userEvent.setup()
    render(<Compra inicial={[{ fecha: '2027-03-01', cantidad: 0 }]} />)
    await abrir(user)
    expect(screen.getByText('Cada vencimiento lleva 1 unidad o más: poné cuántas o quitalo')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Registrar Compra' })).toBeDisabled()
  })
})
