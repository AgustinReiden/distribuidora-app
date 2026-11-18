/**
 * B20 (D17): las metas del mes son plata. Antes se borraba todo menos dígitos, punto y menos, así
 * que «1.500,50» quedaba 1,5005 y «20.000.000», sin meta. Ahora los miles los pone el campo, lo
 * pegado se lee como se muestra la plata, y lo que no se entiende no se guarda.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import '@testing-library/jest-dom/vitest'
import ModalMetas from './ModalMetas'

function montar(metas: { venta: number | null; margen_neto: number | null } | null = null) {
  const onGuardar = vi.fn()
  render(
    <ModalMetas
      metas={metas as never}
      periodoLabel="Noviembre 2026"
      sucursalNombre="Sucursal Uno"
      onGuardar={onGuardar}
      onClose={vi.fn()}
    />,
  )
  return onGuardar
}

const guardar = () => screen.getByRole('button', { name: 'Guardar' })

describe('ModalMetas · los montos', () => {
  it('tipear «20000000» se ve «20.000.000» y se guarda 20000000', async () => {
    const onGuardar = montar()
    await userEvent.type(screen.getByLabelText('Venta objetivo'), '20000000')
    await userEvent.type(screen.getByLabelText('Margen neto objetivo'), '6000000.5')
    expect(screen.getByLabelText('Venta objetivo')).toHaveValue('20.000.000')
    expect(screen.getByLabelText('Margen neto objetivo')).toHaveValue('6.000.000,5')
    await userEvent.click(guardar())
    expect(onGuardar).toHaveBeenCalledWith(20000000, 6000000.5)
  })

  it('pegar «1.250,50» se lee 1250,5', async () => {
    const onGuardar = montar()
    await userEvent.click(screen.getByLabelText('Venta objetivo'))
    await userEvent.paste('1.250,50')
    await userEvent.click(guardar())
    expect(onGuardar).toHaveBeenCalledWith(1250.5, null)
  })

  it('precarga con miles', () => {
    montar({ venta: 20000000, margen_neto: 6000000 })
    expect(screen.getByLabelText('Venta objetivo')).toHaveValue('20.000.000')
  })

  it('lo que no se entiende queda en rojo y no se guarda', async () => {
    const onGuardar = montar()
    await userEvent.click(screen.getByLabelText('Venta objetivo'))
    await userEvent.paste('1,234,567')
    expect(screen.getByLabelText('Venta objetivo')).toHaveAttribute('aria-invalid', 'true')
    expect(guardar()).toBeDisabled()
    expect(onGuardar).not.toHaveBeenCalled()
  })
})
