/** #1697: la etiqueta «Refechado» con la fecha original, y nada cuando no corresponde. */
import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import EtiquetaRefechado from './EtiquetaRefechado'

describe('EtiquetaRefechado', () => {
  it('muestra «Refechado» y la fecha original', () => {
    render(<EtiquetaRefechado pedido={{ estado: 'pendiente', fecha_entrega_programada: '2026-11-26', entrega_refechada_desde: '2026-11-25' }} />)
    const etiqueta = screen.getByTitle('Entrega original: 25/11')
    expect(etiqueta).toHaveTextContent('Refechado')
    expect(etiqueta).toHaveTextContent('antes 25/11')
  })

  it('un pedido sin marca o ya entregado no la muestra', () => {
    const { container, rerender } = render(<EtiquetaRefechado pedido={{ estado: 'pendiente' }} />)
    expect(container).toBeEmptyDOMElement()
    rerender(<EtiquetaRefechado pedido={{ estado: 'entregado', entrega_refechada_desde: '2026-11-25' }} />)
    expect(container).toBeEmptyDOMElement()
  })
})
