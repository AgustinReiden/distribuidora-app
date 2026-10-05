import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import SugerenciasBonificacionBanner from './SugerenciasBonificacionBanner'
import type { SugerenciaBonificacion } from '../../utils/sugerenciasBonificacion'

const sug: SugerenciaBonificacion = {
  promoId: '9', nombre: 'Promo sintética', monto: -1400, base: 'cantidad',
  pesos: { 1: 10, 2: 4, 3: 0 }, lineasAlcance: [1, 2], productoIds: ['a', 'b'],
  esperado: 1400, yaDescontado: 0, explicacion: '14 u. × $100,00 = $1.400,00 (2 líneas)',
}

describe('SugerenciasBonificacionBanner', () => {
  it('sin sugerencias no pinta nada', () => {
    const { container } = render(<SugerenciasBonificacionBanner sugerencias={[]} onAplicar={vi.fn()} onDescartar={vi.fn()} />)
    expect(container).toBeEmptyDOMElement()
  })

  it('dice qué promo, cuánto y en cuántas líneas, y ofrece aplicar o descartar', () => {
    const onAplicar = vi.fn()
    const onDescartar = vi.fn()
    render(<SugerenciasBonificacionBanner sugerencias={[sug]} onAplicar={onAplicar} onDescartar={onDescartar} />)
    expect(screen.getByText(/Promo sintética: el proveedor no descontó .*1\.400.* en 2 líneas/)).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Aplicar' }))
    expect(onAplicar).toHaveBeenCalledWith(sug)
    fireEvent.click(screen.getByRole('button', { name: 'Descartar' }))
    expect(onDescartar).toHaveBeenCalledWith(sug)
  })
})
