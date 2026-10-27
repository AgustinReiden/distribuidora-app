import '@testing-library/jest-dom/vitest'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import ModalHistorialPedido, { type HistorialCambio } from '../ModalHistorialPedido'
import { formatPrecio } from '../../../utils/formatters'
import type { PedidoDB } from '../../../types'

const pedido = { id: 1234 } as unknown as PedidoDB

function renderModal(historial: HistorialCambio[]) {
  return render(
    <ModalHistorialPedido pedido={pedido} historial={historial} loading={false} onClose={vi.fn()} />
  )
}

// #1231: actualizar_pedido_items y cambiar_cliente_pedido anotan el cargo de
// envío ('0.00' -> '500.00') y su estado ('gratis' -> 'bonificado').
describe('ModalHistorialPedido: cargo de envío (#1231)', () => {
  it('muestra el cargo como precio y el estado con su nombre', () => {
    renderModal([
      { campo_modificado: 'cargo_envio', valor_anterior: '0.00', valor_nuevo: '500.00', usuario: { nombre: 'Ana' } },
      { campo_modificado: 'cargo_envio_estado', valor_anterior: 'gratis', valor_nuevo: 'bonificado', usuario: { nombre: 'Ana' } },
    ])
    expect(screen.getByText('Cargo de envío')).toBeInTheDocument()
    expect(document.body.textContent).toContain(formatPrecio(0))
    expect(document.body.textContent).toContain(formatPrecio(500))
    expect(screen.getByText('Envío')).toBeInTheDocument()
    expect(screen.getByText('Gratis')).toBeInTheDocument()
    expect(screen.getByText('Bonificado')).toBeInTheDocument()
    expect(document.body.textContent).not.toContain('cargo_envio')
    expect(document.body.textContent).not.toContain('500.00')
  })
})
